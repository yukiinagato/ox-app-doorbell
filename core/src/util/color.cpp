#include "util/color.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

#define STBI_NO_THREAD_LOCALS
#define STBI_NO_STDIO
// armv7/iOS 5 has no thread-local storage; stb only uses it for a failure-reason string.
#define STBI_NO_THREAD_LOCALS
#include "stb_image.h"
#include "util/common.h"

namespace db {
namespace color {
namespace {

constexpr double kMinButtonContrast = 3.0;
constexpr double kMinTextContrast = 4.5;
// Decoded-pixel budget. stb offers no downscale-on-decode, so this is the real transient cost:
// three bytes per pixel, about 48 MB at the cap, freed as soon as the 16x16 sample is taken.
// 16 MP covers what phone and tablet cameras produce -- the previous 4 MP budget silently
// refused an ordinary 2200x2609 photo and the caller then reported the flat theme colour.
constexpr long long kMaxPixels = 16'000'000LL;

int hexNibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

double linearize(double channel) {
  return channel <= 0.03928 ? channel / 12.92 : std::pow((channel + 0.055) / 1.055, 2.4);
}

double clamp01(double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

uint8_t toByte(double v) {
  const double scaled = std::floor(clamp01(v) * 255.0 + 0.5);
  return static_cast<uint8_t>(scaled);
}

double hueToChannel(double p, double q, double t) {
  if (t < 0) t += 1;
  if (t > 1) t -= 1;
  if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
  if (t < 1.0 / 2.0) return q;
  if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
  return p;
}

}  // namespace

bool parseHex(const std::string& text, Rgb* out) {
  if (text.size() != 7 || text[0] != '#') return false;
  int channels[3] = {0, 0, 0};
  for (int i = 0; i < 3; i++) {
    const int high = hexNibble(text[1 + i * 2]);
    const int low = hexNibble(text[2 + i * 2]);
    if (high < 0 || low < 0) return false;
    channels[i] = high * 16 + low;
  }
  if (out) {
    out->r = static_cast<uint8_t>(channels[0]);
    out->g = static_cast<uint8_t>(channels[1]);
    out->b = static_cast<uint8_t>(channels[2]);
  }
  return true;
}

std::string formatHex(const Rgb& color) {
  char buffer[8];
  std::snprintf(buffer, sizeof(buffer), "#%02X%02X%02X", color.r, color.g, color.b);
  return buffer;
}

double relativeLuminance(const Rgb& color) {
  return 0.2126 * linearize(color.r / 255.0) + 0.7152 * linearize(color.g / 255.0) +
         0.0722 * linearize(color.b / 255.0);
}

double contrastRatioLuminance(double y_a, double y_b) {
  const double hi = std::max(y_a, y_b);
  const double lo = std::min(y_a, y_b);
  return (hi + 0.05) / (lo + 0.05);
}

double contrastRatio(const Rgb& a, const Rgb& b) {
  return contrastRatioLuminance(relativeLuminance(a), relativeLuminance(b));
}

Hsl toHsl(const Rgb& color) {
  const double r = color.r / 255.0, g = color.g / 255.0, b = color.b / 255.0;
  const double max = std::max(r, std::max(g, b));
  const double min = std::min(r, std::min(g, b));
  Hsl out;
  out.l = (max + min) / 2.0;
  const double delta = max - min;
  if (delta <= 0.0) return out;  // grey: hue and saturation are undefined, report zero
  out.s = out.l > 0.5 ? delta / (2.0 - max - min) : delta / (max + min);
  if (max == r) out.h = 60.0 * std::fmod((g - b) / delta + 6.0, 6.0);
  else if (max == g) out.h = 60.0 * ((b - r) / delta + 2.0);
  else out.h = 60.0 * ((r - g) / delta + 4.0);
  return out;
}

Rgb fromHsl(const Hsl& hsl) {
  const double h = std::fmod(std::fmod(hsl.h, 360.0) + 360.0, 360.0) / 360.0;
  const double s = clamp01(hsl.s);
  const double l = clamp01(hsl.l);
  if (s <= 0.0) {
    const uint8_t grey = toByte(l);
    return Rgb{grey, grey, grey};
  }
  const double q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
  const double p = 2.0 * l - q;
  Rgb out;
  out.r = toByte(hueToChannel(p, q, h + 1.0 / 3.0));
  out.g = toByte(hueToChannel(p, q, h));
  out.b = toByte(hueToChannel(p, q, h - 1.0 / 3.0));
  return out;
}

const char* autoInk(const Rgb& background) {
  return relativeLuminance(background) >= 0.5 ? "dark" : "light";
}

Rgb autoAccent(const Rgb& background, const Rgb& text) {
  const double background_luminance = relativeLuminance(background);
  const double text_luminance = relativeLuminance(text);
  const Hsl base = toHsl(background);
  Hsl candidate;
  candidate.h = std::fmod(base.h + 180.0, 360.0);
  // A washed-out background would otherwise rotate into an equally washed-out button; the floor
  // keeps the result a recognisable colour rather than another shade of grey.
  candidate.s = std::max(base.s, 0.35);

  auto satisfies = [&](const Rgb& button) {
    const double y = relativeLuminance(button);
    return contrastRatioLuminance(y, background_luminance) >= kMinButtonContrast &&
           contrastRatioLuminance(text_luminance, y) >= kMinTextContrast;
  };

  // Some backgrounds admit no solution at all: a mid-dark background needs a light button to
  // separate from it, while the supplied text needs a dark one. Rather than return an unreadable
  // colour, keep the best compromise, scored against whichever ink the shell would actually draw
  // on the button (autoInk), and let the caller publish that ink alongside it.
  auto score = [&](const Rgb& button) {
    const double y = relativeLuminance(button);
    const double separation = contrastRatioLuminance(y, background_luminance);
    const double readability =
        std::max(contrastRatioLuminance(1.0, y), contrastRatioLuminance(0.0, y));
    return std::min(separation, readability);
  };

  // Walk away from the background's own lightness, preferring the dark direction over a light
  // background, and take the first lightness that satisfies both constraints.
  const bool dark_first = background_luminance >= 0.5;
  Rgb best = fromHsl(candidate);
  double best_score = -1.0;
  for (int pass = 0; pass < 2; pass++) {
    const bool downward = (pass == 0) == dark_first;
    for (int step = 1; step <= 100; step++) {
      const double l = base.l + (downward ? -0.01 : 0.01) * step;
      if (l < 0.0 || l > 1.0) break;
      candidate.l = l;
      const Rgb button = fromHsl(candidate);
      if (satisfies(button)) return button;
      const double candidate_score = score(button);
      if (candidate_score > best_score) {
        best_score = candidate_score;
        best = button;
      }
    }
  }
  return best;
}

const char* accentInk(const Rgb& button) { return autoInk(button); }

const char* sampleStatusName(SampleStatus status) {
  switch (status) {
    case SampleStatus::kOk: return "ok";
    case SampleStatus::kMissing: return "missing";
    case SampleStatus::kTooLarge: return "too_large";
    case SampleStatus::kDecodeFailed: return "decode_failed";
  }
  return "decode_failed";
}

SampleStatus averageImageColor(const std::string& path, Rgb* out) {
  if (path.empty() || !out) return SampleStatus::kMissing;
  Bytes encoded;
  if (!readFileBytes(path, encoded) || encoded.empty()) return SampleStatus::kMissing;
  // An encoded file this large is past the asset ledger's own 3 MB upload cap; treat it as
  // oversized rather than spending the decode on it.
  if (encoded.size() > static_cast<size_t>(32) * 1024 * 1024) return SampleStatus::kTooLarge;
  const int encoded_len = static_cast<int>(encoded.size());
  int width = 0, height = 0, channels = 0;
  if (!stbi_info_from_memory(encoded.data(), encoded_len, &width, &height, &channels))
    return SampleStatus::kDecodeFailed;
  if (width <= 0 || height <= 0) return SampleStatus::kDecodeFailed;
  if (static_cast<long long>(width) * height > kMaxPixels) return SampleStatus::kTooLarge;
  int decoded_channels = 0;
  unsigned char* pixels =
      stbi_load_from_memory(encoded.data(), encoded_len, &width, &height, &decoded_channels, 3);
  if (!pixels) return SampleStatus::kDecodeFailed;
  // Sample a grid of at most 16x16 points; averaging every pixel of a photo buys no accuracy
  // for a luminance decision and costs real time on the oldest hardware.
  const int steps_x = std::min(width, 16);
  const int steps_y = std::min(height, 16);
  double sum_r = 0, sum_g = 0, sum_b = 0;
  for (int y = 0; y < steps_y; y++) {
    const int py = static_cast<int>((static_cast<long long>(y) * 2 + 1) * height / (steps_y * 2));
    for (int x = 0; x < steps_x; x++) {
      const int px = static_cast<int>((static_cast<long long>(x) * 2 + 1) * width / (steps_x * 2));
      const unsigned char* pixel = pixels + (static_cast<size_t>(py) * width + px) * 3;
      sum_r += pixel[0];
      sum_g += pixel[1];
      sum_b += pixel[2];
    }
  }
  stbi_image_free(pixels);
  const double count = static_cast<double>(steps_x) * steps_y;
  out->r = toByte(sum_r / count / 255.0);
  out->g = toByte(sum_g / count / 255.0);
  out->b = toByte(sum_b / count / 255.0);
  return SampleStatus::kOk;
}

}  // namespace color
}  // namespace db
