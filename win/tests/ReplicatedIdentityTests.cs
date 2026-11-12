using System;
using DoorbellApp.Util;

internal static class ReplicatedIdentityTests
{
    private static int _assertions;

    private static void Check(bool value, string message)
    {
        ++_assertions;
        if (!value) throw new Exception(message);
    }

    public static int Main()
    {
        // Nothing replicated yet (fresh or unpaired device): never applied.
        Check(!ReplicatedIdentity.Decide("panel", "indoor_panel", "", "", "", "", false, false).Apply,
              "an absent record was applied");
        // The same identity is not a change.
        Check(!ReplicatedIdentity.Decide("panel", "indoor_panel", "", "panel", "indoor_panel", "",
                                         true, false).Apply, "an identical identity was applied");
        Check(!ReplicatedIdentity.Decide("gate", "door_station", "door-a", "gate", "door_station",
                                         "door-a", true, true).Apply, "an identical door was applied");
        // Indoor to door needs a valid door.
        var toDoor = ReplicatedIdentity.Decide("panel", "indoor_panel", "", "panel", "door_station",
                                               "door-a", true, true);
        Check(toDoor.Apply && toDoor.Role == "door_station" && toDoor.Door == "door-a",
              "indoor to door was not applied");
        Check(!ReplicatedIdentity.Decide("panel", "indoor_panel", "", "panel", "door_station", "",
                                         true, false).Apply, "a door station without a door was applied");
        // Door to indoor clears the door whatever the record still carries.
        var toIndoor = ReplicatedIdentity.Decide("gate", "door_station", "door-a", "gate",
                                                 "indoor_panel", "door-a", true, true);
        Check(toIndoor.Apply && toIndoor.Role == "indoor_panel" && toIndoor.Door == "",
              "door to indoor kept the door");
        // A stale door on an indoor record is not a difference by itself.
        Check(!ReplicatedIdentity.Decide("panel", "indoor_panel", "", "panel", "indoor_panel",
                                         "door-old", true, true).Apply, "a stale door forced a restart");
        // Unknown roles are refused.
        Check(!ReplicatedIdentity.Decide("panel", "indoor_panel", "", "panel", "monitor", "",
                                         false, false).Apply, "an unknown role was applied");
        // A rename alone applies; an empty name keeps the booted one.
        var renamed = ReplicatedIdentity.Decide("panel", "indoor_panel", "", " Hall ", "indoor_panel",
                                                "", true, false);
        Check(renamed.Apply && renamed.Name == "Hall", "a rename was not applied");
        Check(!ReplicatedIdentity.Decide("panel", "indoor_panel", "", "  ", "indoor_panel", "",
                                         true, false).Apply, "an empty name forced a restart");
        // Moving a door station to another door applies.
        var moved = ReplicatedIdentity.Decide("gate", "door_station", "door-a", "gate",
                                              "door_station", "door-b", true, true);
        Check(moved.Apply && moved.Door == "door-b", "a door move was not applied");
        Check(ReplicatedIdentity.Signature("a", "indoor_panel", "") !=
              ReplicatedIdentity.Signature("a", "door_station", ""), "signatures collide");

        Console.WriteLine("Windows replicated identity tests: " + _assertions + " assertions passed");
        return 0;
    }
}
