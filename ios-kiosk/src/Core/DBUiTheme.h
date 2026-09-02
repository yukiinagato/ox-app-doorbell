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
+ (NSString *)normalizedAppearance:(NSString *)appearance;
+ (NSInteger)minuteOfDayFromClock:(NSString *)hhmm fallback:(NSInteger)fallback;

// Theme tokens for one appearance mode.
+ (NSString *)surfaceHexForMode:(NSString *)mode;
+ (NSString *)inkHexForMode:(NSString *)mode;        // primary ink on that surface
+ (NSString *)mutedInkHexForMode:(NSString *)mode;
+ (NSString *)lightInkHex;
+ (NSString *)darkInkHex;

// ---- automatic ink (§5) ----
// "dark" means: use the dark ink token because the background is light.
+ (NSString *)inkModeForLuminance:(double)luminance;
+ (NSString *)inkModeForBackgroundHex:(NSString *)hex fallbackMode:(NSString *)fallbackMode;
// Resolution order: device ink_override -> cluster ink_override ->
// core-published display.theme.auto_ink -> local computation from the effective
// background -> the appearance default.
+ (NSString *)inkHexForRegion:(NSString *)region
                       config:(NSDictionary *)config
                     deviceId:(NSString *)deviceId
                backgroundHex:(NSString *)backgroundHex
               appearanceMode:(NSString *)appearanceMode;
// A 1 px shadow of the opposite ink is only added below the AA text threshold.
+ (BOOL)needsInkShadowForInk:(NSString *)inkHex background:(NSString *)backgroundHex;

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

// Version + battery footer line, shared by every screen (§5.1, §0.6).
+ (NSString *)versionLineForName:(NSString *)name
                     coreVersion:(NSString *)coreVersion
                      appVersion:(NSString *)appVersion
                      batteryPct:(NSInteger)batteryPct
                        charging:(BOOL)charging;

@end
