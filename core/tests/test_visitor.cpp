// 訪客言語 + 用件 (visit_purposes) + 文言/音声連動の統合テスト。
//  - visitor_lang イベントの複製・uiNotify・自動復帰 (ui.visitor_lang_revert_s)
//  - press payload の purpose/visitor_lang と trigger_rules.when.purposes の分岐
//  - auto_reply アクション (門口機の自動応対) と quick_replies.audio の優先再生
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <thread>
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

struct VFleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};

  VFleet() { psk.fill(0x5a); }

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
    std::vector<std::string> ui;
    std::vector<std::pair<std::string, std::string>> tts;  // (text, lang)
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
    // 条件付き検索: t が一致し key==value を持つ通知の数
    size_t uiCountKv(const std::string& t, const char* key, const std::string& value) const {
      size_t n = 0;
      for (const auto& e : ui) {
        auto d = json::parse(e);
        if (!d || json::getString(d.get(), "t") != t) continue;
        if (json::getString(d.get(), key) == value) n++;
      }
      return n;
    }
    // 直近の t 通知 (無ければ nullptr Doc)
    json::Doc lastUi(const std::string& t) const {
      json::Doc out;
      for (const auto& e : ui) {
        auto d = json::parse(e);
        if (d && json::getString(d.get(), "t") == t) out = std::move(d);
      }
      return out;
    }
  };
  std::vector<std::unique_ptr<N>> nodes;

  N& add(const std::string& addr, const std::string& name, const std::string& role,
         const std::string& door, bool seed_cfg) {
    NodeOptions o;
    o.data_dir = ":memory:";
    o.name = name;
    o.role = role;
    o.door = door;
    o.listen_addr = addr;
    o.advertise_addr = addr;
    o.psk = psk;
    o.enable_beacon = false;  // 実 beacon 禁止 (稼働 fleet への迷入防止)
    o.http_port = 0;
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
    n->node->setUiEventCb([raw](const std::string& e) { raw->ui.push_back(e); });
    n->node->setTtsCb([raw](const std::string& t, const std::string& lang) {
      raw->tts.emplace_back(t, lang);
    });
    nodes.push_back(std::move(n));
    return *nodes.back();
  }

  void run(int64_t ms, int64_t step = 10) {
    for (int64_t t = 0; t < ms; t += step) {
      clock.advance(step);
      loop.pumpDue();
    }
  }
};

// status_json の visitor_lang.<door> ("" = 未選択)
std::string statusVisitorLang(Node& n, const std::string& door) {
  auto st = json::parse(n.statusJson());
  REQUIRE(st);
  return json::getString(json::get(st.get(), "visitor_lang"), door.c_str());
}

}  // namespace

TEST_CASE("visitor: 言語切替が複製され、press に載り、返信文言/TTS が追従する") {
  VFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1500);

  // 復帰を短縮 (既定 60 秒はテストに長い)
  a.node->setConfigKey("ui.visitor_lang_revert_s", "5");
  f.run(500);

  // 門口機で英語を選択 → visitor_lang イベントが複製され両ノードで uiNotify
  a.node->setVisitorLang("", "en");  // door 省略 = 自機担当 d_front
  f.run(500);
  CHECK(a.uiCount("visitor_lang") == 1);
  CHECK(b.uiCount("visitor_lang") == 1);
  CHECK(b.uiCount("event", "visitor_lang") == 1);
  CHECK(statusVisitorLang(*a.node, "d_front") == "en");
  CHECK(statusVisitorLang(*b.node, "d_front") == "en");

  // 用件付き按鈴: payload → 来鈴通知に purpose/visitor_lang が載る
  a.node->press("", "p_delivery");
  f.run(500);
  {
    auto ev = b.lastUi("event");
    REQUIRE(ev);
    CHECK(json::getString(ev.get(), "type") == "press");
    CHECK(json::getString(ev.get(), "purpose") == "p_delivery");
    CHECK(json::getString(ev.get(), "visitor_lang") == "en");
  }

  // クイック返信は訪客言語で表示 + TTS (qr_away の en ラベル)
  b.node->sendQuickReply("qr_away", "", "d_front", "web");
  f.run(500);
  {
    auto r = a.lastUi("reply");
    REQUIRE(r);
    CHECK(json::getString(r.get(), "text") == "We are away right now");
    CHECK(json::getString(r.get(), "lang") == "en");
  }
  REQUIRE(a.tts.size() == 1);
  CHECK(a.tts[0].first == "We are away right now");
  CHECK(a.tts[0].second == "en");

  // 無操作 5 秒 (最後の操作 = press で仕切り直し) → ja へ自動復帰 (イベントも複製)
  f.run(6000);
  CHECK(statusVisitorLang(*a.node, "d_front") == "");
  CHECK(statusVisitorLang(*b.node, "d_front") == "");
  CHECK(a.uiCountKv("visitor_lang", "lang", "ja") == 1);
  CHECK(b.uiCountKv("visitor_lang", "lang", "ja") == 1);
  // 復帰イベントは 1 回だけ (発信ノードのみがタイマーを張る)
  CHECK(a.uiCount("event", "visitor_lang") == 2);  // en + ja
  CHECK(b.uiCount("event", "visitor_lang") == 2);

  // 復帰後の press には visitor_lang が載らない
  a.node->press("");
  f.run(500);
  {
    auto ev = b.lastUi("event");
    REQUIRE(ev);
    CHECK(json::getString(ev.get(), "type") == "press");
    CHECK(json::getString(ev.get(), "visitor_lang") == "");
  }

  a.node->stop();
  b.node->stop();
}

