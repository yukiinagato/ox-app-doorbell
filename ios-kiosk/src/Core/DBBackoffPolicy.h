#import <Foundation/Foundation.h>

// Exponential backoff for a media transport that keeps failing.
//
// A door station whose mesh peer is alive but whose HTTP server is down answers
// neither /stream.mp4 nor its own socket timeout quickly.  The fMP4 player used
// to be restarted on a flat 2 s timer, which produced an unbounded restart loop
// (observed: ~48 consecutive "start fMP4 direct decode" / "response header
// ended n=-1 errno=35" pairs against a single unreachable door).  The schedule
// below spaces those attempts out while keeping the first retry fast enough
// that a door station rebooting normally is picked up within a couple of
// seconds, and it is reset the moment a transport actually plays.
//
// Schedule (seconds): 1, 2, 5, then 10 for every further attempt.
@interface DBBackoffPolicy : NSObject

// Number of delays handed out since the last -reset.
@property(nonatomic, readonly) NSUInteger attempt;

// Seconds to wait before the next attempt, then advances the schedule.
- (NSTimeInterval)nextDelay;

// Seconds the given zero-based attempt index waits. Pure, for tests and logs.
+ (NSTimeInterval)delayForAttempt:(NSUInteger)attempt;

// Called after a transport reports that it is playing.
- (void)reset;

@end
