// Telegram ブリッジの統合テスト (モック HttpsFn — 実 Telegram 不要)。
// InMemNet + SimClock 共有 Runloop で複数 Node を決定的にシミュレーションする
// (test_node.cpp と同じ流儀)。
#include <array>
#include <memory>
#include <string>
#include <vector>

#include "doctest.h"
#include "mesh/mesh.h"
#include "node/node.h"
#include "util/clock.h"
#include "util/common.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

// 捕捉した HTTPS リクエスト
struct HttpsReq {
  std::string method, url, headers;
  std::string body;  // 生バイト列 (multipart の JPEG 含む)
};

// モック HttpsFn: リクエストを記録し、API メソッドに応じて即時応答する。
// done は同期呼びでよい (Node 側が Runloop へ marshal する契約)。
struct MockHttps {
  std::vector<HttpsReq> reqs;
  int64_t next_msg_id = 100;
  bool drop = false;     // true: done を呼ばない (応答が永遠に来ない)
  int fail_status = 0;   // >0: 全リクエストへこの status で失敗応答
  std::string pending_updates = "[]";  // getUpdates が一度だけ返す result 配列

  Node::HttpsFn fn() {
    return [this](const std::string& m, const std::string& u, const std::string& h,
                  const Bytes& b, std::function<void(int, std::string)> done) {
      reqs.push_back({m, u, h, std::string(b.begin(), b.end())});
      if (drop) return;
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

// telegram leader になれる caps (wan=false で不適格にできる)
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

// 標準の telegram 設定 (door/household/rule) を 1 ノードから投入する
void seedTgConfig(Node& n, bool with_snapshot, bool poll_updates = false) {
  n.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");
  n.setConfigKey("households.h_ox", "{\"telegram_chat_ids\":[111]}");
  n.setConfigKey("integrations.telegram.bot_token", "\"TESTTOKEN\"");
  n.setConfigKey("integrations.telegram.text_template", "{\"ja\":\"{door}に来客です ({time})\"}");
  if (poll_updates) n.setConfigKey("integrations.telegram.poll_updates", "true");
  n.setConfigKey("trigger_rules.r1",
                 std::string("{\"enabled\":true,") +
                     "\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]}," +
                     "\"actions\":[{\"type\":\"telegram\",\"households\":[\"h_ox\"]," +
                     "\"with_snapshot\":" + (with_snapshot ? "true" : "false") + "}]}");
}

// BGRA 単色フレームを push (FrameBus → stb で JPEG 化される)
void pushFrame(Node& n, uint8_t shade = 0x7f) {
  const int w = 32, h = 24;
  std::vector<uint8_t> px(static_cast<size_t>(w) * h * 4, shade);
  n.pushCameraFrame(px.data(), /*BGRA=*/3, w, h, w * 4, 1000);
}

const std::string kJpegSoi("\xff\xd8\xff", 3);  // JPEG マジック

}  // namespace

TEST_CASE("telegram: press → sendPhoto (multipart: chat_id/caption/reply_markup/JPEG)") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/true);
  pushFrame(*a.node);
  f.run(1500);  // leader 就任 + configure (デバウンス 300ms)

  // status_json に bridge.telegram=active が出ている
  {
    auto st = json::parse(a.node->statusJson());
    REQUIRE(st);
    CHECK(json::getString(json::get(st.get(), "bridge"), "telegram") == "active");
  }

  a.node->press("");
  REQUIRE(f.runUntil([&] { return a.https.count("sendPhoto") == 1; }, 3000));

  const HttpsReq* r = a.https.last("sendPhoto");
  REQUIRE(r);
  CHECK(r->method == "POST");
  // URL: bot<token>/sendPhoto
  CHECK(r->url.rfind("https://api.telegram.org/botTESTTOKEN/sendPhoto", 0) == 0);
  CHECK(r->headers.find("multipart/form-data; boundary=") != std::string::npos);
  // multipart 欄: chat_id / caption ({door}/{time} 展開) / reply_markup / JPEG バイト列
  CHECK(r->body.find("name=\"chat_id\"") != std::string::npos);
  CHECK(r->body.find("111") != std::string::npos);
  CHECK(r->body.find("正面玄関に来客です") != std::string::npos);
  CHECK(r->body.find("inline_keyboard") != std::string::npos);
  CHECK(r->body.find("qr|qr_away|d_front") != std::string::npos);
  CHECK(r->body.find("ただいま留守にしています") != std::string::npos);  // ボタン文言
  CHECK(r->body.find("filename=\"doorbell.jpg\"") != std::string::npos);
  CHECK(r->body.find(kJpegSoi) != std::string::npos);
  // quick_replies が order 順 (qr_away が最初のボタン)
  CHECK(r->body.find("qr|qr_away|") < r->body.find("qr|qr_no|"));

  // 同一イベントの再送は起きない (notified_at 済み + キュー消化済み)
  f.run(60'000);
  CHECK(a.https.count("sendPhoto") == 1);

  a.node->stop();
}

TEST_CASE("telegram: 複数 households の chat_id 展開と去重") {
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

  a.node->press("");
  // with_snapshot 無し → sendMessage。chat は {111,222,333} — 222 は 1 回だけ
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
    // 降級でも inline ボタンは付く
    CHECK(json::get(b.get(), "reply_markup"));
  }
  CHECK(c111 == 1);
  CHECK(c222 == 1);
  CHECK(c333 == 1);
  f.run(30'000);
  CHECK(a.https.count("sendMessage") == 3);  // 去重・再送なし

  a.node->stop();
}

TEST_CASE("telegram: 失敗 (500) → バックオフ再試行 (30s) → 成功で打ち止め") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);
  f.run(1500);

  a.https.fail_status = 500;
  a.node->press("");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));
  // 失敗 → 30s のバックオフ内は再送しない
  f.run(20'000);
  CHECK(a.https.count("sendMessage") == 1);
  // 30s 経過後に再試行 → 今度は成功
  a.https.fail_status = 0;
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 2; }, 20'000));
  // 成功後は再送しない (notified_at + キュー削除)
  f.run(120'000);
  CHECK(a.https.count("sendMessage") == 2);

  a.node->stop();
}

