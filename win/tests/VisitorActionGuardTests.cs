using System;
using DoorbellApp.Ui;

internal static class VisitorActionGuardTests
{
    private static int _assertions;
    private static void Check(bool value, string message)
    {
        ++_assertions;
        if (!value) throw new Exception(message);
    }

    public static int Main()
    {
        var actions = new VisitorActionGuard();
        actions.Begin("call-a", 1, 1, VisitorActionKind.Cancel);
        Check(!actions.Consume("call-a", 1, 2, VisitorActionKind.End, true), "Held cancel became end");
        actions.Begin("call-a", 1, 2, VisitorActionKind.End);
        Check(!actions.Consume("call-b", 1, 3, VisitorActionKind.End, true), "Old end reached replacement call");
        actions.Begin("call-a", 1, 2, VisitorActionKind.End);
        Check(!actions.Consume("call-a", 2, 2, VisitorActionKind.End, true), "Old end reached replacement Core");
        actions.Begin("call-a", 1, 2, VisitorActionKind.Cancel);
        Check(!actions.Consume("call-a", 1, 2, VisitorActionKind.Cancel, false), "Hidden cancel remained available");
        actions.Begin("call-b", 2, 3, VisitorActionKind.End);
        Check(actions.Consume("call-b", 2, 3, VisitorActionKind.End, true), "Fresh end was blocked");
        Check(actions.Consume("call-b", 2, 3, VisitorActionKind.End, true), "Current accessibility activation was blocked");
        Check(!actions.Consume("call-b", 2, 3, VisitorActionKind.End, false), "Hidden accessibility action ran");
        actions.Begin("call-a", 1, 1, VisitorActionKind.Cancel);
        actions.Begin("call-b", 2, 2, VisitorActionKind.Cancel);
        Check(actions.Consume("call-b", 2, 2, VisitorActionKind.Cancel, true), "A fresh press did not replace old input");

        long abandoned = actions.Begin("call-a", 1, 1, VisitorActionKind.Cancel);
        actions.CompleteInput(abandoned);
        Check(actions.Consume("call-b", 2, 3, VisitorActionKind.End, true),
              "Cancelled pointer input blocked current accessibility activation");
        abandoned = actions.Begin("call-a", 1, 1, VisitorActionKind.Cancel);
        long replacement = actions.Begin("call-b", 2, 3, VisitorActionKind.End);
        actions.CompleteInput(abandoned);
        Check(!actions.Consume("call-c", 2, 4, VisitorActionKind.End, true),
              "Old release cleanup erased a replacement input identity");
        replacement = actions.Begin("call-b", 2, 3, VisitorActionKind.End);
        Check(!actions.Consume("call-b", 2, 4, VisitorActionKind.End, true),
              "Synchronous Click after capture loss ignored its original phase");
        actions.CompleteInput(replacement);
        Check(actions.Consume("call-b", 2, 4, VisitorActionKind.End, true),
              "Finished routed input blocked the next accessibility activation");

        var reviews = new SosReviewGuard();
        long old = reviews.Begin();
        reviews.Revoke();
        Check(!reviews.Consume(old, 1, 1, true), "Cancelled zero-second review triggered");
        old = reviews.Begin();
        long current = reviews.Begin();
        Check(!reviews.Consume(old, 1, 1, true), "Old review confirmed a replacement");
        Check(reviews.Consume(current, 1, 1, true), "Old callback revoked the current review");
        Check(!reviews.Consume(current, 1, 1, true), "Review was reusable");
        current = reviews.Begin();
        Check(!reviews.Consume(current, 1, 2, true), "Review reached replacement Core");
        current = reviews.Begin();
        Check(!reviews.Consume(current, 1, 1, false), "Detached, disabled or declined review triggered");
        current = reviews.Begin();
        Check(reviews.Consume(current, 2, 2, true), "Current confirmed review was blocked");
        Console.WriteLine("PASS: " + _assertions + " production visitor/SOS guard assertions; no WPF runtime or physical actions");
        return 0;
    }
}