TEST_CASE("visitor: when.purposes の分岐 + auto_reply (門口機の自動応対)") {
  VFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1500);

  // 宅配のみ: 自動応対 (電話は鳴らさない)。それ以外: B で chime。
  std::string r_delivery = std::string("{\"enabled\":true,") +
      "\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"],\"purposes\":[\"p_delivery\"]}," +
      "\"actions\":[{\"type\":\"auto_reply\",\"reply_id\":\"qr_wait\"}]}";
  std::string r_chime = std::string("{\"enabled\":true,") +
      "\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]}," +
      "\"actions\":[{\"type\":\"chime\",\"devices\":[\"" + b.node->nodeId() + "\"]}]}";
  a.node->setConfigKey("trigger_rules.r_delivery", r_delivery);
  a.node->setConfigKey("trigger_rules.r_chime", r_chime);
  f.run(500);

  // 用件なしの汎用按鈴 → chime のみ (purposes 指定ルールは発火しない)
  a.node->press("");
  f.run(500);
  CHECK(b.uiCount("chime") == 1);
  CHECK(a.uiCount("reply") == 0);

  // 宅配按鈴 → 門口機 A が自動でクイック返信を表示 + TTS + reply イベント複製
  a.node->press("", "p_delivery");
  f.run(800);
  CHECK(a.uiCount("reply") == 1);
  {
    auto r = a.lastUi("reply");
    REQUIRE(r);
    CHECK(json::getString(r.get(), "text") == "少々お待ちください");
  }
  REQUIRE(a.tts.size() == 1);
  CHECK(a.tts[0].first == "少々お待ちください");
  CHECK(a.uiCount("event", "reply") == 1);
  CHECK(b.uiCount("event", "reply") == 1);
  CHECK(b.uiCount("chime") == 2);  // 汎用ルールは用件付きでも鳴る

  // 室内パネル発の用件付き按鈴でも、実行するのは該当 door の門口機 1 台だけ
  b.node->press("d_front", "p_delivery");
  f.run(800);
  CHECK(a.uiCount("reply") == 2);
  CHECK(a.uiCount("event", "reply") == 2);
  CHECK(b.uiCount("event", "reply") == 2);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("visitor: Node::text は i18n_overrides → ja → 内蔵既定 → key の順で解決する") {
  VFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(a.node->start());
  f.run(300);

  // 内蔵既定 (置換込み)
  CHECK(a.node->text("event.press", "ja", {{"door", "正面玄関"}, {"time", "14:03"}}) ==
        "正面玄関 に来客です (14:03)");
  CHECK(a.node->text("event.press", "en", {{"door", "Front"}, {"time", "14:03"}}) ==
        "Visitor at Front (14:03)");
  CHECK(a.node->text("emergency.notify_off", "zh") == "✅ 警报已解除");
  // 未知言語は ja 既定へ / 未知キーはキー自身
  CHECK(a.node->text("emergency.notify_off", "fr") == "✅ 緊急解除");
  CHECK(a.node->text("no.such.key", "ja") == "no.such.key");

  // 実行時上書き (i18n_overrides — キーはドットを含む平キー)
  a.node->setConfigKey("i18n_overrides.ja", "{\"event.press\":\"{door}にお客様({time})\"}");
  a.node->setConfigKey("i18n_overrides.en", "{}");
  f.run(300);
  CHECK(a.node->text("event.press", "ja", {{"door", "母屋"}, {"time", "9:00"}}) ==
        "母屋にお客様(9:00)");
  // en に訳が無ければ ja 上書きへ回落
  CHECK(a.node->text("event.press", "en", {{"door", "Main"}, {"time", "9:00"}}) ==
        "Mainにお客様(9:00)");

  a.node->stop();
}

