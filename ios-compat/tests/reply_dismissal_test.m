#import <Foundation/Foundation.h>

#import "DBReplyDismissal.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

int main(void) {
  @autoreleasepool {
    DBReplyDismissal s = DBReplyDismissalBegin(100);
    require(DBReplyDismissalHint(s, 102.9) == DBReplyHintNone, @"no hint in the first 3 s");
    require(DBReplyDismissalTap(&s, 101) == DBReplyTapIgnore, @"early tap ignored");
    require(DBReplyDismissalTap(&s, 102.9) == DBReplyTapIgnore, @"early tap ignored at 2.9 s");
    require(DBReplyDismissalHint(s, 103) == DBReplyHintFirst, @"first hint after 3 s");
    require(DBReplyDismissalTap(&s, 104) == DBReplyTapArm, @"first tap arms");
    require(DBReplyDismissalHint(s, 104.5) == DBReplyHintConfirm, @"confirm hint while armed");
    require(DBReplyDismissalTap(&s, 104.1) == DBReplyTapIgnore, @"bounce within 300 ms ignored");
    require(DBReplyDismissalTap(&s, 104.4) == DBReplyTapClose, @"second tap closes");

    s = DBReplyDismissalBegin(0);
    require(DBReplyDismissalTap(&s, 5) == DBReplyTapArm, @"arm");
    require(DBReplyDismissalHint(s, 8.5) == DBReplyHintFirst, @"hint returns after 3 s");
    require(DBReplyDismissalTap(&s, 8.5) == DBReplyTapArm, @"a late tap arms again, not closes");
    require(DBReplyDismissalTap(&s, 9.0) == DBReplyTapClose, @"then closes");
    NSLog(@"reply_dismissal_test ok");
  }
  return 0;
}
