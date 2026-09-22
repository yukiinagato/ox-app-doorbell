using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using DoorbellApp.Core;

internal static class CallTimingTests
{
    private static int _assertions;
    private static void Check(bool condition, string message)
    {
        ++_assertions;
        if (!condition) throw new Exception(message);
    }

    private static CallTiming.Snapshot Snapshot(string sample = "boot:1", long core = 1,
                                                double now = 1000, long duration = 60000)
    {
        var document = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(
            "{\"snapshot_generation\":\"" + sample + "\",\"snapshot_age_ms\":100," +
            "\"wall_ms\":1800000000000,\"active_calls\":[{\"call_id\":\"call-a\",\"door\":\"front\"," +
            "\"snapshot_generation\":\"" + sample + "\",\"state\":\"ringing\",\"stage_revision\":2," +
            "\"dialog_owner\":\"node-a\",\"remaining_ms\":" + duration + "," +
            "\"recovery_required\":true,\"recovery_eligible\":true,\"recovery_remaining_ms\":10000}]}");
        return new CallTiming.Snapshot { Document = document, CoreGeneration = core, RequestedAtMs = now };
    }

    private static Dictionary<string, object> Call(CallTiming.Snapshot snapshot)
    {
        foreach (var item in (System.Collections.IEnumerable)snapshot.Document["active_calls"])
            return (Dictionary<string, object>)item;
        return null;
    }

    private static void HostCases()
    {
        foreach (long wallOffset in new long[] { -300000, 0, 300000 })
        {
            var timing = new CallTiming();
            var snapshot = Snapshot();
            snapshot.Document["wall_ms"] = 1800000000000L + wallOffset;
            Call(snapshot)["expires_at_ms"] = 1800000060000L;
            Check(timing.Observe(snapshot, "call-a", 2000).RemainingMs == 58900,
                "raw wall-clock offset must not change the Core countdown");
            snapshot.RequestedAtMs = 11000;
            Check(timing.Observe(snapshot, "call-a", 11000).RemainingMs == 49900,
                "reading a cached duration again must not restart it");
            Check(timing.Observe(snapshot, "call-a", 100000).RemainingMs == 0,
                "zero is a display state; the call remains present");
        }
        var projector = new CallTiming();
        var valid = Snapshot();
        Check(projector.Observe(valid, "call-a", 1000).RecoveryRemainingMs == 9900, "age reduces recovery");
        Call(valid).Remove("remaining_ms");
        Check(!projector.Observe(valid, "call-a", 1000).RemainingMs.HasValue, "missing duration is unknown");
        Call(valid)["remaining_ms"] = true;
        Check(!projector.Observe(valid, "call-a", 1000).RemainingMs.HasValue, "booleans are not durations");
        Call(valid)["recovery_remaining_ms"] = 10001;
        Check(!projector.Observe(valid, "call-a", 1000).RecoveryRemainingMs.HasValue, "invalid recovery lease rejected");
        Call(valid)["snapshot_generation"] = "mixed";
        Check(projector.Observe(valid, "call-a", 1000) == null, "mixed snapshot rejected");
        valid = Snapshot();
        valid.Document["snapshot_age_ms"] = -1;
        Check(projector.Observe(valid, "call-a", 1000) == null, "unknown cache age rejected");
        valid = Snapshot();
        projector.RequireFresh(valid);
        Check(projector.Observe(valid, "call-a", 1000) == null, "resume rejects identical cached sample and age");
        Check(projector.Observe(valid, "call-a", 9000) == null, "elapsed foreground time does not bypass fresh sample barrier");
        Check(projector.Observe(Snapshot("boot:2"), "call-a", 1000) != null, "new sample unblocks resume");
        var noBaseline = new CallTiming();
        noBaseline.RequireFresh(null);
        Check(noBaseline.Observe(valid, "call-a", 1000) == null, "first unknown-baseline read only establishes baseline");
        Check(noBaseline.Observe(Snapshot("other:1", 2), "call-a", 1000) != null, "new Core generation unblocks");
        Check(!CallTiming.CallbackMatches(1, "call-a", 5, 1, "call-b", 6), "old call callback cannot touch new call");
        Check(!CallTiming.CallbackMatches(1, "call-a", 5, 2, "call-a", 5), "old Core callback rejected even for same call ID");
        Check(!CallTiming.CallbackMatches(1, "call-a", 5, 1, "call-a", 6), "old UI revision callback rejected");
        Check(CallTiming.CallbackMatches(2, "call-b", 6, 2, "call-b", 6), "current callback accepted");
        var recoveryTiming = new CallTiming();
        var owned = Snapshot();
        Call(owned)["origin"] = "node-a";
        Check(CallTiming.OwnedRecovery(Call(owned), "node-a", "door_station", "front"), "local recovery eligible candidate");
        Check(recoveryTiming.Observe(owned, "call-a", 1000).RecoveryRemainingMs == 9900, "initial recovery anchor");
        foreach (string foreignDoor in new[] { "back", "garage", "other" })
        {
            var foreign = Snapshot(); Call(foreign)["origin"] = "node-a"; Call(foreign)["door"] = foreignDoor;
            Check(!CallTiming.OwnedRecovery(Call(foreign), "node-a", "door_station", "front"), "foreign door filtered before projection");
            Call(foreign)["state"] = "in_call"; Call(foreign)["dialog_owner"] = "node-b";
            Check(!CallTiming.OwnedRecovery(Call(foreign), "node-a", "door_station", "front"), "foreign dialog owner filtered before projection");
        }
        owned.RequestedAtMs = 9000;
        Check(recoveryTiming.Observe(owned, "call-a", 9000).RecoveryRemainingMs == 1900, "unrelated candidates cannot restart same-sample recovery anchor");
        var large = Snapshot(duration: 9007199254740991L);
        Check(CallTiming.Milliseconds(Call(large), "remaining_ms") == 9007199254740991L, "64-bit JSON duration preserved");
        Call(large)["remaining_ms"] = 9007199254740992L;
        Check(!CallTiming.Milliseconds(Call(large), "remaining_ms").HasValue, "unsafe JSON integer rejected");
        Check(Marshal.SizeOf(typeof(CoreInterop.DbPlatformV2)) == 8 + 10 * IntPtr.Size, "existing ABI pointer-width layout preserved");
        Console.WriteLine("Host production C# timing and ABI declarations: PASS; runtime pointer width=" + IntPtr.Size);
    }

