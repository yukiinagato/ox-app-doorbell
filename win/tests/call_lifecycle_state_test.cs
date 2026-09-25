using System;
using System.Diagnostics;
using DoorbellApp.Core;

internal static class CallLifecycleStateTest
{
    private static void Require(bool value, string message)
    {
        if (!value) throw new Exception(message);
    }

    private static void PendingThenOwnAnswerThenEnd()
    {
        var state = new CallLifecycleState();
        state.Reset();
        Require(!state.RecordAnswer(CallLifecycleReportResult.Pending), "pending is not rejection");
        Require(state.MayReportEnd, "pending answer may record a terminal end");
        state.ConfirmOwner(true);
        Require(state.MayReportEnd, "Core confirmation retains terminal eligibility");
        state.RecordEnd(CallLifecycleReportResult.Accepted);
        Require(state.Ended && !state.MayReportEnd, "accepted end is sent once");
    }

    private static void PendingThenEndThenOwnAnswer()
    {
        var state = new CallLifecycleState();
        state.Reset();
        state.RecordAnswer(CallLifecycleReportResult.Pending);
        state.RecordEnd(CallLifecycleReportResult.Pending);
        state.ConfirmOwner(true);
        Require(state.Ended, "late own confirmation cannot revive a terminal call");
        Require(!state.MayReportEnd, "late confirmation cannot send a duplicate end");
    }

    private static void DifferentOwnerNeverReportsTerminalEnd()
    {
        var state = new CallLifecycleState();
        state.Reset();
        state.RecordAnswer(CallLifecycleReportResult.Pending);
        Require(state.ConfirmOwner(false), "different owner is rejected locally");
        Require(!state.MayReportEnd, "losing owner cannot publish call_ended");
        Require(state.Ended, "losing SIP leg is terminal locally");
    }

    private static void PeerFramePortIsLocalAndBounded()
    {
        string url;
        Require(PeerFrameUrlBuilder.TryBuild(47180, "?door=d_front", out url) &&
            url == "http://127.0.0.1:47180/peer-frame.jpg?door=d_front",
            "default HTTP port remains supported");
        Require(PeerFrameUrlBuilder.TryBuild(48180, "?call_id=call-1", out url) &&
            url == "http://127.0.0.1:48180/peer-frame.jpg?call_id=call-1",
            "configured port is used with loopback only");
        Require(!PeerFrameUrlBuilder.TryBuild(0, "?door=d_front", out url) && url == null,
            "disabled HTTP port creates no URL");
        foreach (int invalid in new[] { -1, 65536 })
        {
            bool rejected = false;
            try { PeerFrameUrlBuilder.TryBuild(invalid, "", out url); }
            catch (ArgumentOutOfRangeException) { rejected = true; }
            Require(rejected, "out-of-range port must be rejected");
        }
    }

    private static void PeerFrameFreshnessTracksOnlyAcceptedFramesAndIdentity()
    {
        long now = 100;
        var gate = new PeerFrameGate(() => now);
        var a = new PeerFrameGate.Identity { Door = "d_a", CallId = "call-a", Owner = "owner-a",
            Revision = 2, CoreGeneration = 3, ViewGeneration = 4 };
        string generation = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        Require(gate.Accept(a, a, "call-a", "2", "owner-a", generation, "1"),
            "valid first frame is accepted");
        Require(gate.IsFresh(a), "valid frame begins its freshness window");
        now += Stopwatch.Frequency * 2500 / 1000;
        Require(!gate.Accept(a, a, "call-a", "2", "owner-a", generation, "1"),
            "duplicate sequence is rejected");
        now += Stopwatch.Frequency * 600 / 1000;
        Require(!gate.IsFresh(a), "duplicate sequence cannot extend freshness");

        var b = new PeerFrameGate.Identity { Door = "d_b", CallId = "call-b", Owner = "owner-b",
            Revision = 1, CoreGeneration = 5, ViewGeneration = 6 };
        Require(gate.Accept(b, b, "call-b", "1", "owner-b", generation, "1"),
            "a new call identity accepts its own sequence");
        Require(!gate.IsFresh(a) && gate.IsFresh(b),
            "an old identity expires without clearing a newer call");
        now += Stopwatch.Frequency * 3001 / 1000;
        Require(!gate.IsFresh(b), "a live stream with no new frames expires");
        Require(gate.Accept(b, b, "call-b", "1", "owner-b", generation, "2"),
            "a later valid sequence restores the frame");
        Require(gate.IsFresh(b), "recovery frame begins a new freshness window");
    }

    public static int Main()
    {
        PendingThenOwnAnswerThenEnd();
        PendingThenEndThenOwnAnswer();
        DifferentOwnerNeverReportsTerminalEnd();
        PeerFramePortIsLocalAndBounded();
        PeerFrameFreshnessTracksOnlyAcceptedFramesAndIdentity();
        Console.WriteLine("Windows pure contract tests: 5 passed");
        return 0;
    }
}
