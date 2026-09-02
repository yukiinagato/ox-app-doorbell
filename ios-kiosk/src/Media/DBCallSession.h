#import <Foundation/Foundation.h>

// Shared compatibility-shell contract. iOS 5 injects MiniSIP adapters; an iOS
// 9 profile can inject the full core/PJSIP adapter without changing screens.
@protocol DBCallSession <NSObject>
- (void)start;
- (void)hangup;
- (void)sendDtmf:(NSString *)digits;
@end
