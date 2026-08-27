// Store (SQLite 永続化層) のテスト。一時ディレクトリ (mkdtemp) のファイル DB を使う。
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

#include "doctest.h"
#include "store/store.h"
#include "util/hlc.h"

using namespace db;

namespace {

// 一時ディレクトリを作る (プロセス終了で /tmp に残っても害はない)
std::string makeTempDir() {
  char buf[] = "/tmp/doorbell_store_XXXXXX";
  char* d = mkdtemp(buf);
  REQUIRE(d != nullptr);
  return std::string(d);
}

// テスト用イベント (hlc は物理 ms と origin 先頭8文字から合成)
EventRecord mkEv(const std::string& origin, uint64_t seq, int64_t ms, int counter = 0) {
  EventRecord e;
  e.origin = origin;
  e.seq = seq;
  e.type = "press";
  e.door = "d_front";
  e.device = origin;
  e.hlc = HlcClock::format(ms, counter, origin.substr(0, 8));
  e.wall_ms = ms;
  e.payload_json = "{}";
  return e;
}

}  // namespace

TEST_CASE("store: meta 往復") {
  std::string path = makeTempDir() + "/db.sqlite";
  Store s;
  REQUIRE(s.open(path));
  CHECK_FALSE(s.metaGet("missing").has_value());
  s.metaSet("node_id", "abc123");
  CHECK(s.metaGet("node_id") == std::string("abc123"));
  s.metaSet("node_id", "def456");  // 上書き
  CHECK(s.metaGet("node_id") == std::string("def456"));
  // schema_version が migrate で書かれている
  CHECK(s.metaGet("schema_version").has_value());
}

TEST_CASE("store: config 全量往復 (tombstone 含む)") {
  std::string path = makeTempDir() + "/db.sqlite";
  Store s;
  REQUIRE(s.open(path));

  LwwEntry a;
  a.key = "doors.d_front.label";
  a.value_json = "\"玄関\"";
  a.hlc = HlcClock::format(1000, 0, "aaaaaaaa");
  a.author = "aaaaaaaa";
  a.seq = 1;
  LwwEntry b;
  b.key = "doors.d_back.label";
  b.deleted = true;  // tombstone (value 空)
  b.hlc = HlcClock::format(2000, 0, "bbbbbbbb");
  b.author = "bbbbbbbb";
  b.seq = 7;
  s.configPut(a);
  s.configPut(b);

  auto all = s.configLoadAll();
  REQUIRE(all.size() == 2);  // key 昇順: d_back, d_front
  CHECK(all[0].key == "doors.d_back.label");
  CHECK(all[0].deleted);
  CHECK(all[0].value_json == "");
  CHECK(all[0].author == "bbbbbbbb");
  CHECK(all[0].seq == 7);
  CHECK(all[1].key == "doors.d_front.label");
  CHECK_FALSE(all[1].deleted);
  CHECK(all[1].value_json == "\"玄関\"");
  CHECK(all[1].hlc == a.hlc);

  // upsert (同一 key の勝者差し替え)
  a.value_json = "\"表玄関\"";
  a.seq = 2;
  s.configPut(a);
  all = s.configLoadAll();
  REQUIRE(all.size() == 2);
  CHECK(all[1].value_json == "\"表玄関\"");
  CHECK(all[1].seq == 2);

  // tombstone GC 後の物理削除
  s.configDelete(b.key);
  CHECK(s.configLoadAll().size() == 1);
}

TEST_CASE("store: reopen 永続性") {
  std::string path = makeTempDir() + "/db.sqlite";
  {
    Store s;
    REQUIRE(s.open(path));
    s.metaSet("k", "v");
    CHECK(s.eventPut(mkEv("aaaaaaaa", 1, 1000)));
  }
  Store s2;
  REQUIRE(s2.open(path));
  CHECK(s2.metaGet("k") == std::string("v"));
  CHECK(s2.eventExists("aaaaaaaa", 1));
  auto heads = s2.eventHeads();
  CHECK(heads["aaaaaaaa"] == 1);
}

TEST_CASE("store: 破損ファイルは corrupt リネーム後に再作成") {
  std::string dir = makeTempDir();
  std::string path = dir + "/db.sqlite";
  {
    std::ofstream f(path);
    f << "これは SQLite ではないゴミデータ................";
  }
  Store s;
  REQUIRE(s.open(path));  // 破損 → バックアップして再作成
  s.metaSet("k", "v");
  CHECK(s.metaGet("k") == std::string("v"));
  // "<path>.corrupt-<epoch秒>" が存在する
  std::string cmd = "ls " + dir + " | grep -c 'db.sqlite.corrupt-'";
  FILE* p = popen(cmd.c_str(), "r");
  REQUIRE(p != nullptr);
  char out[16] = {0};
  REQUIRE(fgets(out, sizeof(out), p) != nullptr);
  pclose(p);
  CHECK(std::atoi(out) == 1);
}

