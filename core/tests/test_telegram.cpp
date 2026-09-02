


#include <array>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "bridge/telegram.h"
#include "doctest.h"
#include "events/events.h"
#include "mesh/mesh.h"
#include "node/node.h"
#include "store/store.h"
#include "util/clock.h"
#include "util/common.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {


struct HttpsReq {
  std::string method, url, headers;
  std::string body;
};



struct MockHttps {
  std::vector<HttpsReq> reqs;
  int64_t next_msg_id = 100;
  bool drop = false;
  int fail_status = 0;

  std::map<std::string, std::pair<int, std::string>> respond_by_api;
  std::string pending_updates = "[]";

  Node::HttpsFn fn() {
    return [this](const std::string& m, const std::string& u, const std::string& h,
                  const Bytes& b, std::function<void(int, std::string)> done) {
      reqs.push_back({m, u, h, std::string(b.begin(), b.end())});
      if (drop) return;
      for (const auto& r : respond_by_api) {
        if (u.find("/" + r.first) != std::string::npos) {
          done(r.second.first, r.second.second);
          return;
        }
      }
      if (fail_status > 0) {
        done(fail_status, "{\"ok\":false}");
        return;
      }
      if (u.find("/getUpdates") != std::string::npos) {
        std::string r = "{\"ok\":true,\"result\":" + pending_updates + "}";
        pending_updates = "[]";
        done(200, r);
        return;
      }
      done(200, "{\"ok\":true,\"result\":{\"message_id\":" +
                    std::to_string(next_msg_id++) + "}}");
    };
  }

  size_t count(const std::string& api) const {
    size_t n = 0;
    for (const auto& r : reqs)
      if (r.url.find("/" + api) != std::string::npos) n++;
    return n;
  }
  const HttpsReq* last(const std::string& api) const {
    for (auto it = reqs.rbegin(); it != reqs.rend(); ++it)
      if (it->url.find("/" + api) != std::string::npos) return &*it;
    return nullptr;
  }
};


std::string tgCaps(int cpu, bool wan = true) {
  auto o = json::obj();
  json::setBool(o.get(), "tls12", true);
  json::setBool(o.get(), "wan", wan);
  json::setBool(o.get(), "mains_power", true);
  json::setBool(o.get(), "mqtt_reachable", true);
  json::setBool(o.get(), "wall_clock_sane", true);
  json::set(o.get(), "cpu_score", int64_t{cpu});
  return json::dump(o.get());
}

struct TgFleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};

  TgFleet() { psk.fill(0x5a); }

  static MeshSettings timing() {
    MeshSettings m;
    m.heartbeat_ms = 30;
    m.suspect_ms = 90;
    m.dead_ms = 150;
    m.gossip_ms = 50;
    m.sync_ms = 50;
    m.claim_ttl_ms = 300;
    m.reconnect_ms = 50;
    return m;
  }

  struct N {
    std::unique_ptr<Node> node;
    MockHttps https;
    std::map<std::string, std::string> secrets;
    std::vector<std::string> ui;
    std::vector<std::string> tts;
    size_t uiCount(const std::string& t, const std::string& type = "") const {
      size_t n = 0;
      for (const auto& e : ui) {
        auto d = json::parse(e);
        if (!d) continue;
        if (json::getString(d.get(), "t") != t) continue;
        if (!type.empty() && json::getString(d.get(), "type") != type) continue;
        n++;
      }
      return n;
    }
  };
  std::vector<std::unique_ptr<N>> nodes;

  N& add(const std::string& addr, const std::string& name, const std::string& role,
         const std::string& door, bool seed_cfg, const std::string& caps) {
    NodeOptions o;
    o.data_dir = ":memory:";
    o.name = name;
    o.role = role;
    o.door = door;
    o.listen_addr = addr;
    o.advertise_addr = addr;
    o.psk = psk;
    o.enable_beacon = false;
    o.http_port = 0;
    o.caps_json = caps;
    o.seed_default_config = seed_cfg;
    o.mesh_timing_template = timing();
    o.use_mesh_timing_template = true;
    NodeDeps d;
    d.clock = &clock;
    d.loop = &loop;
    d.transport = net.makeTransport(addr);
    d.discovery = net.makeDiscovery(addr);
    auto n = std::make_unique<N>();
    N* raw = n.get();
    n->node.reset(new Node(o, std::move(d)));
    raw->secrets["telegram.test"] = "TESTTOKEN";
    n->node->setSecureStore(
        [raw](const std::string& key) {
          auto it = raw->secrets.find(key);
          return it == raw->secrets.end() ? std::string() : it->second;
        },
        [raw](const std::string& key, const std::string& value) {
          if (value.empty()) raw->secrets.erase(key);
          else raw->secrets[key] = value;
          return true;
        });
    n->node->setHttpsFn(raw->https.fn());
    n->node->setUiEventCb([raw](const std::string& e) { raw->ui.push_back(e); });
    n->node->setTtsCb([raw](const std::string& t, const std::string&) { raw->tts.push_back(t); });
    nodes.push_back(std::move(n));
    return *nodes.back();
  }

  void run(int64_t ms, int64_t step = 10) {
    for (int64_t t = 0; t < ms; t += step) {
      clock.advance(step);
      loop.pumpDue();
    }
  }

  template <class F>
  bool runUntil(F cond, int64_t max_ms, int64_t step = 10) {
    loop.pumpDue();
    if (cond()) return true;
    for (int64_t t = 0; t < max_ms; t += step) {
      clock.advance(step);
      loop.pumpDue();
      if (cond()) return true;
    }
    return false;
  }
};


