using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // Reply voice (speech.*) with its audio cache, listening to stored sounds, and the
    // capability override. The cache status comes from Core's /api/tts over the loopback
    // administrator session, like the Web admin's panel.
    internal sealed partial class SettingsWindow
    {
        private static readonly string[] SpeechLangs = { "ja", "en", "zh" };
        private static readonly string[] SpeechDefaultVoices =
            { "ja-JP-Standard-A", "en-US-Standard-A", "cmn-CN-Standard-A" };
        private bool _speechRequested;
        private MediaPlayer _preview;

        // ---- listening ---------------------------------------------------------------------------

        private static string AssetFile(string hash)
        {
            return string.IsNullOrEmpty(hash) ? null : Path.Combine(App.DataDir, "assets", hash);
        }

        private void StopPreview()
        {
            if (_preview == null) return;
            try { _preview.Stop(); _preview.Close(); } catch (InvalidOperationException) { }
            _preview = null;
        }

        /// <summary>Plays a stored sound once; starting another, or closing settings, stops it.</summary>
        private void PlayPreview(string hash)
        {
            bool first = _preview == null;
            StopPreview();
            string path = AssetFile(hash);
            if (path == null || !File.Exists(path))
            {
                ShowStatus(Texts.T("settings.asset_not_here"), true);
                return;
            }
            var player = new MediaPlayer();
            player.MediaFailed += (s, e) => ShowStatus(Texts.T("speech.unavailable"), true);
            player.Open(new Uri(path));
            player.Play();
            _preview = player;
            if (first) Closed += (s, e) => StopPreview();
        }

        /// <summary>A small picture of a stored image, or null when it is not on this device.</summary>
        private static FrameworkElement AssetThumbnail(string hash)
        {
            string path = AssetFile(hash);
            if (path == null || !File.Exists(path)) return null;
            try
            {
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                // Decoded once at thumbnail size and detached from the file, which Core may replace.
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth = 192;
                bitmap.UriSource = new Uri(path);
                bitmap.EndInit();
                bitmap.Freeze();
                var frame = new Border
                {
                    Width = 96,
                    Height = 64,
                    CornerRadius = new CornerRadius(4),
                    BorderThickness = new Thickness(1),
                    Margin = new Thickness(0, 10, 12, 0),
                    VerticalAlignment = VerticalAlignment.Center,
                    Child = new Image { Source = bitmap, Stretch = Stretch.Uniform },
                };
                frame.SetResourceReference(Border.BorderBrushProperty, "Line");
                return frame;
            }
            catch (NotSupportedException) { return null; }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }

        // ---- reply voice -------------------------------------------------------------------------

        private Dictionary<string, object> SpeechStatus()
        {
            int status;
            string body = AdminHttpSession.Request("GET", "/api/tts", null, out status);
            if (status != 200 || string.IsNullOrEmpty(body)) return null;
            try { return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(body); }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }

        private static string SpeechLangName(string lang)
        {
            switch (lang)
            {
                case "ja": return Texts.T("language.name_ja");
                case "en": return Texts.T("language.name_en");
                case "zh": return Texts.T("language.name_zh");
                default: return lang;
            }
        }

        private static string SpeechStateText(string state)
        {
            switch (state)
            {
                case "ready": return Texts.T("speech.state_ready");
                case "syncing": return Texts.T("speech.state_syncing");
                case "generating": return Texts.T("speech.state_generating");
                case "failed": return Texts.T("speech.state_failed");
                case "system": return Texts.T("settings.speech_state_system");
                default: return Texts.T("speech.state_pending");
            }
        }

        private FrameworkElement BuildSpeech(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var edit = CommandButton(Texts.T("admin.edit"));
            DockPanel.SetDock(edit, Dock.Right);
            head.Children.Insert(0, edit);
            edit.Click += (s, e) => EditSpeech(parts);

            var speech = _store.Get("speech") as Dictionary<string, object> ?? new Dictionary<string, object>();
            bool google = Str(speech, "provider") == "google";
            panel.Children.Add(FieldHint(Texts.T(google ? "speech.cloud_hint" : "settings.speech_system_hint")));
            var replies = ReadRecords("quick_replies");
            var rows = new List<Dictionary<string, object>>();
            if (google)
            {
                string generator = Str(speech, "generator_node");
                var devices = ReadRecords("devices");
                string generatorName = devices.ContainsKey(generator) && Str(devices[generator], "name").Length > 0
                    ? Str(devices[generator], "name") : generator;
                panel.Children.Add(FieldHint(Texts.T("speech.generator") + ": " + generatorName));
                if (!_speechRequested && !AdminHttpSession.HasSession)
                {
                    var load = CommandButton(Texts.T("settings.speech_load"));
                    load.HorizontalAlignment = HorizontalAlignment.Left;
                    load.Margin = new Thickness(0, 10, 0, 0);
                    load.Click += (s, e) => { _speechRequested = true; Refresh(); };
                    panel.Children.Add(load);
                    panel.Children.Add(parts.Error);
                    return panel;
                }
                _speechRequested = true;
                var status = SpeechStatus();
                if (status == null)
                {
                    panel.Children.Add(EmptyLine("speech.unavailable"));
                    panel.Children.Add(parts.Error);
                    return panel;
                }
                bool generatorHere = SettingsStore.AsBool(status.ContainsKey("is_generator") ? status["is_generator"] : null, false);
                bool keyReady = SettingsStore.AsBool(status.ContainsKey("key_ready") ? status["key_ready"] : null, false);
                if (generatorHere && !keyReady) panel.Children.Add(FieldHint(Texts.T("speech.key_required")));
                var bar = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
                var refresh = CommandButton(Texts.T("speech.refresh"));
                refresh.Margin = new Thickness(0, 0, 8, 0);
                refresh.Click += (s, e) => Refresh();
                bar.Children.Add(refresh);
                if (generatorHere)
                {
                    var retry = CommandButton(Texts.T("speech.retry"));
                    retry.Click += (s, e) =>
                    {
                        int code;
                        AdminHttpSession.Request("POST", "/api/tts/cache", "{}", out code);
                        if (code != 200) Report(new SettingsWriteResult { Error = Texts.T("admin.save_failed") }, parts);
                        Refresh();
                    };
                    bar.Children.Add(retry);
                }
                panel.Children.Add(bar);
                var items = status.ContainsKey("items") ? status["items"] as IEnumerable : null;
                if (items != null)
                    foreach (object entry in items)
                    {
                        var row = entry as Dictionary<string, object>;
                        if (row != null) rows.Add(row);
                    }
            }
            else
            {
                foreach (var entry in ReadEntries(new SettingItem { Key = "quick_replies", Handler = "quick_replies" }))
                {
                    if (!SettingsStore.AsBool(entry.Data.ContainsKey("speak") ? entry.Data["speak"] : null, true)) continue;
                    var labels = entry.Data.ContainsKey("label") ? entry.Data["label"] as Dictionary<string, object> : null;
                    foreach (string lang in SpeechLangs)
                        if (Str(labels, lang).Length > 0)
                            rows.Add(new Dictionary<string, object>
                                { { "reply_id", entry.Id }, { "lang", lang }, { "state", "system" } });
                }
            }
            foreach (var row in rows)
            {
                string id = Str(row, "reply_id"), lang = Str(row, "lang"), state = Str(row, "state");
                var labels = replies.ContainsKey(id) && replies[id].ContainsKey("label")
                    ? replies[id]["label"] as Dictionary<string, object> : null;
                string text = Str(labels, lang);
                string subtitle = SpeechLangName(lang) + " · " + SpeechStateText(state) +
                                  (Str(row, "error").Length > 0 ? " · " + Str(row, "error") : "");
                var buttons = new List<Button>();
                if (state == "ready" || state == "system")
                {
                    var listen = CommandButton(Texts.T("speech.preview"));
                    string hash = Str(row, "hash");
                    listen.Click += (s, e) =>
                    {
                        if (hash.Length > 0) { PlayPreview(hash); return; }
                        StopPreview();
                        if (App.Core == null || text.Length == 0) ShowStatus(Texts.T("speech.unavailable"), true);
                        else App.Core.SpeakText(text, lang);
                    };
                    buttons.Add(listen);
                }
                panel.Children.Add(ItemLine(text.Length > 0 ? text : id, subtitle, buttons));
            }
            if (rows.Count == 0) panel.Children.Add(EmptyLine());
            panel.Children.Add(parts.Error);
            return panel;
        }

        private void EditSpeech(RowParts parts)
        {
            var current = _store.Get("speech") as Dictionary<string, object> ?? new Dictionary<string, object>();
            var voices = current.ContainsKey("voices") ? current["voices"] as Dictionary<string, object> : null;
            var draftVoices = new Dictionary<string, object>();
            for (int i = 0; i < SpeechLangs.Length; i++)
                draftVoices[SpeechLangs[i]] = Str(voices, SpeechLangs[i]).Length > 0
                    ? Str(voices, SpeechLangs[i]) : SpeechDefaultVoices[i];
            var draft = new Dictionary<string, object>
            {
                { "provider", Str(current, "provider") == "google" ? "google" : "system" },
                { "voices", draftVoices },
                { "speaking_rate", SettingsStore.AsNumber(current.ContainsKey("speaking_rate") ? current["speaking_rate"] : null, 1) },
                { "auto_cache", SettingsStore.AsBool(current.ContainsKey("auto_cache") ? current["auto_cache"] : null, true) },
            };
            var provider = Fld("provider", FieldKind.Choice, "speech.provider");
            provider.Required = true;
            provider.Options = new List<SettingOption>
            {
                new SettingOption("system", "speech.system"),
                new SettingOption("google", null, "Google Cloud TTS"),
            };
            var fields = new List<Field> { provider };
            foreach (string lang in SpeechLangs)
            {
                var voice = Fld("voices." + lang, FieldKind.Text, "speech.voice");
                voice.Label = Texts.T("speech.voice") + " — " + SpeechLangName(lang);
                voice.MaxLength = 64;
                fields.Add(voice);
            }
            var rate = Fld("speaking_rate", FieldKind.Number, "speech.rate");
            rate.Min = 0.25;
            rate.Max = 4;
            rate.Required = true;
            fields.Add(rate);
            fields.Add(Fld("auto_cache", FieldKind.Bool, "speech.auto_cache"));
            string existingRef = Str(current, "google_key_ref");
            string typedKey = "";
            // The key is typed into a password box that never enters the form's data: it goes to
            // the secure store, and configuration receives only its reference.
            Func<StackPanel, Dictionary<string, object>, Func<Dictionary<string, object>, string>> keyField =
                (form, data) =>
                {
                    form.Children.Add(FieldLabel(Texts.T("speech.api_key")));
                    var box = new PasswordBox { FontSize = 16, MinHeight = MinTouchTarget, MaxLength = 512 };
                    AutomationLabel(box, Texts.T("speech.api_key"));
                    form.Children.Add(box);
                    if (existingRef.Length > 0) form.Children.Add(FieldHint(Texts.T("admin.secret_unchanged")));
                    return d =>
                    {
                        typedKey = box.Password ?? "";
                        if (Str(d, "provider") == "google" && typedKey.Length == 0 && existingRef.Length == 0)
                            return Texts.T("speech.key_required");
                        return null;
                    };
                };
            if (!ShowForm(Texts.T("speech.settings"), fields, draft, null, keyField)) return;

            string self = _store.Context.NodeId;
            string generator = Str(current, "generator_node");
            var sets = new List<KeyValuePair<string, object>>
            {
                new KeyValuePair<string, object>("speech.provider", draft["provider"]),
                new KeyValuePair<string, object>("speech.voices", draft["voices"]),
                new KeyValuePair<string, object>("speech.speaking_rate", draft["speaking_rate"]),
                new KeyValuePair<string, object>("speech.auto_cache", draft["auto_cache"]),
            };
            string retire = null;
            if (typedKey.Length > 0)
            {
                // A new key always gets a new reference and makes this device the generator, so
                // every device sees the change; the reference it replaces is retired only when
                // its value was stored here.
                string reference = "secret:speech.google.key" + RandomHex(6);
                string failure = ProvisionSecret(reference, typedKey);
                typedKey = "";
                if (failure != null)
                {
                    Report(new SettingsWriteResult { Error = failure }, parts);
                    return;
                }
                sets.Add(new KeyValuePair<string, object>("speech.google_key_ref", reference));
                if (existingRef.Length > 0 && generator == self) retire = existingRef;
                generator = self;
            }
            if (generator.Length == 0) generator = self;
            sets.Add(new KeyValuePair<string, object>("speech.generator_node", generator));
            if (!Report(_store.Commit(sets, null), parts)) return;
            if (retire != null) RemoveSecret(retire);
            Refresh();
        }

        // ---- capability override -----------------------------------------------------------------

        /// <summary>
        /// devices.&lt;id&gt;.caps_override: a JSON object that replaces what the device reports.
        /// An empty box removes the key, which returns the device to its measured capabilities.
        /// </summary>
        private FrameworkElement BuildCapsOverride(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var serializer = new JavaScriptSerializer();
            object stored = _store.Get(item.Key);
            string current = stored == null ? "" : serializer.Serialize(stored);
            var box = new TextBox
            {
                Style = (Style)FindResource("SettingsTextBox"),
                Text = current,
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                FontFamily = new FontFamily("Consolas, Courier New"),
                MinHeight = 88,
                MaxHeight = 240,
                MaxLength = 8192,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalContentAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 8, 0, 0),
            };
            AutomationLabel(box, Texts.T(item.LabelKey));
            AutomationId(box, "CapsOverrideText");
            panel.Children.Add(box);
            var save = CommandButton(Texts.T("admin.save"));
            save.HorizontalAlignment = HorizontalAlignment.Right;
            save.Margin = new Thickness(0, 8, 0, 0);
            AutomationId(save, "CapsOverrideSave");
            panel.Children.Add(save);
            panel.Children.Add(parts.Error);
            save.Click += (s, e) =>
            {
                parts.Error.Visibility = Visibility.Collapsed;
                string text = box.Text.Trim();
                if (text == current) return;
                if (text.Length == 0)
                {
                    if (Report(_store.Delete(item.Key), parts)) Refresh();
                    return;
                }
                object parsed = null;
                try { parsed = serializer.DeserializeObject(text); }
                catch (ArgumentException) { }
                catch (InvalidOperationException) { }
                if (!(parsed is Dictionary<string, object>))
                {
                    Report(new SettingsWriteResult { Error = Texts.T("settings.caps_override_invalid") }, parts);
                    return;
                }
                if (Report(_store.Set(item.Key, parsed), parts)) Refresh();
            };
            return panel;
        }

        // ---- another device's settings -----------------------------------------------------------

        /// <summary>
        /// Rows that mean the same thing when written for another device: plain values stored
        /// under that device's id. Anything that acts on this machine (boot profile, secure
        /// store, restart, local files) stays out.
        /// </summary>
        internal static bool EditableForAnotherDevice(SettingItem item)
        {
            if (item.Key == null || item.Key.IndexOf("{self}", StringComparison.Ordinal) < 0 ||
                item.Secret != null || item.RequiresRestart)
                return false;
            switch (item.Kind)
            {
                case SettingKind.Toggle:
                case SettingKind.Slider:
                case SettingKind.Stepper:
                case SettingKind.Choice:
                case SettingKind.MultiChoice:
                case SettingKind.Text:
                case SettingKind.Time:
                    return item.Handler == null || item.Handler == "ui_lang" || item.Handler == "media_source";
                case SettingKind.Editor:
                    return item.Handler == "color" || item.Handler == "caps_override";
                default:
                    return false;
            }
        }

        private void EditDeviceSettings(string id, string role)
        {
            StopPreview();
            _store.SetTarget(id, role);
            if (_query.Length > 0) _search.Text = "";
            if (!HasVisibleItems(Category(_categoryId)))
                foreach (var category in _catalog)
                    if (HasVisibleItems(category)) { _categoryId = category.Id; break; }
            RenderContent();
        }

        private FrameworkElement TargetBanner()
        {
            var devices = ReadRecords("devices");
            string id = _store.Target;
            string name = devices.ContainsKey(id) && Str(devices[id], "name").Length > 0 ? Str(devices[id], "name") : id;
            var done = CommandButton(Texts.T("settings.editing_device_done"));
            AutomationId(done, "SettingsTargetDone");
            done.Click += (s, e) =>
            {
                _store.SetTarget(_store.Context.NodeId, _store.Context.Role);
                RenderContent();
            };
            var line = ItemLine(Texts.T("settings.editing_device", name),
                                Texts.T("settings.editing_device_hint"), new[] { done });
            line.Margin = new Thickness(12, 4, 8, 8);
            var banner = new Border
            {
                CornerRadius = new CornerRadius(4),
                BorderThickness = new Thickness(4, 1, 1, 1),
                Margin = new Thickness(0, 4, 0, 4),
                Child = line,
            };
            banner.SetResourceReference(Border.BackgroundProperty, "Card");
            banner.SetResourceReference(Border.BorderBrushProperty, "Accent");
            AutomationId(banner, "SettingsTargetBanner");
            return banner;
        }
    }
}
