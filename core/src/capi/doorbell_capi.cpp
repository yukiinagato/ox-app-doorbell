
#include "doorbell/doorbell.h"

#include "qrcodegen.h"

#include <condition_variable>
#include <ctime>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "media/fmp4_demux.h"
#include "media/qr_scanner.h"
#ifdef _WIN32
#include "media/decoder_win.h"
#endif
#include "node/node.h"
#include "sipctl/sipctl.h"
#include "util/common.h"
#include "util/json.h"
#include "util/log.h"

using namespace db;




#ifndef DB_VERSION_BASE
#define DB_VERSION_BASE "0.2.0"
#endif
#ifdef DB_BUILD_ID
#define DB_VERSION_FULL DB_VERSION_BASE "+" DB_BUILD_ID
#else
#define DB_VERSION_FULL DB_VERSION_BASE "+dev"
#endif



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
  db_platform_v2 plat{};
  db_ui_event_cb ui_cb = nullptr;
  void* ui_user = nullptr;
  std::shared_ptr<HttpsInflight> https_inflight = std::make_shared<HttpsInflight>();
};

static char* dupString(const std::string& s) {
  char* p = static_cast<char*>(std::malloc(s.size() + 1));
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

static void releasePlatformBuffer(const db_platform_v2& platform, void* p) {
  if (!p) return;
  if (platform.release_buffer) {
    platform.release_buffer(platform.user, p);
  } else {
    std::free(p);
  }
}

static db_core* createCore(const db_platform_v2& platform, const char* data_dir,
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
  if (cJSON* caps = json::get(b.get(), "caps")) {
    opts.caps_json = cJSON_IsString(caps) ? caps->valuestring : json::dump(caps);
  } else {
    auto generated_caps = json::obj();
    const bool has_network_transport = platform.https_request != nullptr;
    json::setBool(generated_caps.get(), "tls12", has_network_transport);
    // Transport availability does not prove that a configured Internet endpoint is reachable.
    json::setBool(generated_caps.get(), "wan", false);
    json::setBool(generated_caps.get(), "mains_power",
                  opts.role == "door_station" || opts.role == "indoor_panel");
    json::setBool(generated_caps.get(), "mqtt_reachable", false);
    json::setBool(generated_caps.get(), "wall_clock_sane",
                  std::time(nullptr) >= 1'577'836'800);
    json::set(generated_caps.get(), "cpu_score", static_cast<int64_t>(0));
    opts.caps_json = json::dump(generated_caps.get());
  }
  opts.caps_json = sanitizeCaps(opts.caps_json, platform.https_request != nullptr);
  opts.has_https = platform.https_request != nullptr;
  opts.sw_version = DB_VERSION_FULL;
  if (cJSON* seeds = json::get(b.get(), "seed_peers")) {
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, seeds) {
      if (cJSON_IsString(it)) opts.seed_peers.push_back(it->valuestring);
    }
  }
  opts.model = json::getString(b.get(), "model", "unknown");
  opts.platform = json::getString(b.get(), "platform", "unknown");
  std::string psk_hex = json::getString(b.get(), "psk_hex");
  const std::string psk_ref = json::getString(b.get(), "psk_ref");
  // Provenance decides what pairing.psk_source reports: a secret reference resolved through the
  // platform store, or a plaintext key still sitting in boot.json.
  if (!psk_hex.empty()) opts.psk_source = "boot_plaintext";
  if (psk_hex.empty() && psk_ref.rfind("secret:", 0) == 0 && psk_ref.size() > 7 &&
      platform.secure_get) {
    char* value = nullptr;
    if (platform.secure_get(platform.user, psk_ref.c_str() + 7, &value) == 0 && value)
      psk_hex = value;
    releasePlatformBuffer(platform, value);
    if (!psk_hex.empty()) {
      opts.psk_source = "secure_store";
      opts.psk_ref = psk_ref;
    }
  }
  if (!psk_hex.empty()) {
    Bytes psk;
    if (!hexDecode(psk_hex, psk) || psk.size() != 32) {
      DB_LOGE("capi", "psk_hex must contain exactly 64 hexadecimal characters");
      return nullptr;
    }
    std::copy(psk.begin(), psk.end(), opts.psk.begin());
  }

  auto* c = new db_core;
  c->plat = platform;
  if (c->plat.log_line) {
    void* user = c->plat.user;
    auto fn = c->plat.log_line;
    setLogSink([fn, user](LogLevel lv, const std::string& line) {
      fn(user, static_cast<int>(lv), line.c_str());
    });
  }
  c->node.reset(new Node(std::move(opts)));
  if (c->plat.https_request) {
    void* user = c->plat.user;
    auto fn = c->plat.https_request;
    auto inflight = c->https_inflight;
    db_platform_v2 copied_platform = c->plat;
    c->node->setHttpsFn([user, fn, inflight, copied_platform](
                            const std::string& method, const std::string& url,
                            const std::string& headers_json, const Bytes& body,
                            std::function<void(int, std::string)> done) {
      inflight->add();
      std::thread([user, fn, inflight, copied_platform, method, url, headers_json, body, done] {
        char* resp = nullptr;
        int status = 0;
        int rc = fn(user, method.c_str(), url.c_str(), headers_json.c_str(),
                    body.empty() ? nullptr : body.data(), body.size(), &resp, &status);
        std::string resp_body = resp ? resp : "";
        releasePlatformBuffer(copied_platform, resp);
        done(rc == 0 ? status : -1, std::move(resp_body));
        inflight->done();
      }).detach();
    });
  }
  if (c->plat.secure_get || c->plat.secure_put) {
    void* user = c->plat.user;
    auto get_fn = c->plat.secure_get;
    auto put_fn = c->plat.secure_put;
    db_platform_v2 copied_platform = c->plat;
    c->node->setSecureStore(
        get_fn ? Node::SecureGetFn([user, get_fn, copied_platform](const std::string& key) {
          char* value = nullptr;
          const int rc = get_fn(user, key.c_str(), &value);
          std::string result = (rc == 0 && value) ? value : "";
          releasePlatformBuffer(copied_platform, value);
          return result;
        }) : Node::SecureGetFn{},
        put_fn ? Node::SecurePutFn([user, put_fn](const std::string& key,
                                                  const std::string& value) {
          return put_fn(user, key.c_str(), value.c_str()) == 0;
        }) : Node::SecurePutFn{});
  }
  if (c->plat.secure_delete) {
    void* user = c->plat.user;
    auto del_fn = c->plat.secure_delete;
    c->node->setSecureDelete([user, del_fn](const std::string& key) {
      return del_fn(user, key.c_str()) == 0;
    });
  }
  if (c->plat.tts_speak) {
    void* user = c->plat.user;
    auto fn = c->plat.tts_speak;
    c->node->setTtsCb([fn, user](const std::string& text, const std::string& lang) {
      fn(user, text.c_str(), lang.c_str());
    });
  }
  if (c->plat.power_state) {
    void* user = c->plat.user;
    auto fn = c->plat.power_state;
    db_platform_v2 copied_platform = c->plat;
    c->node->setPowerStateFn([user, fn, copied_platform]() -> std::string {
      char* out = nullptr;
      const int rc = fn(user, &out);
      std::string result = (rc == 0 && out) ? out : "";
      releasePlatformBuffer(copied_platform, out);
      return result;
    });
  }
  if (c->plat.device_info) {
    void* user = c->plat.user;
    auto fn = c->plat.device_info;
    db_platform_v2 copied_platform = c->plat;
    c->node->setDeviceInfoFn([user, fn, copied_platform]() -> std::string {
      char* out = nullptr;
      int rc = fn(user, &out);
      std::string s = (rc == 0 && out) ? out : "";
      releasePlatformBuffer(copied_platform, out);
      return s;
    });
  }
  return c;
}

extern "C" {

DB_API db_core* db_core_create(const db_platform* platform, const char* data_dir,
                               const char* boot_json) {
  db_platform_v2 v2{};
  v2.struct_size = sizeof(v2);
  v2.version = DB_PLATFORM_V2_VERSION;
  if (platform) {
    v2.user = platform->user;
    v2.https_request = platform->https_request;
    v2.secure_get = platform->secure_get;
    v2.secure_put = platform->secure_put;
    v2.log_line = platform->log_line;
    v2.tts_speak = platform->tts_speak;
  }
  return createCore(v2, data_dir, boot_json);
}

DB_API db_core* db_core_create_v2(const db_platform_v2* platform, const char* data_dir,
                                  const char* boot_json) {
  db_platform_v2 v2{};
  v2.struct_size = sizeof(v2);
  v2.version = DB_PLATFORM_V2_VERSION;
  if (platform) {
    // Only published layouts of this version are accepted: the current size, or one of the
    // earlier published sizes, so a shell that has not been rebuilt still starts. Fields added
    // after the size it declares stay NULL and the corresponding feature is simply absent.
    const size_t kSizeBeforeSecureDelete = offsetof(db_platform_v2, secure_delete);
    const size_t kSizeBeforePowerState = offsetof(db_platform_v2, power_state);
    if (platform->version != DB_PLATFORM_V2_VERSION ||
        (platform->struct_size != sizeof(db_platform_v2) &&
         platform->struct_size != kSizeBeforeSecureDelete &&
         platform->struct_size != kSizeBeforePowerState)) {
      return nullptr;
    }
    std::memcpy(&v2, platform, platform->struct_size);
    v2.struct_size = sizeof(v2);
  }
  return createCore(v2, data_dir, boot_json);
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

DB_API void db_core_press_purpose(db_core* c, const char* door_id, const char* purpose) {
  if (c && c->node) c->node->press(door_id ? door_id : "", purpose ? purpose : "");
}

DB_API void db_core_select_purpose(db_core* c, const char* door_id, const char* purpose) {
  if (c && c->node) c->node->selectPurpose(door_id ? door_id : "", purpose ? purpose : "");
}

DB_API void db_core_cancel_call(db_core* c, const char* door_id) {
  if (c && c->node) c->node->cancelCall(door_id ? door_id : "");
}

DB_API char* db_core_press_v2(db_core* c, const char* door_id, const char* purpose) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->pressV2(door_id ? door_id : "", purpose ? purpose : ""));
}

DB_API int db_core_select_purpose_v2(db_core* c, const char* door_id, const char* call_id,
                                     const char* purpose) {
  if (!c || !c->node || !call_id || !*call_id || !purpose || !*purpose) return -1;
  return c->node->selectPurposeV2(door_id ? door_id : "", call_id, purpose) ? 0 : -2;
}

DB_API int db_core_cancel_call_v2(db_core* c, const char* door_id, const char* call_id,
                                  const char* reason) {
  if (!c || !c->node || !call_id || !*call_id) return -1;
  return c->node->cancelCallV2(door_id ? door_id : "", call_id,
                               reason && *reason ? reason : "visitor") ? 0 : -2;
}

DB_API int db_core_report_call_answered_v2(db_core* c, const char* door_id,
                                           const char* call_id, int stage_revision) {
  if (!c || !c->node || !call_id || !*call_id || stage_revision < 0) return -1;
  return c->node->reportCallAnsweredV2(door_id ? door_id : "", call_id,
                                       stage_revision) ? 0 : -2;
}

DB_API int db_core_report_call_ended_v2(db_core* c, const char* door_id,
                                        const char* call_id, int stage_revision,
                                        const char* reason) {
  if (!c || !c->node || !call_id || !*call_id || stage_revision < 0) return -1;
  return c->node->reportCallEndedV2(door_id ? door_id : "", call_id,
                                    stage_revision,
                                    reason && *reason ? reason : "sip_ended") ? 0 : -2;
}

DB_API void db_core_report_call_recovery(db_core* c, const char* call_id, int restored) {
  if (c && c->node && call_id && *call_id) c->node->reportCallRecovery(call_id, restored != 0);
}

DB_API void db_core_set_visitor_lang(db_core* c, const char* door, const char* lang) {
  if (c && c->node && lang && *lang) c->node->setVisitorLang(door ? door : "", lang);
}

DB_API char* db_core_status_json(db_core* c) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->statusJson());
}