    private static void NativeCase()
    {
        var platform = new CoreInterop.DbPlatformV2 {
            struct_size = (uint)Marshal.SizeOf(typeof(CoreInterop.DbPlatformV2)), version = 2 };
        IntPtr core = CoreInterop.db_core_create_v2(ref platform, ":memory:",
            "{\"role\":\"door_station\",\"door\":\"front\",\"listen_port\":0,\"http_port\":0}");
        Check(core != IntPtr.Zero, "actual native ABI creates Core");
        try
        {
            Check(CoreInterop.db_core_start(core) == 0, "actual native Core starts");
            string id = CoreInterop.TakeUtf8(CoreInterop.db_core_press_v2(core, "front", ""));
            Check(!string.IsNullOrEmpty(id), "actual Core returns call identity");
            CallTiming.Reading reading = null;
            var timing = new CallTiming();
            for (int attempt = 0; attempt < 60; ++attempt)
            {
                double requested = CallTiming.MonotonicMs;
                string json = CoreInterop.TakeUtf8(CoreInterop.db_core_status_json(core));
                var snapshot = new CallTiming.Snapshot { CoreGeneration = 1, RequestedAtMs = requested,
                    Document = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json) };
                reading = timing.Observe(snapshot, id, CallTiming.MonotonicMs);
                if (reading != null && !reading.Absent && reading.RemainingMs.HasValue) break;
                Thread.Sleep(50);
            }
            Check(reading != null && !reading.Absent && reading.RemainingMs > 0,
                "production PInvoke status copy feeds production timing projection");
            Check(CoreInterop.db_core_cancel_call_v2(core, "front", id, "test") == 0, "test call cleans up");
            Console.WriteLine("Actual macOS native Core through unchanged production PInvoke: PASS; not Windows qualification");
        }
        finally { CoreInterop.db_core_stop(core); CoreInterop.db_core_destroy(core); }
    }

    public static int Main(string[] args)
    {
        try
        {
            HostCases();
            if (Array.IndexOf(args, "--native") >= 0) NativeCase();
            Console.WriteLine("Assertions: " + _assertions + " PASS");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
