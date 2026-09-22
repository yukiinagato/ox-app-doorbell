  // These methods are part of Node::Impl. All configuration, Store and mesh access is on loop.
  static json::Doc operationBody(const std::string& text) {
    if (text.empty() || text.size() > 8192 || text.find('\0') != std::string::npos ||
        text.find("\\u0000") != std::string::npos) return {};
    int depth = 0;
    bool quote = false, escape = false;
    for (char c : text) {
      if (quote) {
        if (escape) escape = false;
        else if (c == '\\') escape = true;
        else if (c == '"') quote = false;
      } else if (c == '"') quote = true;
      else if (c == '{' || c == '[') { if (++depth > 8) return {}; }
      else if (c == '}' || c == ']') --depth;
    }
    json::Doc body(cJSON_ParseWithOpts(text.c_str(), nullptr, 1));
    if (!body || !cJSON_IsObject(body.get())) return {};
    std::set<std::string> fields;
    const cJSON* field = nullptr;
    cJSON_ArrayForEach(field, body.get()) {
      const std::string key = field->string ? field->string : "";
      if (!fields.insert(key).second ||
          (key != "schema_version" && key != "request_id" && key != "operation_id" &&
           key != "authority_node" && key != "action" && key != "door" && key != "parameters"))
        return {};
      if (key != "parameters" && key != "schema_version" && !cJSON_IsString(field)) return {};
    }
    const cJSON* version = json::get(body.get(), "schema_version");
    if (!cJSON_IsNumber(version) || version->valuedouble != 2) return {};
    const std::string request_id = json::getString(body.get(), "request_id");
    if (!request_id.empty() && !operationIdValid(request_id)) return {};
    if (request_id.empty()) json::set(body.get(), "request_id", genTokenHex(16));
    const std::string action = json::getString(body.get(), "action");
    const std::string door = json::getString(body.get(), "door");
    if (action != "door_open" && action != "sos_start" && action != "sos_clear") return {};
    if (action == "door_open" ? !operationDoorValid(door) : !door.empty()) return {};
    const cJSON* parameters = json::get(body.get(), "parameters");
    if (parameters && (!cJSON_IsObject(parameters) || parameters->child)) return {};
    return body;
  }

  std::string operationAuthority(const cJSON* body) {
    return json::getString(cfgAt(json::getString(body, "action") == "door_open"
        ? "doors." + json::getString(body, "door") + ".operations" : "cluster.operations"),
        json::getString(body, "action") == "door_open" ? "authority_node" : "sos_authority_node");
  }

  bool operationAllowed(const std::string& peer, const OperationRequest& request) {
    const cJSON* grants = cfgAt("devices." + peer + ".operations");
    std::string error;
    if (!cJSON_IsObject(grants) ||
        !operationConfigValid("devices." + peer + ".operations", grants, &error)) return false;
    if (request.action == "sos_start" || request.action == "sos_clear")
      return json::getBool(grants, request.action.c_str(), false);
    const cJSON* doors = json::get(grants, "doors");
    const cJSON* door = nullptr;
    cJSON_ArrayForEach(door, doors) {
      if (cJSON_IsString(door) && request.door == door->valuestring) return true;
    }
    return false;
  }

  std::string operationGrantVersion(const std::string& peer) {
    const std::string path = "devices." + peer;
    auto identity = json::arr();
    for (const auto& entry : config->all()) {
      if (entry.key != "devices" && entry.key != path && entry.key != path + ".operations" &&
          entry.key.rfind(path + ".operations.", 0) != 0) continue;
      cJSON* item = json::pushObj(identity.get());
      json::set(item, "key", entry.key);
      json::set(item, "hlc", entry.hlc);
      json::set(item, "author", entry.author);
      json::set(item, "seq", std::to_string(entry.seq));
      json::setBool(item, "deleted", entry.deleted);
    }
    return sha256Hex(toBytes(json::dump(identity.get())));
  }

  std::string operationCredential(const std::string& kind) {
    if (kind == "panel") {
      auto identity = json::arr();
      for (const auto& entry : config->all()) {
        if (entry.key != "panel" && entry.key != "panel.token_refs" &&
            entry.key != "panel.token_generation") continue;
        auto* record = json::pushObj(identity.get());
        json::set(record, "key", entry.key);
        json::set(record, "hlc", entry.hlc);
        json::set(record, "author", entry.author);
        json::set(record, "seq", std::to_string(entry.seq));
        json::setBool(record, "deleted", entry.deleted);
      }
      return sha256Hex(toBytes(json::dump(identity.get())));
    }
    const auto& psk = mesh ? mesh->settings().psk : opts.psk;
    return kind == "admin" ? adminCredentialVersionOnLoop()
        : sha256Hex(Bytes(psk.begin(), psk.end()));
  }

  std::string operationCurrentBinding() {
    const auto mqtt = cfgAt("integrations.mqtt");
    const auto port = json::getInt(mqtt, "port", 1883);
    if (port < 1 || port > 65535) return {};
    return HaBridge::operationBinding(json::getString(mqtt, "host"), static_cast<uint16_t>(port),
        json::getString(mqtt, "base_topic", "doorbell"));
  }

  void forgetOperationFeedback(const std::string& id) {
    auto watch = operation_feedback.find(id);
    if (watch == operation_feedback.end()) return;
    if (watch->second.timer) loop->cancelQueued(watch->second.timer);
    operation_feedback.erase(watch);
  }

  void watchOperationFeedback(const std::string& id, bool acknowledgement) {
    if (operation_feedback_stopped) return;
    OperationFeedback watch;
    if (acknowledgement) {
      std::weak_ptr<char> lifetime = alive;
      watch.timer = loop->postDelayed(4000, [this, lifetime, id] {
        if (!lifetime.lock() || operation_feedback_stopped) return;
        auto found = operation_feedback.find(id);
        if (found == operation_feedback.end()) return;
        operation_feedback.erase(found);
        store.operationMarkUnknown(id, "{\"unknown_reason\":\"ack_unavailable\"}", hlc->correctedWallMs());
      });
    }
    operation_feedback.emplace(id, watch);
  }

  void sweepOperationDisconnect() {
    operation_feedback_sweep = 0;
    if (operation_feedback_stopped) return;
    size_t count = 0;
    for (auto it = operation_feedback.begin(); it != operation_feedback.end() && count < 32;) {
      if (!it->second.disconnected) { ++it; continue; }
      store.operationMarkUnknown(it->first, "{\"unknown_reason\":\"transport_ambiguous\"}", hlc->correctedWallMs());
      it = operation_feedback.erase(it);
      ++count;
    }
    for (const auto& item : operation_feedback) if (item.second.disconnected) {
      std::weak_ptr<char> lifetime = alive;
      operation_feedback_sweep = loop->postDelayed(0, [this, lifetime] {
        if (lifetime.lock()) sweepOperationDisconnect();
      });
      break;
    }
  }

  void onOperationDisconnect() {
    if (operation_feedback_stopped) return;
    for (auto& watch : operation_feedback) {
      watch.second.disconnected = true;
      if (watch.second.timer) loop->cancelQueued(watch.second.timer);
      watch.second.timer = 0;
    }
    if (!operation_feedback.empty() && !operation_feedback_sweep) {
      std::weak_ptr<char> lifetime = alive;
      operation_feedback_sweep = loop->postDelayed(0, [this, lifetime] {
        if (lifetime.lock()) sweepOperationDisconnect();
      });
    }
  }

  void onOperationAck(const std::string& payload) {
    if (operation_feedback_stopped) return;
    OperationAck ack;
    if (!operationAckParse(payload, &ack) || ack.authority != node_id) return;
    const cJSON* operations = cfgAt("doors." + ack.door + ".operations");
    const cJSON* source = json::get(operations, "ack");
    if (json::getString(operations, "authority_node") != node_id || !operationAckConfigValid(source) ||
        json::getString(source, "actuator_id") != ack.actuator ||
        !operationAckVerify(ack, json::getString(source, "public_key"))) return;
    // This internal read is authorized only after verifying the commissioned actuator. It never
    // grants HTTP access or replaces the independent current caller authorization for queries.
    OperationAuthorization internal{"actuator:" + ack.actuator, "verified", "verified", "verified", true, true};
    auto known = store.operationQuery(ack.operation_id, internal, clock->monoMs(), hlc->correctedWallMs());
    if (!known.record || !known.record->dispatch_acquired) return;
    const auto& record = *known.record;
    const auto& intent = record.intent;
    auto target = json::parse(intent.target_json);
    const cJSON* frozen_source = json::get(target.get(), "ack");
    const auto command = json::getString(target.get(), "command");
    const auto binding = json::getString(target.get(), "binding");
    if (record.authority_node != node_id || intent.request.action != "door_open" ||
        intent.request.door != ack.door || intent.actuator_id != ack.actuator ||
        !operationAckConfigValid(frozen_source) ||
        json::getString(frozen_source, "actuator_id") != ack.actuator ||
        json::getString(frozen_source, "public_key") != json::getString(source, "public_key") ||
        json::getString(cfgAt("doors." + ack.door + ".unlock"), "command") != command ||
        operationCurrentBinding() != binding ||
        operationCommandDigest(ack.door, command, binding) != ack.command_digest) return;
    auto result = store.operationAcknowledge(ack.operation_id, node_id, ack.actuator, true,
        "{\"ack_protocol\":\"ed25519-v1\",\"actuator_result\":\"command_processed\",\"physical_state\":\"unconfirmed\"}",
        hlc->correctedWallMs());
    if (result.error_code.empty() && result.record && result.record->state == "actuator_ack")
      forgetOperationFeedback(ack.operation_id);
  }

  HttpResp operationResult(const OperationResult& result, const std::string& request_id,
                           bool query) {
    std::string error = result.error_code;
    int status = 503;
    if (error == "forbidden") { error = "permission_denied"; status = 403; }
    else if (error == "unknown_operation") { error = "operation_not_found"; status = 404; }
    else if (error == "operation_capacity") error = "capacity_exceeded";
    else if (error == "authorization_or_configuration_changed") { error = "config_conflict"; status = 409; }
    else if (error == "idempotency_conflict") status = 409;
    else if (error == "invalid_request") status = 400;
    if (!error.empty()) return operationFailure(error, status, request_id);
    if (!result.record) return operationFailure("outcome_unknown", 503, request_id);
    const auto& record = *result.record;
    auto out = json::obj();
    json::setBool(out.get(), "ok", true);
    json::set(out.get(), "schema_version", int64_t{2});
    json::set(out.get(), "request_id", request_id);
    json::set(out.get(), "operation_id", record.operation_id);
    json::set(out.get(), "authority_node", record.authority_node);
    json::set(out.get(), "execution_state", record.state);
    json::set(out.get(), "config_generation", record.config_generation);
    const bool active = record.state == "accepted" || record.state == "dispatching" ||
                        record.state == "dispatched" || record.state == "unknown_after_dispatch";
    json::set(out.get(), "retry_mode", record.state == "prepared" ? "same_operation_execute"
        : active ? "same_operation_query" : "none");
    if (record.state == "prepared") json::set(out.get(), "prepared_remaining_ms",
        std::max(int64_t{0}, std::min(kOperationPreparedMs, record.expires_mono_ms - clock->monoMs())));
    if (record.state == "unknown_after_dispatch") {
      auto details = json::parse(record.result_json);
      const auto reason = json::getString(details.get(), "unknown_reason");
      json::set(out.get(), "unknown_reason", reason == "ack_unavailable" ? reason : "transport_ambiguous");
    }
    else if (record.state == "dispatched") json::set(out.get(), "unknown_reason", "ack_unavailable");
    if (record.state == "actuator_ack") json::set(out.get(), "actuator_result", "command_processed");
    if (record.intent.request.action == "door_open") json::set(out.get(), "physical_state", "unconfirmed");
    return HttpResp::json(json::dump(out.get()), query || !active ? 200 : 202);
  }

  HttpResp operationAtAuthority(const std::string& verb, const cJSON* body,
                                const std::string& peer, const std::string& kind,
                                const std::string& credential, const std::string& grant,
                                const std::string& subject = "", const PanelPrincipal* principal = nullptr) {
    const std::string request_id = json::getString(body, "request_id");
    OperationRequest request{json::getString(body, "action"), json::getString(body, "door"), "{}"};
    const bool subject_valid = subject.size() == 64 &&
        subject.find_first_not_of("0123456789abcdef") == std::string::npos;
    const bool independent_panel = kind == "panel_identity" && principal && subject_valid &&
        !principal->legacy_shared && credential == principal->credential_generation &&
        (request.action == "door_open" || request.action == "sos_start") &&
        panelPrincipalAllowed(*principal, request.door,
            request.action == "door_open" ? "door.open" : "sos.trigger");
    const bool panel_subject = independent_panel ||
        (kind == "panel" && request.action == "sos_start" && subject_valid);
    if (!operationIdValid(peer) ||
        (kind != "native" && kind != "admin" && !panel_subject) ||
        (!panel_subject && !subject.empty()) ||
        credential.empty() || (!independent_panel && credential != operationCredential(kind)) ||
        grant != operationGrantVersion(peer) || !operationAllowed(peer, request))
      return operationFailure("permission_denied", 403, request_id);
    const auto authority = operationAuthority(body);
    if (authority != node_id || json::getString(body, "authority_node") != node_id)
      return operationFailure("authority_unavailable", 503, request_id);
    const std::string operation_principal = independent_panel
        ? "panel_identity:" + sha256Hex(toBytes(peer + ":" + principal->panel_id + ":" + subject))
        : kind + ":" + peer + (panel_subject ? ":" + subject : "");
    OperationAuthorization auth{operation_principal,
        credential, independent_panel ? sha256Hex(toBytes(grant + ":" + principal->grant_version)) : grant,
        configurationRevisionOnLoop(), true, kind == "admin"};
    const auto now = clock->monoMs();
    const auto wall = hlc->correctedWallMs();
    if (verb == "prepare") {
      OperationIntent intent;
      intent.request = request;
      if (request.action == "door_open") {
        const std::string command = json::getString(cfgAt("doors." + request.door + ".unlock"), "command");
        if (!simpleIdValid(command, 32)) return operationFailure("unsupported_capability", 501, request_id);
        auto target = json::obj();
        json::set(target.get(), "command", command);
        const auto mqtt = cfgAt("integrations.mqtt");
        const auto port = json::getInt(mqtt, "port", 1883);
        if (port < 1 || port > 65535) return operationFailure("unsupported_capability", 501, request_id);
        json::set(target.get(), "binding", HaBridge::operationBinding(
            json::getString(mqtt, "host"), static_cast<uint16_t>(port),
            json::getString(mqtt, "base_topic", "doorbell")));
        const auto ack = cfgAt("doors." + request.door + ".operations.ack");
        intent.actuator_id = command;
        if (operationAckConfigValid(ack)) {
          json::setItem(target.get(), "ack", json::Doc(cJSON_Duplicate(ack, 1)));
          intent.actuator_id = json::getString(ack, "actuator_id");
        }
        intent.target_json = json::dump(target.get());
      }
      return operationResult(store.operationPrepare(intent, auth, now, wall), request_id, false);
    }
    const std::string id = json::getString(body, "operation_id");
    auto known = store.operationQuery(id, auth, now, wall);
    if (!known.record) return operationResult(known, request_id, true);
    // The caller's supplied scope is only a lookup/routing hint. Never release a record before
    // checking the actual stored target against the caller's current permissions.
    if (!operationAllowed(peer, known.record->intent.request))
      return operationFailure("permission_denied", 403, request_id);
    if (known.record->intent.request.action != request.action || known.record->intent.request.door != request.door)
      return operationFailure("idempotency_conflict", 409, request_id);
    if (verb == "query") return operationResult(known, request_id, true);
    auto accepted = store.operationAccept(id, auth, now, wall, request);
    if (!accepted.error_code.empty()) return operationResult(accepted, request_id, false);
    if (!accepted.record || accepted.record->state != "accepted")
      return operationResult(accepted, request_id, false);
    // Preflight only establishes availability. The committed acquisition remains the sole
    // permission to call the adapter; a disconnect after it is conservatively unknown.
    auto target = json::parse(accepted.record->intent.target_json);
    if (request.action == "door_open" && (!bridge ||
        !bridge->operationReady(json::getString(target.get(), "binding")))) {
      store.operationReject(id, "authority_unavailable", wall);
      return operationFailure("authority_unavailable", 503, request_id);
    }
    if (request.action == "door_open" && operation_feedback.size() >= kOperationActiveLimit) {
      store.operationReject(id, "capacity_exceeded", wall);
      return operationFailure("capacity_exceeded", 503, request_id);
    }
    auto dispatch = store.operationAcquireDispatch(id, auth, now, wall, request);
    if (!dispatch.dispatch_acquired) return operationResult(dispatch, request_id, false);
    bool sent = false;
    if (request.action == "door_open") {
      sent = bridge->dispatchOperation(request.door, json::getString(target.get(), "command"),
          id, node_id, json::getString(target.get(), "binding"),
          operationAckConfigValid(json::get(target.get(), "ack")) ? accepted.record->intent.actuator_id : "",
          operationCommandDigest(request.door, json::getString(target.get(), "command"),
                                 json::getString(target.get(), "binding")));
    } else {
      auto payload = json::obj();
      json::set(payload.get(), "operation_id", id);
      json::set(payload.get(), "authority_node", node_id);
      json::set(payload.get(), "via", "operation");
      json::set(payload.get(), "source", peer);
      sent = events->append(request.action == "sos_start" ? "emergency" : "emergency_cancel",
                            "", node_id, json::dump(payload.get())).seq != 0;
    }
    if (sent) {
      store.operationMarkDispatched(id, "{\"adapter_accepted\":true}", wall);
      if (request.action == "door_open")
        watchOperationFeedback(id, operationAckConfigValid(json::get(target.get(), "ack")));
    }
    else store.operationMarkUnknown(id, "{\"error_code\":\"outcome_unknown\"}", wall);
    return operationResult(store.operationQuery(id, auth, now, wall), request_id, false);
  }

  void operationRequestOnLoop(const HttpReq& req, const OperationDispatcher::Complete& complete) {
    const bool native = req.method == "NATIVE";
    const std::string prefix = "/api/operations/";
    std::string verb = native ? req.uri : req.uri == prefix + "prepare" ? "prepare"
        : req.method == "GET" ? "query" : "execute";
    auto body = operationBody(req.body);
    if (!body) { complete(operationFailure("invalid_request", 400)); return; }
    const std::string request_id = json::getString(body.get(), "request_id");
    if (verb != "prepare" && verb != "execute" && verb != "query") {
      complete(operationFailure("invalid_request", 400, request_id)); return;
    }
    std::string panel_session;
    if (!native) {
      const auto csrf_header = req.headers.find("x-doorbell-csrf");
      const auto supplied_panel = req.cookie("dbpanel");
      const bool panel_intent = csrf_header != req.headers.end() && !csrf_header->second.empty() &&
          panelSessionRemaining(supplied_panel, csrf_header->second) > 0;
      const bool administrator = !panel_intent && checkSession(req);
      if (!administrator) {
        panel_session = req.cookie("dbpanel");
        if (panelSessionRemaining(panel_session) <= 0) {
          complete(operationFailure("auth_required", 401, request_id)); return;
        }
        const auto csrf = req.headers.find("x-doorbell-csrf");
        const bool origin_required = req.method != "GET" || req.headers.count("origin") != 0;
        PanelPrincipal principal;
        const auto action = json::getString(body.get(), "action");
        const auto door = json::getString(body.get(), "door");
        const bool allowed = panelSessionPrincipal(panel_session, &principal) &&
            (principal.legacy_shared ? action == "sos_start" :
             (action == "door_open" || action == "sos_start") && panelSessionAllowed(panel_session,
                 door, action == "door_open" ? "door.open" : "sos.trigger"));
        if (!allowed ||
            (origin_required && !trustedWebOrigin(req)) || csrf == req.headers.end() ||
            csrf->second.empty() || panelSessionRemaining(panel_session, csrf->second) <= 0) {
          complete(operationFailure("permission_denied", 403, request_id)); return;
        }
      } else if (req.method != "GET") {
        const auto csrf = req.headers.find("x-doorbell-csrf");
        if (!trustedWebOrigin(req) || csrf == req.headers.end() || csrf->second.empty() ||
            csrf->second != sessions.csrfToken(req.cookie("dbsess"), clock->monoMs())) {
          complete(operationFailure("permission_denied", 403, request_id)); return;
        }
      }
    }
    if (verb != "prepare") {
      const auto id = json::getString(body.get(), "operation_id");
      const std::string expected = prefix + id + (verb == "execute" ? "/execute" : "");
      if (!operationIdValid(id) || (!native && req.uri != expected)) {
        complete(operationFailure("invalid_request", 400, request_id)); return;
      }
    } else if (json::get(body.get(), "operation_id")) {
      complete(operationFailure("invalid_request", 400, request_id)); return;
    }
    const std::string authority = operationAuthority(body.get());
    const std::string supplied = json::getString(body.get(), "authority_node");
    if (!operationIdValid(authority) || (verb != "prepare" && supplied.empty()) ||
        (!supplied.empty() && supplied != authority)) {
      complete(operationFailure("authority_unavailable", 503, request_id)); return;
    }
    json::set(body.get(), "authority_node", authority);
    PanelPrincipal panel_principal;
    const bool independent_panel = !panel_session.empty() &&
        panelSessionPrincipal(panel_session, &panel_principal) && !panel_principal.legacy_shared;
    const std::string kind = native ? "native" : panel_session.empty() ? "admin" :
        independent_panel ? "panel_identity" : "panel";
    const std::string subject = panel_session.empty() ? "" : sha256Hex(toBytes(panel_session));
    OperationRequest request{json::getString(body.get(), "action"), json::getString(body.get(), "door"), "{}"};
    if (!operationAllowed(node_id, request)) {
      complete(operationFailure("permission_denied", 403, request_id)); return;
    }
    const auto credential = independent_panel ? panel_principal.credential_generation : operationCredential(kind);
    const auto grant = operationGrantVersion(node_id);
    if (authority == node_id) {
      complete(operationAtAuthority(verb, body.get(), node_id, kind, credential, grant, subject,
          independent_panel ? &panel_principal : nullptr)); return;
    }
    bool connected = false;
    bool supported = false;
    if (mesh) for (const auto& peer : mesh->peers()) {
      if (peer.id != authority) continue;
      connected = peer.connected && peer.status == "alive";
      supported = advertisedFeature(peer.caps_json, "operations_v1");
    }
    if (!connected) { complete(operationFailure("authority_unavailable", 503, request_id)); return; }
    if (!supported) { complete(operationFailure("unsupported_capability", 501, request_id)); return; }
    if (operation_forwards.size() >= OperationDispatcher::kCapacity) {
      complete(operationFailure("capacity_exceeded", 503, request_id)); return;
    }
    const std::string rpc = genTokenHex(16);
    auto command = json::obj();
    json::set(command.get(), "cmd", "operation_request_v1");
    json::set(command.get(), "rpc", rpc);
    json::set(command.get(), "verb", verb);
    json::set(command.get(), "auth_type", kind);
    if (!subject.empty()) json::set(command.get(), "subject", subject);
    if (independent_panel) {
      json::set(command.get(), "panel_id", panel_principal.panel_id);
      json::set(command.get(), "panel_grant_version", panel_principal.grant_version);
    }
    json::set(command.get(), "credential_version", credential);
    json::set(command.get(), "grant_version", grant);
    json::setItem(command.get(), "body", std::move(body));
    OperationForward forward{authority, complete, 0};
    forward.timer = loop->postDelayed(OperationDispatcher::kTimeoutMs, [this, rpc, request_id] {
      auto found = operation_forwards.find(rpc);
      if (found == operation_forwards.end()) return;
      auto complete = std::move(found->second.complete);
      operation_forwards.erase(found);
      complete(operationFailure("outcome_unknown", 503, request_id));
    });
    operation_forwards.emplace(rpc, std::move(forward));
    mesh->sendCommand(authority, json::dump(command.get()));
  }

  void onOperationCommand(const std::string& from, const cJSON* command) {
    const auto rpc = json::getString(command, "rpc");
    if (!operationIdValid(rpc)) return;
    if (json::getString(command, "cmd") == "operation_response_v1") {
      auto pending = operation_forwards.find(rpc);
      if (pending == operation_forwards.end() || pending->second.authority != from) return;
      const int status = static_cast<int>(json::getInt(command, "status"));
      const cJSON* body = json::get(command, "body");
      if (status < 200 || status > 599 || !cJSON_IsObject(body)) return;
      auto complete = std::move(pending->second.complete);
      loop->cancelQueued(pending->second.timer);
      operation_forwards.erase(pending);
      complete(HttpResp::json(json::dump(body), status));
      return;
    }
    auto body = operationBody(json::dump(json::get(command, "body")));
    const auto verb = json::getString(command, "verb");
    if (!body || (verb != "prepare" && verb != "execute" && verb != "query")) return;
    if (verb != "prepare" && !operationIdValid(json::getString(body.get(), "operation_id"))) return;
    // SecureChannel supplies 'from'; a request field can never select the initiating device.
    PanelPrincipal principal;
    principal.panel_id = json::getString(command, "panel_id");
    principal.credential_generation = json::getString(command, "credential_version");
    principal.grant_version = json::getString(command, "panel_grant_version");
    const auto kind = json::getString(command, "auth_type");
    const auto result = operationAtAuthority(verb, body.get(), from, kind,
        json::getString(command, "credential_version"), json::getString(command, "grant_version"),
        json::getString(command, "subject"), kind == "panel_identity" ? &principal : nullptr);
    auto reply = json::obj();
    json::set(reply.get(), "cmd", "operation_response_v1");
    json::set(reply.get(), "rpc", rpc);
    json::set(reply.get(), "status", static_cast<int64_t>(result.status));
    json::setItem(reply.get(), "body", json::parse(result.body));
    mesh->sendCommand(from, json::dump(reply.get()));
  }

  void stopOperationsOnLoop() {
    operation_feedback_stopped = true;
    for (const auto& watch : operation_feedback) if (watch.second.timer) loop->cancelQueued(watch.second.timer);
    operation_feedback.clear();
    if (operation_feedback_sweep) loop->cancelQueued(operation_feedback_sweep);
    operation_feedback_sweep = 0;
    if (operation_dispatcher) operation_dispatcher->stop();
    for (const auto& entry : operation_forwards) loop->cancelQueued(entry.second.timer);
    operation_forwards.clear();
  }

  HttpResp operationHttp(const HttpReq& incoming) {
    if (!checkSession(incoming) && !operationIdValid(incoming.cookie("dbpanel")))
      return operationFailure("auth_required", 401);
    HttpReq req = incoming;
    if (req.method == "GET") {
      std::set<std::string> fields;
      size_t offset = 0;
      while (offset < req.query.size()) {
        const auto end = req.query.find('&', offset);
        const auto pair = req.query.substr(offset, end == std::string::npos ? end : end - offset);
        const auto key = pair.substr(0, pair.find('='));
        if (!fields.insert(key).second || (key != "action" && key != "door" &&
            key != "authority_node" && key != "request_id")) return operationFailure("invalid_request", 400);
        if (end == std::string::npos) break;
        offset = end + 1;
      }
      auto body = json::obj();
      json::set(body.get(), "schema_version", int64_t{2});
      json::set(body.get(), "action", req.param("action"));
      json::set(body.get(), "door", req.param("door"));
      json::set(body.get(), "authority_node", req.param("authority_node"));
      json::set(body.get(), "operation_id", req.uri.substr(std::string("/api/operations/").size()));
      const auto id = req.param("request_id");
      if (!id.empty()) json::set(body.get(), "request_id", id);
      req.body = json::dump(body.get());
    }
    if (req.body.size() > 8192) return operationFailure("capacity_exceeded", 413);
    auto normalized = operationBody(req.body);
    if (!normalized) return operationFailure("invalid_request", 400);
    req.body = json::dump(normalized.get());
    auto response = operation_dispatcher->request(std::move(req));
    response.headers["Cache-Control"] = "no-store";
    return response;
  }
