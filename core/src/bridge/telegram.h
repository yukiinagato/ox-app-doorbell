// Telegram ブリッジ (Phase 2) — telegram duty の leader ノードだけが Bot API へ送る。
// 押鈴を写真付き (sendPhoto multipart) で推送し、inline ボタンのクイック返信を
// getUpdates 長輪詢で受ける。コアは TLS を持たないため HTTPS は HttpsFn (SPI/curl) 経由。
//   - 有効条件: config integrations.telegram.bot_token 非空 かつ mesh.isLeader("telegram")
//     — 判定は Node 側 (configure の active 引数)。リーダー交代/設定変更で再評価される。
//   - 重複防止 (設計 §1.5): press は event.notify の claimed_by を先取り
//     (mergeNotify → 300ms 後に再確認) してから送信し、成功で notified_at を記録。
//     回執は mesh の EVENT 再広播で全ノードへ複製される (Hooks.merge_notify が担う)。
//   - 送信は Store の tg_queue (永続) 経由で直列。失敗は 30s→1m→5m→15m(cap) の
//     バックオフで再試行し、24h 経過分は破棄する。
// スレッド: 全 API は Runloop 上でのみ (HttpsFn の done は任意スレッド → 内部で marshal)。
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "events/events.h"
#include "store/store.h"
#include "util/common.h"
#include "util/json.h"
#include "util/runloop.h"

namespace db {

class TelegramBridge {
 public:
  struct Hooks {
    // HTTPS 送信 (Node::HttpsFn の marshal 済み経路)。done は Runloop 上で呼び返される。
    // status < 0 = トランスポート失敗 (HTTP に到達せず / HttpsFn 未注入)。
    std::function<void(const std::string& method, const std::string& url,
                       const std::string& headers_json, Bytes body,
                       std::function<void(int status, std::string resp_body)> done)>
        https;
    // callback_query → クイック返信配送 (Node::quickReply via="telegram")
    std::function<void(const std::string& reply_id, const std::string& free_text,
                       const std::string& door_id)>
        on_reply;
    // イベントの最新版 (notify 込み) を読む
    std::function<std::optional<EventRecord>(const std::string& origin, uint64_t seq)> get_event;
    // 通知回執の LWW マージ + mesh への再広播 (Node が実装 — 回執を全ノードへ複製する)
    std::function<void(const std::string& origin, uint64_t seq, const std::string& notify_json)>
        merge_notify;
    // HLC 刻印 (claim/notified_at 用)
    std::function<std::string()> hlc_tick;
    // 押鈴ノードの最新 JPEG (Mesh::fetchSnapshot — 自分宛も可)。cb は Runloop 上で呼ぶこと。
    std::function<void(const std::string& node_id, std::function<void(Bytes)> cb)> fetch_snapshot;
  };

  TelegramBridge(Runloop& loop, Store& store, Hooks hooks);
  ~TelegramBridge();

  // 有効条件の再評価 (起動時 / config 変更 / leader 交代時に Node から呼ぶ)。
  // cfg_json = materialize 済み設定全文。active = 自分が telegram leader。
  // bot_token が空なら active でも停止する。
  void configure(const std::string& cfg_json, const std::string& node_id, bool active);

  // Node::onEvent から (毎イベント; 非 leader でも press 追跡のため呼んでよい)。
  // reply イベントの「✅ {text}」通知はここで出す (通知範囲 = press の telegram_msg_ids)。
  void onEvent(const EventRecord& ev);

  // rule の telegram アクション (Node が leader 時のみ呼ぶ)。
  // press: claim → 300ms 再確認 → (快照) → sendPhoto/sendMessage 投入。
  // motion/offline/online: sendMessage 投入 (文言はハードコード ja)。
  void onAction(const EventRecord& ev, const std::string& params_json);

  // 管理画面の「テスト送信」(POST /api/test/telegram)。文言は固定「ドアホン テスト通知」。
  // chat_id_or_empty 空 = 全 households の telegram_chat_ids へ (去重済み)。
  // 非 active / 宛先なしは何もしない (可否判定は Node 側が先に行う)。
  void sendTestMessage(const std::string& chat_id_or_empty);

