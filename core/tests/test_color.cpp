#include <cmath>
#include <algorithm>
#include <cstdio>
#include <string>

#include "doctest.h"
#include "util/color.h"
#include "util/common.h"

using namespace db;
using namespace db::color;

namespace {

Rgb hex(const std::string& text) {
  Rgb out;
  REQUIRE(parseHex(text, &out));
  return out;
}

const Rgb kWhite{255, 255, 255};
const Rgb kBlack{0, 0, 0};

}  // namespace

TEST_CASE("color: hex parsing accepts only #RRGGBB") {
  Rgb value;
  REQUIRE(parseHex("#9BD748", &value));
  CHECK(value.r == 0x9B);
  CHECK(value.g == 0xD7);
  CHECK(value.b == 0x48);
  CHECK(parseHex("#9bd748", &value));
  CHECK(formatHex(value) == "#9BD748");
  CHECK_FALSE(parseHex("9BD748", &value));
  CHECK_FALSE(parseHex("#9BD74", &value));
  CHECK_FALSE(parseHex("#9BD7480", &value));
  CHECK_FALSE(parseHex("#9BD74G", &value));
  CHECK_FALSE(parseHex("", &value));
  CHECK_FALSE(parseHex("rgb(1,2,3)", &value));
}

TEST_CASE("color: relative luminance and contrast follow WCAG 2.x") {
  // Fixed vectors from the WCAG definition.
  CHECK(relativeLuminance(kWhite) == doctest::Approx(1.0).epsilon(0.0001));
  CHECK(relativeLuminance(kBlack) == doctest::Approx(0.0).epsilon(0.0001));
  CHECK(relativeLuminance(hex("#808080")) == doctest::Approx(0.2159).epsilon(0.001));
  CHECK(relativeLuminance(hex("#FF0000")) == doctest::Approx(0.2126).epsilon(0.0001));
  CHECK(relativeLuminance(hex("#00FF00")) == doctest::Approx(0.7152).epsilon(0.0001));
  CHECK(relativeLuminance(hex("#0000FF")) == doctest::Approx(0.0722).epsilon(0.0001));
  CHECK(relativeLuminance(hex("#9BD748")) == doctest::Approx(0.5604).epsilon(0.001));

  CHECK(contrastRatio(kWhite, kBlack) == doctest::Approx(21.0).epsilon(0.0001));
  CHECK(contrastRatio(kBlack, kWhite) == doctest::Approx(21.0).epsilon(0.0001));
  CHECK(contrastRatio(kWhite, kWhite) == doctest::Approx(1.0).epsilon(0.0001));
  // The canonical 4.54:1 pair from the WCAG examples.
  CHECK(contrastRatio(hex("#767676"), kWhite) == doctest::Approx(4.54).epsilon(0.01));
}

TEST_CASE("color: HSL conversion round-trips and reports the expected hue") {
  const Hsl green = toHsl(hex("#9BD748"));
  CHECK(green.h == doctest::Approx(85.17).epsilon(0.01));
  CHECK(green.s == doctest::Approx(0.6413).epsilon(0.001));
  CHECK(green.l == doctest::Approx(0.5627).epsilon(0.001));
  CHECK(toHsl(hex("#FF0000")).h == doctest::Approx(0.0).epsilon(0.001));
  CHECK(toHsl(hex("#00FF00")).h == doctest::Approx(120.0).epsilon(0.001));
  CHECK(toHsl(hex("#0000FF")).h == doctest::Approx(240.0).epsilon(0.001));
  // Grey has no hue; saturation is reported as zero rather than an arbitrary angle.
  CHECK(toHsl(hex("#808080")).s == doctest::Approx(0.0).epsilon(0.0001));

  for (const char* sample : {"#9BD748", "#101418", "#FF8800", "#123456", "#FFFFFF", "#000000"}) {
    const Rgb original = hex(sample);
    const Rgb round_tripped = fromHsl(toHsl(original));
    CAPTURE(sample);
    CHECK(static_cast<int>(round_tripped.r) == static_cast<int>(original.r));
    CHECK(static_cast<int>(round_tripped.g) == static_cast<int>(original.g));
    CHECK(static_cast<int>(round_tripped.b) == static_cast<int>(original.b));
  }
}

