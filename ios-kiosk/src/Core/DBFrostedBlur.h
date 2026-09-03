#import <UIKit/UIKit.h>

// Builds the static image sampled by frosted dashboard plates. The GPU path is
// attempted first; a bounded CPU implementation produces the same contract.
@interface DBFrostedBlur : NSObject
+ (UIImage *)blurredImage:(UIImage *)image radius:(NSUInteger)radius usedGPU:(BOOL *)usedGPU;
@end
