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

/* Versioned platform SPI. version must be DB_PLATFORM_V2_VERSION and struct_size must be either
 * sizeof(db_platform_v2) or one of the earlier published sizes of this same version; any other
 * value is rejected. Fields are only appended, so a shell built against an older header keeps
 * working unchanged. release_buffer releases strings returned by platform callbacks; when NULL,
 * core falls back to free() for compatibility with existing shells. */
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
  /* Optional: remove a secret. Return zero on success. NULL means the platform cannot delete,
   * and core then leaves an orphaned entry behind when pairing is cleared. */
  int (*secure_delete)(void* user, const char* key);
  /* Optional: battery and power state, polled about once a minute on the core runloop. Allocate
   * out_json with malloc; core releases it with release_buffer (or free() when that is NULL).
   * Return zero on success. The document is
   *   {"battery_pct":<-1..100>,"charging":bool,"mains":bool}
   * where battery_pct is -1 on a device with no battery, charging means the battery is being
   * charged right now, and mains means external power is connected. A measured mains value
   * becomes the node's mains_power capability. NULL, a failure, or an empty document leaves the
   * previous reading in place and the device simply reports no power state. */
  int (*power_state)(void* user, char** out_json);
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
 * {"t":"call_log_changed","unread_missed":N} after every call-lifecycle event and after the seen
 *   watermark moves. The shell refreshes the history list and the idle-screen missed badge.
 * {"t":"device_alert","kind":"call_missed","door":"d_front","call_id":"…","unread_missed":N,
 *   "visual":true,"sticky":false,"ttl_s":30,"channels":[…]} when a rule matches a missed call.
 * {"t":"display",...,"theme":{"bg_color":"#101418","bg_image":"<sha256>|null",
 *   "bg_image_path":"<local path>|null"}} for the idle-screen theme. The shell renders the
 *   local path directly; null means it is not cached and display is reissued after asset_ready.
 * {"t":"emergency","active":true,"alarm_sound":"siren1|asset:<sha256>","alarm_volume":100,
 *   "audio_path":"..."} where audio_path exists only for a cached custom alarm.
 * {"t":"time_changed","source":"system|ntp","offset_ms":0,"zone":"Asia/Tokyo"} when the time
 *   source flips or the applied correction moves by more than 500 ms. Every clock the shell
 *   renders should be redrawn; timestamps already recorded are not rewritten.
 * {"t":"power_changed","battery_pct":82,"charging":false,"mains":true} when the battery moves
 *   by five points or more, or charging/mains flips.
 * {"t":"notice_changed","door":"d_front","active":true} when a door announcement is published,
 *   replaced, expired, or cleared anywhere in the cluster. */
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

/* Call history for this device. since_ms is an inclusive lower bound on a row's
 * timestamp; pass 0 for the whole history. limit is clamped to 1..500 and defaults to 50 when it
 * is not positive. Rows are newest first, and concurrency losers, fenced calls, and calls that are
 * still ringing or connected never appear.
 *
 * {"rows":[{"id":"<origin>:<seq>","call_id":"…","ts":<wall ms>,"door":"d_front",
 *           "purpose":"p_delivery","visitor_lang":"en",
 *           "outcome":"answered|replied|missed|cancelled","answered_by":"<device or empty>",
 *           "duration_ms":0,"snapshot":"<sha256 or empty>","hlc":"…","seen":true}],
 *  "unread_missed":0,"seen_hlc":"…","server_ts":<wall ms>}
 *
 * unread_missed counts missed calls newer than the device-local seen watermark; it is what the
 * idle-screen badge shows. Returns NULL on invalid arguments; release the result with db_free. */
DB_API char* db_core_call_log_json(db_core* c, int64_t since_ms, int limit);

/* Move the device-local seen watermark so the missed-call badge clears. up_to_hlc is a row "hlc"
 * from db_core_call_log_json; NULL or an empty string marks every currently known call as seen.
 * The watermark is never replicated and never moves backwards. Returns 0 on success and a
 * negative value on invalid arguments, a core that has not been started, or a persistence
 * failure. A successful call emits
 * {"t":"call_log_changed","unread_missed":N} through the UI callback. */