TEST_CASE("color: automatic ink picks whichever token has the higher contrast") {
  // The rule is not "is the background light?" but "which ink reads better on it?". The two
  // ratios cross at Y = 0.1791, well below mid luminance.
  CHECK(std::string(autoInk(hex("#9BD748"))) == "dark");   // Y 0.560
  CHECK(std::string(autoInk(kWhite)) == "dark");
  CHECK(std::string(autoInk(hex("#101418"))) == "light");  // the default dark theme
  CHECK(std::string(autoInk(kBlack)) == "light");
  // The reported regression: a light grey photograph at Y 0.494. Splitting at mid luminance
  // called for light ink at 1.93:1 when dark ink scores 9.58:1 on the same background.
  CHECK(std::string(autoInk(hex("#BBBBB4"))) == "dark");
  CHECK(contrastRatio(kBlack, hex("#BBBBB4")) > contrastRatio(kWhite, hex("#BBBBB4")));
  // A true mid-dark still wants light ink, so the rule has not simply moved everything to dark.
  CHECK(std::string(autoInk(hex("#404040"))) == "light");  // Y 0.051
  CHECK(contrastRatio(kWhite, hex("#404040")) > contrastRatio(kBlack, hex("#404040")));
  // Mid grey is past the crossover and is better served by dark ink, which the old rule missed.
  CHECK(std::string(autoInk(hex("#808080"))) == "dark");   // Y 0.216
  // Either side of the crossover, one step of grey apart.
  CHECK(std::string(autoInk(hex("#767676"))) == "dark");   // Y 0.18116, black 4.62 / white 4.54
  CHECK(std::string(autoInk(hex("#757575"))) == "light");  // Y 0.17789, black 4.56 / white 4.61
  // A light photograph and a dark photograph produce opposite inks.
  CHECK(std::string(autoInk(hex("#E8E2D5"))) == "dark");
  CHECK(std::string(autoInk(hex("#2A2118"))) == "light");

  // Whatever the answer, it is the better of the two; that is the whole contract.
  for (const char* sample : {"#9BD748", "#101418", "#BBBBB4", "#404040", "#808080", "#767676",
                             "#757575", "#E8E2D5", "#2A2118", "#FFFFFF", "#000000"}) {
    const Rgb background = hex(sample);
    CAPTURE(sample);
    const bool dark = std::string(autoInk(background)) == "dark";
    const double chosen = contrastRatio(dark ? kBlack : kWhite, background);
    const double other = contrastRatio(dark ? kWhite : kBlack, background);
    CHECK(chosen >= other);
  }
}

TEST_CASE("color: the computed call button satisfies both contrast constraints") {
  // Backgrounds where a solution exists: the button must clear both thresholds and keep the
  // rotated hue. A light background must darken, which is the stated preference.
  const char* solvable[] = {"#9BD748", "#FFFFFF", "#E8E2D5", "#101418", "#000000", "#2A2118"};
  for (const char* sample : solvable) {
    const Rgb background = hex(sample);
    const Rgb button = autoAccent(background, kWhite);
    CAPTURE(sample);
    CAPTURE(formatHex(button));
    // (a) the button separates from the background as a large UI element
    CHECK(contrastRatio(button, background) >= 3.0);
    // (b) white text stays readable on the button
    CHECK(contrastRatio(kWhite, button) >= 4.5);
    // The ink the shell is told to draw clears the same bar. Just above the ink crossover both
    // tokens qualify and accentInk reports the better one, so the property is what is asserted
    // here rather than a fixed answer.
    const std::string ink = accentInk(button);
    CHECK(contrastRatio(ink == "light" ? kWhite : kBlack, button) >= 4.5);
    // The hue is the background's, rotated half a turn. Grey has no hue to rotate.
    const Hsl base = toHsl(background);
    if (base.s > 0.01) {
      const double expected = std::fmod(base.h + 180.0, 360.0);
      double delta = std::fabs(toHsl(button).h - expected);
      if (delta > 180.0) delta = 360.0 - delta;
      CHECK(delta < 2.0);
    }
    if (relativeLuminance(background) >= 0.5) CHECK(toHsl(button).l <= base.l);
  }

  // A mid-luminance background admits no solution with white text: separating from it needs a
  // light button and white text needs a dark one. The result is the best compromise on the
  // rotated hue, and the ink to draw on it comes back from accentInk rather than being assumed.
  for (const char* sample : {"#808080", "#123456"}) {
    const Rgb background = hex(sample);
    const Rgb button = autoAccent(background, kWhite);
    CAPTURE(sample);
    CAPTURE(formatHex(button));
    const std::string ink = accentInk(button);
    const Rgb ink_color = ink == "light" ? kWhite : kBlack;
    CHECK(contrastRatio(ink_color, button) >= 4.5);
    CHECK(contrastRatio(button, background) > 1.5);
    const Hsl base = toHsl(background);
    if (base.s > 0.01) {
      const double expected = std::fmod(base.h + 180.0, 360.0);
      double delta = std::fabs(toHsl(button).h - expected);
      if (delta > 180.0) delta = 360.0 - delta;
      CHECK(delta < 2.0);
    }
  }
}

