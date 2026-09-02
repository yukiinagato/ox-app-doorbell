#import "DBScreen.h"




@interface DBHomeScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;


- (void)refreshFromCore;
- (void)appendEvent:(NSDictionary *)ev;
- (void)playChime:(NSDictionary *)ev;
- (void)stopChime;
- (void)showReplyBanner:(NSDictionary *)ev;
- (void)applyDisplayEvent:(NSDictionary *)ev;
- (void)showEmergencyEvent:(NSDictionary *)ev;
- (void)hideEmergencyEvent:(NSDictionary *)ev;
- (void)enterSafeMode;
- (void)exitSafeMode;

@end
