using System;
using DoorbellApp.Util;

internal static class UiTestModeTests
{
    private static int _assertions;

    private static void Check(bool value, string message)
    {
        ++_assertions;
        if (!value) throw new Exception(message);
    }

    public static int Main()
    {
        const string installed = @"C:\ProgramData\Doorbell\data";
        string[] full = { "--ui-test", "--data-dir", @"C:\DoorbellTest\run\data" };

        Check(UiTestMode.ResolveDataDir(full, "1", installed) == @"C:\DoorbellTest\run\data",
              "the complete request was refused");
        // Each of the three conditions is required on its own.
        Check(UiTestMode.ResolveDataDir(full, null, installed) == null, "no environment flag");
        Check(UiTestMode.ResolveDataDir(full, "0", installed) == null, "environment flag off");
        Check(UiTestMode.ResolveDataDir(full, "true", installed) == null, "flag must be exactly 1");
        Check(UiTestMode.ResolveDataDir(new[] { "--data-dir", @"C:\x" }, "1", installed) == null,
              "no switch");
        Check(UiTestMode.ResolveDataDir(new[] { "--ui-test" }, "1", installed) == null,
              "no data directory");
        Check(UiTestMode.ResolveDataDir(new[] { "--ui-test", "--data-dir" }, "1", installed) == null,
              "data directory switch without a value");
        Check(UiTestMode.ResolveDataDir(new[] { "--ui-test", "--data-dir", "  " }, "1", installed)
              == null, "blank data directory");
        Check(UiTestMode.ResolveDataDir(null, "1", installed) == null, "null arguments");
        // The installed data, in any spelling, and anything under the installed root is refused.
        foreach (string real in new[]
                 {
                     @"C:\ProgramData\Doorbell\data", @"c:\programdata\doorbell\DATA\",
                     @"C:/ProgramData/Doorbell/data", @"C:\ProgramData\Doorbell\data\sub",
                     @"C:\ProgramData\Doorbell", @"C:\ProgramData\Doorbell\service",
                 })
            Check(UiTestMode.ResolveDataDir(new[] { "--ui-test", "--data-dir", real }, "1",
                                            installed) == null, "installed data accepted: " + real);
        Check(UiTestMode.ResolveDataDir(
                  new[] { "--ui-test", "--data-dir", @"C:\ProgramData\DoorbellTest" }, "1",
                  installed) != null, "a sibling directory was refused");
        // The production switches alone never enable it.
        Check(UiTestMode.ResolveDataDir(new[] { "--supervised", "--safe-mode" }, "1", installed)
              == null, "production switches enabled test mode");

        string verb, argument;
        Check(UiTestMode.ParseCommand("appearance dark\r\n", out verb, out argument) &&
              verb == "appearance" && argument == "dark", "command with argument");
        Check(UiTestMode.ParseCommand("  INCALL ", out verb, out argument) &&
              verb == "incall" && argument == "", "bare command");
        Check(!UiTestMode.ParseCommand("  \n", out verb, out argument), "blank command");
        Check(!UiTestMode.ParseCommand(null, out verb, out argument), "null command");

        Console.WriteLine("Windows UI test mode tests: " + _assertions + " assertions passed");
        return 0;
    }
}
