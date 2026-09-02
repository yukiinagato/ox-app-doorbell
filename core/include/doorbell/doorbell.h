/* Public doorbell-core C ABI.
 * Strings are UTF-8. Memory returned by core is released with db_free().
 * Platform callbacks may run on core worker threads and must marshal UI work themselves.
 * Exceptions never cross this boundary; zero means success and negative values mean failure.
 */
#ifndef DOORBELL_H
#define DOORBELL_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(DOORBELL_DLL)
#define DB_API __declspec(dllexport)
#else
#define DB_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct db_core db_core;

/* Legacy platform SPI. This layout is frozen at six pointers for ABI compatibility.
 * New integrations must use db_platform_v2 and db_core_create_v2(). */
typedef struct db_platform {
  void* user;
  /* Synchronous HTTPS transport. Core invokes it from a worker thread, so it may block;
   * Telegram long polling can take about 30 seconds. headers_json is a JSON object and body
   * may be empty or binary. Allocate resp_body_out with malloc; core releases it with db_free.
   * Return zero when a response is received, including HTTP errors, and negative on transport
   * failure. db_core_destroy waits for every in-flight request to finish. */
  int (*https_request)(void* user, const char* method, const char* url,
                       const char* headers_json, const uint8_t* body, size_t body_len,
                       char** resp_body_out, int* http_status_out);
  /* Secure storage backed by DPAPI, Keystore, or Keychain. Core releases value_out. */
  int (*secure_get)(void* user, const char* key, char** value_out);
  int (*secure_put)(void* user, const char* key, const char* value);
  /* Log sink, where level ranges from zero (debug) to three (error). NULL uses stderr. */
  void (*log_line)(void* user, int level, const char* line);
  /* TTS for quick replies. lang is a language code such as "ja". NULL leaves only the chime. */
  void (*tts_speak)(void* user, const char* text, const char* lang);
} db_platform;

#define DB_PLATFORM_V2_VERSION 2u

/* Versioned platform SPI. struct_size must be sizeof(db_platform_v2) and version must be
 * DB_PLATFORM_V2_VERSION. release_buffer releases strings returned by platform callbacks;
 * when NULL, core falls back to free() for compatibility with existing shells. */
typedef struct db_platform_v2 {
  uint32_t struct_size;
  uint32_t version;
  void* user;
  int (*https_request)(void* user, const char* method, const char* url,
                       const char* headers_json, const uint8_t* body, size_t body_len,
                       char** resp_body_out, int* http_status_out);
  int (*secure_get)(void* user, const char* key, char** value_out);
  int (*secure_put)(void* user, const char* key, const char* value);
  void (*log_line)(void* user, int level, const char* line);
  void (*tts_speak)(void* user, const char* text, const char* lang);
  int (*device_info)(void* user, char** out_json);
  void (*release_buffer)(void* user, void* buffer);
} db_platform_v2;

/* JSON events delivered from core to the platform UI. Examples:
 * {"t":"state","state":"idle|calling|in_call|degraded|offline"}
 * {"t":"chime","sound":"ding1"} {"t":"config_changed"} {"t":"peers_changed"}
 * {"t":"reply","text":"<localized text>","ttl_s":30,"lang":"ja"}
 *   A cached custom reply includes a local audio_path. The shell plays it without TTS;
 *   otherwise core calls tts_speak.
 * {"t":"chime",...,"audio_path":"..."} for a cached sound "asset:<sha256>"
 * {"t":"visitor_lang","door":"d_front","lang":"en"} for a replicated language change
 * {"t":"asset_ready","hash":"<sha256>"} when a shared asset is ready locally
 * {"t":"display",...,"theme":{"bg_color":"#101418","bg_image":"<sha256>|null",
 *   "bg_image_path":"<local path>|null"}} for the idle-screen theme. The shell renders the
 *   local path directly; null means it is not cached and display is reissued after asset_ready.
 * {"t":"emergency","active":true,"alarm_sound":"siren1|asset:<sha256>","alarm_volume":100,
 *   "audio_path":"..."} where audio_path exists only for a cached custom alarm. */
typedef void (*db_ui_event_cb)(void* user, const char* event_json);

/* Create core with a writable data directory and bootstrap configuration in boot_json. */
DB_API db_core* db_core_create(const db_platform* platform, const char* data_dir,
                               const char* boot_json);
