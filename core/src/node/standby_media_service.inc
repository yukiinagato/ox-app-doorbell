  struct ReservedStandby {
    std::string call_id;
    int64_t deadline = 0;
    std::shared_ptr<StandbyLease> lease;
  };
  std::mutex standby_reservation_mu;
  std::map<std::string, ReservedStandby> standby_reserved;
  std::shared_ptr<VideoTrack::Reader> standby_prime_reader;
  bool standby_primed = false;
  int64_t standby_prime_until = 0;
  StandbyServer standby_server;
  std::map<std::string, std::shared_ptr<StandbyClient>> standby_clients;
  std::vector<std::shared_ptr<StandbyClient>> standby_retired;
  std::map<std::string, int64_t> standby_retry_at;
  std::array<uint8_t, 32> standby_key{};
  uint64_t standby_timer = 0;
  int standby_tick = 0;

  void sendStandbyCommand(const std::string& peer, const StandbyClient& client) {
    if (!mesh || !mesh->isMember(peer)) return;
    auto command = json::obj();
    json::set(command.get(), "cmd", "standby_video_v1");
    json::set(command.get(), "channel", client.channel());
    json::set(command.get(), "token", std::to_string(client.activeToken()));
    mesh->sendCommand(peer, json::dump(command.get()));
  }

  void reserveStandby(const std::string& door, const std::string& call_id) {
    if (!mesh || opts.role != "indoor_panel") return;
    for (const auto& peer : mesh->peers()) {
      if (peer.role != "door_station" || peer.door != door) continue;
      auto found = standby_clients.find(peer.id);
      if (found == standby_clients.end() || !found->second->ready()) continue;
      std::lock_guard<std::mutex> reservations(standby_reservation_mu);
      auto existing = standby_reserved.find(peer.id);
      if (existing != standby_reserved.end() && existing->second.call_id == call_id) return;
      auto lease = found->second->subscribe();
      if (!lease) return;
      ReservedStandby reservation;
      reservation.call_id = call_id; reservation.deadline = clock->monoMs() + 5000;
      reservation.lease = lease; standby_reserved[peer.id] = std::move(reservation);
      sendStandbyCommand(peer.id, *found->second);
      return;
    }
  }

  void onStandbyCommand(const std::string& from, const cJSON* command) {
    if (!mesh || !mesh->isMember(from) || cfgAt("removed_devices." + from) ||
        opts.role != "door_station" || !video_track.enabled()) return;
    const std::string channel = json::getString(command, "channel");
    const std::string token = json::getString(command, "token");
    if (!peerIdShape(channel) || token.empty() || token.size() > 18 ||
        token.find_first_not_of("0123456789") != std::string::npos) return;
    standby_server.command(from, channel, std::strtoull(token.c_str(), nullptr, 10));
  }

  void maintainStandby() {
    standby_server.setRotation(effective_video_rotation.load());
    // Prime the reusable hardware encoder once at startup, without a network
    // subscriber. A missing camera cannot leave this lease running indefinitely.
    if (opts.role != "door_station" || !video_track.enabled()) {
      standby_prime_reader.reset(); standby_primed = false;
    }
    if (opts.role == "door_station" && video_track.enabled() && !standby_primed) {
      if (!standby_prime_reader) {
        standby_prime_reader = video_track.subscribe();
        standby_prime_until = clock->monoMs() + 2000;
      }
      if (video_track.active() || clock->monoMs() >= standby_prime_until) {
        standby_prime_reader.reset(); standby_primed = true;
      }
    }
    const auto key = mediaPeerKeyOnLoop();
    if (key != standby_key) {
      standby_key = key;
      standby_server.clear();
      for (auto& entry : standby_clients) {
        entry.second->stop(); standby_retired.push_back(entry.second);
      }
      standby_clients.clear(); standby_retry_at.clear();
      { std::lock_guard<std::mutex> reservations(standby_reservation_mu); standby_reserved.clear(); }
    }
    std::set<std::string> members, wanted;
    if (mesh && mesh->isPaired()) {
      for (const auto& peer : mesh->peers()) {
        if (peer.id == node_id || !mesh->isMember(peer.id) || cfgAt("removed_devices." + peer.id)) continue;
        members.insert(peer.id);
        if (opts.role == "indoor_panel" && peer.role == "door_station" && peer.connected &&
            wanted.size() < 4) wanted.insert(peer.id);
      }
    }
    if (opts.role != "door_station" || !video_track.enabled()) members.clear();
    standby_server.retain(members);
    for (auto it = standby_clients.begin(); it != standby_clients.end();) {
      tls::Endpoint endpoint;
      if (!wanted.count(it->first) || !peerEndpointOnLoop(it->first, &endpoint) ||
          !it->second->matches(endpoint) || it->second->finished()) {
        const int status = it->second->status();
        if (status == 401 || status == 404 || status == 405)
          standby_retry_at[it->first] = clock->monoMs() + 300000;
        it->second->stop(); standby_retired.push_back(it->second); it = standby_clients.erase(it);
      } else ++it;
    }
    standby_retired.erase(std::remove_if(standby_retired.begin(), standby_retired.end(),
        [](const std::shared_ptr<StandbyClient>& client) { return client->finished(); }), standby_retired.end());
    const int64_t now = clock->monoMs();
    {
    std::lock_guard<std::mutex> reservations(standby_reservation_mu);
    for (auto it = standby_reserved.begin(); it != standby_reserved.end();) {
      bool active = false;
      for (const auto& call : active_calls)
        if (call.second.call_id == it->second.call_id && call.second.state == "ringing") active = true;
      if (!active || it->second.deadline < now || !standby_clients.count(it->first)) it = standby_reserved.erase(it);
      else ++it;
    }
    }
    for (const auto& peer : wanted) {
      if (!standby_clients.count(peer) && now >= standby_retry_at[peer]) {
        tls::Endpoint endpoint;
        if (!peerEndpointOnLoop(peer, &endpoint)) continue;
        const std::string auth = peerAuthHeaderOnLoop("GET", "/media-standby.mp4");
        if (auth.empty()) continue;
        const std::string channel = genTokenHex(16);
        auto client = std::make_shared<StandbyClient>(endpoint,
            std::map<std::string, std::string>{{"X-Doorbell-Peer", auth}, {"X-Doorbell-Channel", channel}}, channel);
        standby_clients[peer] = client; standby_retry_at[peer] = now + 15000;
        client->start();
      }
      auto client = standby_clients.find(peer);
      if (client != standby_clients.end() && client->second->ready() &&
          (client->second->activeToken() == 0 || standby_tick % 5 == 0))
        sendStandbyCommand(peer, *client->second);
    }
    ++standby_tick;
  }

  std::vector<std::shared_ptr<StandbyClient>> stopStandby() {
    if (standby_timer) { loop->cancel(standby_timer); standby_timer = 0; }
    standby_server.clear();
    { std::lock_guard<std::mutex> reservations(standby_reservation_mu); standby_reserved.clear(); }
    standby_prime_reader.reset();
    for (auto& entry : standby_clients) standby_retired.push_back(entry.second);
    standby_clients.clear();
    for (auto& client : standby_retired) client->stop();
    std::vector<std::shared_ptr<StandbyClient>> clients; clients.swap(standby_retired);
    return clients;
  }

  Httpd::StreamResponse standbyResponse(const HttpReq& request) {
    Httpd::StreamResponse response;
    std::shared_ptr<StandbyServer::Slot> slot;
    loop->callSync([&] {
      std::string owner;
      const auto channel = request.headers.find("x-doorbell-channel");
      if (request.uri != "/media-standby.mp4" || (!request.tls && !request.loopback()) || channel == request.headers.end() ||
          !peerIdShape(channel->second) || !verifyPeerAuthOnLoop(request, &owner)) {
        response.status = 403; return;
      }
      if (opts.role != "door_station" || !video_track.enabled()) return;
      slot = standby_server.open(owner, channel->second, video_track);
    });
    if (!slot) return response;
    response.status = 200;
    response.content_type = "application/x-doorbell-standby-v1";
    response.pull = [slot](bool* ended) { return StandbyServer::pull(slot, ended); };
    return response;
  }
