#include "node/node.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <set>

#include "httpd/webui_assets.h"
#include "media/frame_bus.h"
#include "mesh/tcp_transport.h"
#include "mesh/udp_beacon.h"
#include "monocypher.h"
#ifdef _WIN32
#include "media/camera_win.h"
#endif
#include "util/common.h"
#include "util/ids.h"
#include "util/json.h"
#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "node";

std::string hashPassword(const std::string& pw, const std::string& salt_hex) {
  Bytes salt;
  hexDecode(salt_hex, salt);
  Bytes buf = salt;
  buf.insert(buf.end(), pw.begin(), pw.end());
  uint8_t out[32];
  crypto_blake2b(out, sizeof(out), buf.data(), buf.size());
  return hexEncode(out, sizeof(out));
}

bool pskIsZero(const std::array<uint8_t, 32>& psk) {
  for (uint8_t b : psk)
    if (b) return false;
  return true;
}

// "host:port" → host
std::string hostOf(const std::string& addr) {
  auto p = addr.rfind(':');
  return p == std::string::npos ? addr : addr.substr(0, p);
}
}  // namespace

struct Node::Impl {
  NodeOptions opts;

  std::unique_ptr<RealClock> owned_clock;
  IClock* clock = nullptr;
  std::unique_ptr<Runloop> owned_loop;
  Runloop* loop = nullptr;
  bool external_loop = false;

  Store store;
  std::unique_ptr<HlcClock> hlc;
  std::unique_ptr<LwwMap> config;
  std::unique_ptr<EventLog> events;
  RuleEngine rules;
  std::unique_ptr<ITransport> transport;
  std::unique_ptr<IDiscovery> discovery;
  std::unique_ptr<Mesh> mesh;
  std::unique_ptr<Httpd> httpd;
  FrameBus frame_bus;  // 帧総線 (任意スレッドから push / 需要駆動 JPEG)
#ifdef _WIN32
  std::unique_ptr<CameraWin> camera;  // door_station のみ起動
#endif

  json::Doc cfg;  // materialize 済み設定 (loop 上でのみ触る)
  std::string node_id;
  uint64_t epoch = 1;
  bool started = false;

  // press の追跡 (クイック返信の宛先解決・回執)
  std::string last_press_door;
  std::map<std::string, std::pair<std::string, uint64_t>> last_press_by_door;

  // コールバック (任意スレッドから差し替え可)
  std::mutex cb_mu;
  UiEventCb ui_cb;
  TtsCb tts_cb;

  // 管理セッション (civetweb スレッドの auth gate とも共有)
  std::mutex sess_mu;
  std::set<std::string> sessions;