DB_API db_core* db_core_create_v2(const db_platform_v2* platform, const char* data_dir,
                                  const char* boot_json);
DB_API int db_core_start(db_core* c);
DB_API void db_core_stop(db_core* c);
DB_API void db_core_destroy(db_core* c);

DB_API void db_core_set_ui_callback(db_core* c, db_ui_event_cb cb, void* user);

/* Report a call-button press for a configured door ID. */
DB_API void db_core_press(db_core* c, const char* door_id);

/* Report a press with a visit_purposes key. NULL or empty purpose is equivalent to db_core_press.
 * The press payload includes purpose and the currently selected visitor_lang. */
DB_API void db_core_press_purpose(db_core* c, const char* door_id, const char* purpose);

/* Legacy purpose update: replicate purpose_selected without rerunning call rules. */
DB_API void db_core_select_purpose(db_core* c, const char* door_id, const char* purpose);

/* Legacy door-side cancellation: replicate call_cancelled to every node. */
DB_API void db_core_cancel_call(db_core* c, const char* door_id);

/* Versioned call flow. The returned call_id is released with db_free(). Updates are idempotent
 * and rejected when call_id does not identify the active call for the door. */
DB_API char* db_core_press_v2(db_core* c, const char* door_id, const char* purpose);
DB_API int db_core_select_purpose_v2(db_core* c, const char* door_id, const char* call_id,
                                     const char* purpose);
DB_API int db_core_cancel_call_v2(db_core* c, const char* door_id, const char* call_id,
                                  const char* reason);
/* Bind a shell-owned SIP dialog to the matching visitor call. Report answered only after the
 * dialog is established, and report ended only after that same dialog terminates. stage_revision
 * must match the active call; monitor sessions must not use these APIs. Calls are idempotent. */
DB_API int db_core_report_call_answered_v2(db_core* c, const char* door_id,
                                           const char* call_id, int stage_revision);
DB_API int db_core_report_call_ended_v2(db_core* c, const char* door_id,
                                        const char* call_id, int stage_revision,
                                        const char* reason);
/* A restarted shell confirms whether it restored media/UI for a call. Failure, or no report within
 * ten seconds after a recovery request, produces one global call_cancelled event. */
DB_API void db_core_report_call_recovery(db_core* c, const char* call_id, int restored);

/* Change the visitor language. Empty door selects the local shell's assigned door. lang must be
 * listed in ui.languages. The selection returns to Japanese after ui.visitor_lang_revert_s of
 * inactivity, and visitor_lang is delivered to every shell. */
DB_API void db_core_set_visitor_lang(db_core* c, const char* door, const char* lang);

/* Return a JSON snapshot of nodes, leaders, SIP state, and runtime state. Release with db_free. */
DB_API char* db_core_status_json(db_core* c);

/* Return diagnostic JSON for addresses, Wi-Fi, battery, press statistics, and reachability. */
DB_API char* db_core_debug_json(db_core* c);

/* Return fully materialized configuration JSON. Release with db_free. */
DB_API char* db_core_config_json(db_core* c);

/* Runtime contracts reported by a platform shell. JSON must be an object and is copied by core. */
DB_API void db_core_set_capabilities_json(db_core* c, const char* capabilities_json);
DB_API void db_core_set_runtime_status_json(db_core* c, const char* runtime_json);
DB_API void db_core_set_ui_manifest_json(db_core* c, const char* manifest_json);
DB_API char* db_core_capabilities_json(db_core* c);

/* Return pairing discovery and invitation state. Unpaired shells display self/pair_qr; paired
 * shells present pending devices for approval. Release the result with db_free. */
DB_API char* db_core_pairing_json(db_core* c);
/* Join an existing cluster with a PIN and seed. Completion is reported as
 * t:"join_result" followed by t:"paired". The paired event contains psk_ref,
 * never the PSK; secure_put must succeed before that event is emitted. */
DB_API void db_core_join_cluster(db_core* c, const char* host, const char* pin);
/* Create a new cluster with a random PSK. Returns 1 when started and 0 when the
 * node is already paired or creation fails. On success the shell persists the
 * psk_ref from t:"paired" in boot.json; the secret itself is already in secure storage. */
