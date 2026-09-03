#import "DBAdminAddress.h"

@implementation DBAdminAddress

+ (NSArray *)formsForUrl:(NSString *)url {
  if (![url isKindOfClass:[NSString class]] || [url length] == 0) return @[];
  NSMutableArray *forms = [NSMutableArray arrayWithObject:url];
  NSRange separator = [url rangeOfString:@"://"];
  NSString *authority = (separator.location == NSNotFound)
      ? url : [url substringFromIndex:separator.location + separator.length];
  if ([authority length] > 0 && ![forms containsObject:authority])
    [forms addObject:authority];
  NSRange slash = [authority rangeOfString:@"/"];
  if (slash.location != NSNotFound && slash.location > 0) {
    NSString *hostAndPort = [authority substringToIndex:slash.location];
    if ([hostAndPort length] > 0 && ![forms containsObject:hostAndPort])
      [forms addObject:hostAndPort];
  }
  return forms;
}

@end
