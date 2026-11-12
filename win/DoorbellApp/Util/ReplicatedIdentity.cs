namespace DoorbellApp.Util
{
    /// <summary>
    /// Decides whether the replicated desired identity (<c>devices.&lt;self&gt;.name/.role/.door</c>,
    /// editable from the web Admin or another device) differs from what this device booted with
    /// and may be applied. Applying means: persist boot.json, then restart, because Core reads
    /// role and door once at start. It has no WPF dependency so the rule is tested on the host.
    /// </summary>
    internal static class ReplicatedIdentity
    {
        public sealed class Decision
        {
            public bool Apply;
            public string Name, Role, Door;
        }

        /// <summary>
        /// <paramref name="roleValid"/> and <paramref name="doorValid"/> are the boot validators'
        /// answers for the replicated role and door. An absent or invalid record is never
        /// applied; an indoor panel always ends with an empty door; an empty replicated name
        /// keeps the booted one.
        /// </summary>
        public static Decision Decide(string bootName, string bootRole, string bootDoor,
                                      string name, string role, string door,
                                      bool roleValid, bool doorValid)
        {
            var decision = new Decision
            {
                Name = bootName ?? "", Role = bootRole ?? "", Door = bootDoor ?? "",
            };
            if (string.IsNullOrEmpty(role) || !roleValid) return decision;
            if (role == "door_station" && !doorValid) return decision;
            string wantedName = string.IsNullOrWhiteSpace(name) ? decision.Name : name.Trim();
            string wantedDoor = role == "door_station" ? (door ?? "") : "";
            if (wantedName == decision.Name && role == decision.Role && wantedDoor == decision.Door)
                return decision;
            decision.Apply = true;
            decision.Name = wantedName;
            decision.Role = role;
            decision.Door = wantedDoor;
            return decision;
        }

        /// <summary>One line that identifies an identity, for the repeat guard.</summary>
        public static string Signature(string name, string role, string door)
        {
            return (role ?? "") + "\n" + (door ?? "") + "\n" + (name ?? "");
        }
    }
}