DB_API int db_core_call_log_mark_seen(db_core* c, const char* up_to_hlc);

/* Return fully materialized configuration JSON. Release with db_free. */
DB_API char* db_core_config_json(db_core* c);

/* ---- Time service ----
 * Core never sets the operating-system clock. When time.ntp.enabled is on and a sync succeeded
 * within three intervals, core adds its measured offset to every wall-clock reading: the HLC,
 * event and call-history timestamps, rule schedules, and quiet hours. status.time reports
 *   {"zone":"Asia/Tokyo","zone_known":true,"source":"system|ntp","enabled":bool,"ok":bool,
 *    "offset_ms":0,"measured_offset_ms":0,"last_sync_ms":0,"rtt_ms":0,"server":"",
 *    "interval_s":900,"offset_min":540,"syncing":false,"err":"…","local":{…}}
 * where offset_ms is the correction actually applied (zero while the source is system) and
 * measured_offset_ms is the last measurement regardless.
 *
 * Render a wall-clock instant in the configured IANA zone. wall_ms of zero means "now"; the zone
 * comes from a table bundled in core, so a shell on a platform without a usable tz database is
 * still correct. Returns
 *   {"iso":"2026-09-02T21:30:00+09:00","date":"2026-09-02","hh":21,"mm":30,"ss":0,
 *    "weekday":"wed","weekday_num":3,"offset_min":540,"dst":false,"known":true,
 *    "wall_ms":…,"tz":"Asia/Tokyo"}
 * known is false when the configured zone is absent from the table, in which case
 * integrations.tz_offset_min was used. Release the result with db_free. */
DB_API char* db_core_local_time_json(db_core* c, int64_t wall_ms);

/* Start one immediate SNTP round, the same one POST /api/time/sync triggers. The exchange runs
 * on a short-lived worker thread; poll status.time (or wait for time_changed) for the result.
 * Returns 1 when a round started or one is already running, and 0 when NTP is disabled or the
 * core is not started. */
DB_API int db_core_time_sync_now(db_core* c);

/* Effective audio volumes for one device. device_id may be NULL or empty for this node. The
 * resolution order is the device override devices.<id>.local.audio.volume.<level>, then the
 * cluster default audio.volume.<level>, then the built-in default (call 80, sos 100, idle 60);
 * the sos level additionally falls back to emergency.alarm_volume so an existing installation
 * keeps its configured alarm loudness. Returns
 *   {"device":"<id>","call":80,"sos":100,"idle":60,"source":"device|cluster|default",
 *    "sources":{"call":"…","sos":"…","idle":"…"}}
 * where source is the strongest source among the three levels. Release with db_free. */
DB_API char* db_core_audio_json(db_core* c, const char* device_id);

/* ---- Announcements ----
 * Publish a replicated announcement for one door. text is 1..200 characters; expires_ms is an
 * absolute wall-clock deadline in milliseconds and zero means "until cleared". Core records the
 * publishing device and the creation time, replicates the value as doors.<id>.notice, prunes it
 * once the deadline passes, and emits notice_changed. Returns 0 on success and a negative value
 * for a null core, an unknown door, text outside the length limit, or a persistence failure. */
DB_API int db_core_set_door_notice(db_core* c, const char* door, const char* text,
                                   int64_t expires_ms);
/* Remove the announcement for one door. Clearing an absent announcement succeeds. */
DB_API int db_core_clear_door_notice(db_core* c, const char* door);

/* Runtime contracts reported by a platform shell. JSON must be an object and is copied by core. */
DB_API void db_core_set_capabilities_json(db_core* c, const char* capabilities_json);
DB_API void db_core_set_runtime_status_json(db_core* c, const char* runtime_json);
DB_API void db_core_set_ui_manifest_json(db_core* c, const char* manifest_json);
DB_API char* db_core_capabilities_json(db_core* c);