TEST_CASE("visitor: quick_replies.audio はキャッシュ済みなら TTS より優先") {
  VFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(a.node->start());
  f.run(500);

  // カスタム音声を登録し qr_away に ja 音声として紐付け (flat key の合成)
  Bytes wav = toBytes("RIFF....WAVEfake");
  std::string hash = a.node->addAsset(wav, "audio/wav", "away.wav");
  REQUIRE(hash.size() == 64);
  a.node->setConfigKey("quick_replies.qr_away.audio", "{\"ja\":\"" + hash + "\"}");
  f.run(500);

  a.node->press("");
  a.node->sendQuickReply("qr_away", "", "d_front", "web");
  f.run(500);
  {
    auto r = a.lastUi("reply");
    REQUIRE(r);
    CHECK(json::getString(r.get(), "audio") == hash);
    CHECK(json::getString(r.get(), "audio_path") == a.node->assetPath(hash));
  }
  CHECK(a.tts.empty());  // 音声がある → TTS しない

  // 訪客言語 en で en 音声が無い場合は ja 音声へ回落 (文言は en)
  a.node->setVisitorLang("d_front", "en");
  f.run(300);
  a.node->sendQuickReply("qr_away", "", "d_front", "web");
  f.run(300);
  {
    auto r = a.lastUi("reply");
    REQUIRE(r);
    CHECK(json::getString(r.get(), "text") == "We are away right now");
    CHECK(json::getString(r.get(), "audio") == hash);
  }
  CHECK(a.tts.empty());

  a.node->stop();
}

// ---------- 実 TCP + HTTP (panel API 経由の訪客言語) ----------

namespace {

int visFreePort(std::mt19937& rng) {
  std::uniform_int_distribution<int> dist(40000, 60000);
  for (int i = 0; i < 50; i++) {
    int port = dist(rng);
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) continue;
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(static_cast<uint16_t>(port));
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int ok = ::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa));
    ::close(fd);
    if (ok == 0) return port;
  }
  return -1;
}

std::string visReq(int port, const std::string& method, const std::string& path,
                   const std::string& body = "", const std::string& ctype = "",
                   const std::string& cookie = "") {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0);
  std::string r = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
  if (!cookie.empty()) r += "Cookie: dbsess=" + cookie + "\r\n";
  if (!body.empty())
    r += "Content-Type: " + (ctype.empty() ? "application/json" : ctype) +
         "\r\nContent-Length: " + std::to_string(body.size()) + "\r\n";
  r += "Connection: close\r\n\r\n" + body;
  REQUIRE(::send(fd, r.data(), r.size(), 0) == static_cast<ssize_t>(r.size()));
  std::string resp;
  char buf[8192];
  timeval tv{5, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  for (;;) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    resp.append(buf, static_cast<size_t>(n));
  }
  ::close(fd);
  return resp;
}

std::string visBody(const std::string& resp) {
  size_t p = resp.find("\r\n\r\n");
  return p == std::string::npos ? "" : resp.substr(p + 4);
}

