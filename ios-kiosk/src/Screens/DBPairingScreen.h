#import "DBScreen.h"

// Onboarding screen for an unpaired kiosk (spec §5.0). It renders the
// core-authoritative pairing state (unpaired | joining | persist_error) and
// never infers it from side effects. The iPad 1 has no camera, so the Add QR is
// display-only and the Pairing-PIN entry uses a drawn keypad.
@class DBPairUri;

@interface DBPairingScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;

// Prefills the join path from a scanned or opened doorbell://pair invitation
// and asks before replacing an existing cluster. An expired or unreadable one
// is explained inline instead of being acted on.
- (void)presentInvitation:(DBPairUri *)invitation;
- (void)startPolling;
- (void)stopPolling;
- (void)reload;

// Core events forwarded by the router. Every one of them is rendered.
- (void)handleJoinResult:(NSDictionary *)ev;
- (void)handleInviteRejected:(NSDictionary *)ev;
- (void)handlePairingState:(NSDictionary *)ev;
- (void)handleRevoked:(NSDictionary *)ev;
- (void)handlePersistenceError;

// YES when the screen is showing something the user still has to read (the
// create-Cluster code card, a persistence error). The router must not close the
// screen from a `paired` event while this holds.
- (BOOL)requiresUserDismissal;

@end
