using System;
using System.Collections.Generic;
using System.Threading;
using DoorbellApp.Settings;

internal static class SettingsWriteTests
{
    private static int _assertions;

    private static void Check(bool value, string message)
    {
        ++_assertions;
        if (!value) throw new Exception(message);
    }

    public static int Main()
    {
        var steps = new StepAccumulator(30, 5, 300, 5);
        Check(!steps.Dirty, "starts clean");
        steps.Set(steps.Shown + 5);
        steps.Set(steps.Shown + 5);
        steps.Set(steps.Shown + 5);
        Check(steps.Shown == 45 && steps.Committed == 30 && steps.Dirty, "clicks accumulate on the shown value");
        steps.Succeeded(45);
        Check(!steps.Dirty && steps.Committed == 45, "a written value becomes the committed one");
        Check(steps.Set(1000) == 300, "clamped to the maximum");
        Check(steps.Set(-4) == 5, "clamped to the minimum");
        Check(steps.Set(52) == 50, "snapped to the step");
        Check(steps.Failed() == 45 && !steps.Dirty, "a refused write restores the committed value");

        var order = new List<int>();
        var done = new ManualResetEvent(false);
        using (var lane = new WriteLane())
        {
            for (int i = 0; i < 50; i++)
            {
                int n = i;
                lane.Run(() => { order.Add(n); if (n == 49) done.Set(); });
            }
            lane.Run(() => { throw new InvalidOperationException("one failing write must not stop the lane"); });
            var after = new ManualResetEvent(false);
            lane.Run(() => after.Set());
            Check(done.WaitOne(5000), "the lane ran every write");
            Check(after.WaitOne(5000), "the lane survives a failing write");
        }
        bool ordered = order.Count == 50;
        for (int i = 0; ordered && i < order.Count; i++) ordered = order[i] == i;
        Check(ordered, "writes run in submission order");

        Console.WriteLine("Windows settings write tests: " + _assertions + " assertions passed");
        return 0;
    }
}
