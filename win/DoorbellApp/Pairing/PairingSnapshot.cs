using System;
using System.Collections;
using System.Collections.Generic;
using DoorbellApp.Util;

namespace DoorbellApp.Pairing
{
    /// <summary>One pending device as reported by core in pairing.pending.devices[].</summary>
    public sealed class PairingDevice
    {
        public string Id = "";
        public string Addr = "";
        public string Name = "";
        public string Role = "";
        public string Model = "";
        public string Platform = "";
        public string Sw = "";
        public string InviteState = "none";
        public string LastError = "";
        public int AgeS;
        public int Attempts;
    }

    /// <summary>
    /// Typed view of db_core_pairing_json. Shells render <see cref="State"/> and never infer it
    /// from paired/persistence_ready.
    /// </summary>
    public sealed class PairingSnapshot
    {
        public const string StateUnpaired = "unpaired";
        public const string StateJoining = "joining";
        public const string StatePersistError = "persist_error";
        public const string StateReady = "ready";
        public const string StateRevoked = "revoked";

        public bool Known;
        public string State = "";
        public bool IsFounder;
        public string Role = "";

        public string SelfId = "";
        public string SelfName = "";
        public string SelfAddr = "";
        public string SelfModel = "";
        public string SelfPlatform = "";
        public string SelfSw = "";
        public string PairQr = "";

        public int MemberCount;
        public int ConnectedCount;

        public bool TokenActive;
        public int TokenExpiresS;
        public int TokenAttemptsLeft;
        public string TokenHost = "";
        public string TokenPin = "";

        public bool PairingMode;
        public int PairingModeLeftS;
        public int AutoAddedCount;

        public readonly List<PairingDevice> Devices = new List<PairingDevice>();

        public bool IsReady { get { return State == StateReady; } }
        public bool IsUnpaired { get { return State == StateUnpaired; } }

        public static PairingSnapshot From(Dictionary<string, object> root)
        {
            var snapshot = new PairingSnapshot();
            if (root == null || root.Count == 0) return snapshot;
            snapshot.Known = root.ContainsKey("state");
            snapshot.State = Str(root, "state");
            snapshot.IsFounder = Bool(root, "is_founder");
            snapshot.Role = Str(root, "role");
            snapshot.PairQr = Str(root, "pair_qr");

            var self = Obj(root, "self");
            if (self != null)
            {
                snapshot.SelfId = Str(self, "id");
                snapshot.SelfName = Str(self, "name");
                snapshot.SelfAddr = Str(self, "addr");
                snapshot.SelfModel = Str(self, "model");
                snapshot.SelfPlatform = Str(self, "platform");
                snapshot.SelfSw = Str(self, "sw");
            }

            var home = Obj(root, "home");
            if (home != null)
            {
                snapshot.MemberCount = Int(home, "member_count", 0);
                snapshot.ConnectedCount = Int(home, "connected_count", 0);
            }

            var token = Obj(root, "token");
            if (token != null)
            {
                snapshot.TokenActive = Bool(token, "active");
                snapshot.TokenExpiresS = Int(token, "expires_s", 0);
                snapshot.TokenAttemptsLeft = Int(token, "attempts_left", 0);
                snapshot.TokenHost = Str(token, "host");
                snapshot.TokenPin = Str(token, "pin");
            }

            var pending = Obj(root, "pending");
            if (pending != null)
            {
                snapshot.PairingMode = Bool(pending, "pairing_mode");
                snapshot.PairingModeLeftS = Int(pending, "pairing_mode_left_s", 0);
                snapshot.AutoAddedCount = Int(pending, "auto_added_count", 0);
                object raw;
                if (pending.TryGetValue("devices", out raw) && raw is IEnumerable &&
                    !(raw is string))
                {
                    foreach (object item in (IEnumerable)raw)
                    {
                        var entry = item as Dictionary<string, object>;
                        if (entry == null) continue;
                        var device = new PairingDevice
                        {
                            Id = Str(entry, "id"),
                            Addr = Str(entry, "addr"),
                            Name = Str(entry, "name"),
                            Role = Str(entry, "role"),
                            Model = Str(entry, "model"),
                            Platform = Str(entry, "platform"),
                            Sw = Str(entry, "sw"),
                            InviteState = Str(entry, "invite_state"),
                            LastError = Str(entry, "last_error"),
                            AgeS = Int(entry, "age_s", 0),
                            Attempts = Int(entry, "attempts", 0),
                        };
                        if (!string.IsNullOrEmpty(device.Id)) snapshot.Devices.Add(device);
                    }
                }
            }
            return snapshot;
        }

