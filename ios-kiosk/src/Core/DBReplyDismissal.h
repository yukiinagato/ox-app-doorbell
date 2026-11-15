#import <Foundation/Foundation.h>

// The guarded two-step dismissal of a full-screen quick reply. Taps do nothing for the first
// 3 s; then one tap arms the close for 3 s and a second, separate touch at least 0.3 s later
// closes. Times are on one monotonic clock.
typedef enum {
  DBReplyTapIgnore = 0,
  DBReplyTapArm,
  DBReplyTapClose
} DBReplyTapResult;

typedef enum {
  DBReplyHintNone = 0,
  DBReplyHintFirst,
  DBReplyHintConfirm
} DBReplyHint;

typedef struct {
  NSTimeInterval shownAt;
  NSTimeInterval armedAt;  // Negative when not armed.
} DBReplyDismissal;

extern const NSTimeInterval DBReplyQuietSeconds;
extern const NSTimeInterval DBReplyArmSeconds;
extern const NSTimeInterval DBReplyMinimumGapSeconds;

DBReplyDismissal DBReplyDismissalBegin(NSTimeInterval now);
DBReplyTapResult DBReplyDismissalTap(DBReplyDismissal *state, NSTimeInterval now);
DBReplyHint DBReplyDismissalHint(DBReplyDismissal state, NSTimeInterval now);
