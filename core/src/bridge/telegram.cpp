
#include "bridge/telegram.h"

#include <algorithm>
#include <cctype>
#include <cinttypes>
#include <cstdio>

#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "telegram";
constexpr const char* kApiBase = "https://api.telegram.org/bot";
constexpr int64_t kClaimRecheckMs = 300;
constexpr int64_t kPumpPeriodMs = 1000;
constexpr int64_t kQueueTtlMs = 24 * 3600'000LL;
constexpr int64_t kPollRetryMs = 5000;
constexpr int64_t kPollGapMs = 50;
constexpr const char* kDefaultTemplateJa = "{door} に来客です ({time})";


int64_t backoffMs(int attempts) {
  if (attempts <= 1) return 30'000;
  if (attempts == 2) return 60'000;
  if (attempts == 3) return 300'000;
  return 900'000;
}


void replaceAll(std::string& s, const std::string& from, const std::string& to) {
  size_t pos = 0;
  while ((pos = s.find(from, pos)) != std::string::npos) {
    s.replace(pos, from.size(), to);
    pos += to.size();
  }
}


int64_t floorDiv(int64_t a, int64_t b) {
  int64_t q = a / b;
  if ((a % b) != 0 && ((a < 0) != (b < 0))) --q;
  return q;
}


void addFormField(Bytes& out, const std::string& boundary, const std::string& name,
                  const std::string& value) {
  std::string part = "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + name +
                     "\"\r\n\r\n" + value + "\r\n";
  out.insert(out.end(), part.begin(), part.end());
}


int64_t messageIdOf(const std::string& resp) {
  auto d = json::parse(resp);
  if (!d || !json::getBool(d.get(), "ok")) return 0;
  return json::getInt(json::get(d.get(), "result"), "message_id");
}

std::string payloadString(const EventRecord& ev, const char* key) {
  auto payload = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
  return payload ? json::getString(payload.get(), key) : "";
}
}  // namespace

TelegramBridge::TelegramBridge(Runloop& loop, Store& store, Hooks hooks)
    : loop_(loop), store_(store), hooks_(std::move(hooks)) {}

TelegramBridge::~TelegramBridge() { stop(); }



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


std::string TelegramBridge::labelIn(const cJSON* label_obj, const std::string& lang) const {
  if (!label_obj) return "";
  std::string v = json::getString(label_obj, lang.c_str());
  if (v.empty()) v = json::getString(label_obj, "ja");
  if (v.empty()) v = json::getString(label_obj, "en");
  if (v.empty() && label_obj->child && cJSON_IsString(label_obj->child))
    v = label_obj->child->valuestring;
  return v;
}

std::string TelegramBridge::labelJa(const cJSON* label_obj) const {
  return labelIn(label_obj, "ja");
}

std::string TelegramBridge::notifyLang() const {
  std::string l = json::getString(cfgAt("integrations.telegram"), "lang");
  return l.empty() ? "ja" : l;
}

std::string TelegramBridge::tr(const std::string& key,
                               const std::vector<std::pair<std::string, std::string>>& args) const {
  if (!hooks_.text) return key;
  return hooks_.text(key, notifyLang(), args);
}

std::string TelegramBridge::doorLabel(const std::string& door_id) const {
  std::string v = labelIn(json::get(cfgAt("doors." + door_id), "label"), notifyLang());
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



std::string TelegramBridge::hhmm(int64_t wall_ms) const {
  const int64_t local = wall_ms + static_cast<int64_t>(tzOffsetMin()) * 60'000LL;
  const int64_t day_ms = 86'400'000LL;
  const int64_t day = floorDiv(local, day_ms);
  const int minute = static_cast<int>((local - day * day_ms) / 60'000LL);
  char buf[8];
  std::snprintf(buf, sizeof(buf), "%02d:%02d", minute / 60, minute % 60);
  return buf;
}



std::string TelegramBridge::purposeHeadline(const EventRecord& ev) const {
  auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
  if (!p) return "";
  std::string head;
  const std::string purpose = json::getString(p.get(), "purpose");
  if (!purpose.empty()) {
    cJSON* vp = cfgAt("visit_purposes." + purpose);

    std::string label = labelIn(json::get(vp, "label"), notifyLang());
    if (label.empty()) label = purpose;
    const std::string icon = json::getString(vp, "icon");
    head = icon.empty() ? label : icon + " " + label;
  }
  const std::string vlang = json::getString(p.get(), "visitor_lang");
  if (!vlang.empty() && vlang != "ja") {
    std::string badge = "🌐 ";
    for (char c : vlang) badge.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(c))));
    head = head.empty() ? badge : head + " " + badge;
  }
  return head;
}