/* Return pairing discovery and invitation state. The snapshot is built when this is called, so
 * countdowns tick over repeated polls. Shells render "state" and never infer it:
 * {"state":"unpaired|joining|persist_error|ready|revoked",
 *  "paired":bool,"persistence_ready":bool,"is_founder":bool,
 *  "psk_source":"secure_store|boot_plaintext|none","psk_ref":"secret:mesh.psk"|null,"role":"...",
 *  "self":{id,addr,name,role,pk,model,platform,sw},
 *  "pair_qr":"doorbell-pair:<addr>|<id>|<pk>",
 *  "home":{"member_count":int,"connected_count":int},
 *  "token":{"active":bool,"expires_s":int,"attempts_left":int,"host":"<addr>","pin":"<6>"},
 *  "pending":{"pairing_mode":bool,"pairing_mode_left_s":int,"auto_added_count":int,
 *             "devices":[{id,addr,name,role,model,platform,sw,age_s,
 *                         invite_state:"none|sent|acked|joined|failed",attempts,last_error}]}}
 * token.pin is present only while token.active. Release the result with db_free.
 *
 * Pairing events delivered through the UI callback:
 *   {"t":"pairing_state","state":...,"is_founder":bool,"psk_source":...} on every state change
 *   {"t":"pending_changed"} {"t":"invite_result","id":...,"ok":bool,"err":...}
 *   {"t":"device_joined","id":...,"name":...,"role":...}
 *   {"t":"pairing_mode_changed","active":bool,"left_s":int,"auto_added_count":int}
 *   {"t":"join_token_changed","active":bool,"expires_s":int,"attempts_left":int}
 *   {"t":"invite_rejected","reason":...} on the invited device
 *   {"t":"qr_scan_state","active":bool} {"t":"qr_scanned","text":...,"invited":bool}
 *   plus the existing paired, pairing_persistence_error, join_result, and pairing_revoked. */
DB_API char* db_core_pairing_json(db_core* c);
/* Join an existing cluster with a PIN and seed. Completion is reported as t:"join_result" first,
 * then on success t:"paired" and t:"pairing_state". The paired event contains psk_ref,
 * never the PSK; secure_put must succeed before that event is emitted, and a store failure is
 * reported as join_result{ok:false,err:"persist_failed"} plus state "persist_error". */
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
/* Drop one pending device and ignore its announcements for a while. */
DB_API void db_core_deny_device(db_core* c, const char* id);
/* Retry the secure-store write after state "persist_error". Returns 1 once the PSK is stored.
 * A pairing_state event is emitted either way. */
DB_API int db_core_retry_pairing_persistence(db_core* c);
/* Leave the cluster: zero the PSK, delete the stored secret when the platform supports it, drop
 * cluster state, and emit pairing_state with state "unpaired". The shell clears psk_ref and
 * seed_peers from boot.json. */
DB_API void db_core_unpair(db_core* c);

/* Encode a QR bitmap as size*size row-major bytes, where one means dark. Returns NULL on failure;
 * release the result with db_free. */
DB_API unsigned char* db_core_qr_encode(const char* text, int* out_size);

/* Decode one 8-bit grayscale image, w*h bytes, row-major without padding. Returns 0 and assigns
 * *text_out (release with db_free) on success, 1 when no code was found, and -1 on bad arguments.
 * This call is synchronous and runs on the caller's thread. */
DB_API int db_core_qr_decode(const uint8_t* gray, int w, int h, char** text_out);

/* Scan mode. While active, core decodes the frames already delivered through
 * db_core_on_camera_frame on its own thread at up to ten frames per second, emits
 * {"t":"qr_scanned","text":...} once per distinct payload, and invites automatically when the
 * payload is a "doorbell-pair:" QR. It stops after 120 seconds, and start/stop are reported as
 * {"t":"qr_scan_state","active":bool}. */
DB_API void db_core_qr_scan_start(db_core* c);
DB_API void db_core_qr_scan_stop(db_core* c);

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