void seedTgConfig(Node& n, bool with_snapshot, bool poll_updates = false) {
  n.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");
  n.setConfigKey("households.h_ox", "{\"telegram_chat_ids\":[111]}");
  n.setConfigKey("integrations.telegram.bot_token_ref", "\"secret:telegram.test\"");
  n.setConfigKey("integrations.telegram.text_template", "{\"ja\":\"{door}に来客です ({time})\"}");
  if (poll_updates) n.setConfigKey("integrations.telegram.poll_updates", "true");
  n.setConfigKey("trigger_rules.r1",
                 std::string("{\"enabled\":true,") +
                     "\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]}," +
                     "\"actions\":[{\"type\":\"telegram\",\"households\":[\"h_ox\"]," +
                     "\"with_snapshot\":" + (with_snapshot ? "true" : "false") + "}]}");
}


void pushFrame(Node& n, uint8_t shade = 0x7f) {
  const int w = 32, h = 24;
  std::vector<uint8_t> px(static_cast<size_t>(w) * h * 4, shade);
  n.pushCameraFrame(px.data(), /*BGRA=*/3, w, h, w * 4, 1000);
}

const std::string kJpegSoi("\xff\xd8\xff", 3);

}  // namespace

TEST_CASE("telegram: cancellation while snapshot is pending suppresses delivery") {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  Store store;
  REQUIRE(store.open(":memory:"));
  HlcClock hlc{clock, "telegram-test"};
  EventLog events{"telegram-test-node", hlc, store};
  events.loadHeads();

  std::function<void(Bytes)> finish_snapshot;
  size_t sends = 0;
  TelegramBridge::Hooks hooks;
  hooks.https = [&sends](const std::string&, const std::string&, const std::string&, Bytes,
                         std::function<void(int, std::string)> done) {
    sends++;
    done(200, R"({"ok":true,"result":{"message_id":100}})");
  };
  hooks.get_event = [&store](const std::string& origin, uint64_t seq) {
    return store.eventGet(origin, seq);
  };
  hooks.merge_notify = [&events](const std::string& origin, uint64_t seq,
                                  const std::string& notify) {
    events.mergeNotify(origin, seq, notify);
  };
  hooks.hlc_tick = [&hlc] { return hlc.tick(); };
  hooks.fetch_snapshot = [&finish_snapshot](const std::string&,
                                             std::function<void(Bytes)> done) {
    finish_snapshot = std::move(done);
  };

  TelegramBridge bridge{loop, store, std::move(hooks)};
  bridge.configure(
      R"({"integrations":{"telegram":{"bot_token":"TESTTOKEN"}},"households":{"h_ox":{"telegram_chat_ids":[111]}}})",
      "telegram-test-node", true);
  const std::string call_id = "snapshot-call";
  EventRecord press = events.append(
      "press", "d_front", "telegram-test-node",
      R"({"schema_version":2,"call_id":"snapshot-call","stage_revision":0})");
  bridge.onAction(press, R"({"households":["h_ox"],"with_snapshot":true})");
  bridge.onEvent(press);

  clock.advance(300);
  loop.pumpDue();
  REQUIRE(static_cast<bool>(finish_snapshot));
  CHECK(sends == 0);

  EventRecord cancelled = events.append(
      "call_cancelled", "d_front", "telegram-test-node",
      R"({"schema_version":2,"call_id":"snapshot-call","reason":"visitor"})");
  bridge.onEvent(cancelled);
  finish_snapshot(Bytes{0xff, 0xd8, 0xff});
  loop.pumpDue();

  CHECK(sends == 0);
  CHECK(store.tgQueueCount() == 0);
  auto persisted_press = store.eventGet(press.origin, press.seq);
  REQUIRE(persisted_press.has_value());
  auto notify = json::parse(persisted_press->notify_json);
  REQUIRE(notify);
  CHECK(json::getString(notify.get(), "telegram_cancelled_call_id") == call_id);

  Store::TgQueueItem legacy_item;
  legacy_item.kind = "message";
  legacy_item.chat_id = "111";
  legacy_item.payload = "{\"origin\":\"" + press.origin + "\",\"seq\":" +
                        std::to_string(press.seq) + ",\"text\":\"late\"}";
  legacy_item.next_retry_ms = clock.wallMs();
  legacy_item.created_ms = clock.wallMs();
  REQUIRE(store.tgQueuePut(legacy_item) > 0);
  clock.advance(1000);
  loop.pumpDue();
  CHECK(sends == 0);
  CHECK(store.tgQueueCount() == 0);
  bridge.stop();
}

