#import <Foundation/Foundation.h>

// mach_absolute_time is available on iOS 5; foreground freshness must be checked separately.
NSTimeInterval DBCallMonotonicTime(void);

@interface DBCallTimingSnapshot : NSObject
@property(nonatomic, readonly) NSDictionary *document;
@property(nonatomic, readonly) NSUInteger coreGeneration;
@property(nonatomic, readonly) NSTimeInterval requestedAt;
- (id)initWithDocument:(NSDictionary *)document coreGeneration:(NSUInteger)generation
           requestedAt:(NSTimeInterval)requestedAt;
@end

typedef enum {
  DBCallTimingUnavailable = 0,
  DBCallTimingAbsent,
  DBCallTimingActive
} DBCallTimingDisposition;

@interface DBCallTimingReading : NSObject
@property(nonatomic, readonly) DBCallTimingDisposition disposition;
@property(nonatomic, readonly) NSDictionary *call;
@property(nonatomic, readonly) NSNumber *remainingSeconds;
@property(nonatomic, readonly) NSNumber *recoveryRemainingSeconds;
@property(nonatomic, readonly) BOOL mayRestore;
@end

// Main-thread state. A cached Core sample can shorten an anchor but cannot renew it.
@interface DBCallTiming : NSObject
@property(nonatomic, readonly) BOOL waitingForFreshSnapshot;
- (void)reset;
- (void)requireFreshSnapshot:(DBCallTimingSnapshot *)snapshot;
- (BOOL)acceptsSnapshot:(DBCallTimingSnapshot *)snapshot;
- (DBCallTimingReading *)observeSnapshot:(DBCallTimingSnapshot *)snapshot
                                 callID:(NSString *)callID door:(NSString *)door
                                    now:(NSTimeInterval)now;
- (DBCallTimingReading *)observeRecoverySnapshot:(DBCallTimingSnapshot *)snapshot
                                         callID:(NSString *)callID role:(NSString *)role
                                         nodeID:(NSString *)nodeID door:(NSString *)door
                                            now:(NSTimeInterval)now;
- (void)invalidateCallbacks;
- (NSDictionary *)callbackForCall:(NSString *)callID coreGeneration:(NSUInteger)generation;
- (BOOL)acceptsCallback:(NSDictionary *)callback callID:(NSString *)callID
         coreGeneration:(NSUInteger)generation;
@end