  // ---------- helpers ----------
  void uiNotify(const std::string& event_json) {
    UiEventCb cb;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      cb = ui_cb;
    }
    if (cb) cb(event_json);
  }

  void tts(const std::string& text, const std::string& lang) {
    TtsCb cb;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      cb = tts_cb;
    }
    if (cb) cb(text, lang);
  }

  int tzOffsetMin() {
    const cJSON* integ = json::get(cfg.get(), "integrations");
    return static_cast<int>(json::getInt(integ, "tz_offset_min", 540));  // 既定 JST
  }

  void rebuildCfg() {
    cfg = json::parse(config->materializeJson());
    if (!cfg) cfg = json::obj();
    rules.setConfig(json::dump(cfg.get()));
  }

  // 設定ツリーからドットパスで取得 (borrowed)
  cJSON* cfgAt(const std::string& dotpath) {
    cJSON* cur = cfg.get();
    size_t pos = 0;
    while (cur && pos <= dotpath.size()) {
      size_t dot = dotpath.find('.', pos);
      std::string part = dotpath.substr(pos, dot == std::string::npos ? std::string::npos : dot - pos);
      cur = json::get(cur, part.c_str());
      if (dot == std::string::npos) return cur;
      pos = dot + 1;
    }
    return cur;
  }

  // devices.<self>.local.camera の実効値 (無ければ既定 8/60/640x480)
  struct CamCfg {
    int fps = 8;
    int quality = 60;
    int w = 640, h = 480;
    std::string hint;
  };
  CamCfg cameraCfg() {
    CamCfg c;
    cJSON* cam = cfgAt("devices." + node_id + ".local.camera");
    if (cam) {
      c.fps = static_cast<int>(json::getInt(cam, "mjpeg_fps", 8));
      c.quality = static_cast<int>(json::getInt(cam, "mjpeg_quality", 60));
      c.hint = json::getString(cam, "device_hint");
      std::string res = json::getString(cam, "resolution", "640x480");
      size_t x = res.find('x');
      if (x != std::string::npos) {
        int w = std::atoi(res.c_str());
        int h = std::atoi(res.c_str() + x + 1);
        if (w > 0 && h > 0) {
          c.w = w;
          c.h = h;
        }
      }
    }
    if (c.fps <= 0) c.fps = 8;
    return c;
  }

  // fps/quality/解像度を FrameBus + httpd へ反映 (起動時と config_changed 時)
  void applyCameraSettings() {
    CamCfg c = cameraCfg();
    frame_bus.setJpegParams(c.quality, c.w);
    if (httpd)
      httpd->setJpegProvider([this] { return frame_bus.latestJpeg(); }, c.fps);
  }

  std::string labelIn(const cJSON* label_obj, const std::string& lang) {
    if (!label_obj) return "";
    std::string v = json::getString(label_obj, lang.c_str());
    if (v.empty()) v = json::getString(label_obj, "ja");
    if (v.empty() && cJSON_IsString(label_obj->child)) v = label_obj->child->valuestring;
    return v;
  }

  // ---------- 起動 ----------
  bool init() {
    // Store
    std::string db_path = opts.data_dir;
    if (db_path != ":memory:") {
      makeDir(opts.data_dir);  // 既存でもよい
      db_path = opts.data_dir + "/doorbell.db";
    }
    if (!store.open(db_path)) {
      DB_LOGE(kTag, "store open failed: " + db_path);
      return false;
    }
    // 身元
    auto id = store.metaGet("node_id");
    if (!id) {
      node_id = genNodeId();
      store.metaSet("node_id", node_id);
    } else {
      node_id = *id;
    }
    auto ep = store.metaGet("epoch");
    epoch = ep ? std::stoull(*ep) + 1 : 1;
    store.metaSet("epoch", std::to_string(epoch));

    hlc.reset(new HlcClock(*clock, node_id.substr(0, 8)));
    config.reset(new LwwMap(node_id, *hlc));
    config->load(store.configLoadAll());
    events.reset(new EventLog(node_id, *hlc, store));
    events->loadHeads();

    config->onChange([this](const LwwEntry& e, bool is_local) {
      store.configPut(e);
      rebuildCfg();
      if (is_local && mesh) mesh->pushConfigDelta({e});
      // 自機のカメラ設定 (fps/quality/解像度) の変更は即反映
      if (httpd && e.key.compare(0, 8, "devices.") == 0 &&
          e.key.find(node_id) != std::string::npos)
        applyCameraSettings();
      uiNotify("{\"t\":\"config_changed\"}");
    });
    events->onEvent([this](const EventRecord& ev, bool is_local) { onEvent(ev, is_local); });

    // トランスポート
    if (!transport) transport.reset(new TcpTransport(*loop));
    if (!discovery && !pskIsZero(opts.psk))
      discovery.reset(new UdpBeacon(*loop, opts.psk));

    // Mesh
    MeshSettings ms = opts.use_mesh_timing_template ? opts.mesh_timing_template : MeshSettings{};
    ms.node_id = node_id;
    ms.epoch = epoch;
    ms.listen_addr = opts.listen_addr;
    ms.advertise_addr = opts.advertise_addr.empty() ? opts.listen_addr : opts.advertise_addr;
    ms.seed_peers = opts.seed_peers;
    ms.psk = opts.psk;
    ms.role = opts.role;
    ms.sw_version = opts.sw_version;
    ms.caps_json = opts.caps_json;
    Mesh::Callbacks cbs;
    cbs.on_peers_changed = [this] { uiNotify("{\"t\":\"peers_changed\"}"); };
    cbs.on_leader_changed = [this](const std::string& duty, const std::string& leader) {
      auto o = json::obj();
      json::set(o.get(), "t", "leader");
      json::set(o.get(), "duty", duty);
      json::set(o.get(), "id", leader);
      uiNotify(json::dump(o.get()));
    };
    cbs.on_peer_alive_changed = [this](const std::string& id, bool alive) {
      onPeerAlive(id, alive);
    };
    cbs.on_command = [this](const std::string& from, const std::string& cmd) {
      onCommand(from, cmd);
    };
    mesh.reset(new Mesh(*loop, *clock, *hlc, *transport, discovery.get(), store, *config,
                        *events, ms, cbs));

    rebuildCfg();
    seedConfig();
    mesh->start();

    if (opts.http_port > 0) {
      httpd.reset(new Httpd(*loop));
      registerHttp();
      if (!httpd->start(opts.http_port)) {
        DB_LOGE(kTag, "httpd start failed on port " + std::to_string(opts.http_port));
        return false;
      }
      applyCameraSettings();  // /snapshot.jpg・/stream.mjpeg の JPEG 提供者を配線
    }
#ifdef _WIN32
    // Windows の門口機はカメラ採集 (Media Foundation) を起動。失敗はログのみ。
    if (opts.role == "door_station") {
      CamCfg c = cameraCfg();
      camera.reset(new CameraWin(frame_bus));
      camera->start(c.hint, c.w, c.h);
    }
#endif
    started = true;
    DB_LOGI(kTag, "node " + node_id.substr(0, 8) + " (" + opts.name + ") started");
    return true;
  }

  // 既定設定 (初回のみ) + 自機の devices エントリ登録
  void seedConfig() {
    if (opts.seed_default_config && !config->get("schema_version")) {
      config->set("schema_version", "1");
      config->set("reply.display_ttl_s", "30");
      config->set("integrations.tz_offset_min", "540");
      auto qr = [&](const char* id, const char* ja, const char* en, const char* zh, int order) {
        auto o = json::obj();
        cJSON* label = json::addObj(o.get(), "label");
        json::set(label, "ja", ja);
        json::set(label, "en", en);
        json::set(label, "zh", zh);
        json::setBool(o.get(), "speak", true);
        json::set(o.get(), "order", static_cast<int64_t>(order));
        config->set(std::string("quick_replies.") + id, json::dump(o.get()));
      };
      qr("qr_away", "ただいま留守にしています", "We are away right now", "现在不在家", 1);
      qr("qr_no", "結構です", "Not interested", "不需要，谢谢", 2);
      qr("qr_wrong", "お間違いのようです", "Wrong address", "您可能找错地方了", 3);
      qr("qr_wait", "少々お待ちください", "One moment please", "请稍等", 4);
    }
    // 自機のエントリ (差分がある時だけ書く — 起動毎の無駄な gossip を避ける)
    auto dev = json::obj();
    json::set(dev.get(), "name", opts.name);
    json::set(dev.get(), "role", opts.role);
    if (!opts.door.empty()) json::set(dev.get(), "door", opts.door);
    std::string key = "devices." + node_id;
    std::string want = json::dump(dev.get());
    auto cur = config->get(key);
    if (!cur || *cur != want) config->set(key, want);
  }

  // ---------- イベント配送 ----------
  void onEvent(const EventRecord& ev, bool is_local) {
    if (is_local && mesh) mesh->broadcastEvent(ev);
    if (ev.type == "press") {
      last_press_door = ev.door;
      last_press_by_door[ev.door] = {ev.origin, ev.seq};
    }
    {
      auto o = json::obj();
      json::set(o.get(), "t", "event");
      json::set(o.get(), "type", ev.type);
      json::set(o.get(), "door", ev.door);
      json::set(o.get(), "device", ev.device);
      uiNotify(json::dump(o.get()));
    }
    auto actions = rules.evaluate(ev, hlc->correctedWallMs(), tzOffsetMin());
    for (const auto& a : actions) {
      auto p = json::parse(a.params_json.empty() ? "{}" : a.params_json);
      if (a.type == "chime") {
        // devices 配列に自分が含まれる (または "all") 時だけ自分が鳴る
        bool mine = false;
        cJSON* devs = json::get(p.get(), "devices");
        if (!devs) {
          mine = (opts.role == "indoor_panel");  // 省略時: 室内パネル全部
        } else if (cJSON_IsString(devs)) {
          mine = std::string(devs->valuestring) == "all";
        } else if (cJSON_IsArray(devs)) {
          cJSON* it = nullptr;
          cJSON_ArrayForEach(it, devs) {
            if (cJSON_IsString(it) && node_id == it->valuestring) mine = true;
          }
        }
        if (mine) {
          auto o = json::obj();
          json::set(o.get(), "t", "chime");
          json::set(o.get(), "sound", json::getString(p.get(), "sound", "ding1"));
          json::set(o.get(), "door", ev.door);
          uiNotify(json::dump(o.get()));
        }
      } else if (a.type == "sip_call") {
        // 発呼するのは押された門口機本人だけ (Phase 1 で PJSIP へ配線)
        if (is_local && ev.origin == node_id && ev.type == "press") {
          std::string ext = json::getString(p.get(), "target_extension", "600");
          DB_LOGI(kTag, "sip_call -> " + ext + " (Phase 1 で PJSIP 接続)");
          auto o = json::obj();
          json::set(o.get(), "t", "state");
          json::set(o.get(), "state", "calling");
          json::set(o.get(), "target", ext);
          uiNotify(json::dump(o.get()));
        }
      } else if (a.type == "telegram" || a.type == "ha_event") {
        // leader だけが外部へ送る (Phase 2 で bridge へ配線)
        std::string duty = a.type == "telegram" ? "telegram" : "mqtt_bridge";
        if (mesh && mesh->isLeader(duty))
          DB_LOGI(kTag, a.type + " dispatch (Phase 2): " + ev.type + " " + ev.door);
      }
    }
  }

  // 生死変化 → offline/online イベント。重複防止: alive 集合の中で node_id 最大の者だけが記録
  void onPeerAlive(const std::string& id, bool alive) {
    auto peers = mesh->peers();
    std::string max_alive;
    for (const auto& p : peers)
      if (p.status == "alive" && p.id > max_alive) max_alive = p.id;
    if (max_alive != node_id) return;
    events->append(alive ? "online" : "offline", "", id, "{}");
  }

  void onCommand(const std::string& from, const std::string& cmd_json) {
    auto c = json::parse(cmd_json);
    if (!c) return;
    std::string cmd = json::getString(c.get(), "cmd");
    if (cmd == "chime") {
      auto o = json::obj();
      json::set(o.get(), "t", "chime");
      json::set(o.get(), "sound", json::getString(c.get(), "sound", "ding1"));
      uiNotify(json::dump(o.get()));
    } else if (cmd == "show_reply") {
      std::string text = json::getString(c.get(), "text");
      auto o = json::obj();
      json::set(o.get(), "t", "reply");
      json::set(o.get(), "text", text);
      json::set(o.get(), "ttl_s", json::getInt(c.get(), "ttl_s", 30));
      uiNotify(json::dump(o.get()));
      if (json::getBool(c.get(), "speak", true))
        tts(text, json::getString(c.get(), "lang", "ja"));
    } else {
      DB_LOGW(kTag, "unknown command from " + from.substr(0, 8) + ": " + cmd);
    }
  }

  // ---------- クイック返信 ----------
  void quickReply(const std::string& reply_id, const std::string& free_text,
                  const std::string& door_arg, const std::string& via) {
    std::string door = door_arg.empty() ? last_press_door : door_arg;
    std::string text = free_text;
    bool speak = true;
    if (text.empty() && !reply_id.empty()) {
      cJSON* q = cfgAt("quick_replies." + reply_id);
      if (q) {
        text = labelIn(json::get(q, "label"), "ja");
        speak = json::getBool(q, "speak", true);
      }
    }
    if (text.empty()) {
      DB_LOGW(kTag, "quickReply: 本文なし (reply_id=" + reply_id + ")");
      return;
    }
    int64_t ttl = 30;
    if (cJSON* r = cfgAt("reply.display_ttl_s")) ttl = static_cast<int64_t>(cJSON_IsNumber(r) ? r->valuedouble : 30);

    // 宛先: 該当 door の door_station (door 不明なら全 door_station)
    auto c = json::obj();
    json::set(c.get(), "cmd", "show_reply");
    json::set(c.get(), "text", text);
    json::setBool(c.get(), "speak", speak);
    json::set(c.get(), "ttl_s", ttl);
    json::set(c.get(), "lang", "ja");
    std::string cmd = json::dump(c.get());

    cJSON* devices = json::get(cfg.get(), "devices");
    int sent = 0;
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, devices) {
      if (json::getString(it, "role") != "door_station") continue;
      if (!door.empty() && json::getString(it, "door") != door) continue;
      std::string target = it->string ? it->string : "";
      if (target.empty()) continue;
      if (target == node_id) {
        onCommand(node_id, cmd);
      } else {
        mesh->sendCommand(target, cmd);
      }
      sent++;
    }
    if (sent == 0 && opts.role == "door_station") onCommand(node_id, cmd);  // 単機構成

    // reply イベント + 元 press への回執
    auto pl = json::obj();
    json::set(pl.get(), "reply_id", reply_id);
    json::set(pl.get(), "text", text);
    json::set(pl.get(), "via", via);
    events->append("reply", door, node_id, json::dump(pl.get()));
    auto lp = last_press_by_door.find(door);
    if (lp != last_press_by_door.end()) {
      auto n = json::obj();
      json::set(n.get(), "hlc", hlc->tick());
      cJSON* rep = json::addObj(n.get(), "replied");
      json::set(rep, "reply_id", reply_id);
      json::set(rep, "by", via);
      events->mergeNotify(lp->second.first, lp->second.second, json::dump(n.get()));
    }
  }

  // ---------- status ----------
  std::string statusJsonOnLoop() {
    auto o = json::obj();
    cJSON* self = json::addObj(o.get(), "node");
    json::set(self, "id", node_id);
    json::set(self, "name", opts.name);
    json::set(self, "role", opts.role);
    json::set(self, "door", opts.door);
    json::set(self, "version", opts.sw_version);
    cJSON* leaders = json::addObj(o.get(), "leaders");
    if (mesh) {
      json::set(leaders, "telegram", mesh->leaderFor("telegram"));
      json::set(leaders, "mqtt_bridge", mesh->leaderFor("mqtt_bridge"));
    }
    cJSON* arr = json::addArr(o.get(), "peers");
    if (mesh) {
      for (const auto& p : mesh->peers()) {
        cJSON* e = json::pushObj(arr);
        json::set(e, "id", p.id);
        json::set(e, "status", p.status);
        json::set(e, "role", p.role);
        json::set(e, "sw", p.sw_version);
        json::setBool(e, "self", p.id == node_id);
        cJSON* addrs = json::addArr(e, "addrs");
        for (const auto& a : p.addrs) json::push(addrs, json::Doc(cJSON_CreateString(a.c_str())));
        // 表示名・door・ライブ映像 URL は設定から補完
        cJSON* dev = cfgAt("devices." + p.id);
        if (dev) {
          json::set(e, "name", json::getString(dev, "name", p.id.substr(0, 8)));
          std::string door = json::getString(dev, "door");
          if (!door.empty()) {
            json::set(e, "door", door);
            cJSON* d = cfgAt("doors." + door);
            if (d) json::set(e, "door_label", labelIn(json::get(d, "label"), "ja"));
          }
          if (json::getString(dev, "role") == "door_station" && !p.addrs.empty()) {
            json::set(e, "stream", "http://" + hostOf(p.addrs[0]) + ":47180/stream.mjpeg");
          }
        }
      }
    }
    return json::dump(o.get());
  }

  // ---------- HTTP ----------
  bool checkSession(const HttpReq& req) {
    std::string tok = req.cookie("dbsess");
    if (tok.empty()) return false;
    std::lock_guard<std::mutex> lk(sess_mu);
    return sessions.count(tok) > 0;
  }

  void registerHttp() {
    size_t n = 0;
    const WebAsset* assets = webuiAssets(&n);
    for (size_t i = 0; i < n; i++)
      httpd->setStatic(assets[i].path, assets[i].content_type,
                       Bytes(assets[i].data, assets[i].data + assets[i].len));

    // "/" (リダイレクトのみ) は gate 側で例外扱い — prefix リストに "/" を入れると全公開になる
    httpd->setAuth([this](const HttpReq& r) { return r.uri == "/" || checkSession(r); },
                   {"/api/login", "/locale/", "/panel/", "/admin/", "/stream.mjpeg",
                    "/snapshot.jpg"});

    httpd->route("GET", "/", [](const HttpReq&) {
      HttpResp r;
      r.status = 302;
      r.headers["Location"] = "/admin/";
      r.body = "";
      return r;
    });

    httpd->route("POST", "/api/login", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string pw = b ? json::getString(b.get(), "password") : "";
      if (pw.empty()) return HttpResp::json("{\"ok\":false}", 401);
      auto salt = store.metaGet("admin_pw_salt");
      auto hash = store.metaGet("admin_pw_hash");
      if (!salt || !hash) {  // 初回ログインでパスワード設定
        std::string s = genTokenHex(16);
        store.metaSet("admin_pw_salt", s);
        store.metaSet("admin_pw_hash", hashPassword(pw, s));
        DB_LOGI(kTag, "管理パスワードを初期設定した");
      } else if (hashPassword(pw, *salt) != *hash) {
        return HttpResp::json("{\"ok\":false}", 401);
      }
      std::string tok = genTokenHex(16);
      {
        std::lock_guard<std::mutex> lk(sess_mu);
        sessions.insert(tok);
        if (sessions.size() > 64) sessions.erase(sessions.begin());
      }
      HttpResp r = HttpResp::json("{\"ok\":true}");
      r.headers["Set-Cookie"] = "dbsess=" + tok + "; Path=/; HttpOnly; SameSite=Strict";
      return r;
    });

    httpd->route("GET", "/api/status",
                 [this](const HttpReq&) { return HttpResp::json(statusJsonOnLoop()); });

    httpd->route("GET", "/api/events", [this](const HttpReq& req) {
      size_t limit = 50;
      try {
        std::string l = req.param("limit");
        if (!l.empty()) limit = std::stoul(l);
      } catch (...) {
      }
      auto o = json::obj();
      cJSON* arr = json::addArr(o.get(), "events");
      for (const auto& ev : store.recentEvents(limit)) {
        cJSON* e = json::pushObj(arr);
        json::set(e, "type", ev.type);
        json::set(e, "door", ev.door);
        json::set(e, "device", ev.device);
        json::set(e, "wall_ms", ev.wall_ms);
        json::set(e, "payload", ev.payload_json);
      }
      return HttpResp::json(json::dump(o.get()));
    });

    httpd->route("GET", "/api/config", [this](const HttpReq&) {
      return HttpResp::json(config->materializeJson());
    });

    httpd->route("POST", "/api/config", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      if (!b) return HttpResp::json("{\"ok\":false,\"err\":\"bad json\"}", 400);
      std::string key = json::getString(b.get(), "key");
      std::string value = json::getString(b.get(), "value");
      if (key.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no key\"}", 400);
      setKey(key, value);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/press", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string door = b ? json::getString(b.get(), "door") : "";
      doPress(door);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/reply", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      if (!b) return HttpResp::json("{\"ok\":false}", 400);
      quickReply(json::getString(b.get(), "reply_id"), json::getString(b.get(), "text"),
                 json::getString(b.get(), "door"), "web");
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("GET", "/api/logs", [](const HttpReq&) {
      auto o = json::obj();
      cJSON* arr = json::addArr(o.get(), "logs");
      for (const auto& l : recentLogs(200))
        json::push(arr, json::Doc(cJSON_CreateString(l.c_str())));
      return HttpResp::json(json::dump(o.get()));
    });
  }

  void setKey(const std::string& key, const std::string& value) {
    auto v = json::parse(value);
    if (v) {
      config->set(key, value);
    } else {  // 生文字列は JSON 文字列として包む
      auto s = json::Doc(cJSON_CreateString(value.c_str()));
      config->set(key, json::dump(s.get()));
    }
  }

  void doPress(const std::string& door_arg) {
    std::string door = door_arg.empty() ? opts.door : door_arg;
    events->append("press", door, node_id, "{}");
  }
};