DB_API char* db_core_debug_json(db_core* c) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->debugJson());
}

DB_API char* db_core_call_log_json(db_core* c, int64_t since_ms, int limit) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->callLogJson(since_ms, limit));
}

DB_API int db_core_call_log_mark_seen(db_core* c, const char* up_to_hlc) {
  if (!c || !c->node) return -1;
  return c->node->markCallLogSeen(up_to_hlc ? up_to_hlc : "") ? 0 : -2;
}

DB_API char* db_core_config_json(db_core* c) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->configJson());
}

DB_API int db_core_sip_set_mic_muted(db_core* c, int muted) {
  if (!c || !c->node) return -1;
  c->node->setSipMicMuted(muted != 0);
  return 0;
}

DB_API int db_core_admin_password_verify(db_core* c, const char* pw) {
  // -1 is "locked out" in this contract, so a bad argument reports -3 instead.
  if (!c || !c->node || !pw) return -3;
  return c->node->verifyAdminPassword(pw);
}

DB_API int db_core_admin_password_set(db_core* c, const char* current_or_empty,
                                      const char* new_pw) {
  if (!c || !c->node || !new_pw) return -1;
  return c->node->setAdminPassword(current_or_empty ? current_or_empty : "", new_pw);
}

DB_API int db_core_set_config_json(db_core* c, const char* key, const char* value_json) {
  if (!c || !c->node || !key || !*key || !value_json) return -1;
  auto result = json::parse(c->node->setConfigJson(key, value_json));
  return (result && json::getBool(result.get(), "ok")) ? 0 : -2;
}

