#import "DBScreen.h"




@interface DBPairingScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)startPolling;
- (void)stopPolling;
- (void)reload;
- (void)handleJoinResult:(NSDictionary *)ev;
- (void)handlePersistenceError;

@end
