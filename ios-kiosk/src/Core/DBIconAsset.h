#import <UIKit/UIKit.h>

// Tabler Icons (MIT), vendored as PNGs by tools/gen_icons.py and copied into
// the app bundle as ic_tabler_<name>@1x.png / @2x.png.
//
// Icons are never drawn in code and never come from a font: an emoji is not in
// the iOS 5 system font at all, and a hand-drawn path is one more thing that
// disagrees with the other shells. The names this shell asks for are:
//
//   topology-star-3   the cluster counter
//   door              the door-station counter
//   device-tablet     the indoor-panel counter
//   chevrons-right    the SOS knob
//
// A missing asset is not an error. Until the PNGs are vendored every method
// here returns nil and callers lay out without the icon, so the panel degrades
// to text rather than to a crash or a placeholder box.
@interface DBIconAsset : NSObject

// The raw icon at the screen's scale, or nil when it has not been vendored.
+ (UIImage *)imageNamed:(NSString *)name;

// The icon recoloured to ink and drawn at size. iOS 5 has no template
// rendering mode, so the PNG's alpha is used as a clipping mask and the ink is
// filled through it. Results are cached per name, colour and size because this
// is called from drawRect.
+ (UIImage *)tintedImageNamed:(NSString *)name color:(UIColor *)ink size:(CGSize)size;

@end