DB_API char* db_core_last_write_warnings_json(db_core* c) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->lastWriteWarningsJson());
}

DB_API char* db_core_config_batch_json(db_core* c, const char* ops_json) {
  if (!c || !c->node || !ops_json) return nullptr;
  return dupString(c->node->configBatchJson(ops_json));
}

DB_API int db_core_delete_config_key(db_core* c, const char* key) {
  if (!c || !c->node || !key || !*key) return -1;
  auto result = json::parse(c->node->deleteConfigKeyJson(key));
  return (result && json::getBool(result.get(), "ok")) ? 0 : -2;
}

DB_API char* db_core_call_log_json_v2(db_core* c, int64_t since_ms, int64_t before_ms,
                                      int limit) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->callLogJson(since_ms, before_ms, limit));
}

DB_API char* db_core_local_time_json(db_core* c, int64_t wall_ms) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->localTimeJson(wall_ms));
}

DB_API int db_core_time_sync_now(db_core* c) {
  if (!c || !c->node) return 0;
  return c->node->syncTimeNow() ? 1 : 0;
}

DB_API char* db_core_audio_json(db_core* c, const char* device_id) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->audioJson(device_id ? device_id : ""));
}

DB_API int db_core_set_door_notice(db_core* c, const char* door, const char* text,
                                   int64_t expires_ms) {
  if (!c || !c->node || !door || !*door || !text || !*text) return -1;
  return c->node->setDoorNotice(door, text, expires_ms) ? 0 : -2;
}

