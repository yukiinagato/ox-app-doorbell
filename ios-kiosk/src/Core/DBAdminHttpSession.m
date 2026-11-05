#import "DBAdminHttpSession.h"

@interface DBAdminHttpSession ()
@property(nonatomic, readwrite, copy) NSString *session;
@property(nonatomic, readwrite, copy) NSString *csrf;
@property(nonatomic, assign) NSInteger port;
@end

static NSMutableURLRequest *DBLoopbackRequest(NSInteger port, NSString *method, NSString *path,
                                              NSDictionary *body) {
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld%@",
                                                               (long)port, path]];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
  request.HTTPMethod = method;
  // Core accepts administrator writes from its own loopback origin; the cookie
  // is carried by hand so it never enters the shared cookie store.
  request.HTTPShouldHandleCookies = NO;
  [request setValue:[NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)port]
      forHTTPHeaderField:@"Origin"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  if (body) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    request.HTTPBody = data;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  return request;
}

static NSDictionary *DBDecode(NSData *data) {
  if ([data length] == 0) return nil;
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

@implementation DBAdminHttpSession
@synthesize session = _session, csrf = _csrf, port = _port;

+ (void)openWithPassword:(NSString *)password port:(NSInteger)port
              completion:(void (^)(DBAdminHttpSession *, NSString *))completion {
  NSString *secret = [password copy] ?: @"";
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSMutableURLRequest *request = DBLoopbackRequest(port, @"POST", @"/api/login",
                                                     @{ @"password" : secret });
    NSHTTPURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response
                                                     error:NULL];
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? response.statusCode : 0;
    DBAdminHttpSession *result = nil;
    NSString *error = nil;
    if (status == 401 || status == 403) {
      error = @"password";
    } else if (status < 200 || status > 299) {
      error = @"unreachable";
    } else {
      NSString *cookie = [[response allHeaderFields] objectForKey:@"Set-Cookie"];
      NSString *token = nil;
      for (NSString *part in [cookie componentsSeparatedByString:@";"]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        NSRange at = [trimmed rangeOfString:@"dbsess="];
        if (at.location != NSNotFound) {
          token = [trimmed substringFromIndex:at.location + at.length];
          break;
        }
      }
      NSString *csrf = [DBDecode(data) objectForKey:@"csrf_token"];
      if ([token length] > 0 && [csrf isKindOfClass:[NSString class]] && [csrf length] > 0) {
        result = [[DBAdminHttpSession alloc] init];
        result.session = token;
        result.csrf = csrf;
        result.port = port;
      } else {
        error = @"unreachable";
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
  });
}

- (void)request:(NSString *)method path:(NSString *)path body:(NSDictionary *)body
     completion:(void (^)(NSInteger, NSDictionary *))completion {
  NSMutableURLRequest *request = DBLoopbackRequest(_port, method, path, body);
  [request setValue:[NSString stringWithFormat:@"dbsess=%@", _session]
      forHTTPHeaderField:@"Cookie"];
  [request setValue:_csrf forHTTPHeaderField:@"X-Doorbell-CSRF"];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSHTTPURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response
                                                     error:NULL];
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? response.statusCode : 0;
    NSDictionary *json = DBDecode(data);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(status, json); });
  });
}
@end
