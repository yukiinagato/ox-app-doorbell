#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
@class DBCoreBridge;

@interface DBCameraEncoder : NSObject
@property(nonatomic, copy) void (^onStateChanged)(BOOL);
- (id)initWithCore:(DBCoreBridge *)core;
- (void)feed:(CVPixelBufferRef)pixels timestamp:(CMTime)timestamp;
- (void)stop;
@end
