#include <string>

#include "doctest.h"
#include "util/pair_uri.h"

using namespace db;
using namespace db::pair_uri;

TEST_CASE("pair uri: the format is exactly the four documented keys") {
  const std::string uri = build("10.0.1.10:47172", "123456", 1'772'000'000, "京阪ハウス");
  CHECK(uri.rfind("doorbell://pair?", 0) == 0);
  CHECK(uri.find("host=10.0.1.10%3A47172") != std::string::npos);
  CHECK(uri.find("pin=123456") != std::string::npos);
  CHECK(uri.find("exp=1772000000") != std::string::npos);
  // A non-ASCII cluster name is percent-encoded, never raw in the QR payload.
  CHECK(uri.find("cluster=%E4%BA%AC%E9%98%AA") != std::string::npos);
  CHECK(uri.find("京阪") == std::string::npos);

  // The optional fields are left out rather than sent empty.
  const std::string minimal = build("10.0.1.10:47172", "123456", 0, "");
  CHECK(minimal == "doorbell://pair?host=10.0.1.10%3A47172&pin=123456");
  CHECK(minimal.find("exp=") == std::string::npos);
  CHECK(minimal.find("cluster=") == std::string::npos);
}

TEST_CASE("pair uri: encoding round-trips names with spaces and Japanese") {
  struct Case {
    const char* cluster;
  };
  const Case cases[] = {{"京阪ハウス"}, {"Ox House"}, {"Main + Annex"}, {"a&b=c?d"},
                        {"100% Home"},  {"新しい 家"}, {""}};
  for (const auto& item : cases) {
    const std::string uri = build("10.0.1.10:47172", "123456", 1'772'000'000, item.cluster);
    const Parsed parsed = parse(uri, 1'771'000'000);
    CAPTURE(item.cluster);
    CAPTURE(uri);
    REQUIRE(parsed.ok);
    CHECK(parsed.host == "10.0.1.10:47172");
    CHECK(parsed.pin == "123456");
    CHECK(parsed.exp == 1'772'000'000);
    CHECK(parsed.cluster == item.cluster);
  }
  // "+" is a literal plus, not a space: a cluster name is not form data.
  CHECK(percentDecode("Main+Annex") == "Main+Annex");
  CHECK(percentDecode("Main%20Annex") == "Main Annex");
  // A malformed escape is kept rather than swallowing the rest of the name.
  CHECK(percentDecode("100%Z") == "100%Z");
  CHECK(percentDecode("tail%") == "tail%");
}

TEST_CASE("pair uri: parsing rejects exactly what it should") {
  const int64_t now = 1'771'000'000;
  CHECK(parse("", now).err == "bad_scheme");
  CHECK(parse("doorbell://pair", now).err == "bad_scheme");
  CHECK(parse("https://example.invalid/pair?host=a&pin=1", now).err == "bad_scheme");
  CHECK(parse("doorbell-pair:10.0.1.10:47172|id|pk", now).err == "bad_scheme");
  // The scheme's literal part is matched case-insensitively; some readers normalise it.
  CHECK(parse("DOORBELL://PAIR?host=10.0.1.10:47172&pin=123456", now).ok);

  CHECK(parse("doorbell://pair?host=10.0.1.10%3A47172", now).err == "missing_pin");
  CHECK(parse("doorbell://pair?pin=123456", now).err == "missing_host");
  CHECK(parse("doorbell://pair?host=&pin=123456", now).err == "missing_host");
  CHECK(parse("doorbell://pair?host=10.0.1.10%3A47172&pin=", now).err == "missing_pin");

  // Expiry is absolute, so a stale code is refused without knowing when it was made.
  const std::string uri = build("10.0.1.10:47172", "123456", 1'772'000'000, "Ox House");
  CHECK(parse(uri, 1'772'000'001).err == "expired");
  CHECK(parse(uri, 1'772'000'000).ok);
  CHECK(parse(uri, 1'771'999'999).ok);
  // A caller with no trustworthy clock skips the check rather than refusing everything.
  CHECK(parse(uri, 0).ok);
  // No expiry in the code means it does not expire on its own.
  CHECK(parse(build("10.0.1.10:47172", "123456", 0, ""), 9'999'999'999).ok);

  // Unknown keys are ignored, so the format can gain one without breaking shipped parsers.
  const Parsed forward = parse(
      "doorbell://pair?host=10.0.1.10%3A47172&pin=123456&flavour=new&exp=1772000000", now);
  REQUIRE(forward.ok);
  CHECK(forward.host == "10.0.1.10:47172");
  CHECK(forward.pin == "123456");
  // Order does not matter either.
  const Parsed reordered =
      parse("doorbell://pair?cluster=Ox&pin=123456&host=10.0.1.10%3A47172", now);
  REQUIRE(reordered.ok);
  CHECK(reordered.cluster == "Ox");
}
