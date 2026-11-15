#import <UIKit/UIKit.h>

// Framework7 Icons (MIT, SF Symbols style), vendored as PNGs by tools/gen_icons.py and copied
// into the app bundle as f7_<name>.png / f7_<name>@2x.png. Callers ask for "f7:<name>", for
// example "f7:house_fill".
//
// Icons are never drawn in code and never come from a font: an emoji is not in the iOS 5
// system font at all, and a hand-drawn path is one more thing that disagrees with the other
// shells. Every name this shell asks for is a literal "f7:..." at its call site or in
// DBPurposeModel and DBFleetGlyphIconName.
//
// A missing asset is not an error: callers lay out without the icon, so a name this build has
// not vendored degrades to text rather than to a crash or a placeholder box.
// placeholder box.
@interface DBIconAsset : NSObject

// The raw icon at the screen's scale, or nil when it has not been vendored.
+ (UIImage *)imageNamed:(NSString *)name;

// The icon recoloured to ink and drawn at size. iOS 5 has no template
// rendering mode, so the PNG's alpha is used as a clipping mask and the ink is
// filled through it. Results are cached per name, colour and size because this
// is called from drawRect.
+ (UIImage *)tintedImageNamed:(NSString *)name color:(UIColor *)ink size:(CGSize)size;

@end
