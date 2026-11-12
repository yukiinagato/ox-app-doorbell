#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Geometry of a live picture inside its stage. The stage is whatever area the screen has left
// for video; the picture is aspect-fitted in it at 1x and may grow into the letterbox bars
// when zoomed, because the clip rectangle is the stage and not the fitted picture.

// The size of the upright picture for a source frame and its sensor rotation in degrees
// (0, 90, 180, 270): a quarter turn swaps width and height before anything is fitted.
CGSize DBVideoStageUprightSize(CGSize source, NSInteger rotation);

// The upright picture aspect-fitted in the stage at 1x: it fills the width or the height,
// whichever is reached first, and is never stretched or cropped.
CGSize DBVideoStageFitSize(CGSize stage, CGSize source, NSInteger rotation);

// One axis of a zoomed picture. While the zoomed picture is no longer than the stage it stays
// centred (inset on both sides, offset pinned); once it is longer its edges may not come
// inside the stage edges, so no empty space is revealed.
typedef struct {
  CGFloat inset;       // Scroll-view content inset on each side of this axis.
  CGFloat minOffset;   // Allowed content offset range with that inset applied.
  CGFloat maxOffset;
  CGFloat visible;     // Length of picture on screen along this axis.
} DBVideoStageAxis;

DBVideoStageAxis DBVideoStageAxisMake(CGFloat stageLength, CGFloat zoomedLength);
// offset clamped into the axis's allowed range.
CGFloat DBVideoStageClampOffset(DBVideoStageAxis axis, CGFloat offset);
