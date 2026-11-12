using System;
using DoorbellApp.Util;

internal static class RoleContrastTests
{
    private static int _assertions;

    private static void Check(bool value, string message)
    {
        ++_assertions;
        if (!value) throw new Exception(message);
    }

    public static int Main()
    {
        Check(Math.Abs(RoleContrast.Ratio(0x000000, 0xFFFFFF) - 21.0) < 0.01, "black on white is 21:1");
        Check(Math.Abs(RoleContrast.Ratio(0x777777, 0x777777) - 1.0) < 1e-9, "same colour is 1:1");
        Check(RoleContrast.Over(0xFFFFFF, 0.2, 0x2B2B2B) == 0x555555, "20% white over the dark card");
        Check(RoleContrast.Over(0x000000, 1.0, 0xFFFFFF) == 0x000000, "opaque replaces");

        // The complaint that started this: the dark negative fill colour as text on a dark
        // surface is unreadable, and the dedicated text colour is not.
        Check(RoleContrast.Ratio(0xC0392B, 0x2B2B2B) < RoleContrast.TextMinimum, "the fill colour fails as text");
        Check(RoleContrast.Ratio(0xFF99A4, 0x2B2B2B) >= RoleContrast.TextMinimum, "the text colour reads on the card");
        Check(RoleContrast.Ratio(0xFF99A4, 0x000000) >= RoleContrast.TextMinimum, "the text colour reads on the page");

        // An accent that already reads is left alone; one that does not keeps its hue family
        // and is moved until it does, on both kinds of surface.
        Check(RoleContrast.EnsureReadable(0xFFFFFF, 0x000000, 4.5) == 0xFFFFFF, "readable accent changed");
        foreach (int accent in new[] { 0x0078D4, 0x8A5A00, 0x744DA9, 0x107C10, 0xE81123, 0x000000,
                                       0xFFFFFF, 0x808080 })
        {
            foreach (int surface in new[] { 0x000000, 0x2B2B2B, 0xFFFFFF, 0xF2F2F2 })
            {
                int text = RoleContrast.EnsureReadable(accent, surface, RoleContrast.TextMinimum);
                Check(RoleContrast.Ratio(text, surface) >= RoleContrast.TextMinimum,
                      "accent " + accent.ToString("X6") + " unreadable on " + surface.ToString("X6"));
            }
        }
        int lifted = RoleContrast.EnsureReadable(0x0078D4, 0x2B2B2B, 4.5);
        Check((lifted & 0xFF) >= ((lifted >> 16) & 0xFF), "the lifted blue is still blue-dominant");

        Console.WriteLine("Windows role contrast tests: " + _assertions + " assertions passed");
        return 0;
    }
}
