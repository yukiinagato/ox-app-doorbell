using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using DoorbellApp.Core;
using DoorbellApp.Pairing;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // Native editors that talk to Core services beyond the config batch: the asset ledger, the
    // wording overrides, the playback policy, Web panel identities, configuration export and
    // import, software update, cluster rebuild and the administrator password.
    internal sealed partial class SettingsWindow
    {
        // ---- asset ledger ------------------------------------------------------------------------

        private List<KeyValuePair<string, Dictionary<string, object>>> AssetList(string typePrefix)
        {
            var list = new List<KeyValuePair<string, Dictionary<string, object>>>();
            foreach (var pair in ReadRecords("assets"))
                if (typePrefix == null || Str(pair.Value, "type").StartsWith(typePrefix, StringComparison.Ordinal))
                    list.Add(pair);
            list.Sort((a, b) => string.Compare(AssetLabel(a.Key, a.Value), AssetLabel(b.Key, b.Value),
                                               StringComparison.CurrentCulture));
            return list;
        }

        private static string AssetLabel(string hash, Dictionary<string, object> data)
        {
            string label = Str(data, "label");
            return label.Length > 0 ? label : hash.Substring(0, Math.Min(12, hash.Length));
        }

        /// <summary>Configuration paths that reference an asset ("hash" or "asset:hash").</summary>
        private List<string> AssetUsers(string hash)
        {
            var users = new List<string>();
            FindValue(App.Core == null ? null : App.Core.Config(), "", hash, users);
            users.RemoveAll(path => path.StartsWith("assets.", StringComparison.Ordinal));
            return users;
        }

        private static void FindValue(object node, string path, string hash, List<string> found)
        {
            var map = node as Dictionary<string, object>;
            if (map != null)
            {
                foreach (var pair in map)
                    FindValue(pair.Value, path.Length == 0 ? pair.Key : path + "." + pair.Key, hash, found);
                return;
            }
            var text = node as string;
            if (text != null)
            {
                if (text == hash || text == "asset:" + hash) found.Add(path);
                return;
            }
            var list = node as IEnumerable;
            if (list == null) return;
            foreach (object child in list) FindValue(child, path, hash, found);
        }

        private FrameworkElement BuildAssets(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            string prefix = item.Handler == "assets_audio" ? "audio/" : item.Handler == "assets_image" ? "image/" : null;
            var add = CommandButton(Texts.T(prefix == "image/" ? "prefs.image_upload" : prefix == "audio/"
                                            ? "prefs.sound_upload" : "admin.assets_upload"));
            add.IsEnabled = App.Core != null && App.Core.AssetsAvailable;
            DockPanel.SetDock(add, Dock.Right);
            head.Children.Insert(0, add);
            var assets = AssetList(prefix);
            foreach (var asset in assets)
            {
                string hash = asset.Key;
                var data = asset.Value;
                var users = AssetUsers(hash);
                long size = (long)SettingsStore.AsNumber(data.ContainsKey("size") ? data["size"] : null, 0);
                string subtitle = Str(data, "type") + " · " + FormatBytes(size) + " · " +
                                  (users.Count == 0 ? Texts.T("admin.asset_unused")
                                                    : Texts.T("settings.asset_used", string.Join(", ", users)));
                var remove = CommandButton(Texts.T("admin.delete"));
                remove.SetResourceReference(ForegroundProperty, "Negative");
                remove.Click += (s, e) => DeleteAsset(hash, AssetLabel(hash, data), users, parts);
                panel.Children.Add(ItemLine(AssetLabel(hash, data), subtitle, new[] { remove }));
            }
            if (assets.Count == 0) panel.Children.Add(EmptyLine("admin.assets_empty"));
            panel.Children.Add(FieldHint(Texts.T("settings.asset_limits")));
            panel.Children.Add(parts.Error);
            add.Click += (s, e) =>
            {
                string hash = UploadAsset(prefix, parts);
                if (hash != null) Refresh();
            };
            return panel;
        }

        private static string FormatBytes(long bytes)
        {
            if (bytes >= 1024 * 1024) return (bytes / 1048576.0).ToString("0.0", CultureInfo.CurrentCulture) + " MB";
            if (bytes >= 1024) return (bytes / 1024.0).ToString("0", CultureInfo.CurrentCulture) + " KB";
            return bytes + " B";
        }

        private void DeleteAsset(string hash, string label, List<string> users, RowParts parts)
        {
            string question = users.Count > 0
                ? Texts.T("settings.asset_delete_in_use", label, string.Join(", ", users))
                : Texts.T("admin.confirm_delete", label);
            if (!Confirm(question, true)) return;
            var result = App.Core == null ? null : App.Core.AssetRemove(hash);
            if (result != null && SettingsStore.AsBool(result.ContainsKey("ok") ? result["ok"] : null, false))
            {
                ShowStatus(Texts.T("admin.saved"), false);
                _store.Reload();
                Refresh();
                return;
            }
            Report(new SettingsWriteResult { Error = AssetError(result) }, parts);
        }

        private static string AssetError(Dictionary<string, object> result)
        {
            string err = result == null ? "core_unavailable" : Str(result, "err");
            switch (err)
            {
                case "too_large": return Texts.T("admin.asset_too_large");
                case "bad_type": return Texts.T("admin.asset_format_unsupported");
                case "admin_required": return Texts.T("settings.err_admin_required");
                case "core_unavailable":
                case "unsupported": return Texts.T("settings.err_core_unavailable");
                default: return Texts.T("admin.asset_failed") + (err.Length > 0 ? " (" + err + ")" : "");
            }
        }

        /// <summary>
        /// Picks a file with the Windows file dialog and adds it to the ledger. A photograph over
        /// 3 MiB is scaled down to at most 1920 pixels and re-encoded as JPEG first. Returns the
        /// hash, or null when cancelled or refused (the reason is shown).
        /// </summary>
        private string UploadAsset(string prefix, RowParts parts)
        {
            var dialog = new Microsoft.Win32.OpenFileDialog
            {
                Title = Texts.T("admin.asset_choose_file"),
                CheckFileExists = true,
                Multiselect = false,
                Filter = prefix == "image/" ? Texts.T("settings.filter_images") + "|*.jpg;*.jpeg;*.png"
                       : prefix == "audio/" ? Texts.T("settings.filter_sounds") + "|*.mp3;*.wav"
                       : Texts.T("settings.filter_assets") + "|*.jpg;*.jpeg;*.png;*.mp3;*.wav",
            };
            if (dialog.ShowDialog(this) != true) return null;
            string path = dialog.FileName;
            string type;
            switch (Path.GetExtension(path).ToLowerInvariant())
            {
                case ".jpg": case ".jpeg": type = "image/jpeg"; break;
                case ".png": type = "image/png"; break;
                case ".mp3": type = "audio/mpeg"; break;
                case ".wav": type = "audio/wav"; break;
                default:
                    Report(new SettingsWriteResult { Error = Texts.T("admin.asset_format_unsupported") }, parts);
                    return null;
            }
            byte[] bytes;
            try { bytes = File.ReadAllBytes(path); }
            catch (Exception)
            {
                Report(new SettingsWriteResult { Error = Texts.T("admin.file_read_failed") }, parts);
                return null;
            }
            if (bytes.Length > CoreClient.MaxAssetBytes && type.StartsWith("image/", StringComparison.Ordinal))
            {
                bytes = ShrinkImage(bytes);
                type = "image/jpeg";
                if (bytes == null)
                {
                    Report(new SettingsWriteResult { Error = Texts.T("admin.image_resize_failed") }, parts);
                    return null;
                }
            }
            if (bytes.Length > CoreClient.MaxAssetBytes)
            {
                Report(new SettingsWriteResult { Error = Texts.T("admin.asset_too_large") }, parts);
                return null;
            }
            ShowStatus(Texts.T("admin.uploading"), false);
            var result = App.Core == null ? null : App.Core.AssetAdd(bytes, type, Path.GetFileName(path));
            string hash = result == null ? "" : Str(result, "hash");
            if (result == null || !SettingsStore.AsBool(result.ContainsKey("ok") ? result["ok"] : null, false) ||
                hash.Length == 0)
            {
                Report(new SettingsWriteResult { Error = AssetError(result) }, parts);
                return null;
            }
            ShowStatus(Texts.T("admin.asset_registered"), false);
            _store.Reload();
            return hash;
        }

        private static byte[] ShrinkImage(byte[] original)
        {
            try
            {
                var source = new BitmapImage();
                using (var stream = new MemoryStream(original))
                {
                    source.BeginInit();
                    source.CacheOption = BitmapCacheOption.OnLoad;
                    source.StreamSource = stream;
                    source.EndInit();
                }
                for (int edge = 1920; edge >= 640; edge -= 320)
                {
                    double scale = Math.Min(1.0, edge / (double)Math.Max(source.PixelWidth, source.PixelHeight));
                    var scaled = new TransformedBitmap(source, new System.Windows.Media.ScaleTransform(scale, scale));
                    var encoder = new JpegBitmapEncoder { QualityLevel = 85 };
                    encoder.Frames.Add(BitmapFrame.Create(scaled));
                    using (var output = new MemoryStream())
                    {
                        encoder.Save(output);
                        if (output.Length <= CoreClient.MaxAssetBytes) return output.ToArray();
                    }
                }
            }
            catch (Exception) { }
            return null;
        }

        // ---- background image ----------------------------------------------------------------------

        private FrameworkElement BuildBackgroundImage(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            string current = Convert.ToString(_store.Get(item.Key) ?? "");
            var assets = ReadRecords("assets");
            string name = current.Length == 0 ? Texts.T("admin.theme_no_image")
                : assets.ContainsKey(current) ? AssetLabel(current, assets[current]) : current;
            var status = new TextBlock { Text = name, FontSize = 15, TextWrapping = TextWrapping.Wrap,
                                         Margin = new Thickness(0, 8, 0, 0) };
            panel.Children.Add(status);
            var bar = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
            var upload = CommandButton(Texts.T("prefs.image_upload"));
            var choose = CommandButton(Texts.T("settings.bg_choose_existing"));
            var clear = CommandButton(Texts.T("settings.bg_clear"));
            clear.IsEnabled = current.Length > 0;
            upload.IsEnabled = App.Core != null && App.Core.AssetsAvailable;
            choose.IsEnabled = AssetList("image/").Count > 0;
            foreach (var b in new[] { upload, choose, clear })
            {
                b.Margin = new Thickness(0, 0, 8, 6);
                bar.Children.Add(b);
            }
            panel.Children.Add(bar);
            panel.Children.Add(parts.Error);
            upload.Click += (s, e) =>
            {
                string hash = UploadAsset("image/", parts);
                if (hash != null && Report(_store.Set(item.Key, hash), parts)) Refresh();
            };
            choose.Click += (s, e) =>
            {
                var data = new Dictionary<string, object> { { "hash", current.Length > 0 ? current : null } };
                var field = Fld("hash", FieldKind.Choice, item.LabelKey);
                field.Required = true;
                field.Options = new List<SettingOption>();
                foreach (var asset in AssetList("image/"))
                    field.Options.Add(new SettingOption(asset.Key, null, AssetLabel(asset.Key, asset.Value)));
                if (!ShowForm(Texts.T(item.LabelKey), new List<Field> { field }, data)) return;
                if (Report(_store.Set(item.Key, Str(data, "hash")), parts)) Refresh();
            };
            clear.Click += (s, e) =>
            {
                if (!Confirm(Texts.T("settings.reset_confirm"))) return;
                if (Report(_store.Delete(item.Key), parts)) Refresh();
            };
            return panel;
        }

        // ---- wording overrides -----------------------------------------------------------------

        private static readonly string[] OverrideLangs = { "ja", "en", "zh" };
        private Dictionary<string, Dictionary<string, object>> _builtIn;
        private string _textsQuery = "";
        private static readonly Regex Placeholder = new Regex(@"\{[A-Za-z0-9_]+\}");

        /// <summary>The built-in strings, read from this node's /locale/&lt;lang&gt;.json once.</summary>
        private Dictionary<string, Dictionary<string, object>> BuiltInTexts()
        {
            if (_builtIn != null) return _builtIn;
            var all = new Dictionary<string, Dictionary<string, object>>();
            foreach (string lang in OverrideLangs)
            {
                try
                {
                    HttpWebRequest request = LocalMedia.Create(
                        "http://127.0.0.1:" + AdminHttpSession.Port + "/locale/" + lang + ".json", 8000, 8000);
                    request.Proxy = null;
                    using (var response = request.GetResponse())
                    using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                        all[lang] = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 }
                            .Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
                }
                catch (Exception) { all[lang] = new Dictionary<string, object>(); }
            }
            _builtIn = all;
            return all;
        }

        private FrameworkElement BuildTexts(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var search = new TextBox { Style = (Style)FindResource("SettingsTextBox"), Text = _textsQuery,
                                       Margin = new Thickness(0, 10, 0, 6) };
            AutomationLabel(search, Texts.T("settings.texts_search"));
            DoorbellApp.Ui.Fluent.Placeholder(search, Texts.T("settings.texts_search"));
            panel.Children.Add(search);
            var results = new StackPanel();
            panel.Children.Add(results);
            panel.Children.Add(parts.Error);
            var overrides = new Dictionary<string, Dictionary<string, object>>();
            foreach (string lang in OverrideLangs)
                overrides[lang] = (_store.Get("i18n_overrides." + lang) as Dictionary<string, object>) ??
                                  new Dictionary<string, object>();
            Action render = null;
            render = () =>
            {
                results.Children.Clear();
                var builtIn = BuiltInTexts();
                var keys = new SortedSet<string>(StringComparer.Ordinal);
                foreach (var lang in builtIn.Values) foreach (string key in lang.Keys) keys.Add(key);
                foreach (var lang in overrides.Values) foreach (string key in lang.Keys) keys.Add(key);
                string needle = _textsQuery.ToLowerInvariant();
                int shown = 0, matched = 0;
                foreach (string key in keys)
                {
                    bool overridden = false;
                    foreach (var lang in overrides.Values) if (lang.ContainsKey(key)) overridden = true;
                    string sample = BuiltIn(builtIn, Texts.Lang ?? "ja", key);
                    if (needle.Length == 0 ? !overridden
                        : !(key.ToLowerInvariant().Contains(needle) || sample.ToLowerInvariant().Contains(needle) ||
                            OverrideText(overrides, key).ToLowerInvariant().Contains(needle)))
                        continue;
                    matched++;
                    if (shown >= 40) continue;
                    shown++;
                    string k = key;
                    var edit = CommandButton(Texts.T("admin.edit"));
                    edit.Click += (s, e) =>
                    {
                        if (EditOverride(k, builtIn, overrides, parts)) render();
                    };
                    var buttons = new List<Button> { edit };
                    if (overridden)
                    {
                        var reset = CommandButton(Texts.T("settings.texts_reset"));
                        reset.Click += (s, e) =>
                        {
                            if (!Confirm(Texts.T("settings.reset_confirm"))) return;
                            var sets = new List<KeyValuePair<string, object>>();
                            foreach (string lang in OverrideLangs)
                                if (overrides[lang].Remove(k))
                                    sets.Add(new KeyValuePair<string, object>("i18n_overrides." + lang, overrides[lang]));
                            if (Report(_store.Commit(sets, null), parts)) render();
                        };
                        buttons.Add(reset);
                    }
                    string current = OverrideText(overrides, k);
                    results.Children.Add(ItemLine(k, (current.Length > 0 ? "✎ " + current + "\n" : "") + sample,
                                                  buttons));
                }
                if (matched == 0)
                    results.Children.Add(EmptyLine(needle.Length == 0 ? "settings.texts_none" : "settings.search_none"));
                else if (matched > shown)
                    results.Children.Add(FieldHint(Texts.T("settings.texts_more", matched - shown)));
            };
            var settle = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
            settle.Tick += (s, e) => { settle.Stop(); render(); };
            search.TextChanged += (s, e) =>
            {
                _textsQuery = search.Text.Trim();
                settle.Stop();
                settle.Start();
            };
            render();
            return panel;
        }

        private static string BuiltIn(Dictionary<string, Dictionary<string, object>> builtIn, string lang, string key)
        {
            Dictionary<string, object> table;
            object value;
            if (builtIn.TryGetValue(lang, out table) && table.TryGetValue(key, out value) && value != null)
                return value.ToString();
            if (builtIn.TryGetValue("ja", out table) && table.TryGetValue(key, out value) && value != null)
                return value.ToString();
            return "";
        }

        private static string OverrideText(Dictionary<string, Dictionary<string, object>> overrides, string key)
        {
            var texts = new List<string>();
            foreach (string lang in OverrideLangs)
            {
                object value;
                if (overrides[lang].TryGetValue(key, out value) && value != null)
                    texts.Add(lang + ": " + value);
            }
            return string.Join("  ", texts);
        }

        private bool EditOverride(string key, Dictionary<string, Dictionary<string, object>> builtIn,
                                  Dictionary<string, Dictionary<string, object>> overrides, RowParts parts)
        {
            StackPanel form, actions;
            TextBlock error;
            var dialog = FormWindow(key, out form, out actions, out error, 640);
            var boxes = new Dictionary<string, TextBox>();
            foreach (string lang in OverrideLangs)
            {
                string langKey = "language.name_" + lang;
                form.Children.Add(FieldLabel(Texts.T(langKey)));
                form.Children.Add(FieldHint(Texts.T("settings.texts_default", BuiltIn(builtIn, lang, key))));
                object value;
                var box = FormTextBox(overrides[lang].TryGetValue(key, out value) ? Convert.ToString(value) : "", 1000);
                box.AcceptsReturn = true;
                box.TextWrapping = TextWrapping.Wrap;
                AutomationLabel(box, key + " " + lang);
                boxes[lang] = box;
                form.Children.Add(box);
            }
            form.Children.Add(FieldHint(Texts.T("admin.texts_placeholder_hint")));
            var cancel = CommandButton(Texts.T("admin.cancel"));
            var save = PrimaryButton(Texts.T("admin.save"));
            save.Margin = new Thickness(8, 0, 0, 0);
            cancel.IsCancel = true;
            actions.Children.Add(cancel);
            actions.Children.Add(save);
            cancel.Click += (s, e) => dialog.DialogResult = false;
            save.Click += (s, e) =>
            {
                var sets = new List<KeyValuePair<string, object>>();
                foreach (string lang in OverrideLangs)
                {
                    string text = boxes[lang].Text;
                    string original = BuiltIn(builtIn, lang, key);
                    if (text.Trim().Length > 0 && original.Length > 0 && !SamePlaceholders(text, original))
                    {
                        error.Text = Texts.T("admin.texts_placeholder_mismatch");
                        error.Visibility = Visibility.Visible;
                        return;
                    }
                    var table = new Dictionary<string, object>(overrides[lang]);
                    bool changed;
                    if (text.Trim().Length == 0) changed = table.Remove(key);
                    else
                    {
                        object old;
                        changed = !table.TryGetValue(key, out old) || Convert.ToString(old) != text;
                        table[key] = text;
                    }
                    if (changed) sets.Add(new KeyValuePair<string, object>("i18n_overrides." + lang, table));
                }
                if (sets.Count > 0 && !Report(_store.Commit(sets, null), parts)) return;
                foreach (var pair in sets)
                    overrides[pair.Key.Substring("i18n_overrides.".Length)] = (Dictionary<string, object>)pair.Value;
                dialog.DialogResult = true;
            };
            return dialog.ShowDialog() == true;
        }

        private static bool SamePlaceholders(string a, string b)
        {
            var left = new SortedSet<string>(StringComparer.Ordinal);
            var right = new SortedSet<string>(StringComparer.Ordinal);
            foreach (Match m in Placeholder.Matches(a)) left.Add(m.Value);
            foreach (Match m in Placeholder.Matches(b)) right.Add(m.Value);
            return left.SetEquals(right);
        }

        // ---- playback policy -------------------------------------------------------------------

        private static readonly string[] Strategies = { "h264_low_latency", "h264_hls", "mjpeg" };

        private List<Dictionary<string, object>> ReadStrategies()
        {
            var list = new List<Dictionary<string, object>>();
            var raw = _store.Get("video_playback.global.strategies") as IEnumerable;
            if (raw != null && !(raw is string))
                foreach (object entry in raw)
                {
                    var map = entry as Dictionary<string, object>;
                    if (map != null && Array.IndexOf(Strategies, Str(map, "id")) >= 0) list.Add(DeepCopy(map));
                }
            foreach (string id in Strategies)
            {
                bool present = false;
                foreach (var entry in list) if (Str(entry, "id") == id) present = true;
                if (!present)
                    list.Add(new Dictionary<string, object>
                    {
                        { "id", id }, { "enabled", id != "h264_hls" },
                        { "startup_timeout_ms", 5000L }, { "stall_timeout_ms", id == "h264_hls" ? 5000L : 3000L },
                    });
            }
            return list;
        }

        private FrameworkElement BuildVideoPolicy(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var strategies = ReadStrategies();
            Func<bool> save = () =>
            {
                bool any = false;
                foreach (var entry in strategies)
                    if (SettingsStore.AsBool(entry.ContainsKey("enabled") ? entry["enabled"] : null, true)) any = true;
                if (!any)
                {
                    Report(new SettingsWriteResult { Error = Texts.T("admin.playback_one_required") }, parts);
                    return false;
                }
                var array = new List<object>();
                foreach (var entry in strategies) array.Add(entry);
                return Report(_store.Set("video_playback.global.strategies", array), parts);
            };
            for (int i = 0; i < strategies.Count; i++)
            {
                int index = i;
                var entry = strategies[i];
                bool enabled = SettingsStore.AsBool(entry.ContainsKey("enabled") ? entry["enabled"] : null, true);
                var up = CommandButton("↑");
                var down = CommandButton("↓");
                var toggle = CommandButton(Texts.T(enabled ? "settings.disable" : "settings.enable"));
                var edit = CommandButton(Texts.T("admin.edit"));
                AutomationLabel(up, Texts.T("settings.move_up"));
                AutomationLabel(down, Texts.T("settings.move_down"));
                up.IsEnabled = index > 0;
                down.IsEnabled = index < strategies.Count - 1;
                up.Click += (s, e) => { Swap(strategies, index, index - 1); if (save()) Refresh(); };
                down.Click += (s, e) => { Swap(strategies, index, index + 1); if (save()) Refresh(); };
                toggle.Click += (s, e) => { entry["enabled"] = !enabled; if (save()) Refresh(); else entry["enabled"] = enabled; };
                edit.Click += (s, e) =>
                {
                    var draft = DeepCopy(entry);
                    var startup = Fld("startup_timeout_ms", FieldKind.Number, "admin.first_frame_timeout");
                    var stall = Fld("stall_timeout_ms", FieldKind.Number, "admin.stall_timeout");
                    startup.Min = stall.Min = 1000;
                    startup.Max = stall.Max = 30000;
                    startup.Required = stall.Required = true;
                    startup.HintKey = "admin.playback_timeout_range";
                    if (!ShowForm(StrategyText(Str(entry, "id")), new List<Field> { startup, stall }, draft)) return;
                    strategies[index] = draft;
                    if (save()) Refresh();
                };
                string subtitle = (enabled ? Texts.T("admin.enabled") : Texts.T("admin.disabled")) + " · " +
                                  Texts.T("settings.strategy_timeouts",
                                          SettingsStore.AsNumber(entry.ContainsKey("startup_timeout_ms") ? entry["startup_timeout_ms"] : null, 5000),
                                          SettingsStore.AsNumber(entry.ContainsKey("stall_timeout_ms") ? entry["stall_timeout_ms"] : null, 3000));
                panel.Children.Add(ItemLine((index + 1) + ". " + StrategyText(Str(entry, "id")), subtitle,
                                            new[] { up, down, toggle, edit }));
            }
            panel.Children.Add(FieldHint(Texts.T("admin.playback_fallback_hint")));
            panel.Children.Add(parts.Error);
            return panel;
        }

        private static string StrategyText(string id)
        {
            switch (id)
            {
                case "h264_low_latency": return Texts.T("admin.video_low_latency");
                case "h264_hls": return Texts.T("admin.video_hls");
                default: return Texts.T("settings.codec_mjpeg");
            }
        }

        // ---- Web panel identities --------------------------------------------------------------

        private static readonly string[] PanelGrants =
            { "view", "call.monitor", "call.answer", "call.initiate", "sos.trigger", "door.open",
              "media.publish", "notice.write" };

        private bool _panelsRequested;

        private static string GrantText(string grant)
        {
            string key = "panels.grant_" + grant.Replace('.', '_');
            return Texts.T(key);
        }

        private FrameworkElement BuildPanels(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            if (App.Core == null || !App.Core.PanelIdentityAvailable)
            {
                panel.Children.Add(EmptyLine("settings.err_core_unavailable"));
                return panel;
            }
            if (!_panelsRequested && !AdminHttpSession.HasSession)
            {
                var load = CommandButton(Texts.T("settings.panels_load"));
                load.HorizontalAlignment = HorizontalAlignment.Left;
                load.Margin = new Thickness(0, 10, 0, 0);
                load.Click += (s, e) => { _panelsRequested = true; Refresh(); };
                panel.Children.Add(load);
                return panel;
            }
            _panelsRequested = true;
            var list = App.Core.PanelIdentity("list", "{}");
            if (!SettingsStore.AsBool(list.ContainsKey("ok") ? list["ok"] : null, false))
            {
                panel.Children.Add(EmptyLine("settings.panels_unavailable"));
                Report(new SettingsWriteResult { Error = PanelError(list) }, parts);
                panel.Children.Add(parts.Error);
                return panel;
            }
            string revision = Str(list, "revision");
            var create = CommandButton(Texts.T("panels.create"));
            DockPanel.SetDock(create, Dock.Right);
            head.Children.Insert(0, create);
            create.Click += (s, e) =>
            {
                var data = new Dictionary<string, object> { { "grants", new List<object> { "view" } } };
                if (!EditPanelScope(Texts.T("panels.create"), data)) return;
                string credential, reference;
                if (!ProvisionPanelCredential(parts, out credential, out reference)) return;
                var body = new Dictionary<string, object>
                {
                    { "expected_revision", revision }, { "credential_ref", reference },
                    { "door_scope", data["door_scope"] }, { "grants", data["grants"] },
                };
                if (PanelCall("create", body, parts)) ShowPanelLinks(credential);
                Refresh();
            };
            var rows = list.ContainsKey("panels") ? list["panels"] as IEnumerable : null;
            int count = 0;
            if (rows != null)
                foreach (object row in rows)
                {
                    var record = row as Dictionary<string, object>;
                    if (record == null) continue;
                    count++;
                    panel.Children.Add(PanelRow(record, revision, parts));
                }
            if (count == 0) panel.Children.Add(EmptyLine("panels.empty"));
            panel.Children.Add(parts.Error);
            return panel;
        }

        private FrameworkElement PanelRow(Dictionary<string, object> record, string revision, RowParts parts)
        {
            string id = Str(record, "panel_id");
            bool revoked = SettingsStore.AsBool(record.ContainsKey("revoked") ? record["revoked"] : null, false);
            var grants = new List<string>();
            foreach (string grant in StringList(record.ContainsKey("grants") ? record["grants"] : null))
                grants.Add(GrantText(grant));
            string doors = Joined(DoorOptions(), record.ContainsKey("door_scope") ? record["door_scope"] : null);
            var bits = new List<string> { Texts.T(revoked ? "panels.revoked" : "panels.active") };
            if (doors.Length > 0) bits.Add(doors);
            if (grants.Count > 0) bits.Add(string.Join(", ", grants));
            if (Str(record, "provisioning_status") == "provisioning_required" && !revoked)
                bits.Add(Texts.T("panels.provisioning_required"));
            object last = record.ContainsKey("last_activity_ms") ? record["last_activity_ms"] : null;
            double lastMs = SettingsStore.AsNumber(last, 0);
            bits.Add(Texts.T("panels.last_activity") + ": " + (lastMs > 0
                ? DateTimeOffset.FromUnixTimeMilliseconds((long)lastMs).ToLocalTime().ToString("g")
                : Texts.T("panels.never")));
            var buttons = new List<Button>();
            if (!revoked)
            {
                var edit = CommandButton(Texts.T("admin.edit"));
                var rotate = CommandButton(Texts.T("admin.rotate"));
                var revoke = CommandButton(Texts.T("panels.revoke"));
                revoke.SetResourceReference(ForegroundProperty, "Negative");
                edit.Click += (s, e) =>
                {
                    var data = new Dictionary<string, object>
                    {
                        { "door_scope", record.ContainsKey("door_scope") ? record["door_scope"] : null },
                        { "grants", record.ContainsKey("grants") ? record["grants"] : null },
                    };
                    if (!EditPanelScope(Texts.T("admin.edit"), data)) return;
                    PanelCall("update", new Dictionary<string, object>
                    {
                        { "panel_id", id }, { "expected_revision", revision },
                        { "door_scope", data["door_scope"] }, { "grants", data["grants"] },
                    }, parts);
                    Refresh();
                };
                rotate.Click += (s, e) =>
                {
                    if (!Confirm(Texts.T("panels.rotate_confirm"), true)) return;
                    string credential, reference;
                    if (!ProvisionPanelCredential(parts, out credential, out reference)) return;
                    string previous = Str(record, "credential_ref");
                    if (PanelCall("rotate", new Dictionary<string, object>
                        { { "panel_id", id }, { "expected_revision", revision }, { "credential_ref", reference } }, parts))
                    {
                        if (previous.Length > 0 && previous != reference) RemoveSecret(previous);
                        ShowPanelLinks(credential);
                    }
                    else RemoveSecret(reference);
                    Refresh();
                };
                revoke.Click += (s, e) =>
                {
                    if (!Confirm(Texts.T("panels.revoke_confirm"), true)) return;
                    if (PanelCall("revoke", new Dictionary<string, object>
                        { { "panel_id", id }, { "expected_revision", revision } }, parts))
                        ShowStatus(Texts.T("panels.revoked_done"), false);
                    Refresh();
                };
                buttons.AddRange(new[] { edit, rotate, revoke });
            }
            return ItemLine(id.Length > 8 ? id.Substring(0, 8) : id, string.Join(" · ", bits), buttons);
        }

        private bool EditPanelScope(string title, Dictionary<string, object> data)
        {
            var scope = Fld("door_scope", FieldKind.Multi, "panels.door_scope");
            scope.Options = DoorOptions();
            scope.Required = true;
            var grants = Fld("grants", FieldKind.Multi, "panels.grants");
            grants.Options = new List<SettingOption>();
            foreach (string grant in PanelGrants) grants.Options.Add(new SettingOption(grant, null, GrantText(grant)));
            grants.Required = true;
            return ShowForm(title, new List<Field> { scope, grants }, data);
        }

        /// <summary>
        /// A fresh 256-bit panel credential in this device's secure store, referenced as
        /// secret:panel.&lt;16 hex&gt;. Core never returns it; it is shown once as a link.
        /// </summary>
        private bool ProvisionPanelCredential(RowParts parts, out string credential, out string reference)
        {
            credential = RandomHex(32);
            reference = "secret:panel." + RandomHex(8);
            string failure = ProvisionSecret(reference, credential);
            if (failure == null) return true;
            Report(new SettingsWriteResult { Error = failure }, parts);
            return false;
        }

        private static string RandomHex(int bytes)
        {
            var buffer = new byte[bytes];
            using (var random = RandomNumberGenerator.Create()) random.GetBytes(buffer);
            return BitConverter.ToString(buffer).Replace("-", "").ToLowerInvariant();
        }

        private bool PanelCall(string action, Dictionary<string, object> body, RowParts parts)
        {
            var result = App.Core.PanelIdentity(action, new JavaScriptSerializer().Serialize(body));
            if (SettingsStore.AsBool(result.ContainsKey("ok") ? result["ok"] : null, false))
            {
                ShowStatus(Texts.T(action == "create" ? "panels.created" : action == "rotate"
                    ? "panels.rotated" : "admin.saved"), false);
                _store.Reload();
                return true;
            }
            Report(new SettingsWriteResult { Error = PanelError(result) }, parts);
            return false;
        }

        private static string PanelError(Dictionary<string, object> result)
        {
            string code = Str(result, "error_code");
            if (code.Length == 0) code = Str(result, "err");
            if (code == "admin_required" || code == "permission_denied") return Texts.T("settings.err_admin_required");
            return Texts.T("panels.failed_reason", code);
        }

        /// <summary>The one-time panel links (door, monitor, call) as text and QR codes.</summary>
        private void ShowPanelLinks(string credential)
        {
            StackPanel form, actions;
            TextBlock error;
            var dialog = FormWindow(Texts.T("panels.one_time_title"), out form, out actions, out error, 720);
            form.Children.Add(FieldHint(Texts.T("panels.one_time_warning")));
            var hosts = AdminLink.Hosts();
            string host = hosts.Count > 0 ? hosts[0] : "127.0.0.1";
            string base_url = "https://" + host + ":" + AdminLink.HttpsPort;
            foreach (string page in new[] { "door", "monitor", "call" })
            {
                string link = base_url + "/panel/" + page + "#k=" + credential;
                string pageKey = "panels.link_" + page;
                form.Children.Add(FieldLabel(Texts.T(pageKey)));
                var line = new DockPanel();
                var qr = new Image { Source = QrCodeImage.Render(link, 180), Width = 180, Height = 180,
                                     Margin = new Thickness(0, 0, 12, 0) };
                DockPanel.SetDock(qr, Dock.Left);
                line.Children.Add(qr);
                var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
                text.Children.Add(new TextBox
                {
                    Text = link, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontSize = 12,
                    BorderThickness = new Thickness(0), Background = System.Windows.Media.Brushes.Transparent,
                });
                var copy = CommandButton(Texts.T("admin.copy"));
                copy.HorizontalAlignment = HorizontalAlignment.Left;
                copy.Margin = new Thickness(0, 6, 0, 0);
                copy.Click += (s, e) =>
                {
                    try { Clipboard.SetText(link); ShowStatus(Texts.T("admin.copied"), false); }
                    catch (Exception) { ShowStatus(Texts.T("admin.copy_failed"), true); }
                };
                text.Children.Add(copy);
                line.Children.Add(text);
                form.Children.Add(line);
            }
            var done = PrimaryButton(Texts.T("panels.one_time_done"));
            done.IsDefault = true;
            done.Click += (s, e) => dialog.DialogResult = true;
            actions.Children.Add(done);
            dialog.ShowDialog();
        }

        // ---- configuration export and import --------------------------------------------------

        private FrameworkElement BuildBackup(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var bar = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
            var export = CommandButton(Texts.T("admin.export"));
            var import = CommandButton(Texts.T("admin.import"));
            export.Margin = new Thickness(0, 0, 8, 6);
            import.Margin = new Thickness(0, 0, 8, 6);
            bar.Children.Add(export);
            bar.Children.Add(import);
            panel.Children.Add(bar);
            panel.Children.Add(FieldHint(Texts.T("settings.backup_hint")));
            panel.Children.Add(parts.Error);
            export.Click += (s, e) => ExportConfig(parts);
            import.Click += (s, e) => ImportConfig(parts);
            return panel;
        }

        private void ExportConfig(RowParts parts)
        {
            string snapshot = App.Core == null ? null : App.Core.ConfigSnapshotJson();
            Dictionary<string, object> doc = null;
            var json = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };
            try { doc = snapshot == null ? null : json.Deserialize<Dictionary<string, object>>(snapshot); }
            catch (Exception) { }
            if (doc == null || !doc.ContainsKey("config"))
            {
                Report(new SettingsWriteResult { Error = "core_unavailable" }, parts);
                return;
            }
            var dialog = new Microsoft.Win32.SaveFileDialog
            {
                Title = Texts.T("admin.export"),
                FileName = "doorbell-config-" + DateTime.Now.ToString("yyyyMMdd-HHmm", CultureInfo.InvariantCulture) + ".json",
                Filter = "JSON|*.json",
                AddExtension = true,
            };
            if (dialog.ShowDialog(this) != true) return;
            var document = new Dictionary<string, object> { { "schema_version", 2L }, { "config", doc["config"] } };
            try
            {
                File.WriteAllText(dialog.FileName, json.Serialize(document), new UTF8Encoding(false));
                ShowStatus(Texts.T("settings.export_done", Path.GetFileName(dialog.FileName)), false);
            }
            catch (Exception)
            {
                Report(new SettingsWriteResult { Error = Texts.T("settings.export_failed") }, parts);
            }
        }

        /// <summary>
        /// Stage, preflight, show what changes, then commit on confirmation (docs/en/config-
        /// import.md). Nothing changes before the operator confirms the preview; cancelling
        /// releases the stage.
        /// </summary>
        private void ImportConfig(RowParts parts)
        {
            if (App.Core == null) return;
            var open = new Microsoft.Win32.OpenFileDialog
            {
                Title = Texts.T("admin.import_file"),
                Filter = "JSON|*.json",
                CheckFileExists = true,
            };
            if (open.ShowDialog(this) != true) return;
            var json = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };
            Dictionary<string, object> file;
            try
            {
                if (new FileInfo(open.FileName).Length > 4 * 1024 * 1024)
                {
                    Report(new SettingsWriteResult { Error = Texts.T("admin.import_size") }, parts);
                    return;
                }
                file = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(open.FileName, Encoding.UTF8));
            }
            catch (Exception)
            {
                Report(new SettingsWriteResult { Error = Texts.T("admin.import_invalid") }, parts);
                return;
            }
            // Accept this exporter's document, a raw snapshot, or a bare configuration object.
            object config = file != null && file.ContainsKey("config") ? file["config"] : file;
            if (!(config is Dictionary<string, object>))
            {
                Report(new SettingsWriteResult { Error = Texts.T("admin.import_invalid") }, parts);
                return;
            }
            Dictionary<string, object> snapshot = null;
            try { snapshot = json.Deserialize<Dictionary<string, object>>(App.Core.ConfigSnapshotJson() ?? ""); }
            catch (Exception) { }
            string revision = snapshot == null ? "" : Str(snapshot, "revision");
            var stage = App.Core.ConfigImport("stage", json.Serialize(new Dictionary<string, object>
            {
                { "schema_version", 2L }, { "expected_revision", revision },
                { "document", new Dictionary<string, object> { { "schema_version", 2L }, { "config", config } } },
            }));
            if (!SettingsStore.AsBool(stage.ContainsKey("ok") ? stage["ok"] : null, false))
            {
                Report(new SettingsWriteResult { Error = ImportError(stage) }, parts);
                return;
            }
            var envelope = new Dictionary<string, object>
            {
                { "schema_version", 2L }, { "stage_token", Str(stage, "stage_token") }, { "digest", Str(stage, "digest") },
            };
            var preflight = App.Core.ConfigImport("preflight", json.Serialize(envelope));
            bool canCommit = SettingsStore.AsBool(preflight.ContainsKey("can_commit") ? preflight["can_commit"] : null, false);
            if (!ConfirmImport(preflight, canCommit) || !canCommit)
            {
                App.Core.ConfigImport("cancel", json.Serialize(envelope));
                return;
            }
            envelope["operation_id"] = RandomHex(16);
            var commit = App.Core.ConfigImport("commit", json.Serialize(envelope));
            if (SettingsStore.AsBool(commit.ContainsKey("ok") ? commit["ok"] : null, false))
            {
                ShowStatus(Texts.T("admin.imported"), false);
                _store.Reload();
                Refresh();
            }
            else Report(new SettingsWriteResult { Error = ImportError(commit) }, parts);
        }

        private static string ImportError(Dictionary<string, object> result)
        {
            string code = Str(result, "error_code");
            if (code.Length == 0) code = Str(result, "err");
            switch (code)
            {
                case "permission_denied":
                case "admin_required": return Texts.T("admin.import_auth");
                case "config_conflict": return Texts.T("admin.conflict_hint");
                case "capacity_exceeded": return Texts.T("admin.import_size");
                case "unsupported_schema": return Texts.T("admin.import_schema");
                case "invalid_document":
                case "invalid_request": return Texts.T("admin.import_invalid");
                default: return Texts.T("admin.import_error") + (code.Length > 0 ? " (" + code + ")" : "");
            }
        }

        private bool ConfirmImport(Dictionary<string, object> preflight, bool canCommit)
        {
            StackPanel form, actions;
            TextBlock error;
            var dialog = FormWindow(Texts.T("admin.import_preview"), out form, out actions, out error, 720);
            var differences = preflight.ContainsKey("differences") ? preflight["differences"] as IEnumerable : null;
            var lines = new List<string>();
            if (differences != null)
                foreach (object entry in differences)
                {
                    var map = entry as Dictionary<string, object>;
                    if (map == null) continue;
                    bool before = SettingsStore.AsBool(map.ContainsKey("before_exists") ? map["before_exists"] : null, true);
                    bool after = SettingsStore.AsBool(map.ContainsKey("after_exists") ? map["after_exists"] : null, true);
                    lines.Add((before ? after ? "~ " : "− " : "+ ") + Str(map, "path"));
                }
            form.Children.Add(FieldLabel(Texts.T("settings.import_changes", lines.Count)));
            if (lines.Count > 0)
                form.Children.Add(new TextBox
                {
                    Text = string.Join("\n", lines.Count > 300 ? lines.GetRange(0, 300) : lines),
                    IsReadOnly = true, FontFamily = new System.Windows.Media.FontFamily("Consolas"), FontSize = 12,
                    MaxHeight = 300, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    TextWrapping = TextWrapping.NoWrap, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                });
            foreach (var section in new[] { new[] { "problems", "admin.import_blocked" },
                                            new[] { "missing_secret_refs", "admin.import_missing_secrets" },
                                            new[] { "missing_assets", "admin.import_missing_assets" } })
            {
                var items = new List<string>();
                var raw = preflight.ContainsKey(section[0]) ? preflight[section[0]] as IEnumerable : null;
                if (raw != null)
                    foreach (object entry in raw)
                    {
                        var map = entry as Dictionary<string, object>;
                        items.Add(map == null ? Convert.ToString(entry)
                                              : (Str(map, "path") + " " + Str(map, "error_code") + Str(map, "message")).Trim());
                    }
                if (items.Count == 0) continue;
                var title = FieldLabel(Texts.T(section[1]));
                title.SetResourceReference(TextBlock.ForegroundProperty, "Negative");
                form.Children.Add(title);
                form.Children.Add(FieldHint(string.Join("\n", items)));
            }
            if (!canCommit)
            {
                error.Text = Texts.T("admin.import_blocked");
                error.Visibility = Visibility.Visible;
            }
            var cancel = CommandButton(Texts.T("admin.cancel"));
            var commit = PrimaryButton(Texts.T("admin.import_commit"));
            commit.Margin = new Thickness(8, 0, 0, 0);
            commit.IsEnabled = canCommit && lines.Count > 0;
            cancel.IsCancel = true;
            actions.Children.Add(cancel);
            actions.Children.Add(commit);
            cancel.Click += (s, e) => dialog.DialogResult = false;
            commit.Click += (s, e) => dialog.DialogResult = true;
            return dialog.ShowDialog() == true;
        }

        // ---- software update -----------------------------------------------------------------------

        private bool _updateBusy;
        private string _updateStatus = "";
        private UpdateChecker.Release _pendingRelease;

        private FrameworkElement BuildSoftwareUpdate(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var installed = UpdateChecker.ReadInstalled();
            var version = new TextBlock
            {
                Text = installed.FromInstaller ? installed.Version + " (" + installed.BuildId + ")"
                                               : Texts.T("web_admin.update_not_installer"),
                FontSize = 15,
                Margin = new Thickness(0, 8, 0, 0),
                TextWrapping = TextWrapping.Wrap,
            };
            panel.Children.Add(version);
            panel.Children.Add(FieldLabel(Texts.T("settings.update_channel")));
            var channels = new WrapPanel();
            foreach (string channel in new[] { "stable", "prerelease" })
            {
                string value = channel;
                string labelKey = "settings.update_channel_" + channel;
                var button = CommandButton(Texts.T(labelKey));
                bool on = UpdateChecker.Channel == channel;
                if (on) DoorbellApp.Ui.Fluent.MakeAccent(button);
                button.Margin = new Thickness(0, 0, 6, 6);
                button.Click += (s, e) =>
                {
                    try
                    {
                        UpdateChecker.Channel = value;
                        _pendingRelease = null;
                        _updateStatus = "";
                        ShowStatus(Texts.T("admin.saved"), false);
                    }
                    catch (Exception) { ShowStatus(Texts.T("settings.save_failed"), true); }
                    Refresh();
                };
                channels.Children.Add(button);
            }
            panel.Children.Add(channels);
            var status = new TextBlock { Text = _updateStatus, FontSize = 14, TextWrapping = TextWrapping.Wrap,
                                         Margin = new Thickness(0, 6, 0, 0) };
            panel.Children.Add(status);
            var bar = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
            var check = CommandButton(Texts.T("web_admin.update_check"));
            var apply = PrimaryButton(Texts.T("web_admin.update_apply"));
            check.Margin = apply.Margin = new Thickness(0, 0, 8, 6);
            check.IsEnabled = installed.FromInstaller && !_updateBusy;
            apply.Visibility = _pendingRelease != null ? Visibility.Visible : Visibility.Collapsed;
            apply.IsEnabled = !_updateBusy;
            bar.Children.Add(check);
            bar.Children.Add(apply);
            panel.Children.Add(bar);
            Action<string> say = text =>
            {
                _updateStatus = text;
                status.Text = text;
            };
            check.Click += (s, e) =>
            {
                if (_updateBusy) return;
                _updateBusy = true;
                check.IsEnabled = false;
                say(Texts.T("web_admin.update_checking"));
                ThreadPool.QueueUserWorkItem(_ =>
                {
                    UpdateChecker.Release release = null;
                    string failure = null;
                    try { release = UpdateChecker.Check(installed); }
                    catch (Exception ex) { failure = ex.Message; }
                    Dispatcher.BeginInvoke(new Action(() =>
                    {
                        _updateBusy = false;
                        check.IsEnabled = true;
                        if (failure != null) say(Texts.T("web_admin.update_failed", failure));
                        else
                        {
                            _pendingRelease = release.IsNewer ? release : null;
                            say(release.IsNewer ? Texts.T("web_admin.update_available", release.Tag, installed.BuildId)
                                                : Texts.T("web_admin.update_latest", installed.BuildId));
                            apply.Visibility = release.IsNewer ? Visibility.Visible : Visibility.Collapsed;
                        }
                    }));
                });
            };
            apply.Click += (s, e) =>
            {
                var release = _pendingRelease;
                if (_updateBusy || release == null) return;
                if (!Confirm(Texts.T("settings.update_confirm", release.Tag))) return;
                _updateBusy = true;
                check.IsEnabled = apply.IsEnabled = false;
                ThreadPool.QueueUserWorkItem(_ =>
                {
                    string failure = null;
                    try
                    {
                        UpdateChecker.DownloadAndApply(release, stage => Dispatcher.BeginInvoke(new Action(() =>
                            say(Texts.T(stage == "download" ? "web_admin.update_downloading"
                                : stage == "verify" ? "web_admin.update_verifying" : "web_admin.update_installing")))));
                    }
                    catch (UpdateTrustException ex)
                    {
                        CoreClient.WriteAppLog("update refused: " + ex.Message);
                        failure = Texts.T("web_admin.update_untrusted");
                    }
                    catch (Exception ex) { failure = ex.Message; }
                    Dispatcher.BeginInvoke(new Action(() =>
                    {
                        _updateBusy = false;
                        check.IsEnabled = apply.IsEnabled = true;
                        if (failure != null) say(Texts.T("web_admin.update_failed", failure));
                    }));
                });
            };
            return panel;
        }

        // ---- cluster, password, integrations -------------------------------------------------------

        /// <summary>Makes this device the founder of a new cluster (POST /api/pairing/rebuild).</summary>
        private void RebuildCluster()
        {
            if (!Confirm(Texts.T("security.rebuild_confirm"), true)) return;
            int status;
            string body = AdminHttpSession.Request("POST", "/api/pairing/rebuild", "{}", out status);
            if (status == 200 && body != null && body.Contains("\"ok\":true"))
            {
                ShowStatus(Texts.T("security.rebuild_done"), false);
                _store.Reload();
                Refresh();
                return;
            }
            string reason = "";
            try
            {
                var doc = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(body ?? "");
                reason = doc == null ? "" : Str(doc, "err");
            }
            catch (Exception) { }
            if (reason.Length == 0) reason = status == 0 ? Texts.T("settings.err_admin_required") : status.ToString(CultureInfo.InvariantCulture);
            ShowStatus(Texts.T("security.failed", reason), true);
        }

        /// <summary>Changes the cluster administrator password (at least eight characters).</summary>
        private void ChangeAdminPassword()
        {
            var data = new Dictionary<string, object>();
            StackPanel form, actions;
            TextBlock error;
            var dialog = FormWindow(Texts.T("settings.change_password"), out form, out actions, out error, 480);
            var boxes = new List<PasswordBox>();
            foreach (string key in new[] { "settings.password_current", "settings.password_new", "settings.password_confirm" })
            {
                form.Children.Add(FieldLabel(Texts.T(key)));
                var box = new PasswordBox { FontSize = 16, MinHeight = MinTouchTarget,
                                            Padding = new Thickness(10, 8, 10, 8), MaxLength = 128 };
                AutomationLabel(box, Texts.T(key));
                boxes.Add(box);
                form.Children.Add(box);
            }
            form.Children.Add(FieldHint(Texts.T("settings.password_length")));
            var cancel = CommandButton(Texts.T("admin.cancel"));
            var save = PrimaryButton(Texts.T("admin.save"));
            save.Margin = new Thickness(8, 0, 0, 0);
            cancel.IsCancel = true;
            actions.Children.Add(cancel);
            actions.Children.Add(save);
            cancel.Click += (s, e) => dialog.DialogResult = false;
            save.Click += (s, e) =>
            {
                string current = boxes[0].Password, next = boxes[1].Password;
                Action<string> fail = key =>
                {
                    error.Text = Texts.T(key);
                    error.Visibility = Visibility.Visible;
                };
                if (next.Length < AdminDialog.MinimumPasswordLength) { fail("settings.password_length"); return; }
                if (next != boxes[2].Password) { fail("settings.password_mismatch"); return; }
                save.IsEnabled = false;
                // Hashing is deliberately slow: run it off the dispatcher.
                ThreadPool.QueueUserWorkItem(_ =>
                {
                    bool ok = App.Core != null && App.Core.AdminPasswordSet(current, next);
                    Dispatcher.BeginInvoke(new Action(() =>
                    {
                        save.IsEnabled = true;
                        if (!ok) { fail("settings.password_failed"); return; }
                        // Core cleared every admin session; log the loopback one in again.
                        AdminHttpSession.Clear();
                        AdminHttpSession.BeginLogin(next);
                        dialog.DialogResult = true;
                    }));
                });
            };
            if (dialog.ShowDialog() == true) ShowStatus(Texts.T("settings.password_changed"), false);
        }

        /// <summary>Sends a Telegram test message through the elected sender.</summary>
        private void TelegramTest()
        {
            var data = new Dictionary<string, object>();
            var chat = Fld("chat_id", FieldKind.Text, "admin.telegram_test_chat");
            chat.Pattern = new Regex(@"^-?[0-9]{1,20}$|^@[A-Za-z0-9_]{4,64}$");
            chat.HintKey = "settings.telegram_test_hint";
            if (!ShowForm(Texts.T("admin.test_send"), new List<Field> { chat }, data)) return;
            string body = new JavaScriptSerializer().Serialize(new Dictionary<string, object>
                { { "chat_id", Str(data, "chat_id") } });
            int status;
            string result = AdminHttpSession.Request("POST", "/api/test/telegram", body, out status);
            Dictionary<string, object> doc = null;
            try { doc = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(result ?? ""); }
            catch (Exception) { }
            if (doc != null && SettingsStore.AsBool(doc.ContainsKey("ok") ? doc["ok"] : null, false))
            {
                ShowStatus(Texts.T("admin.test_sent"), false);
                return;
            }
            string err = doc == null ? "" : Str(doc, "err");
            ShowStatus(err == "not_leader" ? Texts.T("admin.err_not_leader")
                     : err == "no_token" ? Texts.T("admin.err_no_token")
                     : err == "no_chat" ? Texts.T("admin.err_no_chat")
                     : Texts.T("settings.save_failed_reason", err.Length > 0 ? err
                         : status == 0 ? Texts.T("settings.err_admin_required") : status.ToString(CultureInfo.InvariantCulture)), true);
        }
    }
}