TEST_CASE("telegram: reordered cancellation persists when its press arrives later") {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  Store store;
  REQUIRE(store.open(":memory:"));
  HlcClock hlc{clock, "telegram-reorder"};
  EventLog events{"telegram-reorder-node", hlc, store};
  events.loadHeads();

  size_t sends = 0;
  auto makeHooks = [&]() {
    TelegramBridge::Hooks hooks;
    hooks.https = [&sends](const std::string&, const std::string&, const std::string&, Bytes,
                           std::function<void(int, std::string)> done) {
      sends++;
      done(200, R"({"ok":true,"result":{"message_id":100}})");
    };
    hooks.get_event = [&store](const std::string& origin, uint64_t seq) {
      return store.eventGet(origin, seq);
    };
    hooks.merge_notify = [&events](const std::string& origin, uint64_t seq,
                                    const std::string& notify) {
      events.mergeNotify(origin, seq, notify);
    };
    hooks.hlc_tick = [&hlc] { return hlc.tick(); };
    return hooks;
  };

  const std::string call_id = "reordered-call";
  EventRecord press = events.append(
      "press", "d_front", "telegram-reorder-node",
      R"({"schema_version":2,"call_id":"reordered-call","stage_revision":0})");
  clock.advance(1);
  EventRecord cancelled = events.append(
      "call_cancelled", "d_front", "telegram-reorder-node",
      R"({"schema_version":2,"call_id":"reordered-call","reason":"visitor"})");

  const std::string config =
      R"({"integrations":{"telegram":{"bot_token":"TESTTOKEN"}},"households":{"h_ox":{"telegram_chat_ids":[111]}}})";
  {
    TelegramBridge bridge{loop, store, makeHooks()};
    bridge.configure(config, "telegram-reorder-node", true);
    bridge.onEvent(cancelled);
    bridge.onEvent(press);

    auto persisted_press = store.eventGet(press.origin, press.seq);
    REQUIRE(persisted_press.has_value());
    auto notify = json::parse(persisted_press->notify_json);
    REQUIRE(notify);
    CHECK(json::getString(notify.get(), "telegram_cancelled_call_id") == call_id);
    CHECK(json::getString(notify.get(), "telegram_cancelled_at") == cancelled.hlc);
  }

  Store::TgQueueItem pending;
  pending.kind = "message";
  pending.chat_id = "111";
  pending.payload = "{\"origin\":\"" + press.origin + "\",\"seq\":" +
                    std::to_string(press.seq) + ",\"call_id\":\"" + call_id +
                    "\",\"text\":\"late\"}";
  pending.next_retry_ms = clock.wallMs();
  pending.created_ms = clock.wallMs();
  REQUIRE(store.tgQueuePut(pending) > 0);

  {
    TelegramBridge restarted{loop, store, makeHooks()};
    restarted.configure(config, "telegram-reorder-node", true);
    restarted.onAction(press, R"({"households":["h_ox"],"with_snapshot":false})");
    loop.pumpDue();
    clock.advance(1000);
    loop.pumpDue();

    CHECK(sends == 0);
    CHECK(store.tgQueueCount() == 0);
  }
}

