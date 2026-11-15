  // ---------- Bluetooth air-quality sensors ----------
  // A host device keeps a GATT link to each sensor bound to it and feeds raw notifications to
  // Core. Readings are volatile: they ride the Core-owned air_sensors section of the peer runtime
  // (like power) and are never written to the replicated configuration, so a reading every few
  // seconds costs no journal or anti-entropy traffic. Every device then resolves the one sensor
  // its administrator chose from whichever peer hosts it. All of this runs on the core loop.
  static constexpr int64_t kAirStaleMs = 15 * 60 * 1000;
  static constexpr int64_t kAirPublishGapMs = 30 * 1000;
  static constexpr size_t kAirMaxDiscovered = 8;

  struct AirLocalReading {
    int pm25 = -1;
    int64_t at_ms = 0;
    int battery_pct = -1;
    bool charging = false;
    std::string link = "disconnected";
    std::string firmware;
  };
  struct AirDiscovered {
    std::string address;
    std::string name;
    int rssi = 0;
    int64_t seen_ms = 0;
  };
  std::map<std::string, AirLocalReading> air_local;
  std::vector<AirDiscovered> air_discovered;
  std::string air_ble_state = "unknown";
  std::string air_emitted_digest;
  std::string air_plan_digest;
  int64_t air_published_mono = -kAirPublishGapMs;
  uint64_t air_publish_timer = 0;

  static bool airLinkStateValid(const std::string& s) {
    return s == "connecting" || s == "connected" || s == "disconnected" || s == "not_found";
  }
  static bool airBleStateValid(const std::string& s) {
    return s == "ready" || s == "off" || s == "unauthorized" || s == "unsupported" ||
           s == "unknown";
  }

  const cJSON* airSelfSettings() const {
    return json::get(json::get(json::get(json::get(cfg.get(), "devices"), node_id.c_str()),
                               "local"),
                     "air_quality");
  }

  const cJSON* airSensorDef(const std::string& id) const {
    const cJSON* def = json::get(json::get(cfg.get(), "air_sensors"), id.c_str());
    return cJSON_IsObject(def) ? def : nullptr;
  }

  bool airSensorBoundHere(const std::string& id) const {
    const cJSON* def = airSensorDef(id);
    return def && json::getString(def, "host") == node_id && json::getBool(def, "enabled", true);
  }

  json::Doc airPlanDoc() const {
    auto out = json::obj();
    const bool scan = json::getBool(airSelfSettings(), "host", false);
    cJSON* sensors = json::addArr(out.get(), "sensors");
    const cJSON* def = nullptr;
    cJSON_ArrayForEach(def, json::get(cfg.get(), "air_sensors")) {
      const std::string id = def->string ? def->string : "";
      if (!cJSON_IsObject(def) || !airSensorBoundHere(id)) continue;
      cJSON* s = json::pushObj(sensors);
      json::set(s, "id", id);
      json::set(s, "address", json::getString(def, "address"));
      json::set(s, "kind", json::getString(def, "kind", mops_vida::kKind));
    }
    json::setBool(out.get(), "host", scan || cJSON_GetArraySize(sensors) > 0);
    json::setBool(out.get(), "scan", scan);
    cJSON* ble = json::addObj(out.get(), "mops_vida_pm25");
    json::set(ble, "advertised_service", mops_vida::kAdvertisedService);
    json::set(ble, "advertised_name", mops_vida::kAdvertisedName);
    json::set(ble, "service", mops_vida::kUartService);
    json::set(ble, "rx", mops_vida::kRxCharacteristic);
    json::set(ble, "tx", mops_vida::kTxCharacteristic);
    return out;
  }

  // The peer-visible section. Absent on a device that neither hosts nor scans, so ordinary
  // devices advertise nothing new.
  json::Doc airRuntimeDoc() const {
    auto plan = airPlanDoc();
    if (!json::getBool(plan.get(), "host") && air_local.empty()) return {};
    auto out = json::obj();
    json::set(out.get(), "ble", air_ble_state);
    cJSON* readings = json::addObj(out.get(), "readings");
    for (const auto& kv : air_local) {
      if (!airSensorBoundHere(kv.first)) continue;
      cJSON* r = json::addObj(readings, kv.first.c_str());
      json::set(r, "pm25", static_cast<int64_t>(kv.second.pm25));
      json::set(r, "at_ms", kv.second.at_ms);
      json::set(r, "battery_pct", static_cast<int64_t>(kv.second.battery_pct));
      json::setBool(r, "charging", kv.second.charging);
      json::set(r, "link", kv.second.link);
    }
    cJSON* found = json::addArr(out.get(), "discovered");
    for (const auto& d : air_discovered) {
      cJSON* e = json::pushObj(found);
      json::set(e, "address", d.address);
      json::set(e, "name", d.name);
      json::set(e, "rssi", static_cast<int64_t>(d.rssi));
      json::set(e, "seen_ms", d.seen_ms);
    }
    return out;
  }

  void scheduleAirPublish(bool urgent) {
    const int64_t at = clock->monoMs();
    const int64_t wait = kAirPublishGapMs - (at - air_published_mono);
    if (urgent || wait <= 0) {
      if (air_publish_timer) {
        loop->cancel(air_publish_timer);
        air_publish_timer = 0;
      }
      air_published_mono = at;
      publishMeshRuntime();
      return;
    }
    if (air_publish_timer) return;
    air_publish_timer = loop->postDelayed(wait, [this] {
      air_publish_timer = 0;
      air_published_mono = clock->monoMs();
      publishMeshRuntime();
    });
  }

  // The latest reading for a sensor from whichever device hosts it, as a reading object, plus
  // whether that host is currently reachable.
  json::Doc airReadingFor(const std::string& id, const std::string& host, bool* host_alive) const {
    *host_alive = false;
    if (host == node_id) {
      *host_alive = true;
      auto it = air_local.find(id);
      if (it == air_local.end()) return {};
      auto r = json::obj();
      json::set(r.get(), "pm25", static_cast<int64_t>(it->second.pm25));
      json::set(r.get(), "at_ms", it->second.at_ms);
      json::set(r.get(), "battery_pct", static_cast<int64_t>(it->second.battery_pct));
      json::setBool(r.get(), "charging", it->second.charging);
      json::set(r.get(), "link", it->second.link);
      return r;
    }
    if (!mesh) return {};
    for (const auto& peer : mesh->peers()) {
      if (peer.id != host) continue;
      *host_alive = peer.status == "alive";
      auto runtime = json::parse(peer.runtime_json);
      const cJSON* r =
          json::get(json::get(json::get(runtime.get(), "air_sensors"), "readings"), id.c_str());
      if (!cJSON_IsObject(r)) return {};
      return json::Doc(cJSON_Duplicate(r, 1));
    }
    return {};
  }

  // state: hidden (display off), unconfigured (no sensor chosen or it was removed), waiting (no
  // reading yet), stale (older than fifteen minutes or the host is unreachable), ok.
  json::Doc airQualityDocOnLoop(bool with_age) const {
    auto out = json::obj();
    const cJSON* settings = airSelfSettings();
    const bool show = json::getBool(settings, "show", false);
    const std::string sensor = json::getString(settings, "sensor");
    json::setBool(out.get(), "show", show);
    json::set(out.get(), "sensor", sensor);
    if (!show) {
      json::set(out.get(), "state", "hidden");
      return out;
    }
    const cJSON* def = sensor.empty() ? nullptr : airSensorDef(sensor);
    if (!def) {
      json::set(out.get(), "state", "unconfigured");
      return out;
    }
    json::set(out.get(), "name", json::getString(def, "name"));
    bool host_alive = false;
    auto reading = airReadingFor(sensor, json::getString(def, "host"), &host_alive);
    const int64_t pm25 = reading ? json::getInt(reading.get(), "pm25", -1) : -1;
    const int64_t at_ms = reading ? json::getInt(reading.get(), "at_ms", 0) : 0;
    if (pm25 < 0 || at_ms <= 0) {
      json::set(out.get(), "state", "waiting");
      json::set(out.get(), "link", reading ? json::getString(reading.get(), "link") : "");
      return out;
    }
    const int64_t age_ms = std::max<int64_t>(0, hlc->correctedWallMs() - at_ms);
    const bool stale = !host_alive || age_ms > kAirStaleMs;
    json::set(out.get(), "state", stale ? "stale" : "ok");
    json::set(out.get(), "pm25", pm25);
    json::set(out.get(), "level", air_quality::levelFor(static_cast<int>(pm25)));
    json::set(out.get(), "at_ms", at_ms);
    if (with_age) json::set(out.get(), "age_s", age_ms / 1000);
    const int64_t battery = json::getInt(reading.get(), "battery_pct", -1);
    json::set(out.get(), "battery_pct", battery);
    json::setBool(out.get(), "charging", json::getBool(reading.get(), "charging"));
    return out;
  }

  // Refresh hint for the shell, emitted only when what it draws would differ.
  void refreshAirQuality() {
    auto doc = airQualityDocOnLoop(false);
    const std::string digest = json::dump(doc.get());
    if (digest == air_emitted_digest) return;
    air_emitted_digest = digest;
    uiNotify("{\"t\":\"air_quality_changed\"}");
    scheduleSnapshotRefresh();
  }

  void refreshAirPlan() {
    auto plan = airPlanDoc();
    const std::string digest = json::dump(plan.get());
    if (digest == air_plan_digest) return;
    const bool first = air_plan_digest.empty();
    air_plan_digest = digest;
    for (auto it = air_local.begin(); it != air_local.end();) {
      it = airSensorBoundHere(it->first) ? std::next(it) : air_local.erase(it);
    }
    if (!json::getBool(plan.get(), "scan")) air_discovered.clear();
    if (!first) uiNotify("{\"t\":\"air_sensor_plan_changed\"}");
    scheduleAirPublish(true);
  }

  int airSensorPacketOnLoop(const std::string& id, const std::vector<uint8_t>& bytes) {
    if (!airSensorBoundHere(id)) return -2;
    const auto packet = mops_vida::parse(bytes.data(), bytes.size());
    if (packet.kind == mops_vida::PacketKind::invalid) return -1;
    auto& r = air_local[id];
    const bool was_connected = r.link == "connected";
    r.link = "connected";
    bool changed = !was_connected;
    if (packet.kind == mops_vida::PacketKind::sensor) {
      changed = changed || r.pm25 != packet.pm25;
      r.pm25 = packet.pm25;
      r.at_ms = hlc->correctedWallMs();
    } else if (packet.kind == mops_vida::PacketKind::battery) {
      changed = changed || r.battery_pct != packet.battery_pct || r.charging != packet.charging;
      r.battery_pct = packet.battery_pct;
      r.charging = packet.charging;
    } else if (packet.kind == mops_vida::PacketKind::version) {
      r.firmware = packet.firmware;
    } else {
      return 1;
    }
    // An unchanged value still advances at_ms; the throttled publish carries it so peers do not
    // see a steady reading go stale.
    scheduleAirPublish(!was_connected);
    if (changed || packet.kind == mops_vida::PacketKind::sensor) refreshAirQuality();
    return 0;
  }

  // {"ble":"ready|off|unauthorized|unsupported|unknown",
  //  "discovered":[{"address","name","rssi"}],"links":{"<sensor id>":"connecting|…"}}
  bool airReportOnLoop(const std::string& report_json) {
    auto doc = json::parse(report_json);
    if (!doc || !cJSON_IsObject(doc.get())) return false;
    bool urgent = false;
    const std::string ble = json::getString(doc.get(), "ble");
    if (!ble.empty() && airBleStateValid(ble) && ble != air_ble_state) {
      air_ble_state = ble;
      urgent = true;
    }
    const cJSON* found = json::get(doc.get(), "discovered");
    if (cJSON_IsArray(found) && json::getBool(airSelfSettings(), "host", false)) {
      std::vector<AirDiscovered> next;
      const cJSON* e = nullptr;
      cJSON_ArrayForEach(e, found) {
        if (next.size() >= kAirMaxDiscovered) break;
        AirDiscovered d;
        d.address = json::getString(e, "address");
        d.name = json::getString(e, "name");
        if (d.address.empty() || d.address.size() > 64 || d.name.size() > 64) continue;
        const int64_t rssi = json::getInt(e, "rssi", 0);
        d.rssi = static_cast<int>(std::max<int64_t>(-127, std::min<int64_t>(20, rssi)));
        d.seen_ms = hlc->correctedWallMs();
        next.push_back(std::move(d));
      }
      std::sort(next.begin(), next.end(), [](const AirDiscovered& a, const AirDiscovered& b) {
        return a.address < b.address;
      });
      bool same = next.size() == air_discovered.size();
      for (size_t i = 0; same && i < next.size(); i++) {
        same = next[i].address == air_discovered[i].address && next[i].name == air_discovered[i].name;
      }
      if (!same) urgent = true;
      air_discovered = std::move(next);
    }
    const cJSON* links = json::get(doc.get(), "links");
    const cJSON* link = nullptr;
    cJSON_ArrayForEach(link, links) {
      const std::string id = link->string ? link->string : "";
      const std::string state = cJSON_IsString(link) ? link->valuestring : "";
      if (!airLinkStateValid(state) || !airSensorBoundHere(id)) continue;
      auto& r = air_local[id];
      if (r.link != state) {
        r.link = state;
        urgent = true;
      }
    }
    scheduleAirPublish(urgent);
    refreshAirQuality();
    return true;
  }

  // Administrator view: every configured sensor with its latest reading, and what each scanning
  // host can currently see.
  json::Doc airStatusDoc() const {
    auto out = json::obj();
    cJSON* sensors = json::addArr(out.get(), "sensors");
    const cJSON* def = nullptr;
    cJSON_ArrayForEach(def, json::get(cfg.get(), "air_sensors")) {
      if (!cJSON_IsObject(def) || !def->string) continue;
      cJSON* s = json::pushObj(sensors);
      json::set(s, "id", def->string);
      json::set(s, "name", json::getString(def, "name"));
      json::set(s, "host", json::getString(def, "host"));
      json::set(s, "address", json::getString(def, "address"));
      json::setBool(s, "enabled", json::getBool(def, "enabled", true));
      bool host_alive = false;
      auto reading = airReadingFor(def->string, json::getString(def, "host"), &host_alive);
      json::setBool(s, "host_alive", host_alive);
      if (reading) {
        const int64_t pm25 = json::getInt(reading.get(), "pm25", -1);
        if (pm25 >= 0) json::set(s, "level", air_quality::levelFor(static_cast<int>(pm25)));
        json::setItem(s, "reading", std::move(reading));
      }
    }
    cJSON* hosts = json::addArr(out.get(), "hosts");
    auto add_host = [hosts](const std::string& id, const cJSON* section) {
      if (!cJSON_IsObject(section)) return;
      cJSON* h = json::pushObj(hosts);
      json::set(h, "device", id);
      json::set(h, "ble", json::getString(section, "ble", "unknown"));
      const cJSON* found = json::get(section, "discovered");
      json::setItem(h, "discovered", json::Doc(cJSON_Duplicate(
          cJSON_IsArray(found) ? found : json::arr().get(), 1)));
    };
    auto self = airRuntimeDoc();
    if (self) add_host(node_id, self.get());
    if (mesh) {
      for (const auto& peer : mesh->peers()) {
        if (peer.id == node_id) continue;
        auto runtime = json::parse(peer.runtime_json);
        add_host(peer.id, json::get(runtime.get(), "air_sensors"));
      }
    }
    return out;
  }
