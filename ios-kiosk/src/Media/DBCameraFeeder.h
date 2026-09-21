#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

@interface DBCameraFeeder : NSObject
@property(nonatomic, copy) void (^onPixelBuffer)(CVPixelBufferRef, CMTime);
@property(nonatomic, copy) void (^onCaptureStopped)(void);
- (id)initWithFrameHandler:(void (^)(NSData *, int, int, int, int))frameHandler
              stateHandler:(void (^)(BOOL, NSString *))stateHandler;
- (void)start;
- (void)stop;
@end