TEST_CASE("telegram: press → sendPhoto (multipart: chat_id/caption/reply_markup/JPEG)") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/true);
  pushFrame(*a.node);
  f.run(1500);


  {
    auto st = json::parse(a.node->statusJson());
    REQUIRE(st);
    CHECK(json::getString(json::get(st.get(), "bridge"), "telegram") == "active");
  }

  const std::string call_id = a.node->pressV2("d_front", "");
  REQUIRE(!call_id.empty());
  REQUIRE(f.runUntil([&] { return a.https.count("sendPhoto") == 1; }, 3000));

  const HttpsReq* r = a.https.last("sendPhoto");
  REQUIRE(r);
  CHECK(r->method == "POST");
  // URL: bot<token>/sendPhoto
  CHECK(r->url.rfind("https://api.telegram.org/botTESTTOKEN/sendPhoto", 0) == 0);
  CHECK(r->headers.find("multipart/form-data; boundary=") != std::string::npos);

  CHECK(r->body.find("name=\"chat_id\"") != std::string::npos);
  CHECK(r->body.find("111") != std::string::npos);
  CHECK(r->body.find("正面玄関に来客です") != std::string::npos);
  CHECK(r->body.find("inline_keyboard") != std::string::npos);
  CHECK(r->body.find("qr|qr_away|" + call_id) != std::string::npos);
  CHECK(r->body.find("ただいま留守にしています") != std::string::npos);
  CHECK(r->body.find("filename=\"doorbell.jpg\"") != std::string::npos);
  CHECK(r->body.find(kJpegSoi) != std::string::npos);

  CHECK(r->body.find("qr|qr_away|") < r->body.find("qr|qr_no|"));


  f.run(60'000);
  CHECK(a.https.count("sendPhoto") == 1);

  a.node->stop();
}

TEST_CASE("telegram: expands and deduplicates chat IDs across households") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);
  a.node->setConfigKey("households.h_ox", "{\"telegram_chat_ids\":[111,222]}");
  a.node->setConfigKey("households.h_b", "{\"telegram_chat_ids\":[222,333]}");
  a.node->setConfigKey("trigger_rules.r1",
                       "{\"enabled\":true,\"when\":{\"type\":\"button\"},"
                       "\"actions\":[{\"type\":\"telegram\",\"households\":[\"h_ox\",\"h_b\"]}]}");
  f.run(1500);

  const std::string call_id = a.node->pressV2("d_front", "");
  REQUIRE(!call_id.empty());

  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 3; }, 5000));
  size_t c111 = 0, c222 = 0, c333 = 0;
  for (const auto& r : a.https.reqs) {
    if (r.url.find("/sendMessage") == std::string::npos) continue;
    auto b = json::parse(r.body);
    REQUIRE(b);
    const std::string chat = json::getString(b.get(), "chat_id");
    if (chat == "111") c111++;
    if (chat == "222") c222++;
    if (chat == "333") c333++;

    CHECK(json::get(b.get(), "reply_markup"));
  }
  CHECK(c111 == 1);
  CHECK(c222 == 1);
  CHECK(c333 == 1);
  f.run(30'000);
  CHECK(a.https.count("sendMessage") == 3);

  a.node->stop();
}