std::string TelegramBridge::pressCaption(const EventRecord& ev) const {


  const std::string lang = notifyLang();
  cJSON* tpl = cfgAt("integrations.telegram.text_template");
  std::string t = json::getString(tpl, lang.c_str());
  if (t.empty()) t = json::getString(tpl, "ja");
  if (t.empty()) t = hooks_.text ? tr("event.press") : std::string(kDefaultTemplateJa);
  replaceAll(t, "{door}", doorLabel(ev.door));
  replaceAll(t, "{time}", hhmm(ev.wall_ms));

  const std::string head = purposeHeadline(ev);
  return head.empty() ? t : head + "\n" + t;
}

std::string TelegramBridge::eventText(const EventRecord& ev) const {

  if (ev.type == "motion")
    return tr("event.motion", {{"door", doorLabel(ev.door)}, {"time", hhmm(ev.wall_ms)}});
  if (ev.type == "offline")
    return tr("event.offline", {{"device", deviceName(ev.device)}, {"time", hhmm(ev.wall_ms)}});
  if (ev.type == "online") return tr("event.online", {{"device", deviceName(ev.device)}});
  if (ev.type == "emergency" || ev.type == "emergency_cancel") {
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    std::string source = p ? json::getString(p.get(), "source") : "";
    if (source.empty()) source = ev.device;
    return ev.type == "emergency"
        ? tr("emergency.notify_on", {{"device", deviceName(source)}, {"time", hhmm(ev.wall_ms)}})
        : tr("emergency.notify_off");
  }
  return "";
}


std::string TelegramBridge::replyMarkupJson(const std::string& door_id,
                                            const std::string& call_id) const {
  (void)door_id;
  struct Btn {
    int64_t order;
    std::string id, label;
  };
  std::vector<Btn> btns;
  cJSON* qrs = cfgAt("quick_replies");
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, qrs) {
    if (!it->string) continue;
    std::string label = labelIn(json::get(it, "label"), notifyLang());
    if (label.empty()) continue;
    btns.push_back({json::getInt(it, "order", 1000), it->string, label});
  }
  std::sort(btns.begin(), btns.end(), [](const Btn& a, const Btn& b) {
    return std::tie(a.order, a.id) < std::tie(b.order, b.id);
  });
  auto o = json::obj();
  cJSON* rows = json::addArr(o.get(), "inline_keyboard");
  for (const auto& b : btns) {
    const std::string callback = "qr|" + b.id + "|" + call_id;
    if (call_id.empty() || callback.size() > 64) {
      DB_LOGW(kTag, "quick-reply button omitted because its scoped callback is too long");
      continue;
    }
    json::Doc row(cJSON_CreateArray());
    cJSON* btn = cJSON_CreateObject();
    json::set(btn, "text", b.label);
    json::set(btn, "callback_data", callback);
    cJSON_AddItemToArray(row.get(), btn);
    json::push(rows, std::move(row));
  }
  return json::dump(o.get());
}

