#include <cmath>
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

TEST_CASE("color: automatic ink flips at the WCAG mid luminance") {
  // Y >= 0.5 means the background is light, so the ink drawn on it must be dark.
  CHECK(std::string(autoInk(hex("#9BD748"))) == "dark");   // Y 0.560
  CHECK(std::string(autoInk(kWhite)) == "dark");
  CHECK(std::string(autoInk(hex("#101418"))) == "light");  // the default dark theme
  CHECK(std::string(autoInk(kBlack)) == "light");
  CHECK(std::string(autoInk(hex("#808080"))) == "light");  // Y 0.216 is below the threshold
  // A light photograph and a dark photograph produce opposite inks.
  CHECK(std::string(autoInk(hex("#E8E2D5"))) == "dark");
  CHECK(std::string(autoInk(hex("#2A2118"))) == "light");
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
    CHECK(std::string(accentInk(button)) == "light");
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

TEST_CASE("color: image averaging samples a decodable file and refuses anything else") {
  Rgb average;
  CHECK_FALSE(averageImageColor("", &average));
  CHECK_FALSE(averageImageColor("/nonexistent/theme.jpg", &average));

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
  REQUIRE(averageImageColor(path, &average));
  CHECK(formatHex(average) == "#9BD748");
  std::remove(path.c_str());

  // A file that is not an image at all is refused rather than averaged as noise.
  const std::string junk_path = "/tmp/doorbell_theme_average_junk.png";
  Bytes junk(64, 0x41);
  REQUIRE(writeFileBytes(junk_path, junk));
  CHECK_FALSE(averageImageColor(junk_path, &average));
  std::remove(junk_path.c_str());
}