// 条件が満たされるまで最大 max_ms 待つ (実時計)
template <class F>
bool visWaitFor(F cond, int max_ms = 5000) {
  for (int t = 0; t < max_ms; t += 50) {
    if (cond()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  return cond();
}

}  // namespace

TEST_CASE("visitor: panel API で言語切替 → state/press/events に反映 → 無操作で ja へ復帰") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x1a3cu);
  int mesh_port = visFreePort(rng);
  int http_port = visFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "visitor-http";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x3c);
  o.enable_beacon = false;  // 実 beacon 禁止 (稼働 fleet への迷入防止)
  o.http_port = http_port;
  Node node(o);
  std::mutex ui_mu;
  std::vector<std::string> ui;
  node.setUiEventCb([&](const std::string& e) {
    std::lock_guard<std::mutex> lk(ui_mu);
    ui.push_back(e);
  });
  REQUIRE(node.start());
  node.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");
  // 前半 (state/press/events/返信) は HTTP 往復が数回入るので復帰を長めに。
  // 復帰そのものは後半で 1 秒に縮めて検証する。
  node.setConfigKey("ui.visitor_lang_revert_s", "30");

  // /api/events は管理 API (panel token では読めない) — 初回ログインでセッションを取る
  std::string login = visReq(http_port, "POST", "/api/login", "{\"password\":\"pw\"}");
  REQUIRE(login.rfind("HTTP/1.1 200", 0) == 0);
  size_t cpos = login.find("dbsess=");
  REQUIRE(cpos != std::string::npos);
  const std::string cookie = login.substr(cpos + 7, login.find(';', cpos) - (cpos + 7));

  auto cfg = json::parse(node.configJson());
  REQUIRE(cfg);
  cJSON* toks = json::get(json::get(cfg.get(), "panel"), "tokens");
  REQUIRE(cJSON_GetArraySize(toks) == 1);
  const std::string k = cJSON_GetArrayItem(toks, 0)->valuestring;

  // 認証: token 無しは 403 / lang 欠落は 400
  CHECK(visReq(http_port, "POST", "/api/panel/visitor-lang?lang=en").find("403") !=
        std::string::npos);
  CHECK(visReq(http_port, "POST", "/api/panel/visitor-lang?k=" + k).find("400") !=
        std::string::npos);

  // 英語へ切替 → state の door に visitor_lang=en
  REQUIRE(visReq(http_port, "POST", "/api/panel/visitor-lang?lang=en&k=" + k)
              .rfind("HTTP/1.1 200", 0) == 0);
  REQUIRE(visWaitFor([&] {
    auto st = json::parse(visBody(visReq(http_port, "GET", "/api/panel/state?k=" + k)));
    if (!st) return false;
    cJSON* d0 = cJSON_GetArrayItem(json::get(st.get(), "doors"), 0);
    return json::getString(d0, "visitor_lang") == "en";
  }));

  // 用件付き按鈴 → /api/events の press payload に purpose と visitor_lang
  REQUIRE(visReq(http_port, "POST", "/api/panel/press?door=d_front&purpose=p_delivery&k=" + k)
              .rfind("HTTP/1.1 200", 0) == 0);
  REQUIRE(visWaitFor([&] {
    auto ev =
        json::parse(visBody(visReq(http_port, "GET", "/api/events?limit=20", "", "", cookie)));
    if (!ev) return false;
    cJSON* arr = json::get(ev.get(), "events");
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, arr) {
      if (json::getString(it, "type") != "press") continue;
      auto p = json::parse(json::getString(it, "payload"));
      if (p && json::getString(p.get(), "purpose") == "p_delivery" &&
          json::getString(p.get(), "visitor_lang") == "en")
        return true;
    }
    return false;
  }));

  // クイック返信は訪客言語 (en) のラベルで uiNotify される
  node.sendQuickReply("qr_away", "", "d_front", "web");
  REQUIRE(visWaitFor([&] {
    std::lock_guard<std::mutex> lk(ui_mu);
    for (const auto& e : ui) {
      auto d = json::parse(e);
      if (d && json::getString(d.get(), "t") == "reply" &&
          json::getString(d.get(), "text") == "We are away right now" &&
          json::getString(d.get(), "lang") == "en")
        return true;
    }
    return false;
  }));

  // --- 自動復帰: ui.visitor_lang_revert_s = 1 秒で ja へ戻る ---
  // 一度 ja に落としてから短い復帰時間で en を選び直す (タイマーは切替時に張られる)
  REQUIRE(visReq(http_port, "POST", "/api/panel/visitor-lang?lang=ja&k=" + k)
              .rfind("HTTP/1.1 200", 0) == 0);
  node.setConfigKey("ui.visitor_lang_revert_s", "1");
  {
    std::lock_guard<std::mutex> lk(ui_mu);
    ui.clear();  // ここから先の visitor_lang 通知だけを数える
  }
  REQUIRE(visReq(http_port, "POST", "/api/panel/visitor-lang?lang=en&k=" + k)
              .rfind("HTTP/1.1 200", 0) == 0);

  // 無操作 1 秒 → ja へ自動復帰 (state から visitor_lang が消える)
  REQUIRE(visWaitFor([&] {
    auto st = json::parse(visBody(visReq(http_port, "GET", "/api/panel/state?k=" + k)));
    if (!st) return false;
    cJSON* d0 = cJSON_GetArrayItem(json::get(st.get(), "doors"), 0);
    return json::getString(d0, "visitor_lang").empty();
  }));
  {
    std::lock_guard<std::mutex> lk(ui_mu);
    size_t en = 0, ja = 0;
    for (const auto& e : ui) {
      auto d = json::parse(e);
      if (!d || json::getString(d.get(), "t") != "visitor_lang") continue;
      if (json::getString(d.get(), "lang") == "en") en++;
      if (json::getString(d.get(), "lang") == "ja") ja++;
    }
    CHECK(en == 1);
    CHECK(ja == 1);  // 復帰イベントは 1 回だけ (タイマーの多重発火なし)
  }

  node.stop();
}
