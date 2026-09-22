  // All helpers in this file run on the Core loop. Polling never renews a session.
  std::string panelIdentityGrantVersion(const cJSON* identity) {
    if (!panelIdentityRecordValid(identity)) return {};
    auto canonical = json::obj();
    for (const auto* field : {"credential_ref", "credential_generation", "sip_account_id"})
      json::set(canonical.get(), field, json::getString(identity, field));
    json::setBool(canonical.get(), "revoked", json::getBool(identity, "revoked", true));
    for (const auto* field : {"door_scope", "grants"}) {
      std::set<std::string> sorted;
      const cJSON* item = nullptr;
      cJSON_ArrayForEach(item, json::get(identity, field)) sorted.insert(item->valuestring);
      auto* values = json::addArr(canonical.get(), field);
      for (const auto& value : sorted)
        json::push(values, json::Doc(cJSON_CreateString(value.c_str())));
    }
    return sha256Hex(toBytes(json::dump(canonical.get())));
  }

  PanelCredentialBinding panelIdentityCredentialBinding(const std::string& id) {
    PanelCredentialBinding binding;
    if (!panelIdentityIdValid(id)) return binding;
    const auto* identity = cfgAt("panel.identities." + id);
    if (!panelIdentityRecordValid(identity) || json::getBool(identity, "revoked", true))
      return binding;
    const auto ref = json::getString(identity, "credential_ref");
    const auto secret = secretValue(ref);
    if (secret.empty()) return binding;
    binding.panel_id = id;
    binding.boot_epoch = snapshot_epoch;
    binding.generation = json::getString(identity, "credential_generation");
    binding.grant_version = panelIdentityGrantVersion(identity);
    binding.refs.push_back(ref);
    binding.secret_identity = sha256Hex(toBytes(secret));
    return binding;
  }

  bool panelPrincipalAllowed(const PanelPrincipal& principal, const std::string& door,
                             const std::string& grant) {
    // Only an actual independent identity can cross a node boundary.
    if (principal.legacy_shared || !panelIdentityIdValid(principal.panel_id) ||
        !panelGrantValid(grant)) return false;
    const auto* identity = cfgAt("panel.identities." + principal.panel_id);
    if (!panelIdentityRecordValid(identity) || json::getBool(identity, "revoked", true) ||
        principal.credential_generation != json::getString(identity, "credential_generation") ||
        principal.grant_version != panelIdentityGrantVersion(identity)) return false;
    bool granted = false;
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, json::get(identity, "grants"))
      granted = granted || grant == item->valuestring;
    if (!granted) return false;
    if (grant == "sos.trigger") return door.empty();
    if (door.empty()) return false;
    cJSON_ArrayForEach(item, json::get(identity, "door_scope"))
      if (door == item->valuestring) return true;
    return false;
  }

  bool panelSessionPrincipal(const std::string& session, PanelPrincipal* out) {
    if (!out || panelSessionRemaining(session) <= 0) return false;
    std::lock_guard<std::mutex> lock(sess_mu);
    const auto found = panel_sessions.find(session);
    if (found == panel_sessions.end()) return false;
    const auto& credential = found->second.credential;
    PanelPrincipal principal;
    principal.panel_id = credential.panel_id;
    principal.credential_generation = credential.generation;
    principal.grant_version = credential.grant_version;
    principal.legacy_shared = credential.panel_id.empty();
    *out = std::move(principal);
    return true;
  }

  bool panelSessionAllowed(const std::string& session, const std::string& door,
                           const std::string& grant) {
    PanelPrincipal principal;
    if (!panelSessionPrincipal(session, &principal) || !panelGrantValid(grant)) return false;
    // Local shared sessions retain their explicitly documented compatibility permissions.
    return principal.legacy_shared || panelPrincipalAllowed(principal, door, grant);
  }

  bool panelRequestPrincipal(const HttpReq& request, PanelPrincipal* out) {
    const auto session = request.cookie("dbpanel");
    if (!session.empty()) return panelSessionPrincipal(session, out);
    const auto auth = request.headers.find("authorization");
    if (!out || auth == request.headers.end() || auth->second.rfind("Bearer ", 0) != 0 ||
        !panelCredentialOk(auth->second.substr(7))) return false;
    *out = PanelPrincipal{};
    out->legacy_shared = true;
    return true;
  }

  bool panelRequestAllowed(const HttpReq& request, const std::string& door,
                           const std::string& grant, bool mutation = false,
                           bool interaction = true) {
    PanelPrincipal principal;
    if (!panelRequestPrincipal(request, &principal) || !panelGrantValid(grant)) return false;
    if (principal.legacy_shared) return true;
    if (!panelPrincipalAllowed(principal, door, grant)) return false;
    if (mutation) {
      const auto session = panelMutationSession(request);
      if (session.empty()) return false;
      std::lock_guard<std::mutex> lock(sess_mu);
      const auto found = panel_sessions.find(session);
      if (found == panel_sessions.end()) return false;
      if (interaction) found->second.interactive_mono = clock->monoMs();
    }
    return true;
  }

  bool panelBootstrapBinding(const std::string& candidate, PanelCredentialBinding* out) {
    if (candidate.empty() || candidate.size() > 512 || !out) return false;
    bool matched = false;
    PanelCredentialBinding match;
    const cJSON* identity = nullptr;
    cJSON_ArrayForEach(identity, cfgAt("panel.identities")) {
      const std::string id = identity->string ? identity->string : "";
      const auto binding = panelIdentityCredentialBinding(id);
      if (binding.panel_id.empty()) continue;
      if (constantTimeEqual(candidate, secretValue(binding.refs.front()))) {
        if (matched) return false;  // A credential cannot select between two identities.
        match = binding;
        matched = true;
      }
    }
    if (panelCredentialOk(candidate)) {
      if (matched) return false;
      match = panelCredentialBinding();
      matched = true;
    }
    if (matched) *out = std::move(match);
    return matched;
  }

  void panelIdentityResponse(cJSON* output, const PanelPrincipal& principal) {
    json::setBool(output, "legacy_shared", principal.legacy_shared);
    if (principal.legacy_shared) return;
    json::set(output, "panel_id", principal.panel_id);
    json::set(output, "credential_generation", principal.credential_generation);
    json::set(output, "grant_version", principal.grant_version);
    auto* capabilities = json::addObj(output, "capabilities");
    json::setBool(capabilities, "scoped_push", false);
    json::setBool(capabilities, "scoped_ui_report", false);
    const auto* identity = cfgAt("panel.identities." + principal.panel_id);
    for (const auto* field : {"door_scope", "grants"})
      json::setItem(output, field, json::Doc(cJSON_Duplicate(json::get(identity, field), 1)));
  }

  bool panelIdentitySipConfigured(const std::string& id) {
    const auto* identity = cfgAt("panel.identities." + id);
    const auto account_id = json::getString(identity, "sip_account_id");
    if (!panelIdentityIdValid(account_id) || cfgAt("devices." + account_id)) return false;
    const auto* account = cfgAt("sip.accounts." + account_id);
    const auto user = json::getString(account, "user");
    const auto ref = json::getString(account, "pass_ref");
    if (user.empty() || !secretRefValid(ref) || secretValue(ref).empty() ||
        user == json::getString(cfgAt("integrations.webrtc"), "sip_user")) return false;
    const cJSON* other = nullptr;
    cJSON_ArrayForEach(other, cfgAt("panel.identities")) {
      if (other->string && id != other->string && !json::getBool(other, "revoked", true) &&
          json::getString(other, "sip_account_id") == account_id) return false;
    }
    cJSON_ArrayForEach(other, cfgAt("sip.accounts")) {
      if (other->string && account_id != other->string &&
          user == json::getString(other, "user")) return false;
    }
    return true;
  }

  std::string panelCallSeenKey(const std::string& id, const std::string& door) {
    return "panel.call_seen." + id + "." + door;
  }

  std::vector<Store::CallLogRow> panelCallLogRows(const PanelPrincipal& principal,
                                                const Store::CallLogQuery& query) {
    std::vector<Store::CallLogRow> rows;
    const auto* identity = cfgAt("panel.identities." + principal.panel_id);
    const cJSON* door = nullptr;
    cJSON_ArrayForEach(door, json::get(identity, "door_scope")) {
      const std::string id = door->valuestring;
      if ((!query.door.empty() && query.door != id) ||
          !panelPrincipalAllowed(principal, id, "view")) continue;
      auto scoped = query;
      scoped.door = id;
      auto found = store.callLog(scoped);
      const auto seen = store.metaGet(panelCallSeenKey(principal.panel_id, id)).value_or("");
      for (auto& row : found) {
        row.seen = row.updated_hlc <= seen;
        rows.push_back(std::move(row));
      }
    }
    std::sort(rows.begin(), rows.end(), [](const auto& a, const auto& b) {
      return std::tie(a.ts, a.id) > std::tie(b.ts, b.id);
    });
    if (rows.size() > query.limit) rows.resize(query.limit);
    return rows;
  }

  std::string panelCallLogJson(const PanelPrincipal& principal, const Store::CallLogQuery& query) {
    auto result = json::obj();
    auto* rows = json::addArr(result.get(), "rows");
    int64_t unread = 0;
    for (const auto& row : panelCallLogRows(principal, query)) {
      if (!row.seen && row.outcome == "missed") ++unread;
      json::push(rows, callLogRowJson(row));
    }
    json::set(result.get(), "unread_missed", unread);
    json::set(result.get(), "unread_scope", "returned_page");
    json::set(result.get(), "seen_hlc", "");
    json::set(result.get(), "server_ts", hlc->correctedWallMs());
    return json::dump(result.get());
  }

  bool panelMarkCallLogSeen(const PanelPrincipal& principal, const std::string& up_to) {
    if (up_to.size() > 128) return false;
    Store::CallLogQuery query;
    query.limit = kCallLogMaxLimit;
    std::map<std::string, std::string> maxima;
    for (const auto& row : panelCallLogRows(principal, query)) {
      if (!up_to.empty() && row.updated_hlc > up_to) continue;
      maxima[row.door] = std::max(maxima[row.door], row.updated_hlc);
    }
    std::vector<std::pair<std::string, std::string>> updates;
    for (const auto& entry : maxima) {
      const auto key = panelCallSeenKey(principal.panel_id, entry.first);
      updates.push_back({key, std::max(entry.second, store.metaGet(key).value_or(""))});
    }
    return updates.empty() || store.metaSetBatch(updates);
  }

  std::string panelIdentityJsonOnLoop(const std::string& action, const std::string& request,
      const std::string& session, const std::string& csrf, int* status = nullptr) {
    auto fail = [&](int code, const std::string& error) {
      if (status) *status = code;
      auto result = json::obj();
      json::setBool(result.get(), "ok", false);
      json::set(result.get(), "error_code", error);
      return json::dump(result.get());
    };
    if (status) *status = 200;
    if (!started || !config) return fail(503, "not_started");
    const auto expected_csrf = sessions.csrfToken(session, clock->monoMs());
    if (csrf.empty() || expected_csrf.empty() || !constantTimeEqual(csrf, expected_csrf))
      return fail(403, "permission_denied");
    if (request.size() > 16384 || request.find('\0') != std::string::npos ||
        request.find("\\u0000") != std::string::npos) return fail(400, "invalid_request");
    auto body = configImportParse(request);
    if (!cJSON_IsObject(body.get())) return fail(400, "invalid_request");
    std::set<std::string> fields;
    const cJSON* field = nullptr;
    cJSON_ArrayForEach(field, body.get()) {
      const std::string name = field->string ? field->string : "";
      if (!fields.insert(name).second || (name != "panel_id" && name != "expected_revision" &&
          name != "credential_ref" && name != "door_scope" && name != "grants" &&
          name != "sip_account_id")) return fail(400, "invalid_request");
      if (name != "panel_id" && name != "expected_revision" &&
          !panelIdentityFieldValid(name, field)) return fail(400, "invalid_request");
      if ((name == "panel_id" || name == "expected_revision") && !cJSON_IsString(field))
        return fail(400, "invalid_request");
    }
    if (action == "list") {
      if (!fields.empty()) return fail(400, "invalid_request");
      auto result = json::obj();
      json::setBool(result.get(), "ok", true);
      json::set(result.get(), "revision", configurationRevisionOnLoop());
      auto* records = json::addArr(result.get(), "panels");
      const cJSON* identity = nullptr;
      cJSON_ArrayForEach(identity, cfgAt("panel.identities")) {
        if (!identity->string || !panelIdentityRecordValid(identity)) continue;
        auto copy = json::Doc(cJSON_Duplicate(identity, 1));
        json::set(copy.get(), "panel_id", identity->string);
        json::set(copy.get(), "provisioning_status", panelIdentitySipConfigured(identity->string)
            ? "configured" : "provisioning_required");
        json::push(records, std::move(copy));
      }
      return json::dump(result.get());
    }
    if (action != "create" && action != "update" && action != "revoke" && action != "rotate")
      return fail(400, "invalid_request");
    const auto revision = json::getString(body.get(), "expected_revision");
    if (revision.empty()) return fail(400, "revision_required");
    if (revision != configurationRevisionOnLoop()) return fail(409, "config_conflict");
    std::string id = json::getString(body.get(), "panel_id");
    json::Doc identity;
    if (action == "create") {
      if (fields.count("panel_id")) return fail(400, "invalid_request");
      if (cJSON_GetArraySize(cfgAt("panel.identities")) >= 128)
        return fail(409, "capacity_exceeded");
      id = genTokenHex(16);
      identity = json::obj();
      json::set(identity.get(), "credential_generation", genTokenHex(16));
      json::setBool(identity.get(), "revoked", false);
      json::addArr(identity.get(), "door_scope");
      json::addArr(identity.get(), "grants");
    } else {
      if (!panelIdentityIdValid(id) || !panelIdentityRecordValid(cfgAt("panel.identities." + id)))
        return fail(404, "unknown_panel");
      identity = json::Doc(cJSON_Duplicate(cfgAt("panel.identities." + id), 1));
    }
    if (action == "revoke") {
      if (fields.size() != 2) return fail(400, "invalid_request");
      json::setBool(identity.get(), "revoked", true);
    } else {
      for (const auto* name : {"credential_ref", "door_scope", "grants", "sip_account_id"}) {
        if (const auto* value = json::get(body.get(), name))
          json::setItem(identity.get(), name, json::Doc(cJSON_Duplicate(value, 1)));
      }
      if (action == "rotate" && !json::get(body.get(), "credential_ref"))
        return fail(400, "credential_ref_required");
      const auto ref = json::getString(identity.get(), "credential_ref");
      // Provision through the existing secure-store API; no bearer enters config or this response.
      if (!secretRefValid(ref) || secretValue(ref).empty())
        return fail(409, "credential_provisioning_required");
      const cJSON* other = nullptr;
      cJSON_ArrayForEach(other, cfgAt("panel.identities")) {
        if (other->string && id != other->string && (json::getString(other, "credential_ref") == ref ||
            constantTimeEqual(secretValue(ref), secretValue(json::getString(other, "credential_ref")))))
          return fail(409, "credential_in_use");
      }
      for (const auto& shared : panelSecretRefs())
        if (shared == ref || constantTimeEqual(secretValue(ref), secretValue(shared)))
          return fail(409, "credential_in_use");
    }
    if (action != "create") json::set(identity.get(), "credential_generation", genTokenHex(16));
    if (!panelIdentityRecordValid(identity.get())) return fail(400, "invalid_request");
    auto commit = json::obj();
    json::set(commit.get(), "schema_version", int64_t{2});
    json::set(commit.get(), "expected_revision", revision);
    auto* op = json::pushObj(json::addArr(commit.get(), "ops"));
    json::set(op, "op", "set");
    json::set(op, "key", "panel.identities." + id);
    json::setItem(op, "value", std::move(identity));
    auto result = json::parse(configCommitJsonOnLoop(json::dump(commit.get()), status));
    if (result && json::getBool(result.get(), "ok")) {
      json::set(result.get(), "panel_id", id);
      json::set(result.get(), "provisioning_status", panelIdentitySipConfigured(id)
          ? "configured" : "provisioning_required");
    }
    return json::dump(result.get());
  }
