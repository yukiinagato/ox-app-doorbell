// Included inside Node::Impl. All members below, except mediaWorkerRequest(), run on Core's loop.
  struct MediaWork {
    MediaAuthorization authority;
    std::string request_id;
    std::string body;
    uint64_t sequence = 0;
    int64_t deadline_mono = 0;
    bool authorize = false;
    OperationDispatcher::Complete complete;
  };
  using MediaWorkPtr = std::shared_ptr<MediaWork>;
  std::unique_ptr<OperationDispatcher> media_dispatcher;
  media_relay::LatestQueue<MediaWork> media_queue;
  std::map<std::string, MediaWorkPtr> media_rpcs;
  struct MediaRate { media_relay::Bucket bucket; int64_t seen = 0; };
  std::map<std::string, MediaRate> media_rates;
  std::map<std::string, int64_t> media_retired;
  media_relay::Bucket media_global_rate;
  bool media_stopped = true;
  uint64_t media_sweep = 0;

  static int64_t mediaSteadyMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
  }
  static bool mediaSamePrincipal(const PanelPrincipal& a, const PanelPrincipal& b) {
    return a.panel_id == b.panel_id && a.credential_generation == b.credential_generation &&
        a.grant_version == b.grant_version && a.legacy_shared == b.legacy_shared;
  }
  static bool mediaSameBinding(const MediaAuthorization& a, const MediaAuthorization& b) {
    return a.source_node == b.source_node && a.target_node == b.target_node &&
        a.door == b.door && a.call_id == b.call_id && a.stage_revision == b.stage_revision &&
        a.owner == b.owner && mediaSamePrincipal(a.principal, b.principal);
  }
  bool mediaPeer(const std::string& id, uint64_t* epoch_out = nullptr) {
    if (!mesh || !mesh->isPaired() || !media_relay::hexId(id) ||
        !cJSON_IsObject(cfgAt("devices." + id)) || cfgAt("removed_devices." + id)) return false;
    for (const auto& peer : mesh->peers()) {
      if (peer.id != id || !peer.connected || peer.status == "dead") continue;
      if (epoch_out) *epoch_out = peer.epoch;
      return true;
    }
    return false;
  }
  std::string mediaTarget(const std::string& door) {
    std::set<std::string> candidates;
    if (opts.role == "door_station" && opts.door == door && !cfgAt("removed_devices." + node_id))
      candidates.insert(node_id);
    const cJSON* device = nullptr;
    cJSON_ArrayForEach(device, cfgAt("devices")) {
      if (!device->string || !media_relay::hexId(device->string) ||
          json::getString(device, "role") != "door_station" ||
          json::getString(device, "door") != door || cfgAt("removed_devices." + std::string(device->string))) continue;
      candidates.insert(device->string);
    }
    // An offline competing configured station is still ambiguous; never select the first peer.
    return candidates.size() == 1 ? *candidates.begin() : std::string();
  }
  bool mediaBindingCurrent(const MediaAuthorization& a) {
    if (media_stopped || a.deadline_mono <= clock->monoMs() || mediaTarget(a.door) != a.target_node)
      return false;
    const auto call = active_calls.find(a.door);
    if (call == active_calls.end() || call->second.state != "in_call" ||
        call->second.call_id != a.call_id || call->second.stage_revision != a.stage_revision ||
        call->second.dialog_owner != a.owner ||
        a.owner.compare(0, a.source_node.size() + 5, a.source_node + ":web:") != 0) return false;
    if (a.source_node == node_id) {
      PanelPrincipal current;
      if (a.session.empty() || !panelSessionPrincipal(a.session, &current) ||
          !mediaSamePrincipal(current, a.principal) || !panelSessionAllowed(a.session, a.door, "media.publish"))
        return false;
      const auto lease = web_dialog_timers.find(a.call_id);
      if (lease == web_dialog_timers.end() || lease->second.publisher_session != a.session ||
          webDialogLeaseRemaining(a.door, a.call_id, a.stage_revision, a.owner) <= 0) return false;
      if (a.target_node == node_id) return opts.role == "door_station" && opts.door == a.door;
      uint64_t current_epoch = 0;
      return !a.principal.legacy_shared && mediaPeer(a.target_node, &current_epoch) && current_epoch == a.peer_epoch;
    }
    uint64_t current_epoch = 0;
    return a.session.empty() && a.target_node == node_id && opts.role == "door_station" &&
        opts.door == a.door && mediaPeer(a.source_node, &current_epoch) && current_epoch == a.peer_epoch &&
        !a.principal.legacy_shared && panelPrincipalAllowed(a.principal, a.door, "media.publish");
  }
  static void mediaComplete(const MediaWorkPtr& work, HttpResp response) {
    // Move first: an immediate completion cannot complete this work a second time.
    auto complete = std::move(work->complete);
    work->complete = {};
    if (complete) complete(std::move(response));
  }
  static HttpResp mediaAccepted(const MediaAuthorization& a, uint64_t sequence) {
    auto result = json::obj();
    json::setBool(result.get(), "ok", true);
    json::set(result.get(), "media_generation", a.generation);
    json::set(result.get(), "frame_sequence", std::to_string(sequence));
    json::set(result.get(), "acceptance", "remote_core_accepted");
    auto response = HttpResp::json(json::dump(result.get()));
    response.headers["Cache-Control"] = "no-store";
    return response;
  }
  HttpResp mediaAuthorized(const MediaAuthorization& a) {
    auto result = json::obj();
    json::setBool(result.get(), "ok", true);
    json::set(result.get(), "schema_version", static_cast<int64_t>(1));
    json::set(result.get(), "door", a.door);
    json::set(result.get(), "call_id", a.call_id);
    json::set(result.get(), "stage_revision", static_cast<int64_t>(a.stage_revision));
    json::set(result.get(), "dialog_owner", a.owner);
    json::set(result.get(), "media_generation", a.generation);
    json::set(result.get(), "publish_remaining_ms", std::max<int64_t>(0, a.deadline_mono - clock->monoMs()));
    json::set(result.get(), "upload_path", "/call-frame");
    auto response = HttpResp::json(json::dump(result.get()));
    response.headers["Cache-Control"] = "no-store";
    return response;
  }
  static json::Doc mediaWire(const std::string& command, const MediaAuthorization& a,
                             const std::string& request_id) {
    auto object = json::obj();
    // This prefix is also the non-recursive pre-parser dispatch discriminator.
    json::set(object.get(), "cmd", command);
    json::set(object.get(), "schema_version", "1");
    json::set(object.get(), "request_id", request_id);
    json::set(object.get(), "source_node", a.source_node);
    json::set(object.get(), "target_node", a.target_node);
    json::set(object.get(), "door", a.door);
    json::set(object.get(), "call_id", a.call_id);
    json::set(object.get(), "stage_revision", std::to_string(a.stage_revision));
    json::set(object.get(), "dialog_owner", a.owner);
    json::set(object.get(), "panel_id", a.principal.panel_id);
    json::set(object.get(), "credential_generation", a.principal.credential_generation);
    json::set(object.get(), "grant_version", a.principal.grant_version);
    json::set(object.get(), "media_generation", a.generation);
    json::set(object.get(), "authorization_request_id", a.authorization_request);
    return object;
  }
  static json::Doc mediaParseWire(const std::string& text) {
    if (text.size() > media_relay::kWireBytes || text.find('\0') != std::string::npos ||
        text.find("\\u0000") != std::string::npos) return {};
    int depth = 0;
    bool quoted = false, escaped = false;
    for (unsigned char c : text) {
      if (quoted) {
        if (c < 0x20) return {};
        if (escaped) escaped = false;
        else if (c == '\\') escaped = true;
        else if (c == '"') quoted = false;
      } else if (c == '"') quoted = true;
      else if (c == '[' || c == ']') return {};
      else if (c == '{') { if (++depth != 1) return {}; }
      else if (c == '}') { if (--depth != 0) return {}; }
    }
    if (quoted || escaped || depth != 0) return {};
    json::Doc object(cJSON_ParseWithOpts(text.c_str(), nullptr, 1));
    if (!object || !cJSON_IsObject(object.get())) return {};
    const std::set<std::string> allowed = {"cmd", "schema_version", "request_id", "source_node",
        "target_node", "door", "call_id", "stage_revision", "dialog_owner", "panel_id",
        "credential_generation", "grant_version", "media_generation", "authorization_request_id",
        "ttl_ms", "frame_sequence", "frame_deadline_ms", "frame", "status", "error_code",
        "remaining_ms", "reply_kind"};
    std::set<std::string> fields;
    const cJSON* field = nullptr;
    cJSON_ArrayForEach(field, object.get()) {
      const std::string key = field->string ? field->string : "";
      if (!allowed.count(key) || !fields.insert(key).second || !cJSON_IsString(field) ||
          !field->valuestring || (key != "frame" && std::strlen(field->valuestring) > 256)) return {};
    }
    if (json::getString(object.get(), "schema_version") != "1") return {};
    return object;
  }
  static bool mediaWireBinding(const cJSON* object, MediaAuthorization* a) {
    a->source_node = json::getString(object, "source_node");
    a->target_node = json::getString(object, "target_node");
    a->door = json::getString(object, "door");
    a->call_id = json::getString(object, "call_id");
    a->owner = json::getString(object, "dialog_owner");
    a->generation = json::getString(object, "media_generation");
    a->authorization_request = json::getString(object, "authorization_request_id");
    a->principal.panel_id = json::getString(object, "panel_id");
    a->principal.credential_generation = json::getString(object, "credential_generation");
    a->principal.grant_version = json::getString(object, "grant_version");
    a->principal.legacy_shared = false;
    uint64_t revision = 0;
    if (!media_relay::hexId(a->source_node) || !media_relay::hexId(a->target_node) ||
        a->source_node == a->target_node || !media_relay::identifier(a->door, 128) ||
        !media_relay::identifier(a->call_id) || !media_relay::identifier(a->owner) ||
        !media_relay::hexId(a->principal.panel_id) ||
        !media_relay::hexId(a->principal.credential_generation) ||
        !media_relay::hexId(a->principal.grant_version, 64) ||
        !media_relay::hexId(a->authorization_request) ||
        (!a->generation.empty() && !media_relay::hexId(a->generation)) ||
        !media_relay::decimal(json::getString(object, "stage_revision"), 2147483647, &revision, true)) return false;
    a->stage_revision = static_cast<int>(revision);
    return true;
  }
  void mediaSend(const std::string& target, const cJSON* object) {
    // Mesh::sendCommand uses an established authenticated, encrypted SecureChannel. No HTTP client,
    // browser Cookie/Bearer forwarding, durable event, secret reference or arbitrary URL is involved.
    if (!mediaPeer(target)) return;
    const auto wire = json::dump(object);
    if (wire.size() <= media_relay::kWireBytes) mesh->sendCommand(target, wire);
  }
  void mediaSendRevoke(const MediaAuthorization& a) {
    if (a.source_node != node_id || a.target_node == node_id || a.authorization_request.empty()) return;
    const auto object = mediaWire("media_revoke_v1", a, genTokenHex(16));
    mediaSend(a.target_node, object.get());
  }
  void mediaRetire(const MediaAuthorization& a) {
    if (a.source_node == node_id || a.authorization_request.empty()) return;
    // Admission reserves a replay-cache entry before minting a grant. Retiring never evicts a key.
    const std::string key = a.source_node + ":" + a.authorization_request;
    auto found = media_retired.find(key);
    if (found != media_retired.end()) found->second = clock->monoMs() + 30000;
  }
  void mediaEraseGeneration(const std::string& generation, const std::string& error, bool revoke = true) {
    auto found = media_authorizations.find(generation);
    if (found == media_authorizations.end()) return;
    const auto authority = found->second;
    media_authorizations.erase(found);
    if (peer_frame_generation == generation) {
      peer_frame.clear(); peer_frame_generation.clear(); peer_frame_mono = 0;
    }
    auto work = media_queue.remove(generation);
    for (auto it = media_rpcs.begin(); it != media_rpcs.end();) {
      if (it->second->authority.generation != generation) { ++it; continue; }
      work.push_back(it->second);
      it = media_rpcs.erase(it);
    }
    mediaRetire(authority);
    if (revoke) mediaSendRevoke(authority);
    for (const auto& item : work) mediaComplete(item, mediaFailure(409, error));
  }
  void revokeMediaForCall(const std::string& call_id) {
    std::vector<std::string> generations;
    for (const auto& entry : media_authorizations)
      if (entry.second.call_id == call_id) generations.push_back(entry.first);
    for (const auto& generation : generations) mediaEraseGeneration(generation, "stale_call");
    std::vector<MediaWorkPtr> cancelled;
    for (auto it = media_rpcs.begin(); it != media_rpcs.end();) {
      if (it->second->authority.call_id != call_id) { ++it; continue; }
      cancelled.push_back(it->second);
      it = media_rpcs.erase(it);
    }
    for (const auto& work : cancelled) {
      mediaSendRevoke(work->authority);
      mediaComplete(work, mediaFailure(409, "stale_call"));
    }
  }
  void mediaPrune() {
    std::vector<std::string> expired;
    for (const auto& entry : media_authorizations)
      if (!mediaBindingCurrent(entry.second)) expired.push_back(entry.first);
    for (const auto& generation : expired) mediaEraseGeneration(generation, "stale_media_generation");
  }
  bool mediaRateAllowed(const MediaAuthorization& a) {
    const auto now = clock->monoMs();
    const std::string key = a.source_node + ":" + a.call_id + ":" + a.owner;
    auto found = media_rates.find(key);
    if (found == media_rates.end()) {
      if (media_rates.size() >= media_relay::kPublishers) return false;
      found = media_rates.emplace(key, MediaRate{}).first;
    }
    found->second.seen = now;
    return media_global_rate.take(now, 20, 4) && found->second.bucket.take(now, 10, 2);
  }
  static bool mediaValidJpeg(const std::string& body) {
    if (!media_relay::jpegEnvelope(body)) return false;
    int width = 0, height = 0, components = 0;
    const auto* data = reinterpret_cast<const stbi_uc*>(body.data());
    if (!stbi_info_from_memory(data, static_cast<int>(body.size()), &width, &height, &components) ||
        width <= 0 || height <= 0 || width > 1024 || height > 1024 || width * height > 307200 ||
        (components != 1 && components != 3)) return false;
    // Envelope/dimensions are checked before this allocation (at most 307200 RGB pixels).
    stbi_uc* pixels = stbi_load_from_memory(data, static_cast<int>(body.size()), &width, &height, &components, 3);
    if (!pixels) return false;
    stbi_image_free(pixels);
    return width > 0 && height > 0 && width <= 1024 && height <= 1024 && width * height <= 307200;
  }
  HttpResp mediaStoreFrame(const MediaAuthorization& expected, uint64_t sequence,
                           const std::string& body, int64_t frame_deadline) {
    if (body.size() > media_relay::kFrameBytes) return mediaFailure(413, "frame_too_large");
    if (!mediaValidJpeg(body)) return mediaFailure(400, "invalid_jpeg");
    // No event, network call or callback may be inserted between this check and the slot write.
    const auto found = media_authorizations.find(expected.generation);
    if (found == media_authorizations.end() || !mediaSameBinding(found->second, expected) ||
        !mediaBindingCurrent(found->second) || sequence <= found->second.last_sequence ||
        frame_deadline <= clock->monoMs()) return mediaFailure(409, "stale_media_frame");
    auto& authority = found->second;
    peer_frame.assign(body.begin(), body.end());
    peer_frame_mono = clock->monoMs();
    peer_frame_generation = authority.generation;
    authority.last_sequence = sequence;
    return mediaAccepted(authority, sequence);
  }
  void mediaStartFrame(const MediaWorkPtr& work) {
    if (!work || !work->complete) return;
    const auto now = clock->monoMs();
    auto found = media_authorizations.find(work->authority.generation);
    if (found == media_authorizations.end() || !mediaBindingCurrent(found->second) ||
        !mediaSameBinding(found->second, work->authority) || work->deadline_mono <= now) {
      mediaComplete(work, mediaFailure(409, "stale_media_frame"));
      const auto next = media_queue.finish(work->authority.generation, work);
      if (next) mediaStartFrame(next);
      return;
    }
    if (work->authority.target_node == node_id) {
      auto response = mediaStoreFrame(work->authority, work->sequence, work->body, work->deadline_mono);
      const auto next = media_queue.finish(work->authority.generation, work);
      mediaComplete(work, std::move(response));
      if (next) mediaStartFrame(next);
      return;
    }
    if (media_rpcs.size() >= media_relay::kRpcCapacity) {
      const auto next = media_queue.finish(work->authority.generation, work);
      mediaComplete(work, mediaFailure(429, "media_capacity_exceeded"));
      if (next) mediaStartFrame(next);
      return;
    }
    work->deadline_mono = std::min(work->deadline_mono, now + media_relay::kRpcMs);
    auto object = mediaWire("media_frame_v1", work->authority, work->request_id);
    json::set(object.get(), "frame_sequence", std::to_string(work->sequence));
    // Receiver age starts before sender's authorization-reply receipt. This offset therefore
    // expires conservatively without comparing monotonic clock epochs on different machines.
    const auto offset = std::min(work->authority.ttl_ms,
        std::max<int64_t>(0, now - work->authority.issued_mono) + (work->deadline_mono - now));
    json::set(object.get(), "frame_deadline_ms", std::to_string(offset));
    json::set(object.get(), "frame", base64Encode(reinterpret_cast<const uint8_t*>(work->body.data()), work->body.size()));
    media_rpcs.emplace(work->request_id, work);
    mediaSend(work->authority.target_node, object.get());
  }
  void mediaRequestOnLoop(const HttpReq& request, const OperationDispatcher::Complete& complete) {
    if (media_stopped) { complete(mediaFailure(503, "media_stopped")); return; }
    if (request.method != "POST") { complete(mediaFailure(405, "method_not_allowed")); return; }
    uint64_t steady_deadline = 0;
    const auto deadline = request.headers.find("x-doorbell-internal-media-deadline");
    if (deadline == request.headers.end() ||
        !media_relay::decimal(deadline->second, 9223372036854775807ULL, &steady_deadline) ||
        static_cast<int64_t>(steady_deadline) <= mediaSteadyMs()) {
      complete(mediaFailure(504, "media_deadline_exceeded")); return;
    }
    const auto remaining_request = std::min<int64_t>(media_relay::kHttpMs,
        static_cast<int64_t>(steady_deadline) - mediaSteadyMs());
    const bool frame = request.uri == "/call-frame";
    if (!frame && request.uri != "/api/panel/media-authorize") {
      complete(mediaFailure(404, "not_found")); return;
    }
    std::string identity_text = request.query;
    if (!frame && !request.body.empty()) {
      const auto type = request.headers.find("content-type");
      if (!request.query.empty() || request.body.size() > 2048 || type == request.headers.end() ||
          !media_relay::contentType(type->second, "application/x-www-form-urlencoded")) {
        complete(mediaFailure(400, "invalid_media_identity")); return;
      }
      identity_text = request.body;
    }
    std::map<std::string, std::string> identity;
    uint64_t revision = 0, sequence = 0;
    if (!media_relay::query(identity_text, frame, &identity) ||
        !media_relay::identifier(identity["door"], 128) || !media_relay::identifier(identity["call_id"]) ||
        !media_relay::decimal(identity["stage_revision"], 2147483647, &revision, true) ||
        (frame && (!media_relay::hexId(identity["media_generation"]) ||
          !media_relay::decimal(identity["frame_sequence"], 9223372036854775807ULL, &sequence)))) {
      complete(mediaFailure(400, "invalid_media_identity")); return;
    }
    const auto session = panelMutationSession(request);
    if (session.empty() || !panelSessionAllowed(session, identity["door"], "media.publish")) {
      complete(mediaFailure(403, "permission_denied")); return;
    }
    mediaPrune();
    auto work = std::make_shared<MediaWork>();
    work->complete = complete;
    work->request_id = genTokenHex(16);
    work->deadline_mono = clock->monoMs() + remaining_request;
    if (frame) {
      auto grant = media_authorizations.find(identity["media_generation"]);
      if (grant == media_authorizations.end()) { complete(mediaFailure(409, "stale_media_generation")); return; }
      auto& a = grant->second;
      if (a.source_node != node_id || a.session != session) { complete(mediaFailure(403, "publisher_not_owner")); return; }
      if (a.door != identity["door"] || a.call_id != identity["call_id"] ||
          a.stage_revision != static_cast<int>(revision) || sequence <= a.highest_submitted) {
        complete(mediaFailure(409, "stale_media_frame")); return;
      }
      const auto type = request.headers.find("content-type");
      if (request.body.size() > media_relay::kFrameBytes) { complete(mediaFailure(413, "frame_too_large")); return; }
      if (type == request.headers.end() || type->second != "image/jpeg" ||
          !media_relay::jpegEnvelope(request.body)) { complete(mediaFailure(400, "invalid_jpeg")); return; }
      if (!mediaRateAllowed(a)) { complete(mediaFailure(429, "media_rate_exceeded")); return; }
      a.highest_submitted = sequence;
      work->authority = a;
      work->sequence = sequence;
      work->body = request.body;
      work->deadline_mono = std::min(work->deadline_mono, a.deadline_mono);
      MediaWorkPtr replaced;
      const auto admission = media_queue.offer(a.generation, work, &replaced);
      if (replaced) mediaComplete(replaced, mediaFailure(409, "frame_superseded"));
      if (admission == media_relay::LatestQueue<MediaWork>::Admission::Full)
        mediaComplete(work, mediaFailure(429, "media_capacity_exceeded"));
      else if (admission == media_relay::LatestQueue<MediaWork>::Admission::Start) mediaStartFrame(work);
      return;
    }
    auto& a = work->authority;
    a.door = identity["door"]; a.call_id = identity["call_id"];
    a.stage_revision = static_cast<int>(revision);
    a.session = session; a.source_node = node_id; a.target_node = mediaTarget(a.door);
    a.authorization_request = work->request_id;
    if (a.target_node.empty()) { complete(mediaFailure(409, "media_target_ambiguous")); return; }
    const auto call = active_calls.find(a.door);
    if (call == active_calls.end() || call->second.call_id != a.call_id ||
        call->second.stage_revision != a.stage_revision || call->second.state != "in_call") {
      complete(mediaFailure(409, "stale_call")); return;
    }
    const auto lease = web_dialog_timers.find(a.call_id);
    if (lease == web_dialog_timers.end() || lease->second.publisher_session != session) {
      complete(mediaFailure(403, "publisher_not_owner")); return;
    }
    a.owner = call->second.dialog_owner;
    if (!panelSessionPrincipal(session, &a.principal)) { complete(mediaFailure(403, "permission_denied")); return; }
    if (a.target_node != node_id && (a.principal.legacy_shared || !mediaPeer(a.target_node, &a.peer_epoch))) {
      complete(mediaFailure(a.principal.legacy_shared ? 403 : 503,
          a.principal.legacy_shared ? "independent_panel_identity_required" : "media_peer_unavailable")); return;
    }
    a.ttl_ms = std::min<int64_t>(media_relay::kGrantMs, std::min(panelSessionRemaining(session),
        webDialogLeaseRemaining(a.door, a.call_id, a.stage_revision, a.owner)));
    // Reserve the maximum RPC travel budget in the remote grant; do not lengthen the source lease.
    if (a.target_node != node_id) a.ttl_ms -= media_relay::kRpcMs;
    if (a.ttl_ms <= 0) { complete(mediaFailure(409, "lease_expired")); return; }
    a.issued_mono = clock->monoMs(); a.deadline_mono = a.issued_mono + a.ttl_ms;
    if (!mediaBindingCurrent(a)) { complete(mediaFailure(409, "stale_call")); return; }
    for (const auto& pending : media_rpcs) {
      if (pending.second->authorize && pending.second->authority.call_id == a.call_id) {
        complete(mediaFailure(409, "authorization_in_progress")); return;
      }
    }
    if (a.target_node != node_id && media_rpcs.size() >= media_relay::kRpcCapacity) {
      complete(mediaFailure(429, "media_capacity_exceeded")); return;
    }
    revokeMediaForCall(a.call_id);
    if (media_authorizations.size() >= media_relay::kPublishers) {
      complete(mediaFailure(429, "publisher_limit")); return;
    }
    if (a.target_node == node_id) {
      a.generation = genTokenHex(16);
      media_authorizations.emplace(a.generation, a);
      mediaComplete(work, mediaAuthorized(a));
      return;
    }
    work->authorize = true;
    work->deadline_mono = std::min(work->deadline_mono, clock->monoMs() + media_relay::kRpcMs);
    auto object = mediaWire("media_authorize_v1", a, work->request_id);
    json::set(object.get(), "ttl_ms", std::to_string(a.ttl_ms));
    media_rpcs.emplace(work->request_id, work);
    mediaSend(a.target_node, object.get());
  }
  void mediaReply(const std::string& peer, const std::string& request_id, const std::string& kind,
                  const MediaAuthorization& a, int status, const std::string& error,
                  uint64_t sequence = 0) {
    auto object = mediaWire("media_result_v1", a, request_id);
    json::set(object.get(), "reply_kind", kind);
    json::set(object.get(), "status", std::to_string(status));
    json::set(object.get(), "error_code", error);
    json::set(object.get(), "frame_sequence", std::to_string(sequence));
    json::set(object.get(), "remaining_ms", std::to_string(std::max<int64_t>(0, a.deadline_mono - clock->monoMs())));
    mediaSend(peer, object.get());
  }
  void mediaResult(const std::string& from, const cJSON* object, const MediaAuthorization& received,
                   const std::string& request_id) {
    auto rpc = media_rpcs.find(request_id);
    if (rpc == media_rpcs.end()) return;
    const auto work = rpc->second;
    if (from != work->authority.target_node || !mediaSameBinding(work->authority, received) ||
        received.authorization_request != work->authority.authorization_request ||
        json::getString(object, "reply_kind") != (work->authorize ? "authorize" : "frame") ||
        (!work->authorize && received.generation != work->authority.generation)) return;
    uint64_t status = 0, sequence = 0, remaining = 0;
    if (!media_relay::decimal(json::getString(object, "status"), 599, &status) || status < 200 ||
        (status >= 300 && status < 400) ||
        !media_relay::decimal(json::getString(object, "frame_sequence"), 9223372036854775807ULL, &sequence, true) ||
        !media_relay::decimal(json::getString(object, "remaining_ms"), media_relay::kGrantMs, &remaining, true) ||
        (status < 300 && status != 200) || (!work->authorize && sequence != work->sequence)) return;
    media_rpcs.erase(rpc);
    if (work->deadline_mono <= clock->monoMs() || !mediaBindingCurrent(work->authority)) {
      mediaSendRevoke(received);
      if (!work->authorize) mediaEraseGeneration(work->authority.generation, "stale_media_generation");
      mediaComplete(work, mediaFailure(409, "stale_media_generation"));
      return;
    }
    if (work->authorize) {
      if (status != 200) { mediaComplete(work, mediaFailure(static_cast<int>(status), "media_authorization_rejected")); return; }
      if (!media_relay::hexId(received.generation) || !remaining ||
          media_authorizations.size() >= media_relay::kPublishers || media_authorizations.count(received.generation)) {
        mediaSendRevoke(received);
        mediaComplete(work, mediaFailure(409, "invalid_media_authorization")); return;
      }
      auto grant = work->authority;
      grant.generation = received.generation;
      grant.issued_mono = clock->monoMs();
      grant.deadline_mono = std::min(grant.deadline_mono, grant.issued_mono + static_cast<int64_t>(remaining));
      if (grant.deadline_mono <= grant.issued_mono) {
        mediaSendRevoke(grant); mediaComplete(work, mediaFailure(409, "lease_expired")); return;
      }
      media_authorizations.emplace(grant.generation, grant);
      mediaComplete(work, mediaAuthorized(grant));
      return;
    }
    if (status != 200) {
      // Ambiguous/rejected transport never triggers automatic replay or dispatch of a dependent queue.
      mediaComplete(work, mediaFailure(static_cast<int>(status), "media_frame_rejected"));
      mediaEraseGeneration(work->authority.generation, "media_frame_rejected");
      return;
    }
    auto grant = media_authorizations.find(work->authority.generation);
    if (grant == media_authorizations.end()) { mediaComplete(work, mediaFailure(409, "stale_media_generation")); return; }
    grant->second.last_sequence = work->sequence;
    const auto next = media_queue.finish(work->authority.generation, work);
    mediaComplete(work, mediaAccepted(grant->second, work->sequence));
    if (next) mediaStartFrame(next);
  }
  void onMediaWireCommand(const std::string& from, const std::string& text) {
    if (media_stopped || !mediaPeer(from)) return;
    auto object = mediaParseWire(text);
    if (!object) return;
    const auto command = json::getString(object.get(), "cmd");
    const auto request_id = json::getString(object.get(), "request_id");
    MediaAuthorization incoming;
    if (!media_relay::hexId(request_id) || !mediaWireBinding(object.get(), &incoming)) return;
    if (command == "media_result_v1") { mediaResult(from, object.get(), incoming, request_id); return; }
    if (incoming.source_node != from || incoming.target_node != node_id ||
        (command != "media_authorize_v1" && command != "media_frame_v1" && command != "media_revoke_v1")) return;
    mediaPeer(from, &incoming.peer_epoch);
    if (command == "media_revoke_v1") {
      std::vector<std::string> expired;
      for (const auto& entry : media_authorizations) {
        if (mediaSameBinding(entry.second, incoming) &&
            entry.second.authorization_request == incoming.authorization_request &&
            (incoming.generation.empty() || incoming.generation == entry.first)) expired.push_back(entry.first);
      }
      for (const auto& generation : expired) mediaEraseGeneration(generation, "media_revoked", false);
      return;
    }
    mediaPrune();
    if (command == "media_authorize_v1") {
      uint64_t ttl = 0;
      if (!incoming.generation.empty() || incoming.authorization_request != request_id ||
          !media_relay::decimal(json::getString(object.get(), "ttl_ms"), media_relay::kGrantMs, &ttl)) return;
      incoming.issued_mono = clock->monoMs(); incoming.ttl_ms = static_cast<int64_t>(ttl);
      incoming.deadline_mono = incoming.issued_mono + incoming.ttl_ms;
      if (!mediaBindingCurrent(incoming)) {
        mediaReply(from, request_id, "authorize", incoming, 403, "permission_denied"); return;
      }
      for (const auto& entry : media_authorizations) {
        if (entry.second.source_node == from && entry.second.authorization_request == request_id) {
          if (mediaSameBinding(entry.second, incoming)) mediaReply(from, request_id, "authorize", entry.second, 200, "");
          return;
        }
      }
      const auto replay_key = from + ":" + request_id;
      if (media_retired.count(replay_key) || media_retired.size() >= 64) {
        mediaReply(from, request_id, "authorize", incoming, 409, "authorization_replayed"); return;
      }
      // Never allow a new authenticated request to displace another principal's current publisher.
      std::vector<std::string> previous;
      for (const auto& entry : media_authorizations) {
        if (entry.second.call_id != incoming.call_id) continue;
        if (!mediaSameBinding(entry.second, incoming)) {
          mediaReply(from, request_id, "authorize", incoming, 403, "publisher_not_owner"); return;
        }
        previous.push_back(entry.first);
      }
      if (media_authorizations.size() >= media_relay::kPublishers && previous.empty()) {
        mediaReply(from, request_id, "authorize", incoming, 429, "publisher_limit"); return;
      }
      for (const auto& generation : previous) mediaEraseGeneration(generation, "media_reauthorized", false);
      incoming.generation = genTokenHex(16);
      if (media_authorizations.count(incoming.generation)) return;
      media_retired.emplace(replay_key, clock->monoMs() + incoming.ttl_ms + 30000);
      media_authorizations.emplace(incoming.generation, incoming);
      mediaReply(from, request_id, "authorize", incoming, 200, "");
      return;
    }
    const auto grant = media_authorizations.find(incoming.generation);
    uint64_t sequence = 0, offset = 0;
    if (grant == media_authorizations.end() || !mediaSameBinding(grant->second, incoming) ||
        grant->second.authorization_request != incoming.authorization_request ||
        !media_relay::decimal(json::getString(object.get(), "frame_sequence"), 9223372036854775807ULL, &sequence) ||
        !media_relay::decimal(json::getString(object.get(), "frame_deadline_ms"), media_relay::kGrantMs, &offset) ||
        !mediaBindingCurrent(grant->second) || sequence <= grant->second.last_sequence ||
        offset > static_cast<uint64_t>(grant->second.ttl_ms) ||
        grant->second.issued_mono + static_cast<int64_t>(offset) <= clock->monoMs()) {
      // Echo a parsed sequence where possible so a live caller can correlate rejection promptly.
      media_relay::decimal(json::getString(object.get(), "frame_sequence"), 9223372036854775807ULL, &sequence, true);
      mediaReply(from, request_id, "frame", incoming, 409, "stale_media_frame", sequence); return;
    }
    const auto authority = grant->second;
    if (!mediaRateAllowed(authority)) {
      mediaReply(from, request_id, "frame", authority, 429, "media_rate_exceeded", sequence); return;
    }
    const std::string encoded = json::getString(object.get(), "frame");
    size_t decoded_size = 0;
    Bytes bytes;
    if (!media_relay::canonicalBase64(encoded, &decoded_size) || !base64Decode(encoded, bytes) ||
        bytes.size() != decoded_size) {
      mediaReply(from, request_id, "frame", authority, 400, "invalid_jpeg", sequence); return;
    }
    const auto response = mediaStoreFrame(authority, sequence, toString(bytes),
        authority.issued_mono + static_cast<int64_t>(offset));
    mediaReply(from, request_id, "frame", authority, response.status,
        response.status == 200 ? "" : "media_frame_rejected", sequence);
  }
  void mediaSweep() {
    media_sweep = 0;
    if (media_stopped) return;
    mediaPrune();
    const auto now = clock->monoMs();
    std::vector<MediaWorkPtr> expired;
    for (auto it = media_rpcs.begin(); it != media_rpcs.end();) {
      if (it->second->deadline_mono > now && mediaBindingCurrent(it->second->authority)) { ++it; continue; }
      expired.push_back(it->second);
      it = media_rpcs.erase(it);
    }
    for (const auto& work : expired) {
      // Settle this request before erasing the publisher's pending work, preserving timeout status.
      mediaComplete(work, mediaFailure(504, work->authorize ? "media_authorization_timeout" : "media_outcome_unknown"));
      if (work->authorize) mediaSendRevoke(work->authority);
      else mediaEraseGeneration(work->authority.generation, "stale_media_generation");
    }
    std::vector<std::string> expired_queues;
    for (const auto& slot : media_queue.slots())
      if ((slot.second.active && slot.second.active->deadline_mono <= now) ||
          (slot.second.pending && slot.second.pending->deadline_mono <= now)) expired_queues.push_back(slot.first);
    for (const auto& generation : expired_queues) mediaEraseGeneration(generation, "media_deadline_exceeded");
    for (auto it = media_rates.begin(); it != media_rates.end();)
      if (now - it->second.seen > 30000) it = media_rates.erase(it); else ++it;
    for (auto it = media_retired.begin(); it != media_retired.end();)
      if (it->second <= now) it = media_retired.erase(it); else ++it;
    std::weak_ptr<char> lifetime = alive;
    media_sweep = loop->postDelayed(media_relay::kSweepMs, [this, lifetime] {
      if (lifetime.lock() && !media_stopped) mediaSweep();
    });
  }
  void startMediaOnLoop() {
    media_stopped = false;
    media_global_rate = {};
    media_dispatcher->begin([this](const HttpReq& request, const OperationDispatcher::Complete& complete) {
      mediaRequestOnLoop(request, complete);
    });
    mediaSweep();
  }
  void stopMediaOnLoop() {
    media_stopped = true;
    if (media_sweep) loop->cancelQueued(media_sweep);
    media_sweep = 0;
    std::vector<MediaWorkPtr> work;
    for (const auto& rpc : media_rpcs) work.push_back(rpc.second);
    media_rpcs.clear();
    auto queued = media_queue.clear();
    work.insert(work.end(), queued.begin(), queued.end());
    for (const auto& grant : media_authorizations) mediaSendRevoke(grant.second);
    media_authorizations.clear(); media_rates.clear(); media_retired.clear();
    peer_frame.clear(); peer_frame_generation.clear(); peer_frame_mono = 0;
    for (const auto& item : work) {
      if (item->authorize) mediaSendRevoke(item->authority);
      mediaComplete(item, mediaFailure(503, "media_stopped"));
    }
  }
  HttpResp mediaWorkerRequest(const HttpReq& request) {
    HttpReq bounded = request;
    // Overwrite, never trust an HTTP client supplied internal deadline.
    bounded.headers["x-doorbell-internal-media-deadline"] = std::to_string(mediaSteadyMs() + media_relay::kHttpMs);
    return media_dispatcher->request(std::move(bounded));
  }
  static OperationDispatcher::Limits mediaDispatcherLimits() {
    OperationDispatcher::Limits limits;
    limits.capacity = media_relay::kRpcCapacity;
    limits.body_bytes = media_relay::kFrameBytes;
    limits.timeout_ms = media_relay::kHttpMs;
    limits.inspect_json_body = false;
    limits.failure = [](const std::string& error, int status) {
      return mediaFailure(status, error == "outcome_unknown" ? "media_outcome_unknown" :
          error == "capacity_exceeded" ? "media_capacity_exceeded" : "media_not_started");
    };
    return limits;
  }
  HttpResp mediaReadFrame(const HttpReq& request) {
    const bool loopback = request.remote_addr == "127.0.0.1" || request.remote_addr == "::1" ||
        request.remote_addr == "::ffff:127.0.0.1";
    const auto session = request.cookie("dbpanel");
    // A presented web credential is never upgraded to native access merely by using loopback.
    const bool local_native = loopback && session.empty() && !request.headers.count("authorization");
    if ((!local_native && panelSessionRemaining(session) <= 0) ||
        (request.headers.count("origin") && !trustedWebOrigin(request)))
      return mediaFailure(403, "permission_denied");
    uint64_t revision = 0;
    if (request.param("call_id").empty() ||
        !media_relay::decimal(request.param("stage_revision"), 2147483647, &revision, true))
      return mediaFailure(409, "identity_required");
    if (opts.role != "door_station" || request.param("door", opts.door) != opts.door)
      return mediaFailure(403, "wrong_door");
    mediaPrune();
    const auto found = media_authorizations.find(peer_frame_generation);
    if (peer_frame.empty() || clock->monoMs() - peer_frame_mono > 3000 ||
        found == media_authorizations.end() || found->second.call_id != request.param("call_id") ||
        found->second.stage_revision != static_cast<int>(revision))
      return mediaFailure(404, "no_current_frame");
    const auto& a = found->second;
    if (!local_native && (a.source_node != node_id || a.session.empty() || a.session != session))
      return mediaFailure(403, "publisher_not_owner");
    HttpResp response;
    response.content_type = "image/jpeg";
    response.body.assign(peer_frame.begin(), peer_frame.end());
    response.headers["Cache-Control"] = "no-store";
    response.headers["X-Doorbell-Call-Id"] = a.call_id;
    response.headers["X-Doorbell-Dialog-Owner"] = a.owner;
    response.headers["X-Doorbell-Stage-Revision"] = std::to_string(a.stage_revision);
    response.headers["X-Doorbell-Media-Generation"] = a.generation;
    response.headers["X-Doorbell-Frame-Sequence"] = std::to_string(a.last_sequence);
    return response;
  }
