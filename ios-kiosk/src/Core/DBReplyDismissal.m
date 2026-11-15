#import "DBReplyDismissal.h"

const NSTimeInterval DBReplyQuietSeconds = 3.0;
const NSTimeInterval DBReplyArmSeconds = 3.0;
const NSTimeInterval DBReplyMinimumGapSeconds = 0.3;

DBReplyDismissal DBReplyDismissalBegin(NSTimeInterval now) {
  DBReplyDismissal state = { now, -1 };
  return state;
}

static BOOL DBReplyArmed(DBReplyDismissal state, NSTimeInterval now) {
  return state.armedAt >= 0 && now - state.armedAt <= DBReplyArmSeconds;
}

DBReplyTapResult DBReplyDismissalTap(DBReplyDismissal *state, NSTimeInterval now) {
  if (now - state->shownAt < DBReplyQuietSeconds) return DBReplyTapIgnore;
  if (DBReplyArmed(*state, now)) {
    return now - state->armedAt >= DBReplyMinimumGapSeconds ? DBReplyTapClose : DBReplyTapIgnore;
  }
  state->armedAt = now;
  return DBReplyTapArm;
}

DBReplyHint DBReplyDismissalHint(DBReplyDismissal state, NSTimeInterval now) {
  if (now - state.shownAt < DBReplyQuietSeconds) return DBReplyHintNone;
  return DBReplyArmed(state, now) ? DBReplyHintConfirm : DBReplyHintFirst;
}