// ---------------- 公開 API ----------------

Node::Node(NodeOptions opts, NodeDeps deps) : impl_(new Impl) {
  impl_->opts = std::move(opts);
  if (deps.clock) {
    impl_->clock = deps.clock;
  } else {
    impl_->owned_clock.reset(new RealClock);
    impl_->clock = impl_->owned_clock.get();
  }
  if (deps.loop) {
    impl_->loop = deps.loop;
    impl_->external_loop = true;
  } else {
    impl_->owned_loop.reset(new Runloop(*impl_->clock));
    impl_->loop = impl_->owned_loop.get();
  }
  impl_->transport = std::move(deps.transport);
  impl_->discovery = std::move(deps.discovery);
}

Node::~Node() { stop(); }

bool Node::start() {
  if (impl_->started) return true;
  if (!impl_->external_loop) impl_->loop->start();
  bool ok = false;
  impl_->loop->callSync([&] { ok = impl_->init(); });
  if (ok) node_id_ = impl_->node_id;
  return ok;
}

void Node::stop() {
  if (!impl_ || !impl_->started) return;
  impl_->started = false;
#ifdef _WIN32
  // カメラ採集スレッドを先に止める (frame_bus への push を止めてから httpd を畳む)
  if (impl_->camera) impl_->camera->stop();
#endif
  // httpd は runloop の外から止める (worker が callSync 待ちのまま mg_stop すると死锁)
  if (impl_->httpd) impl_->httpd->stop();
  impl_->loop->callSync([&] {
    if (impl_->mesh) impl_->mesh->stop();
    if (impl_->discovery) impl_->discovery->stop();
  });
  if (!impl_->external_loop) impl_->loop->stop();
}

