#import <Foundation/Foundation.h>

// Coalescing gate for "fetch a Core snapshot on a background queue, then apply
// it on the main thread" refresh loops.
//
// The original inline implementation on DBHomeScreen latched permanently: when
// a refresh request arrived while one was in flight the completion kept `busy`
// set and re-entered the same gate, which only marked the request dirty again
// and returned.  From that moment the screen never refreshed, so a door station
// that joined the Cluster later never appeared in the monitor list.
//
// The contract here is deliberately tiny and side-effect free so it can be
// unit tested on the host without UIKit:
//   * -beginRefresh returns NO when a refresh is already running (the request
//     is remembered as pending).
//   * -endRefresh returns YES when a request arrived while the refresh ran; the
//     gate is then already free, so the caller may start the follow-up
//     immediately with -beginRefresh.
@interface DBRefreshCoalescer : NSObject

@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL pending;

// YES when the caller now owns the refresh slot and must call -endRefresh.
- (BOOL)beginRefresh;

// Releases the slot. YES when at least one request was coalesced away while the
// refresh was running and the caller should refresh again.
- (BOOL)endRefresh;

// Drops a pending request and releases the slot (screen disappeared, teardown).
- (void)reset;

@end
