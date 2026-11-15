namespace DoorbellApp.Ui
{
    internal enum ReplyTap { Ignore, Arm, Close }

    internal enum ReplyHint { None, Exit, Confirm }

    /// <summary>
    /// Guarded dismissal of the quick-reply overlay: taps are ignored for the first GuardMs; a
    /// first tap after that arms the guard for ConfirmMs; a second tap at least MinGapMs later closes.
    /// </summary>
    internal sealed class ReplyDismissGuard
    {
        public const long GuardMs = 3000;
        public const long ConfirmMs = 3000;
        public const long MinGapMs = 300;

        private readonly long _shownAt;
        private long _armedAt = -1;

        public ReplyDismissGuard(long shownAtMs) { _shownAt = shownAtMs; }

        private bool Armed(long now) { return _armedAt >= 0 && now - _armedAt <= ConfirmMs; }

        public ReplyTap Tap(long now)
        {
            if (now - _shownAt < GuardMs) return ReplyTap.Ignore;
            if (Armed(now)) return now - _armedAt < MinGapMs ? ReplyTap.Ignore : ReplyTap.Close;
            _armedAt = now;
            return ReplyTap.Arm;
        }

        public ReplyHint Hint(long now)
        {
            if (now - _shownAt < GuardMs) return ReplyHint.None;
            return Armed(now) ? ReplyHint.Confirm : ReplyHint.Exit;
        }
    }
}