TEST_CASE("store: eventPut 重複は false") {
  Store s;
  REQUIRE(s.open(makeTempDir() + "/db.sqlite"));
  EventRecord e = mkEv("aaaaaaaa", 1, 1000);
  CHECK(s.eventPut(e));
  CHECK_FALSE(s.eventPut(e));  // 同一 (origin,seq)
  e.type = "motion";           // 内容が違っても ID が同じなら無視
  CHECK_FALSE(s.eventPut(e));
  auto got = s.eventGet("aaaaaaaa", 1);
  REQUIRE(got.has_value());
  CHECK(got->type == "press");  // 先勝ち
  CHECK_FALSE(s.eventGet("aaaaaaaa", 2).has_value());
  CHECK(s.eventExists("aaaaaaaa", 1));
  CHECK_FALSE(s.eventExists("bbbbbbbb", 1));
}

TEST_CASE("store: eventHeads / eventsSince (hlc 順・limit)") {
  Store s;
  REQUIRE(s.open(makeTempDir() + "/db.sqlite"));
  // hlc が交互に並ぶよう物理 ms をずらして 2 origin 分投入
  CHECK(s.eventPut(mkEv("aaaaaaaa", 1, 1000)));
  CHECK(s.eventPut(mkEv("bbbbbbbb", 1, 1500)));
  CHECK(s.eventPut(mkEv("aaaaaaaa", 2, 2000)));
  CHECK(s.eventPut(mkEv("bbbbbbbb", 2, 2500)));
  CHECK(s.eventPut(mkEv("aaaaaaaa", 3, 3000)));

  auto heads = s.eventHeads();
  REQUIRE(heads.size() == 2);
  CHECK(heads["aaaaaaaa"] == 3);
  CHECK(heads["bbbbbbbb"] == 2);

  // 空 heads → 全件 hlc 昇順
  auto all = s.eventsSince({}, 100);
  REQUIRE(all.size() == 5);
  for (size_t i = 1; i < all.size(); i++) CHECK(all[i - 1].hlc < all[i].hlc);
  CHECK(all[0].wall_ms == 1000);
  CHECK(all[4].wall_ms == 3000);

  // 相手が知っている分は飛ばす
  auto delta = s.eventsSince({{"aaaaaaaa", 2}, {"bbbbbbbb", 1}}, 100);
  REQUIRE(delta.size() == 2);
  CHECK(delta[0].origin == "bbbbbbbb");
  CHECK(delta[0].seq == 2);
  CHECK(delta[1].origin == "aaaaaaaa");
  CHECK(delta[1].seq == 3);

  // limit は hlc 昇順の先頭から効く
  auto lim = s.eventsSince({}, 2);
  REQUIRE(lim.size() == 2);
  CHECK(lim[0].wall_ms == 1000);
  CHECK(lim[1].wall_ms == 1500);
}

TEST_CASE("store: recentEvents は新しい順") {
  Store s;
  REQUIRE(s.open(makeTempDir() + "/db.sqlite"));
  CHECK(s.eventPut(mkEv("aaaaaaaa", 1, 1000)));
  CHECK(s.eventPut(mkEv("aaaaaaaa", 2, 3000)));
  CHECK(s.eventPut(mkEv("bbbbbbbb", 1, 2000)));
  auto recent = s.recentEvents(2);
  REQUIRE(recent.size() == 2);
  CHECK(recent[0].wall_ms == 3000);
  CHECK(recent[1].wall_ms == 2000);
}

TEST_CASE("store: pruneEvents (件数上限と cutoff)") {
  Store s;
  REQUIRE(s.open(makeTempDir() + "/db.sqlite"));
  for (uint64_t i = 1; i <= 10; i++) {
    CHECK(s.eventPut(mkEv("aaaaaaaa", i, static_cast<int64_t>(1000 * i))));
  }

  // cutoff: 物理部 < 3000ms を削除 (1000, 2000 の 2 件)
  CHECK(s.pruneEvents(100, 3000) == 2);
  auto all = s.eventsSince({}, 100);
  REQUIRE(all.size() == 8);
  CHECK(all[0].wall_ms == 3000);

  // 件数上限: 8 件 → 5 件 (hlc 昇順で古い方から 3 件削除)
  CHECK(s.pruneEvents(5, 0) == 3);
  all = s.eventsSince({}, 100);
  REQUIRE(all.size() == 5);
  CHECK(all[0].wall_ms == 6000);
  CHECK(all[4].wall_ms == 10000);

  // 何も該当しなければ 0
  CHECK(s.pruneEvents(100, 0) == 0);
}
