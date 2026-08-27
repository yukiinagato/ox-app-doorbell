// Telegram ブリッジの実装 (telegram.h 参照)。
#include "bridge/telegram.h"

#include <algorithm>
#include <cinttypes>
#include <cstdio>

#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "telegram";
constexpr const char* kApiBase = "https://api.telegram.org/bot";
constexpr int64_t kClaimRecheckMs = 300;          // claim → 再確認までの待ち (設計 §1.5)
constexpr int64_t kPumpPeriodMs = 1000;           // キュー駆動周期 (再試行の観測粒度)
constexpr int64_t kQueueTtlMs = 24 * 3600'000LL;  // 24h で破棄
constexpr int64_t kPollRetryMs = 5000;            // getUpdates 失敗時の待ち
constexpr int64_t kPollGapMs = 50;                // 応答後の次回までの隙間 (即時再帰の抑止)
constexpr const char* kDefaultTemplateJa = "{door} に来客です ({time})";

// バックオフ: 30s → 1m → 5m → 15m (cap)
int64_t backoffMs(int attempts) {
  if (attempts <= 1) return 30'000;
  if (attempts == 2) return 60'000;
  if (attempts == 3) return 300'000;
  return 900'000;
}

// {placeholder} の全置換
void replaceAll(std::string& s, const std::string& from, const std::string& to) {
  size_t pos = 0;
  while ((pos = s.find(from, pos)) != std::string::npos) {
    s.replace(pos, from.size(), to);
    pos += to.size();
  }
}

// 負値でも床方向へ丸める除算 (rule_engine と同じ — 現地時刻の分計算用)
int64_t floorDiv(int64_t a, int64_t b) {
  int64_t q = a / b;
  if ((a % b) != 0 && ((a < 0) != (b < 0))) --q;
  return q;
}

// multipart/form-data のテキスト欄
void addFormField(Bytes& out, const std::string& boundary, const std::string& name,
                  const std::string& value) {
  std::string part = "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + name +
                     "\"\r\n\r\n" + value + "\r\n";
  out.insert(out.end(), part.begin(), part.end());
}

// Telegram 応答から message_id を取り出す ({"ok":true,"result":{"message_id":N}})。無ければ 0。
int64_t messageIdOf(const std::string& resp) {
  auto d = json::parse(resp);
  if (!d || !json::getBool(d.get(), "ok")) return 0;
  return json::getInt(json::get(d.get(), "result"), "message_id");
}
}  // namespace

TelegramBridge::TelegramBridge(Runloop& loop, Store& store, Hooks hooks)
    : loop_(loop), store_(store), hooks_(std::move(hooks)) {}

TelegramBridge::~TelegramBridge() { stop(); }

// ---------------------------------------------------------------- 設定参照

cJSON* TelegramBridge::cfgAt(const std::string& dotpath) const {
  cJSON* cur = cfg_.get();
  size_t pos = 0;
  while (cur && pos <= dotpath.size()) {
    size_t dot = dotpath.find('.', pos);
    std::string part =
        dotpath.substr(pos, dot == std::string::npos ? std::string::npos : dot - pos);
    cur = json::get(cur, part.c_str());
    if (dot == std::string::npos) return cur;
    pos = dot + 1;
  }
  return cur;
}

std::string TelegramBridge::labelJa(const cJSON* label_obj) const {
  if (!label_obj) return "";
  std::string v = json::getString(label_obj, "ja");
  if (v.empty()) v = json::getString(label_obj, "en");
  if (v.empty() && label_obj->child && cJSON_IsString(label_obj->child))
    v = label_obj->child->valuestring;
  return v;
}

std::string TelegramBridge::doorLabel(const std::string& door_id) const {
  std::string v = labelJa(json::get(cfgAt("doors." + door_id), "label"));
  return v.empty() ? door_id : v;
}

std::string TelegramBridge::deviceName(const std::string& node_id) const {
  std::string v = json::getString(cfgAt("devices." + node_id), "name");
  return v.empty() ? node_id.substr(0, 8) : v;
}

