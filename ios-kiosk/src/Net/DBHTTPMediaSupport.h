#import <Foundation/Foundation.h>

typedef NSString *(^DBHTTPMediaCredentialProvider)(void);
typedef void (^DBMJPEGDataHandler)(NSData *jpeg);

// Shared policy for camera HTTP requests. URL credentials are rejected and
// secure-store values are converted to an ephemeral Authorization header.
@interface DBHTTPMediaSupport : NSObject

+ (NSString *)safeURLString:(NSString *)raw;
+ (NSDictionary *)authorizationHeadersForSecret:(NSString *)secret;
+ (NSMutableURLRequest *)requestWithURLString:(NSString *)urlString
                            credentialProvider:(DBHTTPMediaCredentialProvider)provider
                                        accept:(NSString *)accept
                                       timeout:(NSTimeInterval)timeout;
+ (NSTimeInterval)reconnectDelayForAttempt:(NSUInteger)attempt;

@end

// Bounded incremental multipart parser. It accepts fragmented headers and
// bodies, Content-Length parts, and JPEG marker-delimited camera streams.
@interface DBMJPEGMultipartParser : NSObject

@property(nonatomic, readonly, copy) NSString *errorReason;
@property(nonatomic, readonly) NSUInteger bufferedBytes;
@property(nonatomic, readonly) int64_t lastCaptureTimeMs;
@property(nonatomic, readonly) int64_t lastServerTimeMs;

- (id)initWithFrameHandler:(DBMJPEGDataHandler)handler;
- (BOOL)appendData:(NSData *)data;
- (void)reset;

@end
