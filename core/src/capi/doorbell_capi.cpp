// C ABI 実装 (include/doorbell/doorbell.h)。平台殻はここだけを呼ぶ。
#include "doorbell/doorbell.h"

#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "node/node.h"
#include "util/common.h"
#include "util/json.h"
#include "util/log.h"

using namespace db;

// SPI https_request (同期) の在飛計数。destroy 時に完了を待つ
// (detach したスレッドが破棄済みの Node/loop へ done を返さないため)。
struct HttpsInflight {
  std::mutex mu;
  std::condition_variable cv;
  int count = 0;

  void add() {
    std::lock_guard<std::mutex> lk(mu);
    count++;
  }
  void done() {
    {
      std::lock_guard<std::mutex> lk(mu);
      count--;
    }
    cv.notify_all();
  }
  void waitIdle() {
    std::unique_lock<std::mutex> lk(mu);
    cv.wait(lk, [this] { return count == 0; });
  }
};

struct db_core {
  std::unique_ptr<Node> node;
  db_platform plat{};
  db_ui_event_cb ui_cb = nullptr;
  void* ui_user = nullptr;
  std::shared_ptr<HttpsInflight> https_inflight = std::make_shared<HttpsInflight>();
};

static char* dupString(const std::string& s) {
  char* p = static_cast<char*>(std::malloc(s.size() + 1));
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

extern "C" {

DB_API db_core* db_core_create(const db_platform* platform, const char* data_dir,
                               const char* boot_json) {
  if (!data_dir) return nullptr;
  auto b = json::parse(boot_json ? boot_json : "{}");
  if (!b) return nullptr;

  NodeOptions opts;
  opts.data_dir = data_dir;
  opts.name = json::getString(b.get(), "name", "doorbell");
  opts.role = json::getString(b.get(), "role", "door_station");
  opts.door = json::getString(b.get(), "door");
  int64_t listen_port = json::getInt(b.get(), "listen_port", 47172);
  opts.listen_addr = "0.0.0.0:" + std::to_string(listen_port);
  opts.advertise_addr = json::getString(b.get(), "advertise_addr");
  opts.http_port = static_cast<int>(json::getInt(b.get(), "http_port", 47180));
  opts.caps_json = json::getString(b.get(), "caps", "{}");
  if (cJSON* seeds = json::get(b.get(), "seed_peers")) {
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, seeds) {
      if (cJSON_IsString(it)) opts.seed_peers.push_back(it->valuestring);
    }
  }
  std::string psk_hex = json::getString(b.get(), "psk_hex");
  if (!psk_hex.empty()) {
    Bytes psk;
    if (!hexDecode(psk_hex, psk) || psk.size() != 32) {
      DB_LOGE("capi", "psk_hex が不正 (64 hex 必須)");
      return nullptr;
    }
    std::copy(psk.begin(), psk.end(), opts.psk.begin());
  }

  auto* c = new db_core;
  if (platform) c->plat = *platform;
  if (c->plat.log_line) {
    void* user = c->plat.user;
    auto fn = c->plat.log_line;
    setLogSink([fn, user](LogLevel lv, const std::string& line) {
      fn(user, static_cast<int>(lv), line.c_str());
    });
  }
  c->node.reset(new Node(std::move(opts)));
  if (c->plat.https_request) {
    // 同期 SPI を専用スレッドで呼んで非同期 HttpsFn に変換する (Telegram ブリッジ用)。
    // done は任意スレッド可の契約 (Node 側で Runloop へ marshal される)。
    void* user = c->plat.user;
    auto fn = c->plat.https_request;
    auto inflight = c->https_inflight;
    c->node->setHttpsFn([user, fn, inflight](
                            const std::string& method, const std::string& url,
                            const std::string& headers_json, const Bytes& body,
                            std::function<void(int, std::string)> done) {
      inflight->add();
      std::thread([user, fn, inflight, method, url, headers_json, body, done] {
        char* resp = nullptr;
        int status = 0;
        int rc = fn(user, method.c_str(), url.c_str(), headers_json.c_str(),
                    body.empty() ? nullptr : body.data(), body.size(), &resp, &status);
        std::string resp_body = resp ? resp : "";
        if (resp) std::free(resp);  // 契約: resp_body_out は core が db_free (=free) する
        done(rc == 0 ? status : -1, std::move(resp_body));
        inflight->done();
      }).detach();
    });
  }
  if (c->plat.tts_speak) {
    void* user = c->plat.user;
    auto fn = c->plat.tts_speak;
    c->node->setTtsCb([fn, user](const std::string& text, const std::string& lang) {
      fn(user, text.c_str(), lang.c_str());
    });
  }
  return c;
}

DB_API int db_core_start(db_core* c) {
  if (!c || !c->node) return -1;
  return c->node->start() ? 0 : -2;
}

DB_API void db_core_stop(db_core* c) {
  if (c && c->node) c->node->stop();
}

DB_API void db_core_destroy(db_core* c) {
  if (!c) return;
  setLogSink(nullptr);
  // 在飛の https_request (getUpdates 長輪詢を含む — 最大 ~30 秒) の完了を待ってから
  // Node を破棄する。done は Node 内の弱参照で捨てられるが loop 自体の生存が要る。
  c->https_inflight->waitIdle();
  delete c;
}

DB_API void db_core_set_ui_callback(db_core* c, db_ui_event_cb cb, void* user) {
  if (!c || !c->node) return;
  c->ui_cb = cb;
  c->ui_user = user;
  if (cb) {
    c->node->setUiEventCb([c](const std::string& ev) {
      if (c->ui_cb) c->ui_cb(c->ui_user, ev.c_str());
    });
  } else {
    c->node->setUiEventCb(nullptr);
  }
}

DB_API void db_core_press(db_core* c, const char* door_id) {
  if (c && c->node) c->node->press(door_id ? door_id : "");
}

DB_API char* db_core_status_json(db_core* c) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->statusJson());
}

DB_API char* db_core_config_json(db_core* c) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->configJson());
}

DB_API void db_core_on_camera_frame(db_core* c, const uint8_t* data, int format, int width,
                                    int height, int stride, int64_t ts_ms) {
  if (!c || !c->node) return;
  c->node->pushCameraFrame(data, format, width, height, stride, ts_ms);
}

DB_API void db_core_sip_call(db_core* c, const char* target, const char* mode) {
  if (!c || !c->node || !target || !*target) return;
  c->node->sipCall(target, mode ? mode : "");
}

DB_API void db_core_sip_hangup(db_core* c) {
  if (c && c->node) c->node->sipHangup();
}

DB_API void db_core_quick_reply(db_core* c, const char* reply_id, const char* door) {
  if (!c || !c->node || !reply_id || !*reply_id) return;
  c->node->sendQuickReply(reply_id, "", door ? door : "", "app");
}

DB_API void db_free(char* p) { std::free(p); }

DB_API const char* db_core_version(void) { return "0.1.0"; }

DB_API void db_core_emergency(db_core* c, int active) {
  if (c && c->node) c->node->setEmergency(active != 0, "panel");
}

}  // extern "C"