DB_API int db_core_clear_door_notice(db_core* c, const char* door) {
  if (!c || !c->node || !door || !*door) return -1;
  return c->node->clearDoorNotice(door) ? 0 : -2;
}

DB_API int db_core_open_door(db_core* c, const char* door) {
  if (!c || !c->node || !door || !*door) return -1;
  // The node reports one failure; separate "unknown door" from "nothing configured" here so the
  // shell can tell the visitor-facing message from the administrator-facing one.
  auto status = json::parse(c->node->statusJson());
  const cJSON* entry =
      status ? json::get(json::get(status.get(), "doors"), door) : nullptr;
  if (!cJSON_IsObject(entry)) return -2;
  if (!json::getBool(json::get(entry, "unlock"), "configured", false)) return -3;
  return c->node->openDoor(door) ? 0 : -3;
}

DB_API void db_core_set_capabilities_json(db_core* c, const char* capabilities_json) {
  if (c && c->node && capabilities_json)
    c->node->setRuntimeCapabilities(capabilities_json);
}

DB_API void db_core_set_runtime_status_json(db_core* c, const char* runtime_json) {
  if (c && c->node && runtime_json) c->node->setRuntimeStatus(runtime_json);
}

DB_API void db_core_set_ui_manifest_json(db_core* c, const char* manifest_json) {
  if (c && c->node && manifest_json) c->node->setUiManifest(manifest_json);
}

