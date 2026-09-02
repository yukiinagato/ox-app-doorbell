#import <Foundation/Foundation.h>

// Appearance, automatic text contrast, and the computed call-button colour
// (batch-2 spec §5, §5.1, §5.2). Deliberately Foundation-only so the whole
// colour and layout arithmetic is exercised by the host test suite; the UIKit
// bridge lives in DBUiThemeUIKit.
typedef struct DBRgb {
  double r;  // 0..1 sRGB
  double g;
  double b;
} DBRgb;

// Semantic region identifiers used by the automatic-ink rule. They match the
// ids published in the shell's ui_manifest so every shell agrees.
FOUNDATION_EXPORT NSString *const DBUiRegionClock;
FOUNDATION_EXPORT NSString *const DBUiRegionDate;
FOUNDATION_EXPORT NSString *const DBUiRegionStatusLine;
FOUNDATION_EXPORT NSString *const DBUiRegionHint;
FOUNDATION_EXPORT NSString *const DBUiRegionTileLabel;

@interface DBUiTheme : NSObject

// ---- colour primitives ----
+ (BOOL)parseHex:(NSString *)hex into:(DBRgb *)out;
+ (NSString *)hexFromRgb:(DBRgb)rgb;
+ (double)relativeLuminance:(DBRgb)rgb;          // WCAG 2.x, linearised sRGB.
+ (double)contrastBetween:(DBRgb)a and:(DBRgb)b;  // 1.0 .. 21.0
+ (double)contrastBetweenHex:(NSString *)a andHex:(NSString *)b;  // 0 when unparsable.
// A colour field is never rejected; it warns instead (§5.2).
+ (BOOL)contrastWarnsForForeground:(NSString *)fg background:(NSString *)bg large:(BOOL)large;
+ (double)minimumContrastForLargeText:(BOOL)large;

// ---- appearance (§5.1) ----
// iOS 5 has no system dark mode, so auto_system is treated as auto_schedule.
// Returns "light" or "dark". minutes are local minutes past midnight.
+ (NSString *)appearanceModeForConfig:(NSDictionary *)config
                             deviceId:(NSString *)deviceId
                          minuteOfDay:(NSInteger)minuteOfDay;
// Core resolves the schedule in the configured time zone and reports it as
// status.display.appearance; the shell uses that when present and falls back to
// its own evaluation only for an older core. follow_system is treated as the
// schedule here because iOS 5 has no system light/dark setting.
+ (NSString *)appearanceModeForConfig:(NSDictionary *)config
                             deviceId:(NSString *)deviceId
                              display:(NSDictionary *)display
                          minuteOfDay:(NSInteger)minuteOfDay;
+ (NSString *)normalizedAppearance:(NSString *)appearance;
+ (NSInteger)minuteOfDayFromClock:(NSString *)hhmm fallback:(NSInteger)fallback;

// Theme tokens for one appearance mode.
+ (NSString *)surfaceHexForMode:(NSString *)mode;
+ (NSString *)inkHexForMode:(NSString *)mode;        // primary ink on that surface
+ (NSString *)mutedInkHexForMode:(NSString *)mode;
+ (NSString *)lightInkHex;
+ (NSString *)darkInkHex;

// ---- automatic ink (§5) ----
// "dark" means: use the dark ink token. The choice is whichever ink actually
// reads better -- the one with the higher WCAG contrast ratio against the
// measured luminance -- not a lightness threshold. A midtone wallpaper
// averaging #BBBBB4 sits just under Y = 0.5 and would take white ink at 1.9:1
// under a threshold rule, where the dark ink gives 9.6:1. The crossover falls
// near Y = 0.18 for the ink tokens in use (Y = 0.179 for pure black on white).
+ (NSString *)inkModeForLuminance:(double)luminance;
// The luminance at which the two inks read equally well, for tests and docs.
+ (double)inkCrossoverLuminance;
+ (NSString *)inkModeForBackgroundHex:(NSString *)hex fallbackMode:(NSString *)fallbackMode;
// Resolution order: device ink_override -> cluster ink_override ->
// core-published display.theme.auto_ink -> local computation from the effective
// background -> the appearance default.
+ (NSString *)inkHexForRegion:(NSString *)region
                       config:(NSDictionary *)config
                     deviceId:(NSString *)deviceId
                backgroundHex:(NSString *)backgroundHex
               appearanceMode:(NSString *)appearanceMode;
// Same order, but reading core's computed display.theme first: auto_ink and the
// administrator's ink_override both arrive there already resolved.
+ (NSString *)inkHexForRegion:(NSString *)region
                       config:(NSDictionary *)config
                     deviceId:(NSString *)deviceId
                      display:(NSDictionary *)display
                backgroundHex:(NSString *)backgroundHex
               appearanceMode:(NSString *)appearanceMode;
// The effective background core measured (an averaged theme image, or the
// theme colour). Returns nil when core published none.
+ (NSString *)autoBackgroundHexInDisplay:(NSDictionary *)display;
// A 1 px shadow of the opposite ink is only added when even the better ink
// stays below the AA text threshold.
+ (BOOL)needsInkShadowForInk:(NSString *)inkHex background:(NSString *)backgroundHex;

