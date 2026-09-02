using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace DoorbellApp
{
    public sealed class BootConfig
    {
        public string RawJson = "{}";
        public string Name = "doorbell";
        public string Role = "door_station";
        public string Door = "";
        public string UiLang = "ja";
        public string PskRef = "";
        public bool Kiosk = true;
        public int HttpPort = 47180;
        public string FilePath;
        public bool SetupRequired;
        public string SuggestedDoor;

        private const string DefaultJson =
            "{ \"name\": \"doorbell-win\", \"role\": \"door_station\", \"door\": \"\", " +
            "\"listen_port\": 47172, \"http_port\": 47180, \"ui_lang\": \"ja\", " +
            "\"kiosk\": false, \"setup_complete\": false }";

        public static BootConfig Load(string path)
        {
            var c = new BootConfig();
            c.FilePath = path;
            string primary = ReadValidJson(path);
            string backup = ReadValidJson(path + ".bak");
            c.RawJson = primary ?? backup ?? DefaultJsonWithSuggestedDoor();
            if (primary == null) WriteAtomic(path, c.RawJson);
            // A readable legacy profile is not proof that an operator confirmed
            // its local identity. Require the explicit marker after an upgrade.
            bool setupComplete = false;
            try
            {
                var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(c.RawJson);
                if (d != null)
                {
                    if (d.TryGetValue("name", out var n) && n != null) c.Name = n.ToString();
                    if (d.TryGetValue("role", out var ro) && ro != null) c.Role = ro.ToString();
                    if (d.TryGetValue("door", out var dr) && dr != null) c.Door = dr.ToString();
                    if (d.TryGetValue("ui_lang", out var l) && l != null) c.UiLang = l.ToString();
                    if (d.TryGetValue("psk_ref", out var pr) && pr != null) c.PskRef = pr.ToString();
                    if (d.TryGetValue("kiosk", out var k) && k is bool kb) c.Kiosk = kb;
                    if (d.TryGetValue("setup_complete", out var setup) && setup is bool sb)
                        setupComplete = sb;
                    if (d.TryGetValue("http_port", out var hp) && hp != null)
                    {
                        int p;
                        if (int.TryParse(hp.ToString(), out p) && p > 0) c.HttpPort = p;
                    }
                }
            }
            catch { }
            c.SuggestedDoor = ValidDoor(c.Door) ? c.Door : SuggestedDoorId();
            c.SetupRequired = !setupComplete || !ValidRole(c.Role) ||
                              (c.Role == "door_station" && !ValidDoor(c.Door));
            return c;
        }

        public static bool ValidRole(string value)
        {
            return value == "door_station" || value == "indoor_panel";
        }

        public static bool ValidDoor(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 64) return false;
            char first = value[0];
            if (!((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') ||
                  (first >= '0' && first <= '9'))) return false;
            for (int i = 0; i < value.Length; ++i)
            {
                char ch = value[i];
                if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                      (ch >= '0' && ch <= '9') || ch == '_' || ch == '-')) return false;
            }
            return true;
        }

        private static string SuggestedDoorId()
        {
            byte[] bytes = new byte[4];
            using (var random = RandomNumberGenerator.Create()) random.GetBytes(bytes);
            var text = new StringBuilder("door-");
            foreach (byte value in bytes) text.Append(value.ToString("x2"));
            return text.ToString();
        }

        private static string DefaultJsonWithSuggestedDoor()
        {
            try
            {
                var json = new JavaScriptSerializer();
                var data = json.Deserialize<Dictionary<string, object>>(DefaultJson) ??
                           new Dictionary<string, object>();
                data["door"] = SuggestedDoorId();
                return json.Serialize(data);
            }
            catch { return DefaultJson; }
        }

        public static BootConfig PersistSetup(string path, string name, string role, string door)
        {
            role = (role ?? "").Trim();
            door = (door ?? "").Trim();
            if (!ValidRole(role) || (role == "door_station" && !ValidDoor(door))) return null;
            name = (name ?? "").Trim();
            if (name.Length > 64) name = name.Substring(0, 64);
            if (name.Length == 0) name = "doorbell";
            string current = ReadValidJson(path) ?? ReadValidJson(path + ".bak") ?? DefaultJson;
            try
            {
                var json = new JavaScriptSerializer();
                var data = json.Deserialize<Dictionary<string, object>>(current) ??
                           new Dictionary<string, object>();
                data["name"] = name;
                data["role"] = role;
                data["door"] = role == "door_station" ? door : "";
                data["setup_complete"] = true;
                return WriteAtomic(path, json.Serialize(data)) ? Load(path) : null;
            }
            catch { return null; }
        }

        /// <summary>Pairing PSK/seeds are crash-safely persisted for the next process start.</summary>
        public static string PersistPairingReference(string path, IEnumerable<string> seeds)
        {
            string current = ReadValidJson(path) ?? ReadValidJson(path + ".bak") ?? DefaultJson;
            try
            {
                var json = new JavaScriptSerializer();
                var data = json.Deserialize<Dictionary<string, object>>(current) ??
                           new Dictionary<string, object>();
                data.Remove("psk_hex");
                data["psk_ref"] = "secret:mesh.psk";
                var merged = new List<string>();
                object existing;
                if (data.TryGetValue("seed_peers", out existing) &&
                    existing is System.Collections.IEnumerable && !(existing is string))
                    foreach (object value in (System.Collections.IEnumerable)existing)
                        AddUnique(merged, value == null ? null : value.ToString());
                if (seeds != null) foreach (string seed in seeds) AddUnique(merged, seed);
                if (merged.Count != 0) data["seed_peers"] = merged;
                string output = json.Serialize(data);
                return WritePairingGenerations(path, output) ? output : null;
            }
            catch { return null; }
        }

        /// <summary>Drops the pairing reference and seeds after unpair/revoke.</summary>
        public static bool ClearPairingReference(string path)
        {
            string current = ReadValidJson(path) ?? ReadValidJson(path + ".bak") ?? DefaultJson;
            try
            {
                var json = new JavaScriptSerializer();
                var data = json.Deserialize<Dictionary<string, object>>(current) ??
                           new Dictionary<string, object>();
                data.Remove("psk_hex");
                data.Remove("psk_ref");
                data.Remove("seed_peers");
                return WritePairingGenerations(path, json.Serialize(data));
            }
            catch { return false; }
        }

        /// <summary>
        /// Revoke and device-side "leave the Cluster" are a factory reset of this device's
        /// identity (spec 5.4): the pairing reference, the discovery seeds, and the operator's own
        /// name/role/door confirmation all go, so the next start lands in first-run setup.
        /// </summary>
        public static bool ResetToFactory(string path)
        {
            try
            {
                var json = new JavaScriptSerializer();
                var current = json.Deserialize<Dictionary<string, object>>(
                    ReadValidJson(path) ?? ReadValidJson(path + ".bak") ?? DefaultJson) ??
                    new Dictionary<string, object>();
                var data = new Dictionary<string, object>();
                // Only transport-level bootstrap survives; nothing that identifies this device or
                // its Cluster does.
                foreach (string keep in new[] { "listen_port", "http_port", "ui_lang", "kiosk" })
                {
                    object value;
                    if (current.TryGetValue(keep, out value) && value != null) data[keep] = value;
                }
                data["name"] = "doorbell";
                data["role"] = "";
                data["door"] = SuggestedDoorId();
                data["setup_complete"] = false;
                return WritePairingGenerations(path, json.Serialize(data));
            }
            catch { return false; }
        }

        private static void AddUnique(List<string> values, string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return;
            value = value.Trim();
            if (!values.Contains(value)) values.Add(value);
        }

        private static string ReadValidJson(string path)
        {
            try
            {
                if (!File.Exists(path)) return null;
                string text = File.ReadAllText(path, Encoding.UTF8);
                var parsed = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(text);
                return parsed == null ? null : text;
            }
            catch { return null; }
        }

        private static bool WriteAtomic(string path, string value)
        {
            string temporary = path + ".tmp";
            try
            {
                string directory = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                WriteGeneration(path, value);
                return true;
            }
            catch
            {
                try { File.Delete(temporary); } catch { }
                return false;
            }
        }

        private static bool WritePairingGenerations(string path, string value)
        {
            try
            {
                string directory = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                // Both recoverable generations must contain the scrubbed secret reference.
                WriteGeneration(path + ".bak", value);
                WriteGeneration(path, value);
                return true;
            }
            catch
            {
                try { File.Delete(path + ".tmp"); } catch { }
                try { File.Delete(path + ".bak.tmp"); } catch { }
                return false;
            }
        }

        private static void WriteGeneration(string target, string value)
        {
            string temporary = target + ".tmp";
            byte[] bytes = Encoding.UTF8.GetBytes(value);
            using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write,
                                               FileShare.None, 4096, FileOptions.WriteThrough))
            {
                output.Write(bytes, 0, bytes.Length);
                output.Flush(true);
            }
            if (File.Exists(target)) File.Replace(temporary, target, null, true);
            else File.Move(temporary, target);
        }
    }
}