  // SOS 緊急モードの遷移通知 (Node::applyEmergencyEvent から — 全ノードが呼ぶが送るのは
  // active な leader だけ)。quiet_hours/ルール非依存の組込動作 — 全 households の全 chat_id へ
  // 「🚨 …」/「✅ 緊急解除」を通常キュー経由 (kind="message") で送る。
  void sendEmergency(bool active, const std::string& source_node, int64_t wall_ms);

  // graceful 停止 (Node::stop から)。キューは永続なので未送信分は次回 active 時に再開。
  void stop();

  // status_json 用: "active" | "inactive" (常接続の概念が無いので 2 値)
  std::string status() const;

 private:
  // ---- 設定参照 ----
  cJSON* cfgAt(const std::string& dotpath) const;
  std::string labelJa(const cJSON* label_obj) const;
  std::string doorLabel(const std::string& door_id) const;
  std::string deviceName(const std::string& node_id) const;
  int tzOffsetMin() const;

  // ---- 本文組み立て ----
  std::string pressCaption(const EventRecord& ev) const;  // text_template.ja の {door}/{time}
  std::string eventText(const EventRecord& ev) const;     // motion/offline/online の ja 文言
  std::string replyMarkupJson(const std::string& door_id) const;  // quick_replies → inline_keyboard
  std::vector<std::string> resolveChats(const cJSON* households) const;  // 展開・去重
  std::string hhmm(int64_t wall_ms) const;

  // ---- press の重複防止 (設計 §1.5) ----
  void claimAndSend(const EventRecord& ev, const cJSON* params);
  void enqueuePress(const EventRecord& ev, const std::vector<std::string>& chats,
                    bool with_snapshot);

  // ---- 送信キュー ----
  void enqueue(const std::string& kind, const std::string& chat_id, const std::string& payload,
               const Bytes& snapshot);
  void pump();
  void sendItem(const Store::TgQueueItem& item);
  void onSendDone(const Store::TgQueueItem& item, int status, const std::string& resp);
  void recordNotified(const std::string& origin, uint64_t seq, const std::string& chat_id,
                      int64_t message_id);

  // ---- getUpdates 長輪詢 ----
  void schedulePoll(int64_t delay_ms);
  void sendPoll();
  void onPollDone(uint64_t gen, int status, const std::string& resp);
  void handleCallbackQuery(const cJSON* cq);

  // ---- HTTPS ----
  std::string apiUrl(const std::string& method) const;
  void postJson(const std::string& api_method, const json::Doc& body_obj);  // 応答不問の単発
  // caption 追記 (写真通知)。sendMessage に降級した通知には caption が無く 400 になる —
  // その場合は editMessageText へ降級して同文を書く (どちらも失敗容認)。
  void editCaptionOrText(const std::string& chat_id, int64_t message_id, const std::string& text);
  // 全 households の telegram_chat_ids を展開・去重 (テスト送信/緊急通知用)
  std::vector<std::string> allHouseholdChats() const;

  int64_t nowWallMs() const;
  bool pollEnabled() const;

  Runloop& loop_;
  Store& store_;
  Hooks hooks_;

  json::Doc cfg_;         // configure で渡された設定ツリー
  std::string cfg_json_;  // 同・原文 (変更検出用)
  std::string node_id_;
  std::string token_;     // integrations.telegram.bot_token (MVP 平文)
  bool active_ = false;

  bool sending_ = false;      // キュー直列送信の in-flight
  uint64_t pump_timer_ = 0;   // 周期 pump (再試行の駆動)
  uint64_t poll_gen_ = 0;     // getUpdates 世代 (停止/再構成で古い応答を無効化)
  bool poll_inflight_ = false;
  uint64_t poll_timer_ = 0;
  int64_t poll_offset_ = 0;   // getUpdates offset (メモリのみ。TODO: meta 永続化)

  // press 追跡 (reply 通知・callback 後のボタン撤去の宛先解決)
  std::map<std::string, std::pair<std::string, uint64_t>> last_press_by_door_;

  // 生存トークン: HttpsFn done / postDelayed が破棄後の this に触れないための弱参照
  std::shared_ptr<char> alive_ = std::make_shared<char>(0);
};

}  // namespace db