DB_API char* db_core_capabilities_json(db_core* c) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->capabilitiesJson());
}

DB_API char* db_core_pairing_json(db_core* c) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->pairingJson());
}

DB_API void db_core_join_cluster(db_core* c, const char* host, const char* pin) {
  if (!c || !c->node || !host || !*host || !pin || !*pin) return;
  c->node->joinCluster(host, pin);
}

DB_API void db_core_pairing_mode(db_core* c, int seconds) {
  if (c && c->node) c->node->setPairingMode(seconds);
}

DB_API char* db_core_parse_pair_uri_json(db_core* c, const char* uri) {
  if (!c || !c->node || !uri) return nullptr;
  return dupString(c->node->parsePairUriJson(uri));
}

DB_API char* db_core_mint_join_token_json(db_core* c, int seconds) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->mintJoinTokenJson(seconds));
}

DB_API char* db_core_start_pairing_json(db_core* c, int seconds) {
  if (!c || !c->node) return nullptr;
  return dupString(c->node->startPairingJson(seconds));
}

DB_API void db_core_remove_device(db_core* c, const char* node_id) {
  if (c && c->node && node_id && *node_id) c->node->removeDevice(node_id);
}

DB_API int db_core_found_cluster(db_core* c) {
  if (!c || !c->node) return 0;
  return c->node->foundCluster() ? 1 : 0;
}

DB_API void db_core_invite_device(db_core* c, const char* id) {
  if (c && c->node && id && *id) c->node->inviteDevice(id);
}

DB_API void db_core_invite_direct(db_core* c, const char* addr, const char* id, const char* pk) {
  if (c && c->node && addr && *addr && id && *id && pk && *pk)
    c->node->inviteDeviceDirect(addr, id, pk);
}

DB_API void db_core_deny_device(db_core* c, const char* id) {
  if (c && c->node && id && *id) c->node->denyDevice(id);
}

DB_API int db_core_retry_pairing_persistence(db_core* c) {
  if (!c || !c->node) return 0;
  return c->node->retryPairingPersistence() ? 1 : 0;
}

DB_API void db_core_unpair(db_core* c) {
  if (c && c->node) c->node->unpair();
}



DB_API unsigned char* db_core_qr_encode(const char* text, int* out_size) {
  if (out_size) *out_size = 0;
  if (!text || !*text) return nullptr;
  std::vector<uint8_t> qr(qrcodegen_BUFFER_LEN_MAX), tmp(qrcodegen_BUFFER_LEN_MAX);
  if (!qrcodegen_encodeText(text, tmp.data(), qr.data(), qrcodegen_Ecc_MEDIUM,
                            qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO,
                            true)) {
    return nullptr;
  }
  const int size = qrcodegen_getSize(qr.data());
  if (size <= 0) return nullptr;
  auto* out = static_cast<unsigned char*>(std::malloc(static_cast<size_t>(size) * size));
  if (!out) return nullptr;
  for (int y = 0; y < size; y++)
    for (int x = 0; x < size; x++)
      out[y * size + x] = qrcodegen_getModule(qr.data(), x, y) ? 1 : 0;
  if (out_size) *out_size = size;
  return out;
}

