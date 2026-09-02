#import <Foundation/Foundation.h>

// Tracks the call identity carried by Core schema-v2 events. A replicated
// press may populate the cache, but only a targeted chime can activate a call.
@interface DBCallEventTracker : NSObject

@property(nonatomic, readonly) NSString *currentCallID;

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

// Scoped events must carry the exact active call_id.
- (BOOL)eventMatchesCurrentCall:(NSDictionary *)event;
- (void)clearCurrentCall;

@end