int TelegramBridge::tzOffsetMin() const {
  return static_cast<int>(json::getInt(cfgAt("integrations"), "tz_offset_min", 540));
}

int64_t TelegramBridge::nowWallMs() const {
  return const_cast<Runloop&>(loop_).clock().wallMs();
}

bool TelegramBridge::pollEnabled() const {
  return json::getBool(cfgAt("integrations.telegram"), "poll_updates");
}

// ---------------------------------------------------------------- 本文組み立て

std::string TelegramBridge::hhmm(int64_t wall_ms) const {
  const int64_t local = wall_ms + static_cast<int64_t>(tzOffsetMin()) * 60'000LL;
  const int64_t day_ms = 86'400'000LL;
  const int64_t day = floorDiv(local, day_ms);
  const int minute = static_cast<int>((local - day * day_ms) / 60'000LL);
  char buf[8];
  std::snprintf(buf, sizeof(buf), "%02d:%02d", minute / 60, minute % 60);
  return buf;
}

std::string TelegramBridge::pressCaption(const EventRecord& ev) const {
  // ev.wall_ms は HLC 物理部 = 補正済み壁時計 (発生時刻)
  std::string t = json::getString(cfgAt("integrations.telegram.text_template"), "ja",
                                  kDefaultTemplateJa);
  replaceAll(t, "{door}", doorLabel(ev.door));
  replaceAll(t, "{time}", hhmm(ev.wall_ms));
  return t;
}

std::string TelegramBridge::eventText(const EventRecord& ev) const {
  // i18n の event.* (ja) 相当をハードコード (i18n/strings.yaml 参照)
  if (ev.type == "motion")
    return doorLabel(ev.door) + " で動きを検知 (" + hhmm(ev.wall_ms) + ")";
  if (ev.type == "offline")
    return "⚠ " + deviceName(ev.device) + " オフライン (最終応答 " + hhmm(ev.wall_ms) + ")";
  if (ev.type == "online") return deviceName(ev.device) + " オンライン復帰";
  return "";
}

// quick_replies を order 順に 1 列の inline_keyboard へ
std::string TelegramBridge::replyMarkupJson(const std::string& door_id) const {
  struct Btn {
    int64_t order;
    std::string id, label;
  };
  std::vector<Btn> btns;
  cJSON* qrs = cfgAt("quick_replies");
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, qrs) {
    if (!it->string) continue;
    std::string label = labelJa(json::get(it, "label"));
    if (label.empty()) continue;
    btns.push_back({json::getInt(it, "order", 1000), it->string, label});
  }
  std::sort(btns.begin(), btns.end(), [](const Btn& a, const Btn& b) {
    return std::tie(a.order, a.id) < std::tie(b.order, b.id);
  });
  auto o = json::obj();
  cJSON* rows = json::addArr(o.get(), "inline_keyboard");
  for (const auto& b : btns) {  // 1 列 = 行あたり 1 ボタン
    json::Doc row(cJSON_CreateArray());
    cJSON* btn = cJSON_CreateObject();
    json::set(btn, "text", b.label);
    json::set(btn, "callback_data", "qr|" + b.id + "|" + door_id);
    cJSON_AddItemToArray(row.get(), btn);
    json::push(rows, std::move(row));
  }
  return json::dump(o.get());
}