// The same question asked of a whole sampled region rather than its average.
// A hint line crossing a pale wall and a dark jacket averages to something the
// ink reads well against and still disappears over the jacket, so the shadow
// is gated on the darkest and the lightest patch of the sample as well.
// darkest and lightest may be nil, which falls back to the average alone.
+ (BOOL)needsInkShadowForInk:(NSString *)inkHex
                  background:(NSString *)backgroundHex
                     darkest:(NSString *)darkestHex
                    lightest:(NSString *)lightestHex;

// ---- per-region sampling of a theme image ----
// Core averages the whole image because it has no layout geometry, so a caption
// over a light corner of a mostly dark picture comes back white and unreadable.
// The shell refines each region by sampling only the pixels behind it.
//
// Where an aspect-fill image lands in the view, in view coordinates. The result
// may overflow the view on one axis, which is what aspect fill means.
// Returns @[x, y, width, height].
+ (NSArray *)aspectFillDrawRectForImageWidth:(double)imageWidth
                                 imageHeight:(double)imageHeight
                                   viewWidth:(double)viewWidth
                                  viewHeight:(double)viewHeight;
// One text region's frame mapped onto the low-resolution proxy, clamped to the
// proxy and never empty, so a region partly off-screen still yields a sample.
// Returns @[x, y, width, height] in whole proxy pixels.
+ (NSArray *)samplePixelRectForViewX:(double)x
                                   y:(double)y
                               width:(double)width
                              height:(double)height
                           viewWidth:(double)viewWidth
                          viewHeight:(double)viewHeight
                          proxyWidth:(NSInteger)proxyWidth
                         proxyHeight:(NSInteger)proxyHeight;
// The ink token for one sampled region: dark ink at or above 0.5, else light.
+ (NSString *)inkHexForSampledLuminance:(double)luminance;
// An administrator's explicit colour for one region, device before cluster,
// or nil. It outranks both core's decision and any local sampling.
+ (NSString *)adminInkOverrideHexForRegion:(NSString *)region
                                    config:(NSDictionary *)config
                                  deviceId:(NSString *)deviceId
                                   display:(NSDictionary *)display;
// Longest edge of the per-region sample proxy (16, per the spec's <= 16x16).
+ (NSInteger)maximumSampleEdge;
+ (double)inkShadowAlpha;

// ---- computed call-button colour (§5.2) ----
// Rotates the background hue by 180 degrees and moves lightness until the
// button reads against the background and its own text reads against it.
+ (NSString *)autoAccentForBackgroundHex:(NSString *)backgroundHex;
+ (NSString *)accentTextHexForAccentHex:(NSString *)accentHex;
// Admin override order: devices.<id>.local.theme.call_button_bg ->
// display.theme.call_button_bg -> core display.theme.auto_accent -> local.
+ (NSString *)callButtonHexForConfig:(NSDictionary *)config
                            deviceId:(NSString *)deviceId
                       backgroundHex:(NSString *)backgroundHex;
// display.theme.call_button_bg already folds the administrator's override into
// the computed accent, and call_button_ink says what to draw on it: on a
// mid-luminance background no colour both separates and carries white text, so
// core returns the best compromise rather than an unreadable button.
+ (NSString *)callButtonHexForConfig:(NSDictionary *)config
                            deviceId:(NSString *)deviceId
                             display:(NSDictionary *)display
                       backgroundHex:(NSString *)backgroundHex;
+ (NSString *)callButtonInkHexForConfig:(NSDictionary *)config
                               deviceId:(NSString *)deviceId
                                display:(NSDictionary *)display
                          backgroundHex:(NSString *)backgroundHex;

// ---- deliberate line breaks (§5.1) ----
// Authored labels carry "\n"; the second part renders smaller and muted.
+ (NSArray *)labelPartsFor:(NSString *)text;   // always two entries; [1] may be empty.
+ (double)secondaryFontScale;

// Padded coloured labels (§0.7): 6 dp vertical, 12 dp horizontal, radius 8.
+ (double)pillPaddingVertical;
+ (double)pillPaddingHorizontal;
+ (double)pillRadius;

// Aspect-preserving fit used by the video area: a portrait door camera is
// shown portrait, letterboxed, never cropped or stretched (spec §5.1).
// Returns @[x, y, width, height] inside a rect of origin (0,0).
+ (NSArray *)aspectFitRectForContentWidth:(double)contentWidth
                            contentHeight:(double)contentHeight
                           availableWidth:(double)availableWidth
                          availableHeight:(double)availableHeight;

// ---- footer band ----
// The admin QR, the version/battery line and the SOS slider share the bottom
// of the indoor dashboard. On a real device the version line ran underneath
// the slider in portrait, so the split is computed here, in one place, and
// host-tested to never overlap in either orientation.
// Returns {"sos": @[x,y,w,h], "qr": …, "version": …, "height": <band height>};
// an entry is a zero rect when that element is not shown.
+ (NSDictionary *)footerLayoutForViewWidth:(double)viewWidth
                                viewHeight:(double)viewHeight
                                  portrait:(BOOL)portrait
                                sosVisible:(BOOL)sosVisible;

// Version + battery footer line, shared by every screen (§5.1, §0.6).
+ (NSString *)versionLineForName:(NSString *)name
                     coreVersion:(NSString *)coreVersion
                      appVersion:(NSString *)appVersion
                      batteryPct:(NSInteger)batteryPct
                        charging:(BOOL)charging;

@end
