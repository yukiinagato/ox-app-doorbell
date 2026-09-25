#include "node/media_relay_bounds.h"
#include <iostream>
#include <random>
#include <stdexcept>

#if defined(DB_MEDIA_RELAY_STANDALONE)
static size_t assertions = 0;
#define CHECK(...) do { ++assertions; if (!(__VA_ARGS__)) throw std::runtime_error(std::string(__FILE__) + ":" + std::to_string(__LINE__) + " " #__VA_ARGS__); } while (0)
#else
#include "doctest.h"
#endif

namespace {
void checkMediaRelayBounds() {
  using namespace db::media_relay;
  uint64_t number = 0;
  for (const auto* bad : {"", "00", "01", "-1", "+1", "1.0", "1e2", " 1", "1 ", "9223372036854775808"})
    CHECK(!decimal(bad, 9223372036854775807ULL, &number));
  CHECK(decimal("9223372036854775807", 9223372036854775807ULL, &number));
  CHECK(number == 9223372036854775807ULL);
  CHECK(decimal("0", 0, &number, true));
  CHECK(!decimal("0", 0, &number));
  CHECK(!decimal("1", 0, &number, true));
  CHECK(!decimal("1", 10, nullptr));
  CHECK(hexId(std::string(32, 'a')));
  CHECK(!hexId(std::string(32, 'A')));
  CHECK(!identifier("front\r\n"));
  CHECK(contentType("application/x-www-form-urlencoded;charset=UTF-8", "application/x-www-form-urlencoded"));
  CHECK(contentType(" Application/X-Www-Form-Urlencoded ; charset=utf-8", "application/x-www-form-urlencoded"));
  CHECK(!contentType("application/x-www-form-urlencoded-extra", "application/x-www-form-urlencoded"));
  CHECK(!contentType("application/x-www-form-urlencoded\r\nX-Fake: 1", "application/x-www-form-urlencoded"));
  std::map<std::string, std::string> fields;
  const std::string identity = "door=front&call_id=call-1&stage_revision=0";
  CHECK(query(identity, false, &fields));
  CHECK(fields.at("door") == "front");
  CHECK(query("door=front&call_id=node%3A1&stage_revision=0", false, &fields));
  CHECK(fields.at("call_id") == "node:1");
  for (const char* tail : {"&door=other", "&%64oor=other", "&url=https://evil.test/", "&host=localhost", "&port=80", "&path=/", "&", "&call_id=x"})
    CHECK(!query(identity + tail, false, &fields));
  CHECK(!query("door=%00&call_id=x&stage_revision=0", false, &fields));
  CHECK(!query("door=%&call_id=x&stage_revision=0", false, &fields));
  CHECK(!query(std::string(2049, 'x'), false, &fields));
  CHECK(!query(identity, true, &fields));
  CHECK(query(identity + "&media_generation=" + std::string(32, 'a') + "&frame_sequence=1", true, &fields));

  size_t size = 0;
  CHECK(canonicalBase64("TQ==", &size)); CHECK(size == 1);
  CHECK(canonicalBase64("TWE=", &size)); CHECK(size == 2);
  CHECK(canonicalBase64("TWFu", &size)); CHECK(size == 3);
  for (const auto* bad : {"", "A", "TQ=", "TQ===", "====", "TR==", "TWF=", "TW=F", "TW F", "____", "TQ==\n"})
    CHECK(!canonicalBase64(bad, &size));
  CHECK(!canonicalBase64(std::string(kBase64Bytes + 4, 'A'), &size));
  CHECK(!canonicalBase64(std::string(kBase64Bytes, 'A'), &size));
  auto maximum = std::string(kBase64Bytes - 4, 'A') + "AA==";
  CHECK(canonicalBase64(maximum, &size)); CHECK(size == kFrameBytes);

  Bucket bucket;
  CHECK(bucket.take(1000)); CHECK(bucket.take(1000)); CHECK(!bucket.take(1000));
  CHECK(!bucket.take(900)); CHECK(!bucket.take(1099)); CHECK(bucket.take(1100));
  CHECK(!bucket.take(1100)); CHECK(bucket.take(100000)); CHECK(bucket.take(100000)); CHECK(!bucket.take(100000));

  struct Item { int sequence; explicit Item(int value) : sequence(value) {} };
  LatestQueue<Item> queue;
  using Admission = LatestQueue<Item>::Admission;
  auto first = std::make_shared<Item>(0), pending = std::make_shared<Item>(1);
  std::shared_ptr<Item> replaced;
  CHECK(queue.offer("p", first, &replaced) == Admission::Start);
  CHECK(queue.offer("p", pending, &replaced) == Admission::Pending);
  for (int i = 2; i < 10002; ++i) {
    auto next = std::make_shared<Item>(i);
    CHECK(queue.offer("p", next, &replaced) == Admission::Replaced);
    CHECK(replaced == pending); CHECK(queue.size() == 1);
    pending = next;
  }
  CHECK(!queue.finish("p", replaced));
  CHECK(queue.finish("p", first) == pending);
  CHECK(!queue.finish("p", first)); // A stale completion must not clear the new active frame.
  CHECK(queue.size() == 1);
  for (int i = 0; i < 3; ++i)
    CHECK(queue.offer("other" + std::to_string(i), std::make_shared<Item>(i), &replaced) == Admission::Start);
  CHECK(queue.size() == kQueuePublishers);
  CHECK(queue.offer("overflow", std::make_shared<Item>(999), &replaced) == Admission::Full);
  auto detached = queue.clear(); CHECK(detached.size() == 4); CHECK(queue.size() == 0);
  CHECK(queue.remove("p").empty());

  // Deterministic parser fuzz smoke. This is not proof of complete codec/parser correctness.
  std::mt19937 random(0x1639);
  for (unsigned trial = 0; trial < 20000; ++trial) {
    std::string bytes(random() % 768, '\0');
    for (auto& c : bytes) c = static_cast<char>(random() & 255);
    CHECK(!jpegEnvelope(bytes));
    query(bytes, (trial & 1) != 0, &fields);
    canonicalBase64(bytes, &size);
    decimal(bytes, 9223372036854775807ULL, &number, true);
  }
}
} // namespace

#if defined(DB_MEDIA_RELAY_STANDALONE)
int main() {
  try { checkMediaRelayBounds(); std::cout << "PASS media bounds assertions=" << assertions << "\n"; return 0; }
  catch (const std::exception& error) { std::cerr << error.what() << "\n"; return 1; }
}
#else
TEST_CASE("T16 bounded media identity wire JPEG and latest-only admission") { checkMediaRelayBounds(); }
#endif