std::vector<std::string> TelegramBridge::resolveChats(const cJSON* households) const {
  if (!households || (cJSON_IsString(households) &&
                      std::string(households->valuestring) == "all"))
    return allHouseholdChats();
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

  const bool act = active && !token.empty();
  const bool token_changed = token != token_;
  token_ = token;

  if (!act) {
    if (active_) DB_LOGI(kTag, "bridge stopped because this node is not leader or bot_token is unset");
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
    return;
  }

  if (!active_) DB_LOGI(kTag, "bridge started as Telegram leader");
  active_ = true;
  if (!pump_timer_) {
    pump_timer_ = loop_.postEvery(kPumpPeriodMs, [this] { pump(); });
    std::weak_ptr<char> w = alive_;
    loop_.post([this, w] {
      if (!w.expired()) pump();
    });
  }
  if (token_changed) poll_gen_++;
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


std::vector<std::string> TelegramBridge::allHouseholdChats() const {
  auto ids = json::arr();
  cJSON* hs = cfgAt("households");
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, hs) {
    if (it->string) json::push(ids.get(), json::Doc(cJSON_CreateString(it->string)));
  }
  return resolveChats(ids.get());
}


void TelegramBridge::sendTestMessage(const std::string& chat_id_or_empty) {
  if (!active_) return;
  std::vector<std::string> chats;
  if (!chat_id_or_empty.empty()) {
    chats.push_back(chat_id_or_empty);
  } else {
    chats = allHouseholdChats();
  }
  if (chats.empty()) {
    DB_LOGW(kTag, "test message skipped because no destination chat_id is configured");
    return;
  }
  for (const auto& c : chats) {
    auto pl = json::obj();
    json::set(pl.get(), "text", tr("notify.test"));
    enqueue("message", c, json::dump(pl.get()), Bytes());
  }
  pump();
}