TEST_CASE("color: the computed call button is stable and reproducible") {
  // A fixed vector so a change in the search cannot silently move every fleet's call button.
  const Rgb background = hex("#9BD748");
  const Rgb button = autoAccent(background, kWhite);
  CHECK(formatHex(button) == "#8144D6");
  CHECK(autoAccent(background, kWhite).r == button.r);
  CHECK(relativeLuminance(button) < relativeLuminance(background));

  // A washed-out background still yields a recognisable colour rather than another grey.
  const Rgb pale = autoAccent(hex("#F2F0EE"), kWhite);
  CHECK(toHsl(pale).s >= 0.34);
  CHECK(contrastRatio(kWhite, pale) >= 4.5);

  // Mid-grey button text cannot satisfy both constraints on any hue. The fallback still keeps
  // the button readable with the ink accentInk reports, instead of returning an unreadable one.
  const Rgb impossible = autoAccent(hex("#9BD748"), hex("#808080"));
  const std::string ink = accentInk(impossible);
  CHECK(contrastRatio(ink == "light" ? kWhite : kBlack, impossible) >= 4.5);
}

namespace {

uint32_t crc32Of(const uint8_t* data, size_t len, uint32_t seed = 0) {
  static uint32_t table[256];
  static bool ready = false;
  if (!ready) {
    for (uint32_t i = 0; i < 256; i++) {
      uint32_t c = i;
      for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      table[i] = c;
    }
    ready = true;
  }
  uint32_t crc = seed ^ 0xFFFFFFFFu;
  for (size_t i = 0; i < len; i++) crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
  return crc ^ 0xFFFFFFFFu;
}

void appendBigEndian(Bytes& out, uint32_t value) {
  out.push_back(static_cast<uint8_t>(value >> 24));
  out.push_back(static_cast<uint8_t>(value >> 16));
  out.push_back(static_cast<uint8_t>(value >> 8));
  out.push_back(static_cast<uint8_t>(value));
}

void appendChunk(Bytes& out, const char tag[4], const Bytes& payload) {
  appendBigEndian(out, static_cast<uint32_t>(payload.size()));
  Bytes body(tag, tag + 4);
  body.insert(body.end(), payload.begin(), payload.end());
  out.insert(out.end(), body.begin(), body.end());
  appendBigEndian(out, crc32Of(body.data(), body.size()));
}

// A flat 8-bit greyscale PNG of the requested size, deflated with stored blocks so the test
// needs no compressor. Greyscale keeps a multi-megapixel fixture around one byte per pixel;
// stb expands it to RGB on load, which is what the sampler asks for.
Bytes makeGreyPng(int width, int height, uint8_t value) {
  Bytes raw;
  raw.reserve(static_cast<size_t>(height) * (static_cast<size_t>(width) + 1));
  for (int y = 0; y < height; y++) {
    raw.push_back(0);  // filter type: none
    raw.insert(raw.end(), static_cast<size_t>(width), value);
  }
  uint32_t a = 1, b = 0;
  for (uint8_t byte : raw) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  Bytes zlib{0x78, 0x01};
  size_t offset = 0;
  while (offset < raw.size()) {
    const size_t block = std::min<size_t>(raw.size() - offset, 65535);
    const bool last = offset + block >= raw.size();
    zlib.push_back(last ? 1 : 0);
    zlib.push_back(static_cast<uint8_t>(block & 0xFF));
    zlib.push_back(static_cast<uint8_t>(block >> 8));
    zlib.push_back(static_cast<uint8_t>((~block) & 0xFF));
    zlib.push_back(static_cast<uint8_t>((~block) >> 8));
    zlib.insert(zlib.end(), raw.begin() + static_cast<std::ptrdiff_t>(offset),
                raw.begin() + static_cast<std::ptrdiff_t>(offset + block));
    offset += block;
  }
  appendBigEndian(zlib, (b << 16) | a);

  Bytes header;
  appendBigEndian(header, static_cast<uint32_t>(width));
  appendBigEndian(header, static_cast<uint32_t>(height));
  header.push_back(8);  // bit depth
  header.push_back(0);  // colour type: greyscale
  header.push_back(0);
  header.push_back(0);
  header.push_back(0);

  Bytes png{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
  appendChunk(png, "IHDR", header);
  appendChunk(png, "IDAT", zlib);
  appendChunk(png, "IEND", {});
  return png;
}

std::string writeTempFixture(const std::string& name, const Bytes& bytes) {
  const std::string path = "/tmp/" + name;
  REQUIRE(writeFileBytes(path, bytes));
  return path;
}

}  // namespace

TEST_CASE("color: image averaging samples a decodable file and reports why it could not") {
  Rgb average;
  // Absent input is "missing", not a decode failure: the caller distinguishes the two.
  CHECK(averageImageColor("", &average) == SampleStatus::kMissing);
  CHECK(averageImageColor("/nonexistent/theme.jpg", &average) == SampleStatus::kMissing);
  CHECK(std::string(sampleStatusName(SampleStatus::kOk)) == "ok");
  CHECK(std::string(sampleStatusName(SampleStatus::kMissing)) == "missing");
  CHECK(std::string(sampleStatusName(SampleStatus::kTooLarge)) == "too_large");
  CHECK(std::string(sampleStatusName(SampleStatus::kDecodeFailed)) == "decode_failed");

  // A 2x2 PNG of one flat colour must average to exactly that colour. The bytes below are a
  // minimal PNG encoding #9BD748 so the test needs no fixture file on disk.
  const unsigned char png[] = {
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
      0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02, 0x00, 0x00,
      0x00, 0xFD, 0xD4, 0x9A, 0x73, 0x00, 0x00, 0x00, 0x10, 0x49, 0x44, 0x41, 0x54, 0x78,
      0xDA, 0x63, 0x98, 0x7D, 0xDD, 0x03, 0x88, 0x18, 0x20, 0x14, 0x00, 0x31, 0xB2, 0x06,
      0xE9, 0x0E, 0x76, 0xB2, 0x64, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82};
  const std::string path = "/tmp/doorbell_theme_average_test.png";
  Bytes bytes(png, png + sizeof(png));
  REQUIRE(writeFileBytes(path, bytes));
  REQUIRE(averageImageColor(path, &average) == SampleStatus::kOk);
  CHECK(formatHex(average) == "#9BD748");
  std::remove(path.c_str());

  // A file that is not an image at all is a decode failure, distinct from a missing file.
  const std::string junk_path = "/tmp/doorbell_theme_average_junk.png";
  Bytes junk(64, 0x41);
  REQUIRE(writeFileBytes(junk_path, junk));
  CHECK(averageImageColor(junk_path, &average) == SampleStatus::kDecodeFailed);
  std::remove(junk_path.c_str());

  // A truncated PNG carries a valid header but cannot be decoded.
  Bytes truncated(png, png + 40);
  const std::string truncated_path =
      writeTempFixture("doorbell_theme_average_truncated.png", truncated);
  CHECK(averageImageColor(truncated_path, &average) == SampleStatus::kDecodeFailed);
  std::remove(truncated_path.c_str());
}

TEST_CASE("color: an ordinary phone photograph is sampled, not refused for its size") {
  // The regression: a real 2200x2609 background (5.7 MP) sat above the old 4 MP budget, so it
  // was never sampled and the caller reported the flat theme colour instead.
  Rgb average;
  const Bytes photo = makeGreyPng(2200, 2609, 0xC8);
  const std::string path = writeTempFixture("doorbell_theme_large.png", photo);
  REQUIRE(averageImageColor(path, &average) == SampleStatus::kOk);
  CHECK(formatHex(average) == "#C8C8C8");
  // A light photograph asks for dark ink; before the fix this resolved from #101418 instead.
  CHECK(std::string(autoInk(average)) == "dark");
  std::remove(path.c_str());

  // The budget still exists: a declared size past it is refused before anything is decoded.
  Bytes oversized = makeGreyPng(2, 2, 0x40);
  // Rewrite the IHDR dimensions in place, so stbi_info reports 5000x5000 for a tiny file.
  oversized[16] = 0x00; oversized[17] = 0x00; oversized[18] = 0x13; oversized[19] = 0x88;
  oversized[20] = 0x00; oversized[21] = 0x00; oversized[22] = 0x13; oversized[23] = 0x88;
  const uint32_t fixed = crc32Of(oversized.data() + 12, 17);
  oversized[29] = static_cast<uint8_t>(fixed >> 24);
  oversized[30] = static_cast<uint8_t>(fixed >> 16);
  oversized[31] = static_cast<uint8_t>(fixed >> 8);
  oversized[32] = static_cast<uint8_t>(fixed);
  const std::string big_path = writeTempFixture("doorbell_theme_oversized.png", oversized);
  CHECK(averageImageColor(big_path, &average) == SampleStatus::kTooLarge);
  std::remove(big_path.c_str());
}