TEST_CASE("telegram: retries a server failure with backoff and stops after success") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);
  f.run(1500);

  a.https.fail_status = 500;
  const std::string call_id = a.node->pressV2("d_front", "");
  REQUIRE(!call_id.empty());
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));

  f.run(20'000);
  CHECK(a.https.count("sendMessage") == 1);

  a.https.fail_status = 0;
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 2; }, 20'000));

  f.run(120'000);
  CHECK(a.https.count("sendMessage") == 2);

  a.node->stop();
}

TEST_CASE("telegram: visitor cancellation suppresses claim and queued retry work") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);
  f.run(1500);

  const std::string claim_call = a.node->pressV2("d_front", "");
  REQUIRE(!claim_call.empty());
  REQUIRE(a.node->cancelCallV2("d_front", claim_call, "visitor"));
  f.run(35'000);
  CHECK(a.https.count("sendMessage") == 0);

  a.https.fail_status = 500;
  const std::string retry_call = a.node->pressV2("d_front", "");
  REQUIRE(!retry_call.empty());
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));
  REQUIRE(a.node->cancelCallV2("d_front", retry_call, "visitor"));
  a.https.fail_status = 0;
  f.run(120'000);
  CHECK(a.https.count("sendMessage") == 1);

  a.node->stop();
}

TEST_CASE("telegram: cancellation does not retract a successfully delivered message") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);
  f.run(1500);

  const std::string call_id = a.node->pressV2("d_front", "");
  REQUIRE(!call_id.empty());
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));
  REQUIRE(a.node->cancelCallV2("d_front", call_id, "visitor"));
  f.run(60'000);

  CHECK(a.https.count("sendMessage") == 1);
  CHECK(a.https.count("deleteMessage") == 0);
  a.node->stop();
}