void TelegramBridge::sendEmergency(bool active, const std::string& source_node,
                                   int64_t wall_ms) {
  if (!active_) return;
  auto chats = allHouseholdChats();
  if (chats.empty()) {
    DB_LOGW(kTag, "emergency notification skipped because no destination chat_id is configured");
    return;
  }
  const std::string text =
      active ? tr("emergency.notify_on", {{"device", deviceName(source_node)},
                                          {"time", hhmm(wall_ms)}})
             : tr("emergency.notify_off");
  for (const auto& c : chats) {
    auto pl = json::obj();
    json::set(pl.get(), "text", text);
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



void TelegramBridge::postJson(const std::string& api_method, const json::Doc& body_obj) {
  if (!hooks_.https) return;
  const std::string body = json::dump(body_obj.get());
  std::weak_ptr<char> w = alive_;
  const std::string m = api_method;
  hooks_.https("POST", apiUrl(api_method), "{\"Content-Type\":\"application/json\"}",
               toBytes(body), [w, m](int status, std::string resp) {
                 if (w.expired()) return;
                 if (status < 200 || status >= 300)
                   DB_LOGW(kTag, m + " failed (status=" + std::to_string(status) +
                                     ", body=" + resp.substr(0, 300) + "); accepting response");
               });
}




void TelegramBridge::editCaptionOrText(const std::string& chat_id, int64_t message_id,
                                       const std::string& text) {
  if (!hooks_.https) return;
  auto o = json::obj();
  json::set(o.get(), "chat_id", chat_id);
  json::set(o.get(), "message_id", message_id);
  json::set(o.get(), "caption", text);
  const std::string body = json::dump(o.get());
  std::weak_ptr<char> w = alive_;
  hooks_.https(
      "POST", apiUrl("editMessageCaption"), "{\"Content-Type\":\"application/json\"}",
      toBytes(body), [this, w, chat_id, message_id, text](int status, std::string resp) {
        if (w.expired()) return;
        if (status >= 200 && status < 300) return;
        if (status == 400) {
          auto t = json::obj();
          json::set(t.get(), "chat_id", chat_id);
          json::set(t.get(), "message_id", message_id);
          json::set(t.get(), "text", text);
          postJson("editMessageText", t);
          return;
        }
        DB_LOGW(kTag, "editMessageCaption failed (status=" + std::to_string(status) +
                          ", body=" + resp.substr(0, 300) + "); accepting response");
      });
}



void TelegramBridge::onEvent(const EventRecord& ev) {
  if (ev.type == "press") {
    const std::string call_id = callIdOf(ev);
    if (!call_id.empty()) {
      const CallSource source{ev.origin, ev.seq, ev.wall_ms};
      press_source_by_call_[call_id] = source;
      auto cancelled = cancelled_calls_.find(call_id);
      if (cancelled != cancelled_calls_.end()) {
        markSourceCancelled(source, call_id, cancelled->second.hlc);
        suppressPendingQueue(call_id);
      }
    }
    last_press_by_door_[ev.door] = {ev.origin, ev.seq};
    return;
  }
  if (ev.type == "call_cancelled") {
    cancelPendingCall(ev);
    return;
  }
  if (ev.type != "reply" || !active_) return;


  auto p = json::parse(ev.payload_json);
  const std::string text = p ? json::getString(p.get(), "text") : "";
  if (text.empty()) return;
  const std::string call_id = p ? json::getString(p.get(), "call_id") : "";
  std::optional<EventRecord> press;
  if (!call_id.empty()) {
    auto source = press_source_by_call_.find(call_id);
    if (source != press_source_by_call_.end() && hooks_.get_event)
      press = hooks_.get_event(source->second.origin, source->second.seq);
  } else {
    auto lp = last_press_by_door_.find(ev.door);
    if (lp != last_press_by_door_.end() && hooks_.get_event)
      press = hooks_.get_event(lp->second.first, lp->second.second);
  }
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

  if (ev.type == "press" || ev.type == "purpose_selected") {
    claimAndSend(ev, p.get());
    return;
  }

  const std::string text = eventText(ev);
  if (text.empty()) return;
  auto chats = resolveChats(json::get(p.get(), "households"));
  if (chats.empty()) {
    DB_LOGW(kTag, ev.type + ": skipped because households have no telegram_chat_ids");
    return;
  }
  for (const auto& c : chats) {
    auto pl = json::obj();
    json::set(pl.get(), "text", text);
    enqueue("message", c, json::dump(pl.get()), Bytes());
  }
  pump();
}



void TelegramBridge::claimAndSend(const EventRecord& ev, const cJSON* params) {
  if (!hooks_.get_event || !hooks_.merge_notify || !hooks_.hlc_tick) return;
  const std::string call_id = callIdOf(ev);
  const CallSource source = sourceFor(ev, call_id);
  if (callSuppressed(call_id, source)) {
    DB_LOGI(kTag, "press: skipped because its call was cancelled");
    return;
  }
  auto chats = resolveChats(json::get(params, "households"));
  if (chats.empty()) {
    DB_LOGW(kTag, "press: skipped because households have no telegram_chat_ids");
    return;
  }
  auto cur = hooks_.get_event(ev.origin, ev.seq);
  if (!cur) return;
  auto n = json::parse(cur->notify_json.empty() ? "{}" : cur->notify_json);
  if (n && !json::getString(n.get(), "notified_at").empty()) {
    DB_LOGI(kTag, "press: skipped because notified_at indicates prior delivery");
    return;
  }


  {
    auto c = json::obj();
    json::set(c.get(), "hlc", hooks_.hlc_tick());
    json::set(c.get(), "claimed_by", node_id_);
    hooks_.merge_notify(ev.origin, ev.seq, json::dump(c.get()));
  }
  const bool with_snapshot = json::getBool(params, "with_snapshot");
  std::weak_ptr<char> w = alive_;
  loop_.postDelayed(kClaimRecheckMs, [this, w, ev, chats, with_snapshot, call_id, source] {
    if (w.expired() || !active_) return;
    if (callSuppressed(call_id, source)) return;
    auto cur2 = hooks_.get_event(ev.origin, ev.seq);
    if (!cur2) return;
    auto n2 = json::parse(cur2->notify_json.empty() ? "{}" : cur2->notify_json);
    const std::string claimed = n2 ? json::getString(n2.get(), "claimed_by") : "";
    if (claimed != node_id_) {
      DB_LOGI(kTag, "press: another leader won the claim (" + claimed.substr(0, 8) + "); stopping");
      return;
    }
    if (n2 && !json::getString(n2.get(), "notified_at").empty()) return;
    enqueuePress(ev, chats, with_snapshot, call_id, source);
  });
}

void TelegramBridge::enqueuePress(const EventRecord& ev, const std::vector<std::string>& chats,
                                  bool with_snapshot, const std::string& call_id,
                                  const CallSource& source) {
  const std::string caption = pressCaption(ev);
  const std::string markup = replyMarkupJson(ev.door, call_id);
  auto enqueueAll = [this, ev, chats, caption, markup, call_id, source](const Bytes& jpeg) {
    if (callSuppressed(call_id, source)) return;
    for (const auto& c : chats) {
      auto pl = json::obj();
      json::set(pl.get(), "origin", ev.origin);
      json::set(pl.get(), "seq", static_cast<int64_t>(ev.seq));
      json::set(pl.get(), "door", ev.door);
      json::set(pl.get(), "call_id", call_id);
      json::set(pl.get(), "source_origin", source.origin);
      json::set(pl.get(), "source_seq", static_cast<int64_t>(source.seq));
      json::set(pl.get(), "reply_markup", markup);
      if (jpeg.empty()) {
        json::set(pl.get(), "text", caption);
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
      enqueueAll(jpeg);
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



void TelegramBridge::enqueue(const std::string& kind, const std::string& chat_id,
                             const std::string& payload, const Bytes& snapshot) {
  Store::TgQueueItem item;
  item.kind = kind;
  item.chat_id = chat_id;
  item.payload = payload;
  item.snapshot = snapshot;
  item.next_retry_ms = nowWallMs();
  item.created_ms = nowWallMs();
  const int64_t id = store_.tgQueuePut(item);
  auto p = json::parse(payload.empty() ? "{}" : payload);
  const std::string call_id = p ? json::getString(p.get(), "call_id") : "";
  if (id > 0 && !call_id.empty()) queued_calls_[id] = {call_id, item.created_ms};
}

void TelegramBridge::pump() {
  if (!active_ || sending_) return;
  pruneCallTracking();
  store_.tgQueuePrune(nowWallMs() - kQueueTtlMs);
  while (active_ && !sending_) {
    auto due = store_.tgQueueDue(nowWallMs(), 1);
    if (due.empty()) return;
    if (queueItemSuppressed(due[0])) {
      store_.tgQueueDelete(due[0].id);
      forgetQueueItem(due[0].id);
      continue;
    }
    sending_ = true;
    inflight_item_id_ = due[0].id;
    sendItem(due[0]);
  }
}

void TelegramBridge::sendItem(const Store::TgQueueItem& item) {
  auto p = json::parse(item.payload.empty() ? "{}" : item.payload);
  if (!p || !hooks_.https) {
    onSendDone(item, -1, "");
    return;
  }
  std::weak_ptr<char> w = alive_;
  auto done = [this, w, item](int status, std::string resp) {
    if (w.expired()) return;
    onSendDone(item, status, resp);
  };

  if (item.kind == "photo") {

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
  inflight_item_id_ = 0;
  auto r = json::parse(resp);
  const bool ok = status >= 200 && status < 300 && r && json::getBool(r.get(), "ok");
  if (ok) {
    store_.tgQueueDelete(item.id);
    forgetQueueItem(item.id);
    auto p = json::parse(item.payload.empty() ? "{}" : item.payload);
    const std::string origin = p ? json::getString(p.get(), "origin") : "";
    if (!origin.empty()) {
      recordNotified(origin, static_cast<uint64_t>(json::getInt(p.get(), "seq")), item.chat_id,
                     messageIdOf(resp));
    }
    std::weak_ptr<char> w = alive_;
    loop_.post([this, w] {
      if (!w.expired()) pump();
    });
    return;
  }
  if (queueItemSuppressed(item)) {
    store_.tgQueueDelete(item.id);
    forgetQueueItem(item.id);
    std::weak_ptr<char> w = alive_;
    loop_.post([this, w] {
      if (!w.expired()) pump();
    });
    return;
  }
  const int attempts = item.attempts + 1;
  const int64_t delay = backoffMs(attempts);
  DB_LOGW(kTag, item.kind + " delivery failed (status=" + std::to_string(status) + ", attempt=" +
                    std::to_string(attempts) + "); retrying after " + std::to_string(delay / 1000) + "s");
  store_.tgQueueRetry(item.id, attempts, nowWallMs() + delay);
}

std::string TelegramBridge::callIdOf(const EventRecord& ev) {
  std::string call_id = payloadString(ev, "call_id");
  if (call_id.empty() && ev.type == "press")
    call_id = ev.origin + ":" + std::to_string(ev.seq);
  return call_id;
}

TelegramBridge::CallSource TelegramBridge::sourceFor(const EventRecord& ev,
                                                     const std::string& call_id) const {
  auto it = press_source_by_call_.find(call_id);
  if (it != press_source_by_call_.end()) return it->second;
  return {ev.origin, ev.seq, ev.wall_ms};
}

bool TelegramBridge::eventMarksCancelled(const CallSource& source,
                                         const std::string& call_id) const {
  if (source.origin.empty() || source.seq == 0 || !hooks_.get_event) return false;
  auto event = hooks_.get_event(source.origin, source.seq);
  if (!event) return false;
  auto notify = json::parse(event->notify_json.empty() ? "{}" : event->notify_json);
  return notify && json::getString(notify.get(), "telegram_cancelled_call_id") == call_id;
}

bool TelegramBridge::callSuppressed(const std::string& call_id,
                                    const CallSource& source) const {
  if (call_id.empty()) return false;
  if (cancelled_calls_.find(call_id) != cancelled_calls_.end()) return true;
  return eventMarksCancelled(source, call_id);
}

bool TelegramBridge::queueItemSuppressed(const Store::TgQueueItem& item) const {
  auto payload = json::parse(item.payload.empty() ? "{}" : item.payload);
  if (!payload) return false;
  std::string call_id = json::getString(payload.get(), "call_id");
  const std::string action_origin = json::getString(payload.get(), "origin");
  const uint64_t action_seq = static_cast<uint64_t>(json::getInt(payload.get(), "seq"));
  std::optional<EventRecord> action_event;
  if (call_id.empty() && !action_origin.empty() && action_seq > 0 && hooks_.get_event) {
    action_event = hooks_.get_event(action_origin, action_seq);
    if (action_event) call_id = callIdOf(*action_event);
  }
  CallSource source;
  source.origin = json::getString(payload.get(), "source_origin");
  source.seq = static_cast<uint64_t>(json::getInt(payload.get(), "source_seq"));
  if (source.origin.empty() || source.seq == 0) {
    auto known_source = press_source_by_call_.find(call_id);
    if (known_source != press_source_by_call_.end()) {
      source = known_source->second;
    } else {
      source.origin = action_origin;
      source.seq = action_seq;
      if (action_event) source.wall_ms = action_event->wall_ms;
    }
  }
  return callSuppressed(call_id, source);
}

void TelegramBridge::markSourceCancelled(const CallSource& source, const std::string& call_id,
                                         const std::string& cancelled_hlc) {
  if (source.origin.empty() || source.seq == 0 || !hooks_.merge_notify || !hooks_.hlc_tick) return;
  auto marker = json::obj();
  json::set(marker.get(), "hlc", hooks_.hlc_tick());
  json::set(marker.get(), "telegram_cancelled_call_id", call_id);
  json::set(marker.get(), "telegram_cancelled_at", cancelled_hlc);
  hooks_.merge_notify(source.origin, source.seq, json::dump(marker.get()));
}

void TelegramBridge::suppressPendingQueue(const std::string& call_id) {
  std::vector<int64_t> remove;
  for (const auto& queued : queued_calls_) {
    if (queued.second.first == call_id && queued.first != inflight_item_id_)
      remove.push_back(queued.first);
  }
  for (int64_t id : remove) {
    store_.tgQueueDelete(id);
    forgetQueueItem(id);
  }
  if (!sending_) pump();
}

void TelegramBridge::cancelPendingCall(const EventRecord& ev) {
  const std::string call_id = callIdOf(ev);
  if (call_id.empty()) return;
  auto& cancelled = cancelled_calls_[call_id];
  cancelled.wall_ms = std::max(cancelled.wall_ms, ev.wall_ms > 0 ? ev.wall_ms : nowWallMs());
  if (ev.hlc > cancelled.hlc) cancelled.hlc = ev.hlc;
  auto source = press_source_by_call_.find(call_id);
  if (source != press_source_by_call_.end())
    markSourceCancelled(source->second, call_id, cancelled.hlc);
  suppressPendingQueue(call_id);
}

void TelegramBridge::forgetQueueItem(int64_t id) { queued_calls_.erase(id); }

void TelegramBridge::pruneCallTracking() {
  const int64_t cutoff = nowWallMs() - kQueueTtlMs;
  for (auto it = cancelled_calls_.begin(); it != cancelled_calls_.end();) {
    if (it->second.wall_ms < cutoff)
      it = cancelled_calls_.erase(it);
    else
      ++it;
  }
  for (auto it = press_source_by_call_.begin(); it != press_source_by_call_.end();) {
    if (it->second.wall_ms > 0 && it->second.wall_ms < cutoff)
      it = press_source_by_call_.erase(it);
    else
      ++it;
  }
  for (auto it = queued_calls_.begin(); it != queued_calls_.end();) {
    if (it->second.second < cutoff)
      it = queued_calls_.erase(it);
    else
      ++it;
  }
}



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
  if (gen != poll_gen_) {
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
    if (uid >= 0 && uid + 1 > poll_offset_) poll_offset_ = uid + 1;
    cJSON* cq = json::get(upd, "callback_query");
    if (cq) handleCallbackQuery(cq);
  }
  schedulePoll(kPollGapMs);
}

void TelegramBridge::handleCallbackQuery(const cJSON* cq) {
  // data = "qr|<reply_id>|<call_id>"; the call identity prevents an old button replying to a
  // later visitor at the same door.
  const std::string data = json::getString(cq, "data");
  if (data.compare(0, 3, "qr|") != 0) return;
  const size_t sep = data.find('|', 3);
  if (sep == std::string::npos) return;
  const std::string reply_id = data.substr(3, sep - 3);
  const std::string call_id = data.substr(sep + 1);
  auto projection = store_.callProjection(call_id);
  const std::string door = projection ? projection->door : "";
  const bool accepted = projection && projection->state == "ringing" && hooks_.on_reply &&
                        hooks_.on_reply(reply_id, "", door, call_id);
  DB_LOGI(kTag, "callback_query: " + reply_id + " (call=" + call_id.substr(0, 8) +
                    ", accepted=" + (accepted ? "true" : "false") + ")");

  std::string rlabel = labelIn(json::get(cfgAt("quick_replies." + reply_id), "label"),
                               notifyLang());
  if (rlabel.empty()) rlabel = reply_id;


  {
    auto o = json::obj();
    json::set(o.get(), "callback_query_id", json::getString(cq, "id"));
    json::set(o.get(), "text", accepted ? tr("reply.sent", {{"text", rlabel}})
                                          : tr("reply.failed"));
    postJson("answerCallbackQuery", o);
  }

  if (!accepted || !hooks_.get_event) return;
  auto source = press_source_by_call_.find(call_id);
  if (source == press_source_by_call_.end()) return;
  auto press = hooks_.get_event(source->second.origin, source->second.seq);
  if (!press) return;
  auto n = json::parse(press->notify_json.empty() ? "{}" : press->notify_json);
  cJSON* ids = n ? json::get(n.get(), "telegram_msg_ids") : nullptr;

  const std::string caption =
      pressCaption(*press) + "\n✅ " + tr("reply.answered", {{"text", rlabel}});
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, ids) {
    if (!it->string || !cJSON_IsNumber(it)) continue;
    const int64_t mid = static_cast<int64_t>(it->valuedouble);
    {
      auto o = json::obj();
      json::set(o.get(), "chat_id", std::string(it->string));
      json::set(o.get(), "message_id", mid);


      cJSON* markup = json::addObj(o.get(), "reply_markup");
      json::addArr(markup, "inline_keyboard");
      postJson("editMessageReplyMarkup", o);
    }

    editCaptionOrText(it->string, mid, caption);
  }


}

}  // namespace db