DB_API int db_core_qr_decode(const uint8_t* gray, int w, int h, char** text_out) {
  if (text_out) *text_out = nullptr;
  if (!gray || !text_out || w <= 0 || h <= 0) return -1;
  std::string text;
  if (!db::qrDecodeGray(gray, w, h, &text)) return 1;
  char* out = dupString(text);
  if (!out) return -1;
  *text_out = out;
  return 0;
}

DB_API void db_core_qr_scan_start(db_core* c) {
  if (c && c->node) c->node->startQrScan();
}

DB_API void db_core_qr_scan_stop(db_core* c) {
  if (c && c->node) c->node->stopQrScan();
}

DB_API void db_core_on_camera_frame(db_core* c, const uint8_t* data, int format, int width,
                                    int height, int stride, int64_t ts_ms) {
  if (!c || !c->node) return;
  c->node->pushCameraFrame(data, format, width, height, stride, ts_ms);
}

DB_API void db_core_set_video_sensor_rotation(db_core* c, int degrees) {
  if (c && c->node) c->node->setVideoSensorRotation(degrees);
}

DB_API void db_core_sip_call(db_core* c, const char* target, const char* mode) {
  if (!c || !c->node || !target || !*target) return;
  c->node->sipCall(target, mode ? mode : "");
}

DB_API void db_core_sip_hangup(db_core* c) {
  if (c && c->node) c->node->sipHangup();
}

DB_API int db_core_sip_send_dtmf(db_core* c, const char* digits) {
  if (!c || !c->node || !digits || !*digits) return -1;
  return c->node->sipSendDtmf(digits) ? 0 : -2;
}

DB_API void db_core_quick_reply(db_core* c, const char* reply_id, const char* door) {
  if (!c || !c->node || !reply_id || !*reply_id) return;
  c->node->sendQuickReply(reply_id, "", door ? door : "", "app");
}

DB_API int db_core_quick_reply_v2(db_core* c, const char* reply_id, const char* door,
                                  const char* call_id, int stage_revision) {
  if (!c || !c->node || !reply_id || !*reply_id || !call_id || !*call_id ||
      stage_revision < 0)
    return -1;
  return c->node->sendQuickReplyV2(reply_id, "", door ? door : "", call_id,
                                   stage_revision) ? 0 : -2;
}

DB_API void db_free(char* p) { std::free(p); }

DB_API const char* db_core_version(void) { return DB_VERSION_FULL; }

DB_API const char* db_core_sip_backend(void) { return db::sipBackendName(); }

DB_API void db_core_emergency(db_core* c, int active) {
  (void)db_core_emergency_v2(c, active);
}

DB_API int db_core_emergency_v2(db_core* c, int active) {
  if (!c || !c->node) return 0;
  return c->node->setEmergencyV2(active != 0, "panel") ? 1 : 0;
}

DB_API void db_core_on_encoded_frame(db_core* c, const uint8_t* annexb, size_t len,
                                     int is_keyframe, int64_t ts_ms) {
  if (!c || !c->node || !annexb || len == 0) return;
  c->node->pushEncodedFrame(annexb, len, is_keyframe != 0, ts_ms);
}

#ifdef _WIN32
struct db_h264_player {
  db_h264_frame_cb frame_cb = nullptr;
  db_h264_state_cb state_cb = nullptr;
  void* user = nullptr;
  fmp4::Demuxer demux;
  std::unique_ptr<DecoderWin> decoder;
  std::mutex state_mu;

  void emitState(const json::Doc& doc) {
    std::string text = json::dump(doc.get());
    std::lock_guard<std::mutex> lk(state_mu);
    if (state_cb) state_cb(user, text.c_str());
  }
  void emitSimple(const char* t, const char* key, const std::string& value) {
    json::Doc d = json::obj();
    json::set(d.get(), "t", t);
    json::set(d.get(), key, value);
    emitState(d);
  }
};

