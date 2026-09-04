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
//
// CFNetwork consumes the part headers of multipart/x-mixed-replace itself: the
// connection delegate sees one didReceiveResponse per part and the data callbacks
// carry only the part body. The client forwards each part response through
// -beginPartWithContentLength:…, and a body that starts with a JPEG SOI while a
// header is awaited is parsed marker-delimited instead of being searched for
// headers that will never arrive.
@interface DBMJPEGMultipartParser : NSObject

@property(nonatomic, readonly, copy) NSString *errorReason;
@property(nonatomic, readonly) NSUInteger bufferedBytes;
@property(nonatomic, readonly) int64_t lastCaptureTimeMs;
@property(nonatomic, readonly) int64_t lastServerTimeMs;
@property(nonatomic, readonly) NSUInteger partsAnnounced;

- (id)initWithFrameHandler:(DBMJPEGDataHandler)handler;
- (BOOL)appendData:(NSData *)data;
// Announces a part whose headers were delivered out of band (a per-part
// NSURLResponse). A non-positive or oversized length means marker-delimited.
- (void)beginPartWithContentLength:(long long)contentLength
                     captureTimeMs:(int64_t)captureTimeMs
                      serverTimeMs:(int64_t)serverTimeMs;
- (void)reset;

@end