TEST_CASE("telegram: leader 死 (notified_at 記録後) → 新 leader は再送しない") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(20));
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false, tgCaps(10));
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);
  f.run(2000);  // 合流 + 設定複製 + A が telegram leader

  a.node->press("");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));
  CHECK(b.https.count("sendMessage") == 0);  // 非 leader は送らない
  f.run(500);  // 回執 (notified_at) の複製を待つ

  f.net.killNode("A:1");
  f.run(6000);  // B が leader 就任 → 未通知 press の拾い直し (rescan)
  // notified_at 済みなので B は送らない
  CHECK(b.https.count("sendMessage") == 0);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("telegram: leader 死 (claim のみ・送信未達) → 新 leader が送る (宁重勿漏)") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(20));
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false, tgCaps(10));
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false);
  f.run(2000);

  a.https.drop = true;  // A は送信を発射するが応答が永遠に来ない (notified_at 未記録)
  a.node->press("");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));
  f.run(300);  // claim の複製を待つ

  f.net.killNode("A:1");
  // B が leader 就任 → rescan → claim 奪取 (新しい hlc) → 300ms 再確認 → 送信
  REQUIRE(f.runUntil([&] { return b.https.count("sendMessage") == 1; }, 8000));
  auto bb = json::parse(b.https.last("sendMessage")->body);
  REQUIRE(bb);
  CHECK(json::getString(bb.get(), "chat_id") == "111");
  CHECK(json::getString(bb.get(), "text").find("正面玄関に来客です") != std::string::npos);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("telegram: leader ≠ 押鈴ノード — fetchSnapshot で他ノードの JPEG が載る") {
  TgFleet f;
  // A: 門口機 (カメラあり) だが wan 無し → telegram 不適格。B: indoor_panel が leader。
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(20, /*wan=*/false));
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false, tgCaps(10));
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/true);
  pushFrame(*a.node);
  f.run(2000);

  a.node->press("");  // 押鈴は A、送信は B (leader) — 快照は SNAP_REQ/RESP で A から取る
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

TEST_CASE("telegram: getUpdates 長輪詢 — callback_query → quickReply/TTS + ボタン撤去") {
  TgFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true, tgCaps(10));
  REQUIRE(a.node->start());
  seedTgConfig(*a.node, /*with_snapshot=*/false, /*poll_updates=*/true);
  f.run(1500);
  CHECK(a.https.count("getUpdates") >= 1);  // 輪詢が回っている

  // press → sendMessage (msg_id=100 が notify に記録される)
  a.node->press("");
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") == 1; }, 3000));

  // 住人が inline ボタン「ただいま留守にしています」を押した
  a.https.pending_updates =
      "[{\"update_id\":7,\"callback_query\":{\"id\":\"cbq1\","
      "\"data\":\"qr|qr_away|d_front\","
      "\"message\":{\"message_id\":100,\"chat\":{\"id\":111}}}}]";

  // 門口機 (自分) に reply 表示 + TTS が届く
  REQUIRE(f.runUntil([&] { return a.uiCount("reply") == 1; }, 5000));
  REQUIRE(f.runUntil([&] { return !a.tts.empty(); }, 1000));
  CHECK(a.tts[0] == "ただいま留守にしています");

  // answerCallbackQuery (送信済みトースト) + editMessageReplyMarkup (ボタン撤去)
  REQUIRE(f.runUntil([&] { return a.https.count("answerCallbackQuery") == 1; }, 2000));
  {
    auto bd = json::parse(a.https.last("answerCallbackQuery")->body);
    REQUIRE(bd);
    CHECK(json::getString(bd.get(), "callback_query_id") == "cbq1");
    CHECK(json::getString(bd.get(), "text") == "送信済み");
  }
  REQUIRE(f.runUntil([&] { return a.https.count("editMessageReplyMarkup") == 1; }, 2000));
  {
    auto bd = json::parse(a.https.last("editMessageReplyMarkup")->body);
    REQUIRE(bd);
    CHECK(json::getString(bd.get(), "chat_id") == "111");
    CHECK(json::getInt(bd.get(), "message_id") == 100);
  }
  // caption 末尾に「✅ 応答済み」追記 (失敗容認だがリクエストは飛ぶ)
  REQUIRE(f.runUntil([&] { return a.https.count("editMessageCaption") == 1; }, 2000));
  CHECK(a.https.last("editMessageCaption")->body.find("✅ 応答済み") != std::string::npos);

  // reply イベントの「✅ {text}」通知 (通知範囲 = press と同じ chat)
  REQUIRE(f.runUntil([&] { return a.https.count("sendMessage") >= 2; }, 3000));
  {
    auto bd = json::parse(a.https.last("sendMessage")->body);
    REQUIRE(bd);
    CHECK(json::getString(bd.get(), "chat_id") == "111");
    CHECK(json::getString(bd.get(), "text") == "✅ ただいま留守にしています");
  }

  // offset 管理: 処理済み update は次回以降 offset=8 で要求される (再配送防止)
  REQUIRE(f.runUntil([&] {
    const HttpsReq* g = a.https.last("getUpdates");
    return g && g->url.find("offset=8") != std::string::npos;
  }, 2000));

  a.node->stop();
}
