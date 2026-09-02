#import "DBRefreshCoalescer.h"

@implementation DBRefreshCoalescer {
  BOOL _busy;
  BOOL _pending;
}

- (BOOL)busy {
  @synchronized(self) { return _busy; }
}

- (BOOL)pending {
  @synchronized(self) { return _pending; }
}

- (BOOL)beginRefresh {
  @synchronized(self) {
    if (_busy) {
      _pending = YES;
      return NO;
    }
    _busy = YES;
    _pending = NO;
    return YES;
  }
}

- (BOOL)endRefresh {
  @synchronized(self) {
    BOOL again = _pending;
    _pending = NO;
    // The slot is always released.  Keeping it held for the follow-up refresh
    // is what deadlocked the previous implementation.
    _busy = NO;
    return again;
  }
}

- (void)reset {
  @synchronized(self) {
    _busy = NO;
    _pending = NO;
  }
}

@end