std::vector<std::string> TelegramBridge::resolveChats(const cJSON* households) const {
  std::vector<std::string> out;
  auto add = [&out](const std::string& c) {
    if (!c.empty() && std::find(out.begin(), out.end(), c) == out.end()) out.push_back(c);
  };
  const cJSON* h = nullptr;
  cJSON_ArrayForEach(h, households) {
    if (!cJSON_IsString(h)) continue;
    cJSON* ids = json::get(cfgAt("households." + std::string(h->valuestring)),
                           "telegram_chat_ids");
    const cJSON* id = nullptr;
    cJSON_ArrayForEach(id, ids) {
      if (cJSON_IsNumber(id)) {
        char buf[24];
        std::snprintf(buf, sizeof(buf), "%" PRId64, static_cast<int64_t>(id->valuedouble));
        add(buf);
      } else if (cJSON_IsString(id)) {
        add(id->valuestring);
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------- 構成

void TelegramBridge::configure(const std::string& cfg_json, const std::string& node_id,
                               bool active) {
  if (cfg_json != cfg_json_) {
    cfg_ = json::parse(cfg_json);
    if (!cfg_) cfg_ = json::obj();
    cfg_json_ = cfg_json;
  }
  node_id_ = node_id;

  const std::string token =
      json::getString(cfgAt("integrations.telegram"), "bot_token");
  // TODO(Phase2 後半): bot_token_ref (secure store) 対応 — MVP は平文 bot_token のみ
  const bool act = active && !token.empty();
  const bool token_changed = token != token_;
  token_ = token;

  if (!act) {
    if (active_) DB_LOGI(kTag, "ブリッジ停止 (leader でない / bot_token 未設定)");
    active_ = false;
    if (pump_timer_) {
      loop_.cancel(pump_timer_);
      pump_timer_ = 0;
    }
    if (poll_timer_) {
      loop_.cancel(poll_timer_);
      poll_timer_ = 0;
    }
    poll_gen_++;  // 在飛の getUpdates 応答を無効化
    return;
  }

  if (!active_) DB_LOGI(kTag, "ブリッジ開始 (telegram leader)");
  active_ = true;
  if (!pump_timer_) {
    pump_timer_ = loop_.postEvery(kPumpPeriodMs, [this] { pump(); });
    std::weak_ptr<char> w = alive_;
    loop_.post([this, w] {
      if (!w.expired()) pump();  // 残留キューの即時再開
    });
  }
  if (token_changed) poll_gen_++;  // 旧 token での在飛応答を無効化
  if (pollEnabled()) {
    if (!poll_inflight_ && !poll_timer_) schedulePoll(0);
  } else {
    if (poll_timer_) {
      loop_.cancel(poll_timer_);
      poll_timer_ = 0;
    }
    poll_gen_++;
  }
}

// 管理画面のテスト送信 — 通常キュー経由の sendMessage (失敗時のバックオフも共通)
void TelegramBridge::sendTestMessage(const std::string& chat_id_or_empty) {
  if (!active_) return;
  std::vector<std::string> chats;
  if (!chat_id_or_empty.empty()) {
    chats.push_back(chat_id_or_empty);
  } else {
    // 全 households の chat_ids へ (resolveChats が展開・去重する)
    auto ids = json::arr();
    cJSON* hs = cfgAt("households");
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, hs) {
      if (it->string) json::push(ids.get(), json::Doc(cJSON_CreateString(it->string)));
    }
    chats = resolveChats(ids.get());
  }
  if (chats.empty()) {
    DB_LOGW(kTag, "テスト送信: 宛先 chat_id が無い — スキップ");
    return;
  }
  for (const auto& c : chats) {
    auto pl = json::obj();
    json::set(pl.get(), "text", "ドアホン テスト通知");
    enqueue("message", c, json::dump(pl.get()), Bytes());
  }
  pump();
}

void TelegramBridge::stop() {
  active_ = false;
  if (pump_timer_) {
    loop_.cancel(pump_timer_);
    pump_timer_ = 0;
  }
  if (poll_timer_) {
    loop_.cancel(poll_timer_);
    poll_timer_ = 0;
  }
  poll_gen_++;
}

std::string TelegramBridge::status() const { return active_ ? "active" : "inactive"; }

std::string TelegramBridge::apiUrl(const std::string& method) const {
  return kApiBase + token_ + "/" + method;
}

// 応答不問の単発 POST (answerCallbackQuery / editMessage* — 失敗容認)
void TelegramBridge::postJson(const std::string& api_method, const json::Doc& body_obj) {
  if (!hooks_.https) return;
  const std::string body = json::dump(body_obj.get());
  std::weak_ptr<char> w = alive_;
  const std::string m = api_method;
  hooks_.https("POST", apiUrl(api_method), "{\"Content-Type\":\"application/json\"}",
               toBytes(body), [w, m](int status, std::string) {
                 if (w.expired()) return;
                 if (status < 200 || status >= 300)
                   DB_LOGW(kTag, m + " 失敗 (status=" + std::to_string(status) + ") — 容認");
               });
}

// ---------------------------------------------------------------- イベント

void TelegramBridge::onEvent(const EventRecord& ev) {
  if (ev.type == "press") {
    // 非 leader でも追跡する — 交代後の callback/reply の宛先解決に使う
    last_press_by_door_[ev.door] = {ev.origin, ev.seq};
    return;
  }
  if (ev.type != "reply" || !active_) return;

  // reply → 「✅ {text}」。通知範囲は press と同じ = press notify の telegram_msg_ids。
  auto p = json::parse(ev.payload_json);
  const std::string text = p ? json::getString(p.get(), "text") : "";
  if (text.empty()) return;
  auto lp = last_press_by_door_.find(ev.door);
  if (lp == last_press_by_door_.end() || !hooks_.get_event) return;
  auto press = hooks_.get_event(lp->second.first, lp->second.second);
  if (!press) return;
  auto n = json::parse(press->notify_json.empty() ? "{}" : press->notify_json);
  cJSON* ids = n ? json::get(n.get(), "telegram_msg_ids") : nullptr;
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, ids) {
    if (!it->string) continue;
    auto pl = json::obj();
    json::set(pl.get(), "text", "✅ " + text);
    enqueue("message", it->string, json::dump(pl.get()), Bytes());
  }
  pump();
}

void TelegramBridge::onAction(const EventRecord& ev, const std::string& params_json) {
  if (!active_) return;
  auto p = json::parse(params_json.empty() ? "{}" : params_json);
  if (!p) return;

  if (ev.type == "press") {
    claimAndSend(ev, p.get());
    return;
  }
  // motion / offline / online → sendMessage (households はアクション params から)
  const std::string text = eventText(ev);
  if (text.empty()) return;
  auto chats = resolveChats(json::get(p.get(), "households"));
  if (chats.empty()) {
    DB_LOGW(kTag, ev.type + ": households に telegram_chat_ids が無い — スキップ");
    return;
  }
  for (const auto& c : chats) {
    auto pl = json::obj();
    json::set(pl.get(), "text", text);
    enqueue("message", c, json::dump(pl.get()), Bytes());
  }
  pump();
}

// ---------------------------------------------------------------- press (設計 §1.5)

void TelegramBridge::claimAndSend(const EventRecord& ev, const cJSON* params) {
  if (!hooks_.get_event || !hooks_.merge_notify || !hooks_.hlc_tick) return;
  auto chats = resolveChats(json::get(params, "households"));
  if (chats.empty()) {
    DB_LOGW(kTag, "press: households に telegram_chat_ids が無い — スキップ");
    return;
  }
  auto cur = hooks_.get_event(ev.origin, ev.seq);
  if (!cur) return;
  auto n = json::parse(cur->notify_json.empty() ? "{}" : cur->notify_json);
  if (n && !json::getString(n.get(), "notified_at").empty()) {
    DB_LOGI(kTag, "press: 送信済み (notified_at あり) — スキップ");
    return;
  }

  // claim を先取りして 300ms 後に再確認 (他 leader の claim が勝ったら中止)
  {
    auto c = json::obj();
    json::set(c.get(), "hlc", hooks_.hlc_tick());
    json::set(c.get(), "claimed_by", node_id_);
    hooks_.merge_notify(ev.origin, ev.seq, json::dump(c.get()));
  }
  const bool with_snapshot = json::getBool(params, "with_snapshot");
  std::weak_ptr<char> w = alive_;
  loop_.postDelayed(kClaimRecheckMs, [this, w, ev, chats, with_snapshot] {
    if (w.expired() || !active_) return;
    auto cur2 = hooks_.get_event(ev.origin, ev.seq);
    if (!cur2) return;
    auto n2 = json::parse(cur2->notify_json.empty() ? "{}" : cur2->notify_json);
    const std::string claimed = n2 ? json::getString(n2.get(), "claimed_by") : "";
    if (claimed != node_id_) {
      DB_LOGI(kTag, "press: 他 leader の claim が勝った (" + claimed.substr(0, 8) + ") — 中止");
      return;
    }
    if (n2 && !json::getString(n2.get(), "notified_at").empty()) return;  // 送信済み
    enqueuePress(ev, chats, with_snapshot);
  });
}

void TelegramBridge::enqueuePress(const EventRecord& ev, const std::vector<std::string>& chats,
                                  bool with_snapshot) {
  const std::string caption = pressCaption(ev);
  const std::string markup = replyMarkupJson(ev.door);
  auto enqueueAll = [this, ev, chats, caption, markup](const Bytes& jpeg) {
    for (const auto& c : chats) {
      auto pl = json::obj();
      json::set(pl.get(), "origin", ev.origin);
      json::set(pl.get(), "seq", static_cast<int64_t>(ev.seq));
      json::set(pl.get(), "door", ev.door);
      json::set(pl.get(), "reply_markup", markup);
      if (jpeg.empty()) {
        json::set(pl.get(), "text", caption);  // 快照無し → sendMessage に降級
        enqueue("message", c, json::dump(pl.get()), Bytes());
      } else {
        json::set(pl.get(), "caption", caption);
        enqueue("photo", c, json::dump(pl.get()), jpeg);
      }
    }
    pump();
  };
  if (with_snapshot && hooks_.fetch_snapshot) {
    std::weak_ptr<char> w = alive_;
    hooks_.fetch_snapshot(ev.origin, [w, enqueueAll](Bytes jpeg) {
      if (w.expired()) return;
      enqueueAll(jpeg);  // 空 = 取得失敗 → sendMessage に降級
    });
  } else {
    enqueueAll(Bytes());
  }
}

void TelegramBridge::recordNotified(const std::string& origin, uint64_t seq,
                                    const std::string& chat_id, int64_t message_id) {
  if (!hooks_.get_event || !hooks_.merge_notify || !hooks_.hlc_tick) return;
  auto cur = hooks_.get_event(origin, seq);
  if (!cur) return;
  auto n = json::parse(cur->notify_json.empty() ? "{}" : cur->notify_json);
  auto upd = json::obj();
  json::set(upd.get(), "hlc", hooks_.hlc_tick());
  json::set(upd.get(), "notified_at", hooks_.hlc_tick());
  // telegram_msg_ids はフィールド単位 LWW — 既存分に自 chat を足した全量で上書きする
  cJSON* ids = json::addObj(upd.get(), "telegram_msg_ids");
  cJSON* prev = n ? json::get(n.get(), "telegram_msg_ids") : nullptr;
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, prev) {
    if (it->string && cJSON_IsNumber(it))
      json::set(ids, it->string, static_cast<int64_t>(it->valuedouble));
  }
  if (message_id > 0) json::set(ids, chat_id.c_str(), message_id);
  hooks_.merge_notify(origin, seq, json::dump(upd.get()));
}

// ---------------------------------------------------------------- 送信キュー

void TelegramBridge::enqueue(const std::string& kind, const std::string& chat_id,
                             const std::string& payload, const Bytes& snapshot) {
  Store::TgQueueItem item;
  item.kind = kind;
  item.chat_id = chat_id;
  item.payload = payload;
  item.snapshot = snapshot;
  item.next_retry_ms = nowWallMs();  // 即時送信可
  item.created_ms = nowWallMs();
  store_.tgQueuePut(item);
}

void TelegramBridge::pump() {
  if (!active_ || sending_) return;
  store_.tgQueuePrune(nowWallMs() - kQueueTtlMs);  // 24h 超は破棄
  auto due = store_.tgQueueDue(nowWallMs(), 1);
  if (due.empty()) return;
  sending_ = true;
  sendItem(due[0]);
}

void TelegramBridge::sendItem(const Store::TgQueueItem& item) {
  auto p = json::parse(item.payload.empty() ? "{}" : item.payload);
  if (!p || !hooks_.https) {  // 壊れた行 / HTTPS 経路なし → 破棄せず失敗扱い
    onSendDone(item, -1, "");
    return;
  }
  std::weak_ptr<char> w = alive_;
  auto done = [this, w, item](int status, std::string resp) {
    if (w.expired()) return;
    onSendDone(item, status, resp);
  };

  if (item.kind == "photo") {
    // sendPhoto (multipart/form-data 手組み: chat_id, caption, reply_markup, photo)
    const std::string boundary = "----doorbellTg" + hexEncode(randomBytes(8));
    Bytes body;
    addFormField(body, boundary, "chat_id", item.chat_id);
    const std::string caption = json::getString(p.get(), "caption");
    if (!caption.empty()) addFormField(body, boundary, "caption", caption);
    const std::string markup = json::getString(p.get(), "reply_markup");
    if (!markup.empty()) addFormField(body, boundary, "reply_markup", markup);
    std::string head = "--" + boundary +
                       "\r\nContent-Disposition: form-data; name=\"photo\"; "
                       "filename=\"doorbell.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n";
    body.insert(body.end(), head.begin(), head.end());
    body.insert(body.end(), item.snapshot.begin(), item.snapshot.end());
    const std::string tail = "\r\n--" + boundary + "--\r\n";
    body.insert(body.end(), tail.begin(), tail.end());
    auto h = json::obj();
    json::set(h.get(), "Content-Type", "multipart/form-data; boundary=" + boundary);
    hooks_.https("POST", apiUrl("sendPhoto"), json::dump(h.get()), std::move(body),
                 std::move(done));
    return;
  }

  // sendMessage (JSON)
  auto b = json::obj();
  json::set(b.get(), "chat_id", item.chat_id);
  json::set(b.get(), "text", json::getString(p.get(), "text"));
  const std::string markup = json::getString(p.get(), "reply_markup");
  if (!markup.empty()) {
    auto m = json::parse(markup);
    if (m) json::setItem(b.get(), "reply_markup", std::move(m));
  }
  hooks_.https("POST", apiUrl("sendMessage"), "{\"Content-Type\":\"application/json\"}",
               toBytes(json::dump(b.get())), std::move(done));
}

void TelegramBridge::onSendDone(const Store::TgQueueItem& item, int status,
                                const std::string& resp) {
  sending_ = false;
  auto r = json::parse(resp);
  const bool ok = status >= 200 && status < 300 && r && json::getBool(r.get(), "ok");
  if (ok) {
    store_.tgQueueDelete(item.id);
    auto p = json::parse(item.payload.empty() ? "{}" : item.payload);
    const std::string origin = p ? json::getString(p.get(), "origin") : "";
    if (!origin.empty()) {  // press → notified_at + telegram_msg_ids を回執
      recordNotified(origin, static_cast<uint64_t>(json::getInt(p.get(), "seq")), item.chat_id,
                     messageIdOf(resp));
    }
    std::weak_ptr<char> w = alive_;
    loop_.post([this, w] {
      if (!w.expired()) pump();  // 次の due を直列で送る
    });
    return;
  }
  const int attempts = item.attempts + 1;
  const int64_t delay = backoffMs(attempts);
  DB_LOGW(kTag, item.kind + " 送信失敗 (status=" + std::to_string(status) + ", attempt=" +
                    std::to_string(attempts) + ") — " + std::to_string(delay / 1000) + "s 後に再試行");
  store_.tgQueueRetry(item.id, attempts, nowWallMs() + delay);
}

// ---------------------------------------------------------------- getUpdates 長輪詢

void TelegramBridge::schedulePoll(int64_t delay_ms) {
  if (poll_timer_) loop_.cancel(poll_timer_);
  std::weak_ptr<char> w = alive_;
  const uint64_t gen = poll_gen_;
  poll_timer_ = loop_.postDelayed(delay_ms, [this, w, gen] {
    if (w.expired()) return;
    poll_timer_ = 0;
    if (!active_ || gen != poll_gen_ || !pollEnabled()) return;
    sendPoll();
  });
}

void TelegramBridge::sendPoll() {
  if (poll_inflight_ || !hooks_.https) return;
  poll_inflight_ = true;
  const uint64_t gen = poll_gen_;
  std::weak_ptr<char> w = alive_;
  const std::string url =
      apiUrl("getUpdates") + "?timeout=25&offset=" + std::to_string(poll_offset_);
  hooks_.https("GET", url, "{}", Bytes(), [this, w, gen](int status, std::string resp) {
    if (w.expired()) return;
    onPollDone(gen, status, resp);
  });
}

void TelegramBridge::onPollDone(uint64_t gen, int status, const std::string& resp) {
  poll_inflight_ = false;
  if (!active_ || !pollEnabled()) return;
  if (gen != poll_gen_) {  // 再構成後の旧応答 — 内容は捨てて新しい輪詢を張り直す
    schedulePoll(0);
    return;
  }
  auto r = json::parse(resp);
  if (status < 200 || status >= 300 || !r || !json::getBool(r.get(), "ok")) {
    schedulePoll(kPollRetryMs);
    return;
  }
  const cJSON* upd = nullptr;
  cJSON_ArrayForEach(upd, json::get(r.get(), "result")) {
    const int64_t uid = json::getInt(upd, "update_id", -1);
    if (uid >= 0 && uid + 1 > poll_offset_) poll_offset_ = uid + 1;  // 再配送防止
    cJSON* cq = json::get(upd, "callback_query");
    if (cq) handleCallbackQuery(cq);
  }
  schedulePoll(kPollGapMs);  // 応答後ほぼ即時 (長輪詢はサーバ側 timeout=25 が待つ)
}

void TelegramBridge::handleCallbackQuery(const cJSON* cq) {
  // data = "qr|<reply_id>|<door_id>"
  const std::string data = json::getString(cq, "data");
  if (data.compare(0, 3, "qr|") != 0) return;
  const size_t sep = data.find('|', 3);
  if (sep == std::string::npos) return;
  const std::string reply_id = data.substr(3, sep - 3);
  const std::string door = data.substr(sep + 1);
  DB_LOGI(kTag, "callback_query: " + reply_id + " (door=" + door + ")");
  if (hooks_.on_reply) hooks_.on_reply(reply_id, "", door);

  // 回執トースト (失敗容認)
  {
    auto o = json::obj();
    json::set(o.get(), "callback_query_id", json::getString(cq, "id"));
    json::set(o.get(), "text", "送信済み");
    postJson("answerCallbackQuery", o);
  }

  // 該当 press の全 chat のメッセージからボタンを撤去し、caption に「✅ 応答済み」を追記
  auto lp = last_press_by_door_.find(door);
  if (lp == last_press_by_door_.end() || !hooks_.get_event) return;
  auto press = hooks_.get_event(lp->second.first, lp->second.second);
  if (!press) return;
  auto n = json::parse(press->notify_json.empty() ? "{}" : press->notify_json);
  cJSON* ids = n ? json::get(n.get(), "telegram_msg_ids") : nullptr;
  const std::string caption = pressCaption(*press) + "\n✅ 応答済み";
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, ids) {
    if (!it->string || !cJSON_IsNumber(it)) continue;
    const int64_t mid = static_cast<int64_t>(it->valuedouble);
    {
      auto o = json::obj();
      json::set(o.get(), "chat_id", std::string(it->string));
      json::set(o.get(), "message_id", mid);
      json::addObj(o.get(), "reply_markup");  // 空 reply_markup = ボタン撤去
      postJson("editMessageReplyMarkup", o);
    }
    {
      // sendMessage に降級した通知には caption が無い — その場合の失敗も容認
      auto o = json::obj();
      json::set(o.get(), "chat_id", std::string(it->string));
      json::set(o.get(), "message_id", mid);
      json::set(o.get(), "caption", caption);
      postJson("editMessageCaption", o);
    }
  }
  // TODO(v1.1): 自由文返信 (bot へのテキストリプライ) — message.reply_to_message から
  // 該当 press を特定し quickReply(free_text) へ配線する。
}

}  // namespace db
