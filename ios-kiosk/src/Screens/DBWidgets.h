#import <UIKit/UIKit.h>

#import "../Core/DBAdminAddress.h"
#import "../Core/DBBackdropCompositor.h"
#import "../Core/DBSosSlideModel.h"

@class DBTexts;

// Shared kiosk widgets for the batch-2 UI: the resolved appearance palette,
// padded coloured labels, two-part labels, the SOS slide control, the admin QR
// block, and the announcement chip. Every control is drawn with manual frames
// and UIButtonTypeCustom because iOS 5 has no Auto Layout and renders
// UIButtonTypeSystem invisibly.

UIColor *DBColorFromHex(NSString *hex, UIColor *fallback);
// Letterboxed video placement: the door camera's aspect is preserved inside the
// available area, so a portrait stream is shown portrait.
CGRect DBAspectFitRect(CGRect available, CGSize contentSize);
NSString *DBHexFromColor(UIColor *color);

// The cluster's theme picture, prepared once for this panel.
//
// A full-size decode per layout is not affordable on an SGX535 with 256 MB, and
// a bright wallpaper behind text is unreadable however the ink is chosen. The
// backdrop is therefore decoded once per (image, size), scaled to the panel
// with aspect fill and darkened, then reused. The same darkened image is what
// the ink sampler measures, so the contrast decision matches what is on screen.
@interface DBThemeBackdrop : NSObject

// Decodes and prepares off the main thread. key identifies the picture, which
// is the asset hash. Returns nil when the data is not an image.
+ (UIImage *)backdropForData:(NSData *)data key:(NSString *)key size:(CGSize)size;
// The prepared image when this exact picture and size were already built.
+ (UIImage *)cachedBackdropForKey:(NSString *)key size:(CGSize)size;
// How far the picture is darkened, so callers can describe it.
+ (CGFloat)darkeningAlpha;
// The bitmap is prepared at the panel's aspect ratio but no more than this on
// its long side, then scaled back up by the view.
+ (CGFloat)maximumLongSide;
+ (CGSize)preparedSizeForViewSize:(CGSize)size;

@end

// A low-resolution copy of the theme background exactly as it is drawn on
// screen, so each text region can be measured against the pixels actually
// behind it. Core averages the whole image because it has no layout geometry;
// this is the refinement its contract invites.
@interface DBBackgroundSampler : NSObject

// Renders the image with the same aspect-fill mapping the theme view uses.
// Call it off the main thread: it decodes and scales. Returns nil when there
// is no usable image.
+ (DBBackgroundSampler *)samplerWithImage:(UIImage *)image viewSize:(CGSize)viewSize;

@property(nonatomic, readonly) CGSize viewSize;
// Mean colour of one region, sampled at no more than 16x16 points; nil for an
// empty rect. averageHex is the same measurement over the whole view.
- (NSString *)averageHexInViewRect:(CGRect)rect;
- (NSString *)averageHex;
// The same sample with its extremes: @{"average", "darkest", "lightest"} by
// relative luminance. The average decides the ink; the extremes decide whether
// it needs a shadow, because a line crossing a pale wall and a dark jacket
// averages to something readable and still vanishes over the jacket.
- (NSDictionary *)sampleInViewRect:(CGRect)rect;

@end

// One appearance's colour tokens plus the per-region automatic ink rule.
@interface DBUiPalette : NSObject

@property(nonatomic, readonly, copy) NSString *mode;  // "light" | "dark"
@property(nonatomic, readonly, copy) NSString *surfaceHex;
@property(nonatomic, readonly) UIColor *surface;
@property(nonatomic, readonly) UIColor *elevated;   // tiles, rows, chips
@property(nonatomic, readonly) UIColor *chipPlate; // opaque enough for a picture
@property(nonatomic, readonly) UIColor *separator;
@property(nonatomic, readonly) UIColor *ink;
@property(nonatomic, readonly) UIColor *mutedInk;
@property(nonatomic, readonly) UIColor *accent;     // computed call/primary colour
@property(nonatomic, readonly) UIColor *accentInk;
@property(nonatomic, readonly) UIColor *danger;
@property(nonatomic, readonly) UIColor *dangerInk;
@property(nonatomic, readonly) UIColor *notice;
@property(nonatomic, readonly) UIColor *noticeInk;

