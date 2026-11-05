#import <Foundation/Foundation.h>

@class DBBootConfig;
@class DBCoreBridge;
@class DBEditPage;
@class DBEditorView;
@class DBRouter;
@class DBTexts;

// Native editors for every setting the kiosk used to send to the web admin
// (docs: .worktrees/native-settings-spec.md). Each page reads the live Core
// configuration when it is built and writes through Core's native config
// path; a closed admin window asks for the 管理パスワード once and retries.
// Secrets go to this device's Keychain and only a "secret:<name>" reference
// is written to configuration.
@interface DBSettingsPages : NSObject
- (id)initWithRouter:(DBRouter *)router editor:(DBEditorView *)editor nodeId:(NSString *)nodeId;
@property(nonatomic, copy) NSString *nodeId;
// Page identifiers: theme, wording, ntp_servers, rules, quiet_hours, telegram,
// secrets, panels, media_sources, sounds, quick_replies, purposes,
// notice_presets, places, devices, sip, mqtt, config_transfer, admin_password.
- (DBEditPage *)pageNamed:(NSString *)name;
// Called when the editor closes: the HTTP admin session is dropped.
- (void)close;
@end
