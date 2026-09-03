// Colour maths for the automatic theme: WCAG relative luminance and contrast, HSL conversion,
// the automatic ink decision, and the computed call-button colour.
//
// Core owns these so every shell in the fleet agrees on one answer instead of each platform
// deriving its own from the same background. The results are published in the display contract
// (display.theme.auto_ink / auto_accent); a shell that predates the field recomputes locally.
#pragma once

#include <cstdint>
#include <string>

namespace db {
namespace color {

struct Rgb {
  uint8_t r = 0;
  uint8_t g = 0;
  uint8_t b = 0;
};

struct Hsl {
  double h = 0;  // degrees, 0..360
  double s = 0;  // 0..1
  double l = 0;  // 0..1
};

// "#RRGGBB", case-insensitive. Returns false for any other syntax.
bool parseHex(const std::string& text, Rgb* out);
std::string formatHex(const Rgb& color);

// WCAG 2.x relative luminance on linearised sRGB: Y = 0.2126R + 0.7152G + 0.0722B.
double relativeLuminance(const Rgb& color);
// WCAG contrast ratio, 1..21.
double contrastRatio(const Rgb& a, const Rgb& b);
double contrastRatioLuminance(double y_a, double y_b);

Hsl toHsl(const Rgb& color);
Rgb fromHsl(const Hsl& hsl);

// The ink token that reads better on this background: whichever of dark or light has the higher
// WCAG contrast ratio against it. The crossover is Y = 0.1791, not mid luminance -- a grey that
// looks "middling" is already far better served by dark ink. The name is the ink to use, not the
// background. When even the better ink falls below 4.5:1 the shell adds the 40% opposite-ink
// shadow; that fallback is unchanged.
const char* autoInk(const Rgb& background);

// The computed call-button colour: the background hue rotated 180 degrees, with lightness moved
// (preferring the dark direction over a light background) until both
//   contrast(button, background) >= 3:1   and   contrast(button_text, button) >= 4.5:1
// hold. text is the colour the shell draws on the button, normally white.
//
// Some backgrounds admit no solution: separating from a mid-dark background needs a light
// button while white text needs a dark one. The result is then the best compromise on that hue,
// scored against whichever ink would actually be drawn on it, so the caller must take the button
// text from accentInk() rather than assuming white.
Rgb autoAccent(const Rgb& background, const Rgb& text);

// The ink to draw on a computed button: "light" or "dark", by the same rule as autoInk.
const char* accentInk(const Rgb& button);

// Why a background image could not be sampled. The caller must publish the distinction: a
// configured image that failed to sample is not the same as no image at all, and reporting the
// flat theme colour for it makes every shell paint the wrong ink over the real background.
enum class SampleStatus {
  kOk,
  kMissing,        // the file is absent, unreadable, or empty
  kTooLarge,       // beyond the decode budget below
  kDecodeFailed,   // not a JPEG or PNG this build can decode
};

// Stable lowercase name for the published contract: "ok", "missing", "too_large",
// "decode_failed".
const char* sampleStatusName(SampleStatus status);

// Average colour of an image file, sampled on a grid of at most 16x16 points rather than
// touching every pixel. Images come from the asset ledger, which caps uploads at 3 MB.
//
// The budget below is on decoded pixels, because stb has no downscale-on-decode: a 16 MP photo
// costs about 48 MB of RGB while it is being sampled and is freed immediately afterwards. That
// covers what an ordinary phone or tablet camera produces. A shell on hardware that cannot
// afford the transient allocation should sample locally and ignore core's answer; the published
// source field tells it when core has not sampled.
SampleStatus averageImageColor(const std::string& path, Rgb* out);

}  // namespace color
}  // namespace db
