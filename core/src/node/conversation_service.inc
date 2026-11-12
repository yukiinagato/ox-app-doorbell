  static bool conversationProtocolEnabled() {
#ifdef DB_ENABLE_CONVERSATION_V1
    return true;
#else
    return false;
#endif
  }
  bool conversation_external_transport = false;
  std::string conversation_external_signature;
  std::map<std::string, int64_t> deferred_conversations;
  std::map<std::string, Conversation> conversations;
  std::set<std::string> requested_conversations;
  std::set<std::string> failed_conversation_legs;
  std::set<std::string> local_conversation_media;
  std::string conversation_focus;
  std::map<std::string, int64_t> conversation_web_leases;
  std::map<std::string, std::pair<std::string, std::string>> conversation_receipts;
  std::deque<std::string> conversation_receipt_order;

  bool conversationHostSupported(const std::string& door) {
    if (!conversationProtocolEnabled()) return false;
    const auto station = doorStation(door);
    if (station == node_id) return sipBackendAvailable();
    if (!mesh) return false;
    for (const auto& peer : mesh->peers()) if (peer.id == station && peer.status == "alive") {
      auto runtime = json::parse(peer.runtime_json);
      const auto* protocol = json::get(runtime.get(), "conversation");
      return json::getInt(protocol, "schema_version", 0) == 1 && json::getBool(protocol, "enabled");
    }
    return false;
  }

  bool conversationSupported(const std::string& door) {
    return (sipBackendAvailable() || conversation_external_transport) && conversationHostSupported(door);
  }
  static std::string conversationSigner(const std::string& actor) {
    return actor.rfind("web_", 0) == 0 && actor.size() == 69 && actor[36] == '_'
        ? actor.substr(4, 32) : actor;
  }

  static std::string conversationMode(const Conversation& room, const Conversation::Participant& p) {
    return "room:" + room.call_id + ":" + std::to_string(room.stage_revision) + ":" + p.leg;
  }

  void notifyConversationResult(const std::string& request, const std::string& error) {
    auto out = json::obj();
    json::set(out.get(), "t", "conversation_result");
    json::set(out.get(), "request_id", request);
    json::setBool(out.get(), "ok", error.empty());
    json::set(out.get(), "error", error);
    uiNotify(json::dump(out.get()));
  }

  std::string conversationTarget(const std::string& authority) {
    if (!mesh) return "";
    for (const auto& peer : mesh->peers()) if (peer.id == authority && peer.status == "alive") {
      for (const auto& address : peer.addrs) {
        const auto host = hostOf(address);
        if (host.empty()) continue;
        return "sip:" + (host.find(':') == std::string::npos ? host : "[" + host + "]") +
            ":" + std::to_string(sipSettings().direct_port);
      }
    }
    return "";
  }

  void syncConversationMedia() {
    if (!conversationProtocolEnabled()) return;
    std::map<std::string, SipCtl::RoomPolicy> policies;
    std::map<std::string, std::string> admissions;
    std::vector<std::pair<std::string, std::string>> dial;
    std::string focused_mode;
    for (const auto& entry : conversations) {
      const auto& room = entry.second;
      auto call = active_calls.find(room.door);
      if (call == active_calls.end() || call->second.call_id != room.call_id ||
          call->second.stage_revision != room.stage_revision) continue;
      for (const auto& member : room.participants) {
        if (member.second.state == "waiting") continue;
        const auto mode = conversationMode(room, member.second);
        if (failed_conversation_legs.count(mode)) continue;
        if (room.authority == node_id) {
          policies[mode] = SipCtl::RoomPolicy{room.call_id, true, member.second.state == "held"};
          admissions[mode] = conversationSigner(member.first);
        } else if (member.first == node_id && requested_conversations.count(room.call_id)) {
          policies[mode] = SipCtl::RoomPolicy{room.call_id, false, member.second.state == "held"};
          if (conversation_focus == room.call_id) focused_mode = mode;
          if (member.second.state == "dialing" && !failed_conversation_legs.count(mode)) {
            auto target = conversationTarget(room.authority);
            if (!target.empty()) dial.emplace_back(mode, target);
          }
        }
      }
    }
    {
      std::lock_guard<std::mutex> lock(sip_admission->mu);
      sip_admission->rooms = std::move(admissions);
    }
    if (conversation_external_transport && !sipBackendAvailable()) {
      auto transport = json::obj();
      json::set(transport.get(), "t", "conversation_transport");
      auto* sessions = json::addArr(transport.get(), "sessions");
      for (const auto& entry : policies) if (!entry.second.host) {
        auto room = conversations.find(entry.second.room);
        if (room == conversations.end()) continue;
        auto* item = json::pushObj(sessions);
        json::set(item, "mode", entry.first);
        json::set(item, "target", conversationTarget(room->second.authority));
        json::setBool(item, "held", entry.second.held || entry.first != focused_mode);
      }
      const auto signature = json::dump(transport.get());
      if (signature != conversation_external_signature) {
        conversation_external_signature = signature;
        uiNotify(signature);
      }
      return;
    }
    if (!sipctl) return;
    sipctl->setRoomPolicies(policies);
    sipctl->setRoomFocus(focused_mode);
    for (const auto& attempt : dial) if (!sipctl->callRoom(attempt.first, attempt.second)) {
      failed_conversation_legs.insert(attempt.first);
      onConversationMedia(attempt.first, SipCallState::Ended);
    }
  }

  json::Doc conversationPresentation(const Conversation& room) {
    auto out = room.document();
    auto* member = json::get(out.get(), "participants");
    cJSON* item = nullptr;
    cJSON_ArrayForEach(item, member) {
      const auto actor = json::getString(item, "device");
      auto name = json::getString(cfgAt("devices." + actor), "name");
      if (name.empty()) name = labelIn(json::get(cfgAt("devices." + actor), "label"), visitorLangFor(room.door));
      if (!name.empty()) json::set(item, "name", name);
    }
    return out;
  }

  bool conversationLocalMedia(const Conversation& room) const {
    const auto member = room.participants.find(node_id);
    return member != room.participants.end() && local_conversation_media.count(conversationMode(room, member->second));
  }

  bool commitConversation(const Conversation& room) {
    auto payload = room.document();
    return events->append("conversation_state", room.door, node_id, json::dump(payload.get())).seq != 0;
  }

  void applyConversationEvent(const EventRecord& event) {
    auto payload = json::parse(event.payload_json);
    Conversation room;
    if (!Conversation::parse(payload.get(), &room) || event.door != room.door ||
        event.origin != room.authority || room.authority != doorStation(room.door)) return;
    const auto active = active_calls.find(room.door);
    if (active == active_calls.end() || active->second.call_id != room.call_id ||
        active->second.stage_revision != room.stage_revision) return;
    const auto current = conversations.find(room.call_id);
    if (current != conversations.end() && current->second.version >= room.version) return;
    conversations[room.call_id] = room;
    clearRecoveryLease(active->second);
    syncConversationMedia();
    auto out = conversationPresentation(room);
    json::set(out.get(), "t", "conversation");
    uiNotify(json::dump(out.get()));
  }

  void restoreConversations(bool restart = false) {
    for (const auto& event : store.latestConversationStates()) applyConversationEvent(event);
    if (!restart) return;
    std::vector<Conversation> recovered;
    for (const auto& entry : conversations) if (entry.second.authority == node_id) {
      auto next = entry.second;
      for (auto& member : next.participants) if (member.second.state != "waiting") {
        member.second.state = "held";
        member.second.established = false;
        member.second.leg = genTokenHex(16);
      }
      ++next.version;
      recovered.push_back(std::move(next));
    }
    for (const auto& room : recovered) commitConversation(room);
  }

  void maintainConversations() {
    restoreConversations();
    if (!mesh) return;
    std::set<std::string> dead;
    for (const auto& peer : mesh->peers()) if (peer.status == "dead") dead.insert(peer.id);
    std::vector<Conversation> changed;
    for (const auto& entry : conversations) if (entry.second.authority == node_id) {
      auto next = entry.second;
      std::vector<std::string> retired;
      for (const auto& member : next.participants) {
        bool unavailable = dead.count(conversationSigner(member.first)) || cfgAt("removed_devices." + conversationSigner(member.first));
        if (member.first != conversationSigner(member.first)) {
          const auto lease = conversation_web_leases.find(next.call_id + ":" + member.first);
          const auto identity = cfgAt("panel.identities." + member.first.substr(37));
          unavailable = unavailable || lease == conversation_web_leases.end() || lease->second <= clock->monoMs() ||
              json::getBool(identity, "revoked", true);
        }
        if (unavailable) retired.push_back(member.first);
      }
      for (const auto& peer : retired) next.apply(peer, "leave", next.version, "");
      if (!retired.empty()) changed.push_back(std::move(next));
    }
    for (const auto& room : changed) {
      if (!commitConversation(room)) continue;
      const auto call = active_calls.find(room.door);
      if (room.participants.empty() && call != active_calls.end() && call->second.state == "in_call")
        doEndCall(room.door, room.call_id, "conversation_empty");
    }
  }

  std::string conversationAtAuthority(const std::string& sender, const cJSON* command) {
    const auto actor = json::getString(command, "actor", sender.c_str());
    const auto door = json::getString(command, "door");
    const auto id = json::getString(command, "call_id");
    const int revision = static_cast<int>(json::getInt(command, "stage_revision", -1));
    const auto action = json::getString(command, "action");
    const auto active = active_calls.find(door);
    if (doorStation(door) != node_id) return "wrong_authority";
    if (active == active_calls.end() || active->second.call_id != id ||
        active->second.stage_revision != revision ||
        (active->second.state == "ringing" && active->second.expires_wall_ms <= hlc->correctedWallMs()))
      return "stale_call";
    if (action != "respond" && action != "leave" && !sipBackendAvailable()) return "media_unavailable";
    if ((sender != node_id && (!mesh || !mesh->isMember(sender))) || cfgAt("removed_devices." + sender))
      return "permission_denied";
    if (actor != sender) {
      PanelPrincipal principal;
      principal.panel_id = json::getString(command, "panel_id");
      principal.credential_generation = json::getString(command, "credential_generation");
      principal.grant_version = json::getString(command, "grant_version");
      if (actor != "web_" + sender + "_" + principal.panel_id ||
          !panelPrincipalAllowed(principal, door, "call.answer")) return "permission_denied";
    } else if (json::getString(cfgAt("devices." + actor), "role") != "indoor_panel")
      return "permission_denied";
    Conversation room;
    const auto existing = conversations.find(id);
    if (existing != conversations.end()) room = existing->second;
    else {
      if (conversations.size() >= 256) return "capacity";
      // A legacy dialog cannot be silently reclassified as a conference.
      if (active->second.state == "in_call") return "legacy_dialog";
      room.door = door;
      room.call_id = id;
      room.authority = node_id;
      room.stage_revision = revision;
    }
    if (action == "heartbeat") {
      const auto member = room.participants.find(actor);
      if (actor == sender || member == room.participants.end() ||
          member->second.leg != json::getString(command, "leg")) return "stale_call";
      conversation_web_leases[id + ":" + actor] = clock->monoMs() + 15000;
      return "";
    }
    const auto error = room.apply(actor, action, json::getInt(command, "expected_version", -1), genTokenHex(16));
    if (!error.empty()) return error;
    if (!commitConversation(room)) return "persistence_failed";
    if (actor != sender) conversation_web_leases[id + ":" + actor] = clock->monoMs() + 15000;
    if (room.participants.empty() && active->second.state == "in_call")
      doEndCall(door, id, "conversation_empty");
    return "";
  }

  void onConversationCommand(const std::string& from, const cJSON* command) {
    if (!started || !conversationProtocolEnabled()) return;
    const auto kind = json::getString(command, "cmd");
    if (!mesh || !mesh->isMember(from) || cfgAt("removed_devices." + from)) return;
    if (kind == "conversation_media_failed_v1") {
      const auto id = json::getString(command, "call_id");
      const auto found = conversations.find(id);
      if (found == conversations.end() || found->second.authority != node_id) return;
      Conversation next = found->second;
      if (next.media(from, json::getString(command, "leg"), false)) {
        commitConversation(next);
        const auto active = active_calls.find(next.door);
        if (next.participants.empty() && active != active_calls.end() && active->second.state == "in_call")
          doEndCall(next.door, id, "conversation_empty");
      }
      return;
    }
    if (kind == "conversation_result_v1") {
      const auto request = json::getString(command, "request_id");
      auto pending = conversation_receipts.find(request);
      if (pending == conversation_receipts.end() || pending->second.first != from) return;
      const auto error = json::getString(command, "error");
      conversation_receipts.erase(pending);
      notifyConversationResult(request, error);
      return;
    }
    if (kind != "conversation_request_v1") return;
    const auto request = json::getString(command, "request_id");
    if (request.size() != 32 || request.find_first_not_of("0123456789abcdef") != std::string::npos) return;
    const auto key = from + ":" + request;
    const auto body = json::dump(command);
    const auto receipt = conversation_receipts.find(key);
    std::string error;
    if (receipt != conversation_receipts.end())
      error = receipt->second.first == body ? receipt->second.second : "request_conflict";
    else {
      error = conversationAtAuthority(from, command);
      conversation_receipts[key] = {body, error};
      conversation_receipt_order.push_back(key);
      while (conversation_receipt_order.size() > 256) {
        conversation_receipts.erase(conversation_receipt_order.front());
        conversation_receipt_order.pop_front();
      }
    }
    auto response = json::obj();
    json::set(response.get(), "cmd", "conversation_result_v1");
    json::set(response.get(), "request_id", request);
    json::set(response.get(), "error", error);
    if (from == node_id) notifyConversationResult(request, error);
    else mesh->sendCommand(from, json::dump(response.get()));
  }

  void onConversationMedia(const std::string& mode, SipCallState state) {
    if (!started) return;
    if (state == SipCallState::InCall) local_conversation_media.insert(mode);
    else local_conversation_media.erase(mode);
    refreshSnapshots();
    auto transport = json::obj();
    json::set(transport.get(), "t", "conversation_media");
    uiNotify(json::dump(transport.get()));
    for (const auto& entry : conversations) {
      const auto room = entry.second;
      for (const auto& member : room.participants) {
        if (conversationMode(room, member.second) != mode) continue;
        if (room.authority == node_id) {
          Conversation next = room;
          if (!next.media(member.first, member.second.leg, state == SipCallState::InCall)) return;
          // Media, not the answer button or the INVITE, establishes a visitor conversation.
          if (!commitConversation(next)) {
            failed_conversation_legs.insert(mode);
            syncConversationMedia();
            return;
          }
          const auto active = active_calls.find(room.door);
          if (active != active_calls.end() && state == SipCallState::InCall && active->second.state == "ringing")
            doReportCallAnsweredResult(room.door, room.call_id, room.stage_revision, member.first);
          if (active != active_calls.end() && next.participants.empty() && active->second.state == "in_call")
            doEndCall(room.door, room.call_id, "conversation_empty");
        } else if (member.first == node_id && state == SipCallState::Ended && mesh) {
          auto failure = json::obj();
          json::set(failure.get(), "cmd", "conversation_media_failed_v1");
          json::set(failure.get(), "call_id", room.call_id);
          json::set(failure.get(), "leg", member.second.leg);
          mesh->sendCommand(room.authority, json::dump(failure.get()));
        }
        return;
      }
    }
  }

  std::string conversationRequestOnLoop(const std::string& request_json, const std::string& delegated_actor = "") {
    const auto actor = delegated_actor.empty() ? node_id : delegated_actor;
    auto body = json::parse(request_json);
    auto out = json::obj();
    auto fail = [&](const std::string& error) {
      json::setBool(out.get(), "ok", false);
      json::set(out.get(), "error", error);
      return json::dump(out.get());
    };
    if (!conversationProtocolEnabled()) return fail("feature_unavailable");
    if (!body || request_json.size() > 2048) return fail("invalid_request");
    const auto door = json::getString(body.get(), "door");
    const auto id = json::getString(body.get(), "call_id");
    const auto action = json::getString(body.get(), "action");
    if (action == "end" && delegated_actor.empty() && opts.role == "door_station" && door == opts.door && doorStation(door) == node_id) {
      const auto call = active_calls.find(door);
      if (call == active_calls.end() || call->second.call_id != id ||
          call->second.stage_revision != json::getInt(body.get(), "stage_revision", -1)) return fail("stale_call");
      const bool ended = call->second.state == "in_call" ? doEndCall(door, id, "visitor") : doCancelCall(door, id, "visitor");
      json::setBool(out.get(), "ok", ended);
      return json::dump(out.get());
    }
    if (delegated_actor.empty() && opts.role != "indoor_panel") return fail("permission_denied");
    if (actor == node_id && sipctl && sipBackendAvailable() &&
        (action == "answer" || action == "join" || action == "takeover" || action == "resume") &&
        (sipctl->callState() != SipCallState::Idle || sipctl->monitorCount() > 0)) {
      auto request = json::getString(body.get(), "request_id");
      if (request.empty()) { request = genTokenHex(16); json::set(body.get(), "request_id", request); }
      if (deferred_conversations.size() >= 32 && !deferred_conversations.count(request)) return fail("capacity");
      if (!deferred_conversations.count(request)) deferred_conversations[request] = clock->monoMs();
      if (clock->monoMs() - deferred_conversations[request] >= 5000) {
        deferred_conversations.erase(request);
        notifyConversationResult(request, "legacy_dialog_busy");
        return fail("legacy_dialog_busy");
      }
      sipctl->hangup();
      const auto retry = json::dump(body.get());
      std::weak_ptr<char> lifetime = alive;
      loop->postDelayed(50, [this, lifetime, retry] {
        if (lifetime.lock()) conversationRequestOnLoop(retry);
      });
      json::setBool(out.get(), "ok", true);
      json::set(out.get(), "state", "pending");
      json::set(out.get(), "request_id", request);
      return json::dump(out.get());
    }

    if (actor == node_id && (action == "select" || action == "answer" || action == "join" ||
        action == "takeover" || action == "resume")) {
      std::vector<std::string> holds;
      for (const auto& entry : conversations) {
        if (entry.first == id) continue;
        auto member = entry.second.participants.find(node_id);
        if (member == entry.second.participants.end()) continue;
        const auto& state = member->second.state;
        if (state != "connected" && state != "dialing") continue;
        auto request = json::obj();
        json::set(request.get(), "door", entry.second.door);
        json::set(request.get(), "call_id", entry.first);
        json::set(request.get(), "stage_revision", int64_t{entry.second.stage_revision});
        json::set(request.get(), "expected_version", entry.second.version);
        json::set(request.get(), "action", state == "connected" ? "hold" : "leave");
        holds.push_back(json::dump(request.get()));
      }
      for (const auto& request : holds) conversationRequestOnLoop(request);
    }
    if (action == "select") {
      if (actor == node_id) {
        conversation_focus.clear();
        syncConversationMedia();
      }
      json::setBool(out.get(), "ok", true);
      return json::dump(out.get());
    }
    const auto authority = doorStation(door);
    if (authority.empty() || id.empty()) return fail("authority_unavailable");
    const auto active = active_calls.find(door);
    if (active == active_calls.end() || active->second.call_id != id ||
        active->second.stage_revision != json::getInt(body.get(), "stage_revision", -1)) return fail("stale_call");
    auto request = json::getString(body.get(), "request_id");
    if (request.empty()) request = genTokenHex(16);
    if (request.size() != 32 || request.find_first_not_of("0123456789abcdef") != std::string::npos)
      return fail("invalid_request");
    deferred_conversations.erase(request);
    json::set(body.get(), "cmd", "conversation_request_v1");
    json::set(body.get(), "request_id", request);
    json::set(body.get(), "actor", actor);
    if (actor == node_id && (action == "answer" || action == "join" || action == "takeover" || action == "resume")) {
      if (!sipBackendAvailable() && !conversation_external_transport) return fail("media_unavailable");
      requested_conversations.insert(id);
      conversation_focus = id;
      syncConversationMedia();
    }
    if (authority == node_id) onConversationCommand(node_id, body.get());
    else {
      if (!mesh || conversationTarget(authority).empty()) return fail("authority_unavailable");
      if (conversation_receipts.size() >= 512) return fail("capacity");
      conversation_receipts[request] = {authority, ""};
      std::weak_ptr<char> lifetime = alive;
      loop->postDelayed(5000, [this, lifetime, request, authority] {
        if (!lifetime.lock()) return;
        auto pending = conversation_receipts.find(request);
        if (pending == conversation_receipts.end() || pending->second.first != authority) return;
        conversation_receipts.erase(pending);
        notifyConversationResult(request, "confirmation_unavailable");
      });
      mesh->sendCommand(authority, json::dump(body.get()));
    }
    json::setBool(out.get(), "ok", true);
    json::set(out.get(), "request_id", request);
    json::set(out.get(), "state", "pending");
    return json::dump(out.get());
  }
