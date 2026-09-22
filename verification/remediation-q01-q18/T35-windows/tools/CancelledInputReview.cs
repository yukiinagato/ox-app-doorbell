using System;
using DoorbellApp.Ui;

internal static class CancelledInputReview
{
    public static int Main()
    {
        var guard = new VisitorActionGuard();
        guard.Begin("call-a", 1, 1, VisitorActionKind.Cancel);
        // A pointer release outside the button does not raise Click, so the r2
        // production binding has no event that consumes or cancels this capture.
        bool currentAccessibilityAction = guard.Consume("call-b", 1, 3,
            VisitorActionKind.End, true);
        Console.WriteLine("Current accessible End after a cancelled old press: " +
            currentAccessibilityAction);
        return currentAccessibilityAction ? 0 : 1;
    }
}
