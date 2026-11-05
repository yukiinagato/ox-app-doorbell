using System;
using System.Collections;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using DoorbellApp.Core;

namespace DoorbellApp.Settings
{
    /// <summary>Outcome of one settings write.</summary>
    internal sealed class SettingsWriteResult
    {
        public bool Ok;
        public string Error = "";
        public string Warnings = "";
    }

    /// <summary>
    /// Reads and writes configuration for the settings window. Every write is one
    /// db_core_config_batch_json commit (CoreClient.ConfigBatchJson), the same validated, atomic
    /// path as the web admin's /api/config/batch; a closed native admin window is answered by
    /// CoreClient's admin prompt and one retry. Keys beginning with "boot:" are fields of this
    /// device's boot.json rather than replicated configuration.
    /// </summary>
    internal sealed class SettingsStore
    {
        public const string BootPrefix = "boot:";
        private readonly JavaScriptSerializer _json = new JavaScriptSerializer();
        private Dictionary<string, object> _config = new Dictionary<string, object>();

        public SettingsContext Context { get; private set; }

        public SettingsStore(string nodeId, string role)
        {
            Context = new SettingsContext { NodeId = nodeId ?? "", Role = role ?? "" };
            Reload();
        }

        public void Reload()
        {
            _config = (App.Core == null ? null : App.Core.Config()) ??
                      new Dictionary<string, object>();
        }

        public string Resolve(string key)
        {
            return key == null ? null : key.Replace("{self}", Context.NodeId);
        }

        public object Get(string key)
        {
            if (string.IsNullOrEmpty(key)) return null;
            if (key.StartsWith(BootPrefix, StringComparison.Ordinal)) return BootValue(key);
            return CoreClient.Dig(_config, Resolve(key));
        }

        /// <summary>The configured value, or the documented default when nothing is set.</summary>
        public object Effective(SettingItem item)
        {
            object value = Get(item.Key);
            return value ?? item.Default;
        }

        private static object BootValue(string key)
        {
            if (App.Boot == null) return null;
            switch (key.Substring(BootPrefix.Length))
            {
                case "kiosk": return App.Boot.Kiosk;
                case "ui_lang": return App.Boot.UiLang;
                default: return null;
            }
        }

        public SettingsWriteResult Set(string key, object value)
        {
            return Commit(new List<KeyValuePair<string, object>>
            {
                new KeyValuePair<string, object>(key, value),
            }, null);
        }

        public SettingsWriteResult Delete(params string[] keys)
        {
            return Commit(null, keys);
        }

        /// <summary>
        /// Commits sets and deletes as one atomic batch. A null value in a set is written as JSON
        /// null; use deletes to remove a key.
        /// </summary>
        public SettingsWriteResult Commit(IList<KeyValuePair<string, object>> sets,
                                          IList<string> deletes)
        {
            var result = new SettingsWriteResult();
            var ops = new List<object>();
            if (sets != null)
                foreach (var pair in sets)
                    ops.Add(new Dictionary<string, object>
                    {
                        { "op", "set" }, { "key", Resolve(pair.Key) }, { "value", pair.Value },
                    });
            if (deletes != null)
                foreach (string key in deletes)
                    ops.Add(new Dictionary<string, object>
                    {
                        { "op", "delete" }, { "key", Resolve(key) },
                    });
            if (ops.Count == 0)
            {
                result.Ok = true;
                return result;
            }
            if (App.Core == null)
            {
                result.Error = "core_unavailable";
                return result;
            }
            string body = _json.Serialize(new Dictionary<string, object> { { "ops", ops } });
            string answer = App.Core.ConfigBatchJson(body);
            if (answer == null)
            {
                result.Error = "core_unavailable";
                return result;
            }
            Dictionary<string, object> doc = null;
            try { doc = _json.Deserialize<Dictionary<string, object>>(answer); }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            object ok;
            result.Ok = doc != null && doc.TryGetValue("ok", out ok) && ok is bool && (bool)ok;
            if (!result.Ok)
            {
                object err;
                result.Error = doc != null && doc.TryGetValue("err", out err) && err != null
                    ? err.ToString() : "rejected";
            }
            object warnings;
            if (doc != null && doc.TryGetValue("warnings", out warnings) &&
                warnings is IEnumerable && !(warnings is string))
            {
                var parts = new List<string>();
                // {"key","property","contrast","message_key"}: advisory, the write succeeded.
                foreach (object w in (IEnumerable)warnings)
                {
                    var entry = w as Dictionary<string, object>;
                    if (entry == null) continue;
                    object messageKey, contrast;
                    string text = entry.TryGetValue("message_key", out messageKey) && messageKey != null
                        ? DoorbellApp.Util.Texts.T(messageKey.ToString()) : "";
                    if (entry.TryGetValue("contrast", out contrast) && contrast != null)
                        text += " (" + Convert.ToString(contrast,
                            System.Globalization.CultureInfo.InvariantCulture) + ":1)";
                    if (text.Length > 0) parts.Add(text);
                }
                result.Warnings = string.Join("; ", parts);
            }
            Reload();
            return result;
        }

        public static bool AsBool(object value, bool fallback)
        {
            if (value is bool) return (bool)value;
            if (value == null) return fallback;
            string text = value.ToString();
            if (text == "true" || text == "1") return true;
            if (text == "false" || text == "0") return false;
            return fallback;
        }

        public static double AsNumber(object value, double fallback)
        {
            if (value == null) return fallback;
            double number;
            return double.TryParse(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture),
                System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture,
                out number) ? number : fallback;
        }

        /// <summary>Numbers are written as integers when the step is whole, as Core expects.</summary>
        public static object NumberValue(double value, double step)
        {
            if (Math.Abs(step - Math.Round(step)) < 1e-9) return (long)Math.Round(value);
            return Math.Round(value, 3);
        }

        public static List<string> AsStringList(object value)
        {
            var list = new List<string>();
            var items = value as IEnumerable;
            if (items == null || value is string) return list;
            foreach (object entry in items)
                if (entry != null) list.Add(entry.ToString());
            return list;
        }
    }
}
