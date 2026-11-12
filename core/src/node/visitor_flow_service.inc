// Included inside Node::Impl after conversation_service.inc. Runs only on Core's loop.

  // The same step within this window is one message: a visitor who taps twice, or a shell that
  // retries, gets the first message's id back.
  static constexpr int64_t kVisitorNotifyRepeatMs = 60'000;
  static constexpr int64_t kVisitorNotifySpacingMs = 30'000;
  static constexpr int64_t kVisitorNotifyWindowMs = 600'000;
  static constexpr size_t kVisitorNotifyWindowLimit = 6;
  static constexpr int64_t kVisitorSnapshotTimeoutMs = 4'000;
  static constexpr size_t kVisitorSnapshotMaxBytes = 2 * 1024 * 1024;
  static constexpr int64_t kVisitorSnapshotKeepMs = 7LL * 86'400'000;

  struct VisitorNotifyRecord {
    std::string step;
    std::string message_id;
    int64_t at_mono = 0;
  };
  std::map<std::string, std::deque<VisitorNotifyRecord>> visitor_notify_log;
  std::string visitor_flow_reported_revision;
  // Snapshot files this node holds for visitor messages, by hash, with the wall time each stops
  // being kept. They are not ledger assets: nothing replicates them and they age out.
  std::map<std::string, int64_t> visitor_snapshot_keep;
  bool visitor_snapshot_keep_loaded = false;
  // Resolved public documents by door, dropped whenever configuration or an asset changes.
  std::map<std::string, std::string> visitor_flow_cache;
  Node::CameraFetchFn camera_fetch_fn;

  visitor_flow::ResolveEnv visitorFlowEnv() {
    visitor_flow::ResolveEnv env;
    env.text = [this](const std::string& key, const std::string& lang) {
      return textOnLoop(key, lang, {});
    };
    env.asset_path = [this](const std::string& hash) {
      return assetCached(hash) ? assetFilePath(hash) : std::string();
    };
    return env;
  }

  // A native door shell renders the flow only when it measured the feature and its manifest
  // carries the elements the pages are built from, the same rule effectiveCallFlow applies.
  bool visitorFlowShellSupported(const std::string& door) const {
    return doorFeature(door, "visitor_flow_v1") && doorFeature(door, "ui_manifest_v1") &&
           doorManifestSupports(door, "purpose.button") &&
           doorManifestSupports(door, "call.primary") &&
           doorManifestSupports(door, "cancel.call");
  }

  json::Doc visitorFlowDoc(const std::string& door_arg, bool require_shell,
                           bool with_private = false) {
    const std::string door = door_arg.empty() ? opts.door : door_arg;
    const bool refused = require_shell && !visitorFlowShellSupported(door);
    if (!refused && !with_private) {
      auto cached = visitor_flow_cache.find(door);
      if (cached != visitor_flow_cache.end()) return json::parse(cached->second);
    }
    json::Doc doc = refused
        ? visitor_flow::disabledDocument(door, "unsupported_shell")
        : visitor_flow::resolve(cfg.get(), door, visitorFlowEnv(), with_private);
    json::set(doc.get(), "revision", sha256Hex(toBytes(json::dump(doc.get()))).substr(0, 16));
    if (!refused && !with_private && visitor_flow_cache.size() < 64)
      visitor_flow_cache[door] = json::dump(doc.get());
    return doc;
  }

  void evalVisitorFlow() {
    visitor_flow_cache.clear();
    if (!started || opts.role != "door_station" || opts.door.empty()) return;
    auto doc = visitorFlowDoc(opts.door, true);
    const std::string revision = json::getString(doc.get(), "revision");
    if (revision == visitor_flow_reported_revision) return;
    const bool first = visitor_flow_reported_revision.empty();
    visitor_flow_reported_revision = revision;
    if (first) return;  // A shell reads the document once at startup; only changes are news.
    auto event = json::obj();
    json::set(event.get(), "t", "visitor_flow_changed");
    json::set(event.get(), "door", opts.door);
    json::set(event.get(), "revision", revision);
    json::setBool(event.get(), "enabled", json::getBool(doc.get(), "enabled"));
    uiNotify(json::dump(event.get()));
  }

  std::string visitorFlowTemplateJson(const std::string& name) {
    auto raw = visitor_flow::templateFlow(cfg.get(), visitorFlowEnv().text, name);
    auto out = json::obj();
    json::setBool(out.get(), "ok", static_cast<bool>(raw));
    if (raw) json::setItem(out.get(), "flow", std::move(raw));
    else json::set(out.get(), "err", "unknown_template");
    return json::dump(out.get());
  }

  bool visitorFlowCandidateValid(std::string* error, std::vector<ConfigWarning>* warnings) {
    std::vector<visitor_flow::Warning> found;
    if (!visitor_flow::candidateValid(cfg.get(), visitorFlowEnv().text, error, &found))
      return false;
    if (warnings) {
      for (const auto& item : found) {
        ConfigWarning warning;
        warning.key = item.key;
        warning.message_key = item.message_key;
        warnings->push_back(std::move(warning));
      }
    }
    return true;
  }

  // ---------- snapshot for a notify step ----------
  static bool jpegComplete(const Bytes& data) {
    if (data.size() < 4 || data.size() > kVisitorSnapshotMaxBytes) return false;
    if (data[0] != 0xFF || data[1] != 0xD8 || data[2] != 0xFF) return false;
    // A transport that truncates at a NUL byte must not produce a half image.
    const size_t tail = data.size() > 64 ? data.size() - 64 : 0;
    for (size_t i = data.size() - 1; i > tail; --i)
      if (data[i] == 0xD9 && data[i - 1] == 0xFF) return true;
    return false;
  }

  // The media-source secret is {"username","password"}, {"bearer_token"} or "user:password",
  // the forms the shells already accept. It only ever becomes a request header.
  static std::string mediaAuthorization(const std::string& secret) {
    auto header_safe = [](const std::string& text, size_t limit) {
      if (text.empty() || text.size() > limit) return false;
      for (unsigned char c : text)
        if (c < 0x20 || c == 0x7F) return false;
      return true;
    };
    std::string user, password, bearer;
    bool basic = false;
    auto parsed = json::parse(secret);
    if (parsed && cJSON_IsObject(parsed.get())) {
      const cJSON* name = json::get(parsed.get(), "username");
      const cJSON* pass = json::get(parsed.get(), "password");
      if (cJSON_IsString(name) && cJSON_IsString(pass)) {
        user = name->valuestring;
        password = pass->valuestring;
        basic = true;
      } else {
        bearer = json::getString(parsed.get(), "bearer_token");
      }
    } else if (!secret.empty() && secret[0] != '{') {
      const size_t colon = secret.find(':');
      if (colon != std::string::npos) {
        user = secret.substr(0, colon);
        password = secret.substr(colon + 1);
        basic = true;
      }
    }
    if (basic && header_safe(user, 256) && (password.empty() || header_safe(password, 512)))
      return "Basic " + base64Encode(toBytes(user + ":" + password));
    if (header_safe(bearer, 768)) return "Bearer " + bearer;
    return "";
  }

  void cameraFetch(const std::string& url, const std::string& headers_json,
                   std::function<void(int, Bytes)> done) {
    Node::CameraFetchFn fn;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      fn = camera_fetch_fn;
    }
    if (fn) {
      std::weak_ptr<char> w = alive;
      Runloop* lp = loop;
      fn(url, headers_json, [w, lp, done](int status, Bytes body) {
        if (w.expired()) return;
        lp->post([w, done, status, body] {
          if (!w.expired()) done(status, body);
        });
      });
      return;
    }
    httpsCall("GET", url, headers_json, {}, [done](int status, std::string body) {
      done(status, Bytes(body.begin(), body.end()));
    });
  }

  // One still for a notify step: the external camera the step names, or the door station's own
  // camera when the administrator chose that. done receives an empty buffer when there is no
  // usable image, and is always called exactly once, at the latest when the timeout fires.
  void captureVisitorSnapshot(const std::string& door, const cJSON* snapshot,
                              std::function<void(Bytes)> done) {
    auto finished = std::make_shared<bool>(false);
    auto finish = [finished, done](Bytes jpeg) {
      if (*finished) return;
      *finished = true;
      done(jpegComplete(jpeg) ? std::move(jpeg) : Bytes());
    };
    std::weak_ptr<char> w = alive;
    loop->postDelayed(kVisitorSnapshotTimeoutMs, [w, finish] {
      if (!w.expired()) finish(Bytes());
    });
    const std::string source = json::getString(snapshot, "source");
    if (source == "door_station") {
      std::string station;
      if (configuredStationForDoor(door, &station) != 1 || station.empty()) return finish(Bytes());
      if (station == node_id) return finish(frame_bus.latestJpeg());
      if (!mesh) return finish(Bytes());
      mesh->fetchSnapshot(station, finish);
      return;
    }
    const std::string camera = json::getString(snapshot, "id");
    const cJSON* definition = cfgAt("media_sources." + camera);
    const std::string url =
        json::getString(json::get(json::get(definition, "streams"), "snapshot"), "url");
    const bool http = url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0;
    if (source != "media_source" || !http || credentialUrl(url)) return finish(Bytes());
    auto headers = json::obj();
    json::set(headers.get(), "Accept", "image/jpeg");
    const std::string authorization =
        mediaAuthorization(secretValue(json::getString(definition, "secret_ref")));
    if (!authorization.empty()) json::set(headers.get(), "Authorization", authorization);
    // The address and the credential stay out of the log; the source id identifies the camera.
    cameraFetch(url, json::dump(headers.get()), [this, camera, finish](int status, Bytes body) {
      if (status != 200)
        DB_LOGW(kTag, "visitor snapshot from media source " + camera + " failed (status=" +
                          std::to_string(status) + ")");
      finish(status == 200 ? std::move(body) : Bytes());
    });
  }

  void keepVisitorSnapshot(const std::string& hash, int64_t event_wall_ms) {
    if (isSha256HexStr(hash)) visitor_snapshot_keep[hash] = event_wall_ms + kVisitorSnapshotKeepMs;
  }

  // Hashes the asset collector must leave alone. Rebuilt once from recent history so a restart
  // does not discard the pictures of the last few days.
  std::set<std::string> keptVisitorSnapshots() {
    const int64_t now = hlc->correctedWallMs();
    if (!visitor_snapshot_keep_loaded) {
      visitor_snapshot_keep_loaded = true;
      for (const auto& ev : store.recentEvents(512)) {
        if (ev.type != "visitor_message") continue;
        auto payload = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
        keepVisitorSnapshot(
            json::getString(json::get(payload.get(), "snapshot"), "sha256"), ev.wall_ms);
      }
    }
    std::set<std::string> out;
    for (auto it = visitor_snapshot_keep.begin(); it != visitor_snapshot_keep.end();) {
      if (it->second <= now) {
        it = visitor_snapshot_keep.erase(it);
      } else {
        out.insert(it->first);
        ++it;
      }
    }
    return out;
  }

  // ---------- notify without ringing ----------
  static std::string visitorNotifyResult(bool ok, const std::string& error,
                                         const std::string& message_id, bool throttled,
                                         bool duplicate) {
    auto out = json::obj();
    json::setBool(out.get(), "ok", ok);
    if (!ok) {
      json::set(out.get(), "err", error);
      return json::dump(out.get());
    }
    json::setBool(out.get(), "throttled", throttled);
    if (!message_id.empty()) json::set(out.get(), "message_id", message_id);
    if (duplicate) json::setBool(out.get(), "duplicate", true);
    return json::dump(out.get());
  }

  static int visitorNotifyStatus(const std::string& result) {
    auto parsed = json::parse(result);
    if (parsed && json::getBool(parsed.get(), "ok")) return 200;
    const std::string error = parsed ? json::getString(parsed.get(), "err") : "";
    return error == "event_persistence_failed" ? 500 : error == "flow_disabled" ? 409 : 400;
  }

  bool appendVisitorMessage(const std::string& door, cJSON* payload, const Bytes& jpeg) {
    if (!jpeg.empty()) {
      const std::string hash = sha256Hex(jpeg);
      if (fileExists(assetFilePath(hash)) || writeFileBytes(assetFilePath(hash), jpeg)) {
        cJSON* snapshot = json::get(payload, "snapshot");
        json::set(snapshot, "sha256", hash);
        json::set(snapshot, "bytes", static_cast<int64_t>(jpeg.size()));
        json::set(snapshot, "type", "image/jpeg");
        json::set(snapshot, "node", node_id);
        keepVisitorSnapshot(hash, hlc->correctedWallMs());
      }
    }
    // A snapshot that could not be taken leaves a text-only message, never a dangling reference.
    if (json::getString(json::get(payload, "snapshot"), "sha256").empty())
      cJSON_DeleteItemFromObjectCaseSensitive(payload, "snapshot");
    return events->append("visitor_message", door, node_id, json::dump(payload)).seq != 0;
  }

  // The caller names a notify step and nothing else. The text is read from the resolved flow, so
  // neither a visitor nor a panel client can put words into a resident's notification.
  std::string doVisitorNotify(const std::string& door_arg, const std::string& step_id) {
    const std::string door = door_arg.empty() ? opts.door : door_arg;
    if (door.empty() || !doorExists(door)) return visitorNotifyResult(false, "unknown_door", "", false, false);
    auto flow = visitorFlowDoc(door, false, true);
    if (!json::getBool(flow.get(), "enabled"))
      return visitorNotifyResult(false, "flow_disabled", "", false, false);
    const cJSON* step = json::get(json::get(flow.get(), "steps"), step_id.c_str());
    if (step_id.empty() || json::getString(step, "kind") != "notify")
      return visitorNotifyResult(false, "unknown_step", "", false, false);

    const int64_t now = clock->monoMs();
    auto& log = visitor_notify_log[door];
    while (!log.empty() && now - log.front().at_mono >= kVisitorNotifyWindowMs) log.pop_front();
    for (auto it = log.rbegin(); it != log.rend(); ++it) {
      if (it->step == step_id && now - it->at_mono < kVisitorNotifyRepeatMs)
        return visitorNotifyResult(true, "", it->message_id, false, true);
    }
    // Throttling is reported as success and the shell shows the same closing page, so someone
    // leaning on the button learns nothing from it.
    if ((!log.empty() && now - log.back().at_mono < kVisitorNotifySpacingMs) ||
        log.size() >= kVisitorNotifyWindowLimit)
      return visitorNotifyResult(true, "", "", true, false);

    const std::string message_id = genTokenHex(16);
    auto payload = json::obj();
    json::set(payload.get(), "schema_version", static_cast<int64_t>(1));
    json::set(payload.get(), "message_id", message_id);
    json::set(payload.get(), "step", step_id);
    const std::string purpose = json::getString(step, "purpose");
    if (!purpose.empty()) json::set(payload.get(), "purpose", purpose);
    json::setItem(payload.get(), "text", json::Doc(cJSON_Duplicate(json::get(step, "message"), 1)));
    json::set(payload.get(), "visitor_lang", visitorLangFor(door));
    json::set(payload.get(), "capture_cutoff_ms", clock->systemWallMs());

    const cJSON* snapshot = json::get(step, "snapshot");
    if (!snapshot) {
      if (!appendVisitorMessage(door, payload.get(), Bytes()))
        return visitorNotifyResult(false, "event_persistence_failed", "", false, false);
      log.push_back({step_id, message_id, now});
      return visitorNotifyResult(true, "", message_id, false, false);
    }
    // The message waits for its picture, bounded by the capture timeout, so the event every
    // rule sees is complete. The visitor's closing page does not wait.
    cJSON* requested = json::addObj(payload.get(), "snapshot");
    json::set(requested, "source", json::getString(snapshot, "source"));
    if (json::get(snapshot, "id")) json::set(requested, "id", json::getString(snapshot, "id"));
    log.push_back({step_id, message_id, now});
    std::shared_ptr<cJSON> pending(payload.release(), json::Deleter());
    std::weak_ptr<char> w = alive;
    captureVisitorSnapshot(door, snapshot, [this, w, door, pending](Bytes jpeg) {
      if (w.expired()) return;
      if (!appendVisitorMessage(door, pending.get(), jpeg))
        DB_LOGE(kTag, "visitor message could not be persisted");
    });
    return visitorNotifyResult(true, "", message_id, false, false);
  }

  // ---------- presentation of a visitor message ----------
  json::Doc visitorMessageAlert(const EventRecord& ev) {
    auto payload = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    auto o = json::obj();
    json::set(o.get(), "schema_version", static_cast<int64_t>(2));
    json::set(o.get(), "t", "device_alert");
    json::set(o.get(), "kind", "visitor_message");
    json::set(o.get(), "event_id", eventIdentity(ev));
    json::set(o.get(), "origin", ev.origin);
    json::set(o.get(), "seq", static_cast<int64_t>(ev.seq));
    json::set(o.get(), "event_hlc", ev.hlc);
    json::set(o.get(), "door", ev.door);
    json::set(o.get(), "wall_ms", ev.wall_ms);
    const cJSON* p = payload.get();
    json::set(o.get(), "message_id", json::getString(p, "message_id"));
    json::set(o.get(), "step", json::getString(p, "step"));
    const std::string purpose = json::getString(p, "purpose");
    if (!purpose.empty()) json::set(o.get(), "purpose", purpose);
    const cJSON* text = json::get(p, "text");
    if (cJSON_IsObject(text)) json::setItem(o.get(), "text", json::Doc(cJSON_Duplicate(text, 1)));
    json::set(o.get(), "visitor_lang", json::getString(p, "visitor_lang", "ja"));
    const std::string hash = json::getString(json::get(p, "snapshot"), "sha256");
    if (isSha256HexStr(hash)) {
      cJSON* snapshot = json::addObj(o.get(), "snapshot");
      json::set(snapshot, "sha256", hash);
      json::set(snapshot, "url", "/asset/" + hash);
      if (assetCached(hash)) json::set(snapshot, "path", assetFilePath(hash));
      else json::setItem(snapshot, "path", json::Doc(cJSON_CreateNull()));
    }
    return o;
  }

  void visitorMessageNotifyUi(const EventRecord& ev, const cJSON* params) {
    if (!deviceAlertTargetsSelf(params) || !alertUsesLocalChannel(params)) return;
    auto alert = visitorMessageAlert(ev);
    const cJSON* presentation = json::get(params, "presentation");
    json::setBool(alert.get(), "visual", json::getBool(presentation, "visual", true));
    json::setBool(alert.get(), "sticky", json::getBool(presentation, "sticky", false));
    json::set(alert.get(), "ttl_s", json::getInt(presentation, "ttl_s", 60));
    const std::string sound = json::getString(presentation, "sound");
    if (!sound.empty()) {
      json::set(alert.get(), "sound", sound);
      const std::string sound_hash = assetRefHash(sound);
      if (!sound_hash.empty() && assetCached(sound_hash))
        json::set(alert.get(), "audio_path", assetFilePath(sound_hash));
    }
    if (cJSON* channels = json::get(params, "channels"))
      json::setItem(alert.get(), "channels", json::Doc(cJSON_Duplicate(channels, 1)));
    const std::string hash = json::getString(json::get(alert.get(), "snapshot"), "sha256");
    std::shared_ptr<cJSON> pending(alert.release(), json::Deleter());
    auto deliver = [this, pending, hash] {
      if (!hash.empty() && assetCached(hash))
        json::set(json::get(pending.get(), "snapshot"), "path", assetFilePath(hash));
      uiNotify(json::dump(pending.get()));
    };
    if (hash.empty() || assetCached(hash) || !mesh) return deliver();
    // The picture lives on the node that took it. Fetch it by hash before showing the alert, and
    // show the text alone if it cannot be had.
    std::weak_ptr<char> w = alive;
    const int64_t event_wall_ms = ev.wall_ms;
    mesh->fetchBlob(hash, [this, w, hash, deliver, event_wall_ms](Bytes data) {
      if (w.expired()) return;
      if (!data.empty() && sha256Hex(data) == hash && jpegComplete(data) &&
          writeFileBytes(assetFilePath(hash), data))
        keepVisitorSnapshot(hash, event_wall_ms);
      deliver();
    });
  }
