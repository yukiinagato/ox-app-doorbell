using System;
using System.Collections.Generic;
using DoorbellApp.Core;

internal static class PeerFrameGateTests
{
    private static int _assertions;
    private static void Check(bool condition, string message)
    {
        ++_assertions;
        if (!condition) throw new Exception(message);
    }
    private static CallTiming.Snapshot Snapshot(string id = "call/a", long core = 1,
                                               string owner = "owner-a", int revision = 2,
                                               string state = "in_call")
    {
        return new CallTiming.Snapshot { CoreGeneration = core, Document = new Dictionary<string, object> {
            { "active_calls", new object[] { new Dictionary<string, object> {
                { "door", "front" }, { "call_id", id }, { "dialog_owner", owner },
                { "stage_revision", revision }, { "state", state } } } } } };
    }
    public static void Main()
    {
        const string generation = "0123456789abcdef0123456789abcdef";
        var gate = new PeerFrameGate();
        var request = PeerFrameGate.Capture(Snapshot(), "front", "call/a", 7);
        Check(request != null, "current local in-call identity is available");
        Check(request.Query == "?door=front&call_id=call%2Fa&stage_revision=2", "identity query is encoded");
        Check(PeerFrameGate.Capture(Snapshot(), "back", "call/a", 7) == null, "wrong door is not eligible");
        Check(PeerFrameGate.Capture(Snapshot(), "front", "call/b", 7) == null, "global SIP state cannot choose another call");
        Check(PeerFrameGate.Capture(Snapshot(state: "ringing"), "front", "call/a", 7) == null, "ringing cannot display peer frames");
        Check(PeerFrameGate.Capture(Snapshot(owner: ""), "front", "call/a", 7) == null, "owner is required");
        Check(PeerFrameGate.Capture(Snapshot(revision: -1), "front", "call/a", 7) == null, "negative revisions are rejected");
        Check(gate.Accept(request, request, "call/a", "2", "owner-a", generation, "1"), "matching frame displays");
        Check(!gate.Accept(request, request, "call/a", "2", "owner-a", generation, "1"), "duplicate does not redisplay");
        Check(gate.Accept(request, request, "call/a", "2", "owner-a", generation, "3"), "new sequence displays");
        Check(!gate.Accept(request, request, "call/a", "2", "owner-a", generation, "2"), "out-of-order frame is rejected");
        foreach (var current in new[] {
            PeerFrameGate.Capture(Snapshot(id: "call/b"), "front", "call/b", 7),
            PeerFrameGate.Capture(Snapshot(core: 2), "front", "call/a", 7),
            PeerFrameGate.Capture(Snapshot(owner: "owner-b"), "front", "call/a", 7),
            PeerFrameGate.Capture(Snapshot(revision: 3), "front", "call/a", 7),
            PeerFrameGate.Capture(Snapshot(), "front", "call/a", 8), null })
            Check(!gate.Accept(request, current, "call/a", "2", "owner-a", generation, "4"),
                "retired call/core/owner/revision/view never paints a current view");
        Check(!gate.Accept(request, request, "call/b", "2", "owner-a", generation, "4"), "wrong response call is rejected");
        Check(!gate.Accept(request, request, "call/a", "3", "owner-a", generation, "4"), "wrong response revision is rejected");
        Check(!gate.Accept(request, request, "call/a", "2", "owner-b", generation, "4"), "wrong response owner is rejected");
        foreach (string sequence in new[] { "", "0", "01", "-1", "+1", " 4", "4.0", "9223372036854775808", "99999999999999999999" })
            Check(!gate.Accept(request, request, "call/a", "2", "owner-a", generation, sequence), "invalid decimal sequence is rejected");
        foreach (string invalid in new[] { "", "ABCDEF0123456789abcdef0123456789", generation + "0", "z123456789abcdef0123456789abcdef" })
            Check(!gate.Accept(request, request, "call/a", "2", "owner-a", invalid, "4"), "invalid generation is rejected");
        Check(gate.Accept(request, request, "call/a", "2", "owner-a", generation, "9223372036854775807"), "64-bit maximum remains exact");
        Check(gate.Accept(request, request, "call/a", "2", "owner-a", new string('b', 32), "1"), "renewed server generation can restart its sequence");
        gate.Reset();
        Check(gate.Accept(request, request, "call/a", "2", "owner-a", generation, "1"), "a new view starts with a clean cursor");
        Console.WriteLine("PeerFrameGate production cases: " + _assertions + " assertions PASS");
    }
}
