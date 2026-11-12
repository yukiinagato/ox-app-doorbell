using System;
using DoorbellApp.Settings;

internal static class TimeSettingsTests
{
    private static int _assertions;

    private static void Check(bool value, string message)
    {
        ++_assertions;
        if (!value) throw new Exception(message);
    }

    public static int Main()
    {
        Check(TimeSettings.Zones.Length > 90, "the zone table is too short");
        Check(Array.IndexOf(TimeSettings.Zones, "Asia/Tokyo") >= 0, "Asia/Tokyo is missing");
        Check(Array.IndexOf(TimeSettings.Zones, "UTC") == 0, "UTC is not first");

        var one = TimeSettings.ParseNtpServers("ntp.nict.jp");
        Check(one != null && one.Count == 1 && one[0] == "ntp.nict.jp", "one host");
        var mixed = TimeSettings.ParseNtpServers(" ntp.nict.jp, time.google.com:123\n10.0.0.1 ");
        Check(mixed != null && mixed.Count == 3 && mixed[1] == "time.google.com:123", "list with a port");
        Check(TimeSettings.ParseNtpServers("[2001:db8::1]:123") != null, "bracketed IPv6 with a port");
        Check(TimeSettings.ParseNtpServers("2001:db8::1") != null, "bare IPv6");
        var twice = TimeSettings.ParseNtpServers("a.example, a.example");
        Check(twice != null && twice.Count == 1, "duplicates collapse");
        // Refused: empty, more than four, bad characters, bad ports.
        Check(TimeSettings.ParseNtpServers("") == null, "empty list");
        Check(TimeSettings.ParseNtpServers("  ,\n ") == null, "blank list");
        Check(TimeSettings.ParseNtpServers("a,b,c,d,e") == null, "five servers");
        Check(TimeSettings.ParseNtpServers("a,b,c,d") != null, "four servers");
        Check(TimeSettings.ParseNtpServers("https://ntp.example") == null, "a URL");
        Check(TimeSettings.ParseNtpServers("ntp.example:0") == null, "port 0");
        Check(TimeSettings.ParseNtpServers("ntp.example:65536") == null, "port 65536");
        Check(TimeSettings.ParseNtpServers("ntp.example:abc") == null, "non-numeric port");
        Check(TimeSettings.ParseNtpServers("ntp exa$mple") == null, "bad character");
        Check(TimeSettings.ParseNtpServers(null) == null, "null");

        Console.WriteLine("Windows time settings tests: " + _assertions + " assertions passed");
        return 0;
    }
}
