#import "DBScreen.h"




@interface DBHomeScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;


- (void)refreshFromCore;
// Re-reads the PM2.5 line, for the air_quality_changed hint.
- (void)refreshAirQuality;
- (void)refreshAfterCallEvent;
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
