#import <Foundation/Foundation.h>
#import <stdlib.h>

#import "DBTexts.h"

static void DBRequire(BOOL condition, NSString *message) {
  if (condition) return;
  NSLog(@"DBTexts test failed: %@", message);
  abort();
}

int main(void) {
  @autoreleasepool {
    DBTexts *texts = [[DBTexts alloc] init];
    [texts setLang:@"en"];
    DBRequire([[texts ts:@"calling.cancel"] isEqualToString:@"Cancel"],
              @"generated English default");
    DBRequire([[texts t:@"idle.call_button", @"Front", nil]
                  isEqualToString:@"Call Front"],
              @"positional placeholder replacement");
    DBRequire([[texts ts:@"ring.open_door"] isEqualToString:@"Unlock"],
              @"legacy key alias");

    NSDictionary *oldOverrides =
        [NSDictionary dictionaryWithObjectsAndKeys:@"Release", @"ring.open_door", nil];
    NSDictionary *oldConfig = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSDictionary dictionaryWithObjectsAndKeys:oldOverrides, @"en", nil],
        @"i18n_overrides", nil];
    [texts setConfig:oldConfig];
    DBRequire([[texts ts:@"ring.open_door"] isEqualToString:@"Release"],
              @"legacy config override precedence");

    NSDictionary *newOverrides =
        [NSDictionary dictionaryWithObjectsAndKeys:@"Open", @"ring.unlock", nil];
    NSDictionary *newConfig = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSDictionary dictionaryWithObjectsAndKeys:newOverrides, @"en", nil],
        @"i18n_overrides", nil];
    [texts setConfig:newConfig];
    DBRequire([[texts ts:@"ring.open_door"] isEqualToString:@"Open"],
              @"canonical config override fallback");
  }
  return 0;
}