// backgroundHex is the effective background behind the text: the theme colour,
// or the sampled average of the theme image when one is loaded.
// display is status.display: core resolves the appearance, the averaged
// background, the per-region ink and the call-button colour there, so every
// shell agrees. Pass nil for an older core and the palette computes locally.
+ (DBUiPalette *)paletteForConfig:(NSDictionary *)config
                         deviceId:(NSString *)deviceId
                          display:(NSDictionary *)display
                    backgroundHex:(NSString *)backgroundHex
                      minuteOfDay:(NSInteger)minuteOfDay;

// Region ink without layout knowledge: the whole-background answer.
- (UIColor *)inkForRegion:(NSString *)region;
- (BOOL)needsShadowForRegion:(NSString *)region;

// Region ink refined by what is actually behind the text. An administrator's
// override still wins, and core's per-region value is used when the background
// is a flat colour, where core's answer is exact.
- (void)setBackgroundSampler:(DBBackgroundSampler *)sampler;
// NO for a screen that paints its own chrome instead of the cluster's theme
// picture, such as the incoming/monitor page. Core's published per-region ink
// describes the theme background, so a screen that does not draw it must not
// take that answer: on the device it made the call title dark grey on black.
- (void)setUsesThemeBackground:(BOOL)usesThemeBackground;
- (UIColor *)inkForRegion:(NSString *)region frame:(CGRect)frame;
- (BOOL)needsShadowForRegion:(NSString *)region frame:(CGRect)frame;
// Applies both to one label in a single call, which is what every screen wants.
- (void)applyInkToLabel:(UILabel *)label region:(NSString *)region;
// Average colour of a theme image, downsampled to 16x16 off the main thread.
+ (NSString *)averageHexForImage:(UIImage *)image;

@end

// The three cluster counters in the dashboard header: total devices, door
// stations online/total, indoor panels online/total. Each is a glyph drawn in
// code -- no image asset, no emoji, nothing an iOS 5 font may lack -- followed
// by its number.
typedef enum {
  DBFleetGlyphCluster = 0,
  DBFleetGlyphDoorStation,
  DBFleetGlyphIndoorPanel,
} DBFleetGlyph;

@interface DBFleetCounter : UIView
@property(nonatomic, assign) DBFleetGlyph glyph;
@property(nonatomic, copy) NSString *value;
@property(nonatomic, strong) UIColor *ink;
@property(nonatomic, strong) UIColor *fill;
- (CGFloat)widthThatFits;
@end

// Coloured background text always gets 6/12 padding and a radius (spec §0.7).
@interface DBPillLabel : UILabel
@property(nonatomic, assign) UIEdgeInsets contentInsets;
@end

// Deliberate two-part labels: the authored "\n" splits the title and the second
// line renders smaller and muted (spec §5.1). Never auto-wrapped mid phrase.
@interface DBTwoPartButton : UIButton
- (void)setTwoPartTitle:(NSString *)title;
- (void)setPrimaryColor:(UIColor *)primary secondaryColor:(UIColor *)secondary;
@end

@class DBSosSlider;

@protocol DBSosSliderDelegate <NSObject>
- (void)sosSliderDidArm:(DBSosSlider *)slider;
- (void)sosSliderDidCancel:(DBSosSlider *)slider;
- (void)sosSliderDidFire:(DBSosSlider *)slider;
@end

// Slide-to-trigger SOS. Releasing past 90 % starts the cancellable countdown;
// Core is told only when the countdown reaches zero.
@interface DBSosSlider : UIView
@property(nonatomic, weak) id<DBSosSliderDelegate> delegate;
@property(nonatomic, readonly) DBSosPhase phase;
- (void)applyConfig:(NSDictionary *)config texts:(DBTexts *)texts;
- (void)applyPalette:(DBUiPalette *)palette;
- (void)reset;
@end

// Admin-page QR plus its URL. Visible on every indoor surface; opening the
// admin still requires the password.
@interface DBAdminQrView : UIView
- (void)setUrl:(NSString *)url caption:(NSString *)caption;
- (void)applyPalette:(DBUiPalette *)palette;
@property(nonatomic, readonly, copy) NSString *url;
@end

// Compact 「お知らせ」 chip with an active dot (spec §5.2).
@interface DBNoticeChip : UIButton
- (void)setChipTitle:(NSString *)title active:(BOOL)active;
- (void)applyPalette:(DBUiPalette *)palette;
@end
