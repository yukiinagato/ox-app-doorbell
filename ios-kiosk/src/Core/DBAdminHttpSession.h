#import <Foundation/Foundation.h>

// An administrator session on this device's own Core, over loopback only.
// Core's panel-identity and configuration-import ABI and the Telegram test
// require an administrator HTTP session and its CSRF value; native writes do
// not. The session is opened with the 管理パスワード right before such an
// operation and kept only while the settings editor is open. Nothing here
// leaves 127.0.0.1, and the password is never stored.
@interface DBAdminHttpSession : NSObject
@property(nonatomic, readonly, copy) NSString *session;  // dbsess cookie value
@property(nonatomic, readonly, copy) NSString *csrf;

// Completion runs on the main queue with a session, or nil and an error of
// "password" (wrong password) or "unreachable".
+ (void)openWithPassword:(NSString *)password port:(NSInteger)port
              completion:(void (^)(DBAdminHttpSession *session, NSString *error))completion;

// JSON request on the same loopback origin. body may be nil. Completion runs on
// the main queue with the HTTP status (0 when unreachable) and the decoded body.
- (void)request:(NSString *)method path:(NSString *)path body:(NSDictionary *)body
     completion:(void (^)(NSInteger status, NSDictionary *json))completion;
@end
