using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace DoorbellApp
{
    internal sealed class RuntimeProcessSnapshot
    {
        public long Generation;
        public string LastExitReason;
        public bool StatePersisted;
    }

    internal sealed class RuntimeProcessState
    {
        private const long MaxGeneration = 9000000000000000L;
        private const int MaxStateBytes = 32 * 1024;
        private readonly object _gate = new object();
        private readonly string _path;
        private long _generation;
        private string _lastExitReason;
        private bool _sessionOpen;
        private bool _statePersisted;

        private RuntimeProcessState(string path)
        {
            _path = path;
            bool valid;
            Dictionary<string, object> stored = Load(path, out valid);
            long previous = Number(stored, "generation");
            _generation = previous >= 0 && previous < MaxGeneration ? previous + 1 : 1;
            bool previousOpen = Boolean(stored, "session_open");
            string previousReason = Text(stored, "last_exit_reason");
            _lastExitReason = previousOpen ? "unexpected_termination" :
                (string.IsNullOrEmpty(previousReason) ?
                    (valid ? "first_launch" : "state_unavailable") : previousReason);
            _lastExitReason = RuntimeToken(_lastExitReason);
            _sessionOpen = true;
            _statePersisted = Persist();
        }

        public static RuntimeProcessState Begin(string path) => new RuntimeProcessState(path);

        public RuntimeProcessSnapshot Snapshot()
        {
            lock (_gate)
                return new RuntimeProcessSnapshot
                {
                    Generation = _generation,
                    LastExitReason = _lastExitReason,
                    StatePersisted = _statePersisted,
                };
        }

        public void RecordExit(string reason)
        {
            lock (_gate)
            {
                if (!_sessionOpen) return;
                _lastExitReason = RuntimeToken(reason);
                _sessionOpen = false;
                _statePersisted = Persist();
            }
        }

        internal static string RuntimeToken(string value)
        {
            if (string.IsNullOrEmpty(value)) return "unknown";
            var output = new StringBuilder(Math.Min(value.Length, 128));
            for (int index = 0; index < value.Length && output.Length < 128; index++)
            {
                char character = value[index];
                bool valid = character < 128 &&
                    ((character >= 'a' && character <= 'z') ||
                     (character >= 'A' && character <= 'Z') ||
                     (character >= '0' && character <= '9') ||
                     character == '_' || character == '-' || character == '.' ||
                     character == ':');
                output.Append(valid ? character : '_');
            }
            return output.Length == 0 ? "unknown" : output.ToString();
        }

        private bool Persist()
        {
            string temporary = _path + ".tmp";
            try
            {
                string directory = Path.GetDirectoryName(_path);
                if (string.IsNullOrEmpty(directory)) return false;
                Directory.CreateDirectory(directory);
                var data = new Dictionary<string, object>
                {
                    { "schema_version", 1 },
                    { "generation", _generation },
                    { "last_exit_reason", _lastExitReason },
                    { "session_open", _sessionOpen },
                };
                byte[] bytes = new UTF8Encoding(false).GetBytes(
                    new JavaScriptSerializer().Serialize(data));
                using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write,
                                                   FileShare.None, 4096,
                                                   FileOptions.WriteThrough))
                {
                    output.Write(bytes, 0, bytes.Length);
                    output.Flush(true);
                }
                if (File.Exists(_path)) File.Replace(temporary, _path, null, true);
                else File.Move(temporary, _path);
                return true;
            }
            catch
            {
                try { File.Delete(temporary); } catch { }
                return false;
            }
        }

        private static Dictionary<string, object> Load(string path, out bool valid)
        {
            valid = !File.Exists(path);
            try
            {
                var info = new FileInfo(path);
                if (!info.Exists) return new Dictionary<string, object>();
                if (info.Length <= 0 || info.Length > MaxStateBytes)
                    return new Dictionary<string, object>();
                var value = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(
                    File.ReadAllText(path, Encoding.UTF8));
                if (Number(value, "schema_version") != 1)
                    return new Dictionary<string, object>();
                valid = true;
                return value;
            }
            catch { return new Dictionary<string, object>(); }
        }

        private static long Number(Dictionary<string, object> value, string key)
        {
            object raw;
            if (value == null || !value.TryGetValue(key, out raw) || raw == null) return 0;
            try { return Convert.ToInt64(raw); } catch { return 0; }
        }

        private static bool Boolean(Dictionary<string, object> value, string key)
        {
            object raw;
            return value != null && value.TryGetValue(key, out raw) && raw is bool && (bool)raw;
        }

        private static string Text(Dictionary<string, object> value, string key)
        {
            object raw;
            return value != null && value.TryGetValue(key, out raw) && raw is string
                ? RuntimeToken((string)raw) : "";
        }
    }
}
