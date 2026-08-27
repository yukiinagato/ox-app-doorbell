/* doorbell-core 公開 C ABI。
 * プラットフォーム殻 (WPF P/Invoke, JNI, Swift) はこのヘッダだけを見る。
 * 規約:
 *  - 文字列はすべて UTF-8。core が返す char* は db_free() で解放。
 *  - コールバックは core 内部スレッドから呼ばれる。UI スレッドへの marshal は殻の責務。
 *  - 例外は境界を越えない。失敗は戻り値 (0=成功 / 負=エラー)。
 * Phase 0 では host テストから使う最小面のみ。camera/audio/sip は Phase 1 で拡張。
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

/* プラットフォーム提供機能 (SPI)。不要なものは NULL 可 (機能が無効になる)。 */
typedef struct db_platform {
  void* user;
  /* HTTPS (Telegram 等)。resp_body_out は core が db_free する。戻り 0=成功 */
  int (*https_request)(void* user, const char* method, const char* url,
                       const char* headers_json, const uint8_t* body, size_t body_len,
                       char** resp_body_out, int* http_status_out);
  /* 安全な鍵保管 (DPAPI/Keystore/Keychain)。value_out は core が db_free する */
  int (*secure_get)(void* user, const char* key, char** value_out);
  int (*secure_put)(void* user, const char* key, const char* value);
  /* ログ転送 (level: 0=debug..3=error)。NULL なら stderr のみ */
  void (*log_line)(void* user, int level, const char* line);
} db_platform;

/* core → 殻 への UI イベント通知 (JSON)。例:
 * {"t":"state","state":"idle|calling|in_call|degraded|offline"}
 * {"t":"chime","sound":"ding1"} {"t":"config_changed"} {"t":"peers_changed"} */
typedef void (*db_ui_event_cb)(void* user, const char* event_json);

/* 生成: data_dir は書込可能ディレクトリ。boot_json は初期設定
 * ({"listen_port":47172,"http_port":47180,"role":"door_station",...} — 詳細は docs)。 */
DB_API db_core* db_core_create(const db_platform* platform, const char* data_dir,
                               const char* boot_json);
DB_API int db_core_start(db_core* c);
DB_API void db_core_stop(db_core* c);
DB_API void db_core_destroy(db_core* c);

DB_API void db_core_set_ui_callback(db_core* c, db_ui_event_cb cb, void* user);

/* 呼出ボタン押下 (door_id は設定に基づく)。 */
DB_API void db_core_press(db_core* c, const char* door_id);

/* ノード表・リーダー・SIP 状態などのスナップショット JSON。db_free で解放。 */
DB_API char* db_core_status_json(db_core* c);

/* カメラフレーム push (Phase 1)。format: 0=NV21, 1=NV12, 2=YUY2, 3=BGRA */
DB_API void db_core_on_camera_frame(db_core* c, const uint8_t* data, int format, int width,
                                    int height, int stride, int64_t ts_ms);

DB_API void db_free(char* p);

DB_API const char* db_core_version(void);

#ifdef __cplusplus
}
#endif

#endif /* DOORBELL_H */