        public static string Str(Dictionary<string, object> d, string key)
        {
            object value;
            return d != null && d.TryGetValue(key, out value) && value != null ?
                   value.ToString() : "";
        }

        public static bool Bool(Dictionary<string, object> d, string key)
        {
            object value;
            if (d == null || !d.TryGetValue(key, out value) || value == null) return false;
            if (value is bool) return (bool)value;
            string text = value.ToString();
            return text == "true" || text == "True" || text == "1";
        }

        public static int Int(Dictionary<string, object> d, string key, int fallback)
        {
            object value;
            int number;
            return d != null && d.TryGetValue(key, out value) && value != null &&
                   int.TryParse(value.ToString(), out number) ? number : fallback;
        }

        public static Dictionary<string, object> Obj(Dictionary<string, object> d, string key)
        {
            object value;
            return d != null && d.TryGetValue(key, out value) ?
                   value as Dictionary<string, object> : null;
        }
    }

    /// <summary>Shared presentation helpers for the pairing surfaces.</summary>
    public static class PairingText
    {
        /// <summary>Maps a core error code onto pair.err.*; never shows the raw code.</summary>
        public static string ErrorMessage(string code)
        {
            string key = string.IsNullOrEmpty(code) ? "unknown" : code.Trim();
            string message = Texts.T("pair.err." + key);
            // L10n returns the key itself when the resource is missing.
            if (message == "pair.err." + key) message = Texts.T("pair.err.unknown");
            return message;
        }

        /// <summary>The small details line carrying the raw code, empty when there is none.</summary>
        public static string ErrorDetail(string code)
        {
            return string.IsNullOrEmpty(code) ? "" : Texts.T("pair.err_detail", code);
        }

        public static string Countdown(int seconds)
        {
            if (seconds < 0) seconds = 0;
            return Texts.T("pair.code_expires_in", (seconds / 60).ToString(),
                           (seconds % 60).ToString("00"));
        }

        public static string AddAllOn(int seconds, int added)
        {
            if (seconds < 0) seconds = 0;
            return Texts.T("pair.add_all_on", (seconds / 60).ToString(),
                           (seconds % 60).ToString("00"), added.ToString());
        }

        /// <summary>Human row title: the device name, else model + a short id.</summary>
        public static string DisplayName(PairingDevice device)
        {
            if (device == null) return "";
            if (!string.IsNullOrEmpty(device.Name)) return device.Name;
            string id = device.Id ?? "";
            if (id.Length > 6) id = id.Substring(0, 6);
            string model = string.IsNullOrEmpty(device.Model) ? "" : device.Model + " ";
            return (model + id).Trim();
        }

        public static string RoleLabel(string role)
        {
            if (role == "indoor_panel") return Texts.T("admin.role_indoor");
            if (role == "door_station") return Texts.T("admin.role_door");
            return "";
        }

        /// <summary>Second row line: role, model/platform and software version.</summary>
        public static string Subtitle(PairingDevice device)
        {
            if (device == null) return "";
            var parts = new List<string>();
            string role = RoleLabel(device.Role);
            if (!string.IsNullOrEmpty(role)) parts.Add(role);
            string hardware = string.IsNullOrEmpty(device.Model) ? device.Platform :
                string.IsNullOrEmpty(device.Platform) ? device.Model :
                device.Model + " / " + device.Platform;
            if (!string.IsNullOrEmpty(hardware)) parts.Add(hardware);
            if (!string.IsNullOrEmpty(device.Sw)) parts.Add("v" + device.Sw);
            return string.Join(" · ", parts.ToArray());
        }

        /// <summary>"doorbell-pair:&lt;addr&gt;|&lt;id&gt;|&lt;pk&gt;" split into its three parts.</summary>
        public static bool TryParsePairPayload(string text, out string addr, out string id,
                                               out string publicKey)
        {
            addr = null;
            id = null;
            publicKey = null;
            const string prefix = "doorbell-pair:";
            if (string.IsNullOrEmpty(text) ||
                !text.StartsWith(prefix, StringComparison.Ordinal)) return false;
            string body = text.Substring(prefix.Length);
            int first = body.IndexOf('|');
            int last = body.LastIndexOf('|');
            if (first < 0 || last <= first) return false;
            addr = body.Substring(0, first);
            id = body.Substring(first + 1, last - first - 1);
            publicKey = body.Substring(last + 1);
            return addr.Length != 0 && publicKey.Length == 64;
        }
    }
}
