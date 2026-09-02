
// Telegram Bot bridge. Only the elected telegram leader sends notifications. Press delivery
// uses a replicated claim before enqueueing, the persistent queue retries with bounded backoff,
// and queued items expire after 24 hours. All public methods run on Runloop; HTTPS completions
// may originate on any thread but Hooks must marshal them back to Runloop.
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
    // HTTPS reports transport failures with a negative status.
    std::function<void(const std::string& method, const std::string& url,
                       const std::string& headers_json, Bytes body,
                       std::function<void(int status, std::string resp_body)> done)>
        https;
    // Deliver a Telegram callback as a quick reply.
    std::function<bool(const std::string& reply_id, const std::string& free_text,
                       const std::string& door_id, const std::string& call_id)>
        on_reply;
    // Read and merge replicated event notification receipts.
    std::function<std::optional<EventRecord>(const std::string& origin, uint64_t seq)> get_event;
    std::function<void(const std::string& origin, uint64_t seq, const std::string& notify_json)>
        merge_notify;
    // Return a fresh HLC stamp for claims and receipts.
    std::function<std::string()> hlc_tick;
    // Fetch a node snapshot and complete on Runloop.
    std::function<void(const std::string& node_id, std::function<void(Bytes)> cb)> fetch_snapshot;
    // Resolve localized core text.
    std::function<std::string(const std::string& key, const std::string& lang,
                              const std::vector<std::pair<std::string, std::string>>& args)>
        text;
  };

  TelegramBridge(Runloop& loop, Store& store, Hooks hooks);
  ~TelegramBridge();

  // Reconfigure from the materialized tree. active means this node is the elected leader.
  void configure(const std::string& cfg_json, const std::string& node_id, bool active);

  // Track every event; non-leaders retain press context for a later leadership transition.
  void onEvent(const EventRecord& ev);

  // Execute a rule action. Press actions claim before enqueueing to prevent duplicate delivery.
  void onAction(const EventRecord& ev, const std::string& params_json);

  // Send an administrator test message to one chat or every configured household chat.
  void sendTestMessage(const std::string& chat_id_or_empty);

  // Send a leader-only SOS transition independent of quiet hours.
  void sendEmergency(bool active, const std::string& source_node, int64_t wall_ms);

  // Stop polling while leaving the persistent retry queue intact.
  void stop();

  // Returns "active" or "inactive"; Telegram has no persistent connection state.
  std::string status() const;

 private:
  struct CallSource {
    std::string origin;
    uint64_t seq = 0;
    int64_t wall_ms = 0;
  };

  struct CallCancellation {
    int64_t wall_ms = 0;
    std::string hlc;
  };

  cJSON* cfgAt(const std::string& dotpath) const;
  std::string labelIn(const cJSON* label_obj, const std::string& lang) const;
  std::string labelJa(const cJSON* label_obj) const;
  std::string doorLabel(const std::string& door_id) const;
  std::string deviceName(const std::string& node_id) const;
  int tzOffsetMin() const;


  std::string notifyLang() const;

  std::string tr(const std::string& key,
                 const std::vector<std::pair<std::string, std::string>>& args = {}) const;


  std::string pressCaption(const EventRecord& ev) const;

  std::string purposeHeadline(const EventRecord& ev) const;
  std::string eventText(const EventRecord& ev) const;
  std::string replyMarkupJson(const std::string& door_id,
                              const std::string& call_id) const;  // scoped quick replies
  std::vector<std::string> resolveChats(const cJSON* households) const;
  std::string hhmm(int64_t wall_ms) const;


  void claimAndSend(const EventRecord& ev, const cJSON* params);
  void enqueuePress(const EventRecord& ev, const std::vector<std::string>& chats,
                    bool with_snapshot, const std::string& call_id,
                    const CallSource& source);

  static std::string callIdOf(const EventRecord& ev);
  CallSource sourceFor(const EventRecord& ev, const std::string& call_id) const;
  bool eventMarksCancelled(const CallSource& source, const std::string& call_id) const;
  bool callSuppressed(const std::string& call_id, const CallSource& source) const;
  bool queueItemSuppressed(const Store::TgQueueItem& item) const;
  void markSourceCancelled(const CallSource& source, const std::string& call_id,
                           const std::string& cancelled_hlc);
  void suppressPendingQueue(const std::string& call_id);
  void cancelPendingCall(const EventRecord& ev);
  void forgetQueueItem(int64_t id);
  void pruneCallTracking();


  void enqueue(const std::string& kind, const std::string& chat_id, const std::string& payload,
               const Bytes& snapshot);
  void pump();
  void sendItem(const Store::TgQueueItem& item);
  void onSendDone(const Store::TgQueueItem& item, int status, const std::string& resp);
  void recordNotified(const std::string& origin, uint64_t seq, const std::string& chat_id,
                      int64_t message_id);


  void schedulePoll(int64_t delay_ms);
  void sendPoll();
  void onPollDone(uint64_t gen, int status, const std::string& resp);
  void handleCallbackQuery(const cJSON* cq);

  // ---- HTTPS ----
  std::string apiUrl(const std::string& method) const;
  void postJson(const std::string& api_method, const json::Doc& body_obj);


  void editCaptionOrText(const std::string& chat_id, int64_t message_id, const std::string& text);

  std::vector<std::string> allHouseholdChats() const;

  int64_t nowWallMs() const;
  bool pollEnabled() const;

  Runloop& loop_;
  Store& store_;
  Hooks hooks_;

  json::Doc cfg_;
  std::string cfg_json_;
  std::string node_id_;
  std::string token_;
  bool active_ = false;

  bool sending_ = false;
  int64_t inflight_item_id_ = 0;
  uint64_t pump_timer_ = 0;
  uint64_t poll_gen_ = 0;  // Invalidates stale HTTPS completions after reconfiguration.
  bool poll_inflight_ = false;
  uint64_t poll_timer_ = 0;
  int64_t poll_offset_ = 0;

  // Keeps callback destinations available across a leadership transition.
  std::map<std::string, std::pair<std::string, uint64_t>> last_press_by_door_;

  // Call identity follows work through claim, snapshot, and persistent retry stages.
  std::map<std::string, CallSource> press_source_by_call_;
  std::map<std::string, CallCancellation> cancelled_calls_;
  std::map<int64_t, std::pair<std::string, int64_t>> queued_calls_;

  // Async completions capture this weak lifetime token instead of a raw bridge lifetime.
  std::shared_ptr<char> alive_ = std::make_shared<char>(0);
};

}  // namespace db