DB_API db_h264_player* db_h264_player_create(db_h264_frame_cb frame_cb,
                                             db_h264_state_cb state_cb, void* user) {
  auto* p = new db_h264_player();
  p->frame_cb = frame_cb;
  p->state_cb = state_cb;
  p->user = user;
  db_h264_player* raw = p;
  p->decoder = std::make_unique<DecoderWin>(
      [raw](const DecoderWin::Frame& f) {
        if (raw->frame_cb)
          raw->frame_cb(raw->user, f.bgra, f.width, f.height, f.stride, f.capture_ms);
      },
      [raw](const std::string& state, const std::string& detail) {
        if (state == "configured") {
          DecoderWin::Stats st = raw->decoder->stats();
          json::Doc d = json::obj();
          json::set(d.get(), "t", "configured");
          json::set(d.get(), "width", static_cast<int64_t>(st.width));
          json::set(d.get(), "height", static_cast<int64_t>(st.height));
          json::set(d.get(), "decoder", detail);
          raw->emitState(d);
        } else if (state == "first_frame") {
          json::Doc d = json::obj();
          json::set(d.get(), "t", "first_frame");
          json::set(d.get(), "ms", static_cast<int64_t>(std::atoll(detail.c_str())));
          raw->emitState(d);
        } else {
          raw->emitSimple("error", "reason", detail);
        }
      });
  p->demux.on_config = [raw](const fmp4::Demuxer::Config& cfg) {
    raw->decoder->configure(cfg);
  };
  p->demux.on_sample = [raw](fmp4::Demuxer::AccessUnit&& au) {
    raw->decoder->feed(std::move(au));
  };
  p->decoder->start();
  return p;
}

DB_API int db_h264_player_feed(db_h264_player* p, const uint8_t* data, size_t len) {
  if (!p) return -1;
  if (!p->demux.feed(data, len)) {
    p->emitSimple("parse_error", "reason", p->demux.error());
    return -1;
  }
  return p->decoder && p->decoder->running() ? 0 : -1;
}

DB_API char* db_h264_player_stats_json(db_h264_player* p) {
  if (!p || !p->decoder) return nullptr;
  DecoderWin::Stats st = p->decoder->stats();
  json::Doc d = json::obj();
  json::set(d.get(), "received", static_cast<int64_t>(st.received));
  json::set(d.get(), "decoded", static_cast<int64_t>(st.decoded));
  json::set(d.get(), "dropped", static_cast<int64_t>(st.dropped));
  json::set(d.get(), "errors", static_cast<int64_t>(st.errors));
  json::set(d.get(), "width", static_cast<int64_t>(st.width));
  json::set(d.get(), "height", static_cast<int64_t>(st.height));
  json::set(d.get(), "first_frame_ms", static_cast<int64_t>(st.first_frame_ms));
  json::set(d.get(), "buffered", static_cast<int64_t>(p->demux.buffered()));
  json::set(d.get(), "decoder", st.decoder);
  return dupString(json::dump(d.get()));
}

DB_API void db_h264_player_destroy(db_h264_player* p) {
  if (!p) return;
  {
    std::lock_guard<std::mutex> lk(p->state_mu);
    p->state_cb = nullptr;
    p->frame_cb = nullptr;
  }
  if (p->decoder) p->decoder->stop();
  delete p;
}
#else
DB_API db_h264_player* db_h264_player_create(db_h264_frame_cb, db_h264_state_cb, void*) {
  return nullptr;
}
DB_API int db_h264_player_feed(db_h264_player*, const uint8_t*, size_t) { return -1; }
DB_API char* db_h264_player_stats_json(db_h264_player*) { return nullptr; }
DB_API void db_h264_player_destroy(db_h264_player*) {}
#endif

DB_API int db_core_video_encoder_wanted(db_core* c) {
  if (!c || !c->node) return 0;
  return c->node->videoEncoderWanted() ? 1 : 0;
}

DB_API int db_core_take_video_keyframe_request(db_core* c) {
  if (!c || !c->node) return 0;
  return c->node->takeVideoKeyframeRequest() ? 1 : 0;
}

}  // extern "C"