DB_API int db_core_found_cluster(db_core* c);
/* Enable pairing mode for the requested duration and automatically invite discovered devices. */
DB_API void db_core_pairing_mode(db_core* c, int seconds);
/* Start automatic pairing and mint a one-time PIN for manual joining. The returned JSON contains
 * ok, host, pin, and expires_s; the PIN is never persisted. Release the result with db_free. */
DB_API char* db_core_start_pairing_json(db_core* c, int seconds);
/* Request that an indoor-panel administrator remove one connected peer. The peer receives an
 * authenticated local-reset command and acknowledges it through its UI. */
DB_API void db_core_remove_device(db_core* c, const char* node_id);
/* Approve and invite one pending node. */
DB_API void db_core_invite_device(db_core* c, const char* id);
/* Invite an address, ID, and public key directly without discovery, for QR or routed networks. */
DB_API void db_core_invite_direct(db_core* c, const char* addr, const char* id, const char* pk);

/* Encode a QR bitmap as size*size row-major bytes, where one means dark. Returns NULL on failure;
 * release the result with db_free. */
DB_API unsigned char* db_core_qr_encode(const char* text, int* out_size);

/* Push a camera frame. format: 0=NV21, 1=NV12, 2=YUY2, 3=BGRA. */
DB_API void db_core_on_camera_frame(db_core* c, const uint8_t* data, int format, int width,
                                    int height, int stride, int64_t ts_ms);

/* Door-station orientation in clockwise degrees. Core normalizes to 0/90/180/270 and
 * applies it to live-video metadata when devices.<self>.local.video.rotation is auto. */
DB_API void db_core_set_video_sensor_rotation(db_core* c, int degrees);

/* Place or end a SIP call. target is an extension or full sip: URI. Empty mode is bidirectional;
 * "monitor" is one-way monitoring in which the receiver sends microphone audio only.
 * This is a no-op in builds without PJSIP. */
DB_API void db_core_sip_call(db_core* c, const char* target, const char* mode);
DB_API void db_core_sip_hangup(db_core* c);
DB_API int db_core_sip_send_dtmf(db_core* c, const char* digits);

/* Deliver an unscoped announcement to the door UI, TTS, and event stream. Empty door selects the
 * door from the latest press; while a schema-v2 call is active this legacy entry point fails
 * closed and cannot terminate it. Use db_core_quick_reply_v2 for a call reply. */
DB_API void db_core_quick_reply(db_core* c, const char* reply_id, const char* door);
/* Scoped quick reply. Returns zero only when call_id and stage_revision identify the active call;
 * invalid arguments return -1 and stale or rejected calls return -2. */
DB_API int db_core_quick_reply_v2(db_core* c, const char* reply_id, const char* door,
                                  const char* call_id, int stage_revision);

DB_API void db_free(char* p);

DB_API const char* db_core_version(void);
/* Compile-time SIP backend identity. Release artifacts must report "pjsip"; "stub" is
 * permitted only for explicitly marked development/display-only builds. */
DB_API const char* db_core_sip_backend(void);

/* Set or clear SOS. Emergency state is replicated to every node and delivered to each shell.
 * Authorization and PIN verification for clearing SOS remain the shell's responsibility. */
DB_API void db_core_emergency(db_core* c, int active);
/* Durable SOS variant. Returns one only after the event and its materialized projection commit;
 * shells should use this before showing an optimistic local acknowledgement. */
DB_API int db_core_emergency_v2(db_core* c, int active);

/* Core packages encoded H.264 into fMP4 at /stream.mp4. Platform hardware encoders produce the
 * bitstream; Windows uses the Media Foundation implementation hosted in core. */

/* Push one H.264 Annex-B access unit from any thread. SPS/PPS may be included or sent alone as a
 * codec-config buffer. Set is_keyframe for an IDR and ts_ms to the presentation timestamp.
 * Frames are ignored while camera.codec is mjpeg. */
DB_API void db_core_on_encoded_frame(db_core* c, const uint8_t* annexb, size_t len,
                                     int is_keyframe, int64_t ts_ms);

/* Return one when the shell should run its encoder: codec is h264/auto and /stream.mp4 has a
 * subscriber. Poll roughly every five seconds to avoid encoding without consumers. */
DB_API int db_core_video_encoder_wanted(db_core* c);

#ifdef __cplusplus
}
#endif

#endif /* DOORBELL_H */