TEST_CASE("telegram: a new leader does not resend after notified_at is recorded") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(20));
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false, tgCaps(10));
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);
  f.run(2000);

  a.node->press("");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));
  CHECK(b.https.count("sendMessage") == 0);
  f.run(500);

  f.net.killNode("A:1");
  f.run(6000);

  CHECK(b.https.count("sendMessage") == 0);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("telegram: a new leader sends when its predecessor claimed but did not deliver") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(20));
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false, tgCaps(10));
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);
  f.run(2000);

  a.https.drop = true;
  a.node->press("");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));
  f.run(300);

  f.net.killNode("A:1");

  REQUIRE(f.runUntil([&] { return b.https.count("sendMessage") == 1; }, 8000));
  auto bb = json::parse(b.https.last("sendMessage")->body);
  REQUIRE(bb);
  CHECK(json::getString(bb.get(), "chat_id") == "111");
  CHECK(json::getString(bb.get(), "text").find("正面玄関に来客です") != std::string::npos);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("telegram: leader fetches a JPEG snapshot from the originating node") {
  TgFleet f;

  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(20, /*wan=*/false));
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false, tgCaps(10));
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/true);
  pushFrame(*a.node);
  f.run(2000);

  a.node->press("");
  REQUIRE(f.runUntil([&] { return b.https.count("sendPhoto") == 1; }, 5000));
  CHECK(a.https.count("sendPhoto") == 0);
  const HttpsReq* r = b.https.last("sendPhoto");
  REQUIRE(r);
  CHECK(r->body.find("filename=\"doorbell.jpg\"") != std::string::npos);
  CHECK(r->body.find(kJpegSoi) != std::string::npos);
  CHECK(r->body.find("正面玄関に来客です") != std::string::npos);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("telegram: getUpdates handles callback queries, replies, TTS, and button removal") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false, /*poll_updates=*/true);
  f.run(1500);
  CHECK(a.https.count("getUpdates") >= 1);


  const std::string callback_call_id = a.node->pressV2("d_front", "");
  REQUIRE(!callback_call_id.empty());
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));


  a.https.pending_updates =
      std::string("[{\"update_id\":7,\"callback_query\":{\"id\":\"cbq1\",") +
      "\"data\":\"qr|qr_away|" + callback_call_id + "\","
      "\"message\":{\"message_id\":100,\"chat\":{\"id\":111}}}}]";


  REQUIRE(f.runUntil([&] { return a.uiCount("reply") == 1; }, 5000));
  REQUIRE(f.runUntil([&] { return !a.tts.empty(); }, 1000));
  CHECK(a.tts[0] == "ただいま留守にしています");


  REQUIRE(f.runUntil([&] { return a.https.count("answerCallbackQuery") == 1; }, 2000));
  {
    auto bd = json::parse(a.https.last("answerCallbackQuery")->body);
    REQUIRE(bd);
    CHECK(json::getString(bd.get(), "callback_query_id") == "cbq1");
    CHECK(json::getString(bd.get(), "text") == "reply.sent");
  }
  REQUIRE(f.runUntil([&] { return a.https.count("editMessageReplyMarkup") == 1; }, 2000));
  {
    const HttpsReq* rr = a.https.last("editMessageReplyMarkup");
    CHECK(rr->url.rfind("https://api.telegram.org/botTESTTOKEN/editMessageReplyMarkup", 0) == 0);
    CHECK(rr->headers.find("application/json") != std::string::npos);
    auto bd = json::parse(rr->body);
    REQUIRE(bd);
    CHECK(json::getString(bd.get(), "chat_id") == "111");
    CHECK(json::getInt(bd.get(), "message_id") == 100);


    cJSON* markup = json::get(bd.get(), "reply_markup");
    REQUIRE(markup);
    cJSON* kb = json::get(markup, "inline_keyboard");
    REQUIRE(kb);
    CHECK(cJSON_IsArray(kb));
    CHECK(cJSON_GetArraySize(kb) == 0);
  }

  REQUIRE(f.runUntil([&] { return a.https.count("editMessageCaption") == 1; }, 2000));
  CHECK(a.https.last("editMessageCaption")->body.find("✅ 応答済み") != std::string::npos);


  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") >= 2; }, 3000));
  {
    auto bd = json::parse(a.https.last("sendMessage")->body);
    REQUIRE(bd);
    CHECK(json::getString(bd.get(), "chat_id") == "111");
    CHECK(json::getString(bd.get(), "text") == "✅ ただいま留守にしています");
  }


  REQUIRE(f.runUntil([&] {
    const HttpsReq* g = a.https.last("getUpdates");
    return g && g->url.find("offset=8") != std::string::npos;
  }, 2000));

  a.node->stop();
}

TEST_CASE("telegram: sendMessage updates fall back to editMessageText after status 400") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false, /*poll_updates=*/true);
  f.run(1500);


  a.https.respond_by_api["editMessageCaption"] = {
      400,
      "{\"ok\":false,\"error_code\":400,"
      "\"description\":\"Bad Request: there is no caption in the message to edit\"}"};

  const std::string call_id = a.node->pressV2("d_front", "");
  REQUIRE(!call_id.empty());  // with_snapshot=false → sendMessage (msg_id=100)
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));

  a.https.pending_updates =
      "[{\"update_id\":9,\"callback_query\":{\"id\":\"cbq2\","
      "\"data\":\"qr|qr_away|" + call_id + "\","
      "\"message\":{\"message_id\":100,\"chat\":{\"id\":111}}}}]";


  REQUIRE(f.runUntil([&] { return a.https.count("editMessageCaption") == 1; }, 5000));
  REQUIRE(f.runUntil([&] { return a.https.count("editMessageText") == 1; }, 2000));
  {
    auto bd = json::parse(a.https.last("editMessageText")->body);
    REQUIRE(bd);
    CHECK(json::getString(bd.get(), "chat_id") == "111");
    CHECK(json::getInt(bd.get(), "message_id") == 100);
    CHECK(json::getString(bd.get(), "text").find("正面玄関に来客です") != std::string::npos);
    CHECK(json::getString(bd.get(), "text").find("✅ 応答済み") != std::string::npos);
  }

  a.node->stop();
}

