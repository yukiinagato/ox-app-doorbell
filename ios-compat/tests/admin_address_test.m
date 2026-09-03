#import <Foundation/Foundation.h>

#import "DBAdminAddress.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

int main(void) {
  @autoreleasepool {
    // The address the iPad 1 actually shows, which used to arrive on the panel
    // clipped to "http://10.10.38.147:47180/admi".
    NSArray *forms = [DBAdminAddress formsForUrl:@"http://10.10.38.147:47180/admin/"];
    require([forms isEqualToArray:(@[ @"http://10.10.38.147:47180/admin/",
                                      @"10.10.38.147:47180/admin/",
                                      @"10.10.38.147:47180" ])],
            @"the path goes first and the scheme second, host and port last");
    require([[forms objectAtIndex:[forms count] - 1] rangeOfString:@"10.10.38.147:47180"].location
                == 0,
            @"the shortest form still carries the whole host and port");

    // An IPv6 literal keeps its brackets and its port in the last form.
    forms = [DBAdminAddress formsForUrl:@"http://[fd40:174a:3820:10::353]:47180/admin/"];
    require([[forms lastObject] isEqualToString:@"[fd40:174a:3820:10::353]:47180"],
            @"an IPv6 host survives with its brackets and port");

    // No path: there is nothing to drop beyond the scheme.
    forms = [DBAdminAddress formsForUrl:@"http://192.0.2.5:47180"];
    require([forms isEqualToArray:(@[ @"http://192.0.2.5:47180", @"192.0.2.5:47180" ])],
            @"a URL with no path has exactly two forms");

    // A bare host is already its own shortest form, listed once.
    forms = [DBAdminAddress formsForUrl:@"192.0.2.5:47180"];
    require([forms isEqualToArray:@[ @"192.0.2.5:47180" ]],
            @"a schemeless host is not duplicated");

    forms = [DBAdminAddress formsForUrl:@"192.0.2.5:47180/admin/"];
    require([forms isEqualToArray:(@[ @"192.0.2.5:47180/admin/", @"192.0.2.5:47180" ])],
            @"a schemeless URL still drops its path");

    require([[DBAdminAddress formsForUrl:@""] count] == 0, @"an empty URL has no forms");
    require([[DBAdminAddress formsForUrl:nil] count] == 0, @"a nil URL has no forms");

    puts("PASS: DBAdminAddress keeps the host when the footer runs out of width");
  }
  return 0;
}
