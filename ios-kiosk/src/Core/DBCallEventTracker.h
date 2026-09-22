#import <Foundation/Foundation.h>
@class DBCallTimingReading;
@class DBCallTimingSnapshot;

// Tracks the call identity carried by Core schema-v2 events. A replicated
// press may populate the cache, but only a targeted chime can activate a call.
@interface DBCallEventTracker : NSObject

@property(nonatomic, readonly) NSString *currentCallID;
@property(nonatomic, readonly) NSUInteger pendingChimeCount;

// Cache state from raw press/purpose events without activating UI or audio. Returns YES only when
// this event advances the cached call revision.
- (BOOL)recordCallEvent:(NSDictionary *)event;

// Remember cancellation even when it arrives before the targeted chime, so a
// delayed rule action cannot resurrect the resolved call.
- (void)recordCancellationEvent:(NSDictionary *)event;

// Answered calls suppress delayed chimes but remain current on the answering
// panel until call_ended. Ended calls also clear an exactly matching current UI.
- (BOOL)recordAnsweredEvent:(NSDictionary *)event;
- (BOOL)recordEndedEvent:(NSDictionary *)event;

// Consumes the one SIP-ended callback produced while tearing down a superseded answer leg.
- (BOOL)consumeSupersededIdleForCurrentCall;

// Returns a normalized, immutable chime event when it is current, unexpired,
// and newer than the last accepted revision for its call. Otherwise nil.
- (NSDictionary *)acceptChimeEvent:(NSDictionary *)event nowMs:(long long)nowMs;
// Recovery uses the Core-projected duration, while retaining identity/revision deduplication.
- (NSDictionary *)acceptChimeEvent:(NSDictionary *)event timingReading:(DBCallTimingReading *)reading;

// Targeted events may arrive before the cached Core row. Pending admission is bounded to 128
// identities and ten monotonic seconds; expiry drops only the notification, never the call.
- (BOOL)queueChimeEvent:(NSDictionary *)event coreGeneration:(NSUInteger)generation
                   now:(NSTimeInterval)now;
- (NSArray *)takeReadyChimesFromSnapshot:(DBCallTimingSnapshot *)snapshot
                         coreGeneration:(NSUInteger)generation now:(NSTimeInterval)now;
- (void)requireFreshChimeSnapshot:(DBCallTimingSnapshot *)snapshot;

// Scoped events must carry the exact active call_id.
- (BOOL)eventMatchesCurrentCall:(NSDictionary *)event;
- (void)clearCurrentCall;

@end
