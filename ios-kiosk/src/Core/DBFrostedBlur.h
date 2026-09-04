#import <UIKit/UIKit.h>

// Builds the static image sampled by frosted dashboard plates. Small radii use
// GPU sampling; large radii use the bounded dense CPU implementation.
@interface DBFrostedBlur : NSObject
+ (UIImage *)blurredImage:(UIImage *)image radius:(NSUInteger)radius usedGPU:(BOOL *)usedGPU;
@end
