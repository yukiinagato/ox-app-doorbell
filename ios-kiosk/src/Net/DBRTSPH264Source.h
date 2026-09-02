#import <Foundation/Foundation.h>

typedef BOOL (^DBRTSPH264FrameHandler)(NSData *annexB, BOOL keyframe,
                                       int64_t timestampMs);
typedef NSString *(^DBRTSPCredentialProvider)(void);
typedef void (^DBRTSPH264StateHandler)(NSString *state, NSString *reason,
                                       BOOL forwardingMeasured);
typedef BOOL (^DBRTSPInterleavedFrameHandler)(uint8_t channel, NSData *frame);

// Incremental bounded parser used both by the network client and host tests.
@interface DBRTSPResponseParser : NSObject

@property(nonatomic, readonly, copy) NSString *errorReason;
- (NSDictionary *)appendData:(NSData *)data;
- (NSData *)drainRemainingData;

@end

// Parses interleaved '$' frames and bounded RTSP keepalive responses.
@interface DBRTSPInterleavedParser : NSObject

@property(nonatomic, readonly, copy) NSString *errorReason;
- (id)initWithFrameHandler:(DBRTSPInterleavedFrameHandler)handler;
- (BOOL)appendData:(NSData *)data;

@end

@interface DBRTSPH264Source : NSObject

@property(nonatomic, readonly, copy) NSString *state;
@property(nonatomic, readonly) BOOL forwardingMeasured;

- (id)initWithURLString:(NSString *)urlString
     credentialProvider:(DBRTSPCredentialProvider)credentialProvider
            frameHandler:(DBRTSPH264FrameHandler)frameHandler
            stateHandler:(DBRTSPH264StateHandler)stateHandler;
- (void)start;
- (void)stop;

// Deterministic protocol helpers are public so malformed and oversized inputs
// can be exercised without a camera or network in the host test suite.
+ (NSDictionary *)parseH264SDP:(NSData *)data
                   contentBase:(NSString *)contentBase
                    requestURL:(NSString *)requestURL
                         error:(NSString **)error;
+ (NSString *)basicAuthorizationForSecret:(NSString *)secret;
+ (NSTimeInterval)reconnectDelayForAttempt:(NSUInteger)attempt;

@end
