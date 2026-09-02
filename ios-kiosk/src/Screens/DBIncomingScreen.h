#import "DBScreen.h"
#import "../Media/DBSipSession.h"

// Incoming-call view with video, answer/listen/unlock/ignore, and quick replies.
// DBRouter exclusively owns the SIP session; this view renders state and actions.
@interface DBIncomingScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;

// Prepares visitor state on the main thread before display.
- (void)prepareWithDoor:(NSString *)door purpose:(NSString *)purpose lang:(NSString *)lang
                 callID:(NSString *)callID stageRevision:(NSInteger)stageRevision
            expiresAtMs:(long long)expiresAtMs;

// Starts active monitoring for a confirmed door peer and does not auto-expire.
- (void)prepareMonitorWithPeer:(NSDictionary *)peer;
// A chime must not collapse an active monitor back to the compact ring layout.
- (BOOL)isActiveMonitor;
- (BOOL)isAnsweringCall;
- (void)yieldAnsweredDialog;
- (BOOL)isIncomingForDoor:(NSString *)door;
// Replaces an explicit door_host placeholder when confirmed peer metadata arrives.
- (void)refreshFromCore;
// Starts listen-only audio from either the normal UI or router.
- (void)beginMonitorAudio;

// Updates purpose/language for the call already displayed.
- (void)refreshPurpose:(NSString *)purpose lang:(NSString *)lang
          stageRevision:(NSInteger)stageRevision;

// SIP state forwarded by DBRouter while this view is visible.
- (void)sipStateChanged:(DBMiniSipState)state;
- (void)handleSupersededSipIdle;

// Core event forwarded by DBRouter while this view is visible.
- (void)handleReplyEvent:(NSDictionary *)ev;
- (void)handleVisitorLangEvent:(NSDictionary *)ev;
- (void)handlePurposeSelected:(NSDictionary *)ev;
- (void)handleCallCancelled:(NSDictionary *)ev;

// Memory-pressure hook used by the compatibility app delegate. Stops all
// decoders/network readers and drops retained frames without changing flow.
- (void)releaseMediaForMemoryPressure;
- (void)enterSafeMode;
- (void)exitSafeMode;
- (NSDictionary *)safeModeMediaStatus;
- (void)suspendMediaForBackground;
- (void)resumeMediaAfterBackground;

@end