TEST_CASE("telegram: SOS leader notifies every chat regardless of quiet hours") {
  TgFleet f;

  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(20));
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false, tgCaps(10, /*wan=*/false));
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);

  a.node->setConfigKey(
      "quiet_hours.default",
      "{\"windows\":[{\"from\":\"00:00\",\"to\":\"24:00\"}],\"suppress\":[\"telegram\",\"chime\"]}");
  f.run(2000);


  b.node->setEmergency(true, "panel");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 5000));
  CHECK(b.https.count("sendMessage") == 0);
  {
    auto bd = json::parse(a.https.last("sendMessage")->body);
    REQUIRE(bd);
    CHECK(json::getString(bd.get(), "chat_id") == "111");
    const std::string text = json::getString(bd.get(), "text");
    CHECK(text.find("🚨 緊急事態です") != std::string::npos);
    CHECK(text.find("kitchen から発報") != std::string::npos);
  }


  a.node->setEmergency(false, "admin");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 2; }, 5000));
  CHECK(json::getString(json::parse(a.https.last("sendMessage")->body).get(), "text") ==
        "✅ 緊急解除");


  f.run(5000);
  CHECK(a.https.count("sendMessage") == 2);
  CHECK(b.https.count("sendMessage") == 0);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("telegram: press notification includes purpose and visitor-language badge") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);
  f.run(1500);


  a.node->press("");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));
  {
    auto bd = json::parse(a.https.last("sendMessage")->body);
    REQUIRE(bd);
    const std::string text = json::getString(bd.get(), "text");
    CHECK(text.rfind("正面玄関に来客です (", 0) == 0);
    CHECK(text.find('\n') == std::string::npos);
  }
  a.node->cancelCall("d_front");
  f.run(200);


  a.node->setVisitorLang("d_front", "en");
  f.run(300);
  a.node->press("", "p_delivery");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 2; }, 3000));
  {
    const std::string text =
        json::getString(json::parse(a.https.last("sendMessage")->body).get(), "text");
    CHECK(text.rfind("📦 宅配便 🌐 EN\n", 0) == 0);
    CHECK(text.find("正面玄関に来客です") != std::string::npos);
  }
  a.node->cancelCall("d_front");
  f.run(200);


  a.node->setVisitorLang("d_front", "ja");
  f.run(300);
  a.node->press("", "p_mail");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 3; }, 3000));
  {
    const std::string text =
        json::getString(json::parse(a.https.last("sendMessage")->body).get(), "text");
    CHECK(text.rfind("✉️ 郵便\n", 0) == 0);
    CHECK(text.find("🌐") == std::string::npos);
  }

  a.node->stop();
}

TEST_CASE("telegram: i18n overrides replace motion and offline text through Node::text") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  a.node->setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");
  a.node->setConfigKey("households.h_ox", "{\"telegram_chat_ids\":[111]}");
  a.node->setConfigKey("integrations.telegram.bot_token_ref", "\"secret:telegram.test\"");
  a.node->setConfigKey("trigger_rules.r_motion",
                       std::string("{\"enabled\":true,\"when\":{\"type\":\"motion\"},") +
                           "\"actions\":[{\"type\":\"telegram\",\"households\":[\"h_ox\"]}]}");
  f.run(1500);


  a.node->loop().callSync([] {});
  a.node->press("");
  CHECK(a.node->text("event.motion", "ja", {{"door", "正面玄関"}, {"time", "09:13"}}) ==
        "正面玄関 で動きを検知 (09:13)");


  a.node->setConfigKey("i18n_overrides.ja",
                       "{\"event.motion\":\"🚶 {door} に動きあり {time}\","
                       "\"event.online\":\"{device} 復帰\"}");
  f.run(500);
  CHECK(a.node->text("event.motion", "ja", {{"door", "正面玄関"}, {"time", "09:13"}}) ==
        "🚶 正面玄関 に動きあり 09:13");
  CHECK(a.node->text("event.online", "ja", {{"device", "front"}}) == "front 復帰");

  a.node->stop();
}
