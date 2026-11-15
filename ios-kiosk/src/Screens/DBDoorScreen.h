#import "DBScreen.h"
#import "../Media/DBSipSession.h"
@class DBCallTimingSnapshot;

// Visitor-facing compatibility screen used by both iOS 5 and iOS 9 profiles.
// It intentionally owns only presentation state; all durable ring/cancel state
// remains in the core event log.
@interface DBDoorScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)refreshFromCore;
// Re-reads the PM2.5 line, for the air_quality_changed hint.
- (void)refreshAirQuality;
// The call identity selects a row; state and recovery permission come only from the snapshot.
- (BOOL)restoreWaitingCall:(NSString *)callID snapshot:(DBCallTimingSnapshot *)snapshot;
- (void)handleCallEvent:(NSDictionary *)event;
- (void)handleReplyEvent:(NSDictionary *)event;
- (void)handleVisitorLangEvent:(NSDictionary *)event;
// {t:"visitor_flow_changed"}: the resolved visitor flow changed; it is read again.
- (void)handleFlowChanged:(NSDictionary *)event;
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

// Debug start screens "visitor:calling|connected|reply|noanswer" put the page in that state, and
// "visitor:flow[:<step id>]" shows the visitor flow's start page or that step.
- (void)debugShowState:(NSString *)state;

@end
