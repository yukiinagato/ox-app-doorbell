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
  /* HTTPS (Telegram 等)。同期呼び — core が専用スレッドから呼ぶのでブロックしてよい
   * (Telegram getUpdates 長輪詢では最大 ~30 秒ブロックする)。
   * headers_json: {"Content-Type":"..."} 形式。body は body_len バイト (0 可, バイナリ可)。
   * resp_body_out: malloc した応答本文 (core が db_free する)。*http_status_out: HTTP 状態。
   * 戻り 0=成功 (HTTP 4xx/5xx でも応答が取れれば 0)、負=トランスポート失敗。
   * 注意: 在飛の呼び出しがある間 db_core_destroy はその完了を待つ。 */
  int (*https_request)(void* user, const char* method, const char* url,
                       const char* headers_json, const uint8_t* body, size_t body_len,
                       char** resp_body_out, int* http_status_out);
  /* 安全な鍵保管 (DPAPI/Keystore/Keychain)。value_out は core が db_free する */
  int (*secure_get)(void* user, const char* key, char** value_out);
  int (*secure_put)(void* user, const char* key, const char* value);
  /* ログ転送 (level: 0=debug..3=error)。NULL なら stderr のみ */
  void (*log_line)(void* user, int level, const char* line);
  /* TTS 朗読 (クイック返信の読み上げ)。lang: "ja" 等。NULL なら chime 音のみ */
  void (*tts_speak)(void* user, const char* text, const char* lang);
} db_platform;

/* core → 殻 への UI イベント通知 (JSON)。例:
 * {"t":"state","state":"idle|calling|in_call|degraded|offline"}
 * {"t":"chime","sound":"ding1"} {"t":"config_changed"} {"t":"peers_changed"}
 * {"t":"reply","text":"ただいま留守にしています","ttl_s":30,"lang":"ja"}
 *   — クイック返信の面板表示。カスタム音声がキャッシュ済みなら "audio_path" (ローカル
 *     ファイル) が付く: 殻はそれを再生し TTS はしない (無ければ tts_speak が呼ばれる)。
 * {"t":"chime",...,"audio_path":"..."} — sound "asset:<sha256>" のカスタム音 (キャッシュ済時)
 * {"t":"visitor_lang","door":"d_front","lang":"en"} — 訪客言語の切替/復帰 (全ノード)
 * {"t":"asset_ready","hash":"<sha256>"} — 統一資産のキャッシュ完了 (背景画像等の再読込合図)
 * {"t":"display",...,"theme":{"bg_color":"#101418","bg_image":"<sha256>|null",
 *   "bg_image_path":"<ローカルパス>|null"}} — 待機画面テーマ。殻は bg_image_path を
 *   そのまま描画する (null = 未キャッシュ — asset_ready 後に display が再発行される)
 * {"t":"emergency","active":true,"alarm_sound":"siren1|asset:<sha256>","alarm_volume":100,
 *   "audio_path":"..."} — 警報音。audio_path はカスタム音キャッシュ済時のみ (無ければ内蔵音) */
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

/* 用件付き按鈴 (訪客の用件ボタン 1 タップ)。purpose: 設定 visit_purposes のキー
 * (NULL/"" = 用件なし = db_core_press と同じ)。press イベント payload に
 * "purpose" と選択中の訪客言語 "visitor_lang" が載る。 */
DB_API void db_core_press_purpose(db_core* c, const char* door_id, const char* purpose);

/* 訪客言語切替 (門口機の言語ボタン)。door NULL/"" = 自機担当 door。
 * lang: "en" 等 (設定 ui.languages が候補)。"ja" で即時復帰。
 * ui.visitor_lang_revert_s 秒の無操作で自動的に ja へ戻る。全ノードの殻に
 * {"t":"visitor_lang","door":…,"lang":…} が届く。 */
DB_API void db_core_set_visitor_lang(db_core* c, const char* door, const char* lang);

/* ノード表・リーダー・SIP 状態などのスナップショット JSON。db_free で解放。 */
DB_API char* db_core_status_json(db_core* c);

/* materialize 済み設定全文 JSON (doors/quick_replies 等の表示に使う)。db_free で解放。 */
DB_API char* db_core_config_json(db_core* c);

/* カメラフレーム push (Phase 1)。format: 0=NV21, 1=NV12, 2=YUY2, 3=BGRA */
DB_API void db_core_on_camera_frame(db_core* c, const uint8_t* data, int format, int width,
                                    int height, int stride, int64_t ts_ms);

/* SIP 発呼/切断 (Phase 3: TV/室内機の門口監聴)。
 * target: 内線番号、または "sip:" で始まる完全 URI (Asterisk 非経由の直接呼 —
 *         例 "sip:10.0.1.5:47190"、宛先は status_json peers[].addrs から解決する)。
 * mode: NULL/"" = 通常 (双方向) / "monitor" = 一方向監聴 (受け側は自マイク音声のみ送る)。
 * PJSIP 無効ビルドでは no-op。 */
DB_API void db_core_sip_call(db_core* c, const char* target, const char* mode);
DB_API void db_core_sip_hangup(db_core* c);

/* クイック返信の配送 (門口機の面板表示 + TTS + reply イベント)。
 * reply_id: 設定 quick_replies のキー。door: 対象 door_id ("" = 最新 press の door)。 */
DB_API void db_core_quick_reply(db_core* c, const char* reply_id, const char* door);

DB_API void db_free(char* p);

DB_API const char* db_core_version(void);

/* SOS 緊急モード (Phase 3)。active=1 で発報 / 0 で解除。emergency / emergency_cancel
 * イベントが全ノードへ複製され、各殻に {"t":"emergency","active":bool} が届く。
 * 解除時の PIN 検証 (kiosk PIN 等) は殻の責務 — core は検証しない。 */
DB_API void db_core_emergency(db_core* c, int active);

/* ---- H.264 流暢档 (Phase 6a) ----
 * コアは符号化済みデータを fMP4 に箱詰めして /stream.mp4 で配るだけ —
 * エンコードは殻/平台層の HW エンコーダ (Android MediaCodec / iOS VideoToolbox。
 * Windows のみ core 内の Media Foundation が camera_win と同居)。 */

/* 符号化フレーム投入 (任意スレッド可)。annexb: 1 アクセスユニット分の H.264 AnnexB
 * (start code 区切り。SPS/PPS 同梱可 — コアが抽出する。MediaCodec の CODEC_CONFIG
 * 出力だけを渡してもよい)。is_keyframe: IDR を含むなら 1。ts_ms: エンコーダの提示時刻。
 * config camera.codec が mjpeg の間は無視される。 */
DB_API void db_core_on_encoded_frame(db_core* c, const uint8_t* annexb, size_t len,
                                     int is_keyframe, int64_t ts_ms);

/* 殻がエンコーダを回すべきか (省電力: 購読者ゼロならエンコードしない)。
 * config camera.codec が h264/auto かつ /stream.mp4 の購読者がいる時 1、それ以外 0。
 * 殻は 5 秒毎程度にこれを確認してエンコーダの起動/停止を切り替える。 */
DB_API int db_core_video_encoder_wanted(db_core* c);

#ifdef __cplusplus
}
#endif

#endif /* DOORBELL_H */