void Node::setUiEventCb(UiEventCb cb) {
  std::lock_guard<std::mutex> lk(impl_->cb_mu);
  impl_->ui_cb = std::move(cb);
}

void Node::setTtsCb(TtsCb cb) {
  std::lock_guard<std::mutex> lk(impl_->cb_mu);
  impl_->tts_cb = std::move(cb);
}

void Node::press(const std::string& door_id) {
  impl_->loop->callSync([&] { impl_->doPress(door_id); });
}

void Node::pushCameraFrame(const uint8_t* data, int format, int width, int height, int stride,
                           int64_t ts_ms) {
  if (!data || width <= 0 || height <= 0) return;
  size_t n = rawFrameBytes(format, width, height, stride);
  if (n == 0) return;  // 未知 format
  RawFrame f;
  f.format = format;
  f.w = width;
  f.h = height;
  f.stride = stride;
  f.ts_ms = ts_ms;
  f.data.assign(data, data + n);  // コピーはこの 1 回だけ
  impl_->frame_bus.push(std::move(f));
}

void Node::sendQuickReply(const std::string& reply_id, const std::string& free_text,
                          const std::string& door_id, const std::string& via) {
  impl_->loop->callSync([&] { impl_->quickReply(reply_id, free_text, door_id, via); });
}

std::string Node::statusJson() {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->statusJsonOnLoop(); });
  return out;
}

std::string Node::configJson() {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->config->materializeJson(); });
  return out;
}

void Node::setConfigKey(const std::string& key, const std::string& value_json) {
  impl_->loop->callSync([&] { impl_->setKey(key, value_json); });
}

Runloop& Node::loop() { return *impl_->loop; }

}  // namespace db
