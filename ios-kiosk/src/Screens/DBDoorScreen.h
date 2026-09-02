#import "DBScreen.h"
#import "../Media/DBSipSession.h"

// Visitor-facing compatibility screen used by both iOS 5 and iOS 9 profiles.
// It intentionally owns only presentation state; all durable ring/cancel state
// remains in the core event log.
@interface DBDoorScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)refreshFromCore;
- (BOOL)restoreWaitingCall:(NSDictionary *)call recoveryState:(NSString *)state;
- (void)handleCallEvent:(NSDictionary *)event;
- (void)handleReplyEvent:(NSDictionary *)event;
- (void)handleVisitorLangEvent:(NSDictionary *)event;
- (void)handleCallCancelled:(NSDictionary *)event;
- (void)handleCallAnswered:(NSDictionary *)event;
- (void)handleCallEnded:(NSDictionary *)event;
- (void)handleStateEvent:(NSDictionary *)event;
- (void)handleEmergencyEvent:(NSDictionary *)event;
- (void)miniSipListenerStateChanged:(DBMiniSipState)state mode:(NSString *)mode;
- (void)releaseMediaForMemoryPressure;
- (void)enterSafeMode;
- (void)exitSafeMode;
- (NSDictionary *)safeModeMediaStatus;
- (void)suspendMediaForBackground;
- (void)resumeMediaAfterBackground;

@end
