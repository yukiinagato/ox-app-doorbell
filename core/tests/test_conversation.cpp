#include "doctest.h"
#include "call/conversation.h"
using namespace db;

TEST_CASE("conversation: admission is not media and join preserves the owner") {
  Conversation c;
  c.door = "front"; c.call_id = "call1"; c.authority = "station";
  CHECK(c.apply("living", "respond", 0, "").empty());
  CHECK(c.phase() == "waiting");
  CHECK(c.owner.empty());
  CHECK(c.apply("living", "answer", 1, "leg1").empty());
  CHECK(c.phase() == "dialing");
  CHECK_FALSE(c.participants.at("living").established);
  CHECK_FALSE(c.media("living", "obsolete", true));
  REQUIRE(c.media("living", "leg1", true));
  CHECK(c.phase() == "connected");
  CHECK(c.apply("kitchen", "join", c.version, "leg2").empty());
  CHECK(c.owner == "living");
  REQUIRE(c.media("kitchen", "leg2", true));
  auto doc = c.document();
  Conversation restored;
  REQUIRE(Conversation::parse(doc.get(), &restored));
  CHECK(restored.participants.size() == 2);
  CHECK(restored.version == c.version);
}

TEST_CASE("conversation: takeover fences every old leg and conflicting attempt") {
  Conversation c;
  REQUIRE(c.apply("living", "answer", 0, "leg1").empty());
  REQUIRE(c.media("living", "leg1", true));
  const auto observed = c.version;
  REQUIRE(c.apply("kitchen", "takeover", observed, "leg2").empty());
  CHECK(c.owner == "kitchen");
  CHECK(c.participants.size() == 1);
  CHECK_FALSE(c.media("living", "leg1", false));
  CHECK_FALSE(c.media("living", "leg1", true));
  CHECK(c.apply("bedroom", "takeover", observed, "leg3") == "conflict");
  CHECK(c.owner == "kitchen");
  REQUIRE(c.media("kitchen", "leg2", true));
  CHECK(c.apply("kitchen", "hold", c.version, "").empty());
  CHECK(c.phase() == "held");
  CHECK(c.apply("kitchen", "resume", c.version, "unused").empty());
  CHECK(c.participants.at("kitchen").leg == "leg2");
  CHECK(c.phase() == "connected");
}

TEST_CASE("conversation: independent rooms and participant departures do not end the winner") {
  Conversation a, b;
  REQUIRE(a.apply("living", "answer", 0, "frontleg").empty());
  REQUIRE(b.apply("kitchen", "answer", 0, "sideleg").empty());
  REQUIRE(a.media("living", "frontleg", true));
  REQUIRE(b.media("kitchen", "sideleg", true));
  REQUIRE(a.apply("kitchen", "join", a.version, "joinleg").empty());
  REQUIRE(a.media("kitchen", "joinleg", true));
  REQUIRE(a.apply("living", "leave", a.version, "").empty());
  CHECK(a.owner == "kitchen");
  CHECK(a.phase() == "connected");
  CHECK(b.owner == "kitchen");
  CHECK_FALSE(b.media("kitchen", "joinleg", false));
  CHECK(b.phase() == "connected");
  REQUIRE(a.apply("kitchen", "leave", a.version, "").empty());
  CHECK(a.owner.empty());
  CHECK(a.participants.empty());
}

TEST_CASE("conversation: held reconnect has a fresh generation and participant capacity is bounded") {
  Conversation c;
  for (size_t i = 0; i < Conversation::kMaxParticipants; ++i)
    REQUIRE(c.apply("panel" + std::to_string(i), "respond", c.version, "").empty());
  CHECK(c.apply("overflow", "respond", c.version, "") == "capacity");
  CHECK(c.apply("overflow", "takeover", c.version, "newleg").empty());
  CHECK(c.participants.size() == 1);
  c.participants.at("overflow").state = "held";
  CHECK(c.apply("overflow", "resume", c.version, "reconnectleg").empty());
  CHECK(c.participants.at("overflow").leg == "reconnectleg");
  CHECK_FALSE(c.media("overflow", "newleg", true));
  CHECK(c.media("overflow", "reconnectleg", true));
}
