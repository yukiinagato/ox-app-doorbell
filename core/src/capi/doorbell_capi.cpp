// C ABI 実装 (include/doorbell/doorbell.h)。平台殻はここだけを呼ぶ。
#include "doorbell/doorbell.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "node/node.h"
#include "util/common.h"
#include "util/json.h"
#include "util/log.h"

using namespace db;

struct db_core {
  std::unique_ptr<Node> node;
  db_platform plat{};
  db_ui_event_cb ui_cb = nullptr;
  void* ui_user = nullptr;
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
  // Phase 1: 帧総線 (MJPEG/動検/SIP ビデオ) へ配線する。現状は受け流し。
  (void)c;
  (void)data;
  (void)format;
  (void)width;
  (void)height;
  (void)stride;
  (void)ts_ms;
}

DB_API void db_free(char* p) { std::free(p); }

DB_API const char* db_core_version(void) { return "0.1.0"; }

}  // extern "C"
