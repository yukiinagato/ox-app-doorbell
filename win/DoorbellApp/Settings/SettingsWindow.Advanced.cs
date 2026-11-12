using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // Advanced: what the web Admin offers for an administrator who knows the configuration
    // model. Per-element appearance overrides for this device, the app log, and a direct
    // configuration key editor. Every write still goes through SettingsStore, so Core validates
    // it and the admin window rules apply.
    internal sealed partial class SettingsWindow
    {
        /// <summary>The semantic ids Core's UI manifest knows (RuntimeContracts.UiManifest).</summary>
        internal static readonly string[] UiElementIds =
        {
            "call.primary", "cancel.call", "call.end", "purpose.button", "sos.trigger", "sos.cancel",
            "ring.title", "ring.action", "reply.button", "monitor.close",
        };

        private static readonly Regex UiElementIdPattern = new Regex(
            "^(" + string.Join("|", Array.ConvertAll(UiElementIds, Regex.Escape)) + ")$");

        /// <summary>
        /// devices.&lt;self&gt;.local.ui.elements.&lt;semantic id&gt;. The ids contain a dot, so the
        /// map is written whole. The shell applies only what passes its own safety checks
        /// (Util/SemanticUiOverrides): no shrinking of safety-critical elements, and colours need
        /// enough contrast.
        /// </summary>
        private RecordSpec UiElementSpec()
        {
            return new RecordSpec
            {
                Key = "devices.{self}.local.ui.elements",
                WholeMap = true,
                IdPrefix = null,
                IdLabelKey = "settings.ui_element_id",
                IdPattern = UiElementIdPattern,
                Fields = () =>
                {
                    var scale = Fld("scale", FieldKind.Number, "settings.ui_scale");
                    var font = Fld("font_scale", FieldKind.Number, "settings.ui_font_scale");
                    scale.Min = font.Min = 0.75;
                    scale.Max = font.Max = 2.0;
                    var radius = Fld("radius", FieldKind.Number, "settings.ui_radius");
                    radius.Min = 0;
                    radius.Max = 64;
                    return new List<Field>
                    {
                        scale, font, radius,
                        Fld("foreground", FieldKind.Color, "settings.ui_foreground"),
                        Fld("background", FieldKind.Color, "settings.ui_background"),
                        Fld("accent", FieldKind.Color, "settings.ui_accent"),
                        Fld("border", FieldKind.Color, "settings.ui_border"),
                    };
                },
                Title = (id, d) => id,
                Subtitle = (id, d) =>
                {
                    var set = new List<string>();
                    foreach (string key in new[] { "scale", "font_scale", "radius", "foreground",
                                                   "background", "accent", "border" })
                        if (d.ContainsKey(key) && d[key] != null)
                            set.Add(key + " " + Convert.ToString(d[key],
                                System.Globalization.CultureInfo.InvariantCulture));
                    return string.Join(" · ", set);
                },
            };
        }

        // ---- app log ---------------------------------------------------------------------------

        private const int LogTailLines = 400;

        /// <summary>The last lines of a log file, read while the app keeps writing to it.</summary>
        internal static string TailOf(string path, int lines)
        {
            try
            {
                if (!File.Exists(path)) return "";
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                                                   FileShare.ReadWrite | FileShare.Delete))
                {
                    // The tail of a large log: at most the last 256 KiB is decoded.
                    long start = Math.Max(0, stream.Length - 256 * 1024);
                    stream.Seek(start, SeekOrigin.Begin);
                    using (var reader = new StreamReader(stream, Encoding.UTF8))
                    {
                        string[] all = reader.ReadToEnd().Split('\n');
                        int from = Math.Max(start > 0 ? 1 : 0, all.Length - lines);
                        return string.Join("\n", all, from, all.Length - from).TrimEnd();
                    }
                }
            }
            catch (IOException) { return ""; }
            catch (UnauthorizedAccessException) { return ""; }
        }

        private void ShowLogViewer()
        {
            StackPanel form, actions;
            TextBlock error;
            var dialog = FormWindow(Texts.T("settings.view_log"), out form, out actions, out error,
                                    Math.Max(480, Math.Min(1100, ActualWidth - 48)));
            var text = new TextBox
            {
                IsReadOnly = true,
                AcceptsReturn = true,
                TextWrapping = TextWrapping.NoWrap,
                FontFamily = new FontFamily("Consolas, Courier New"),
                FontSize = 13,
                MinHeight = 320,
                MaxHeight = Math.Max(320, ActualHeight - 280),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            };
            AutomationLabel(text, Texts.T("settings.view_log"));
            AutomationId(text, "LogViewerText");
            form.Children.Add(text);
            Action load = () =>
            {
                string log = TailOf(Path.Combine(App.DataDir, "logs", "doorbell.log"), LogTailLines);
                string crash = TailOf(Path.Combine(App.DataDir, "crash.log"), 60);
                var all = new StringBuilder();
                if (crash.Length != 0)
                    all.Append("== ").Append(Texts.T("settings.log_crash")).Append(" ==\n")
                       .Append(crash).Append("\n\n");
                all.Append(log.Length != 0 ? log : Texts.T("settings.log_empty"));
                text.Text = all.ToString();
                text.ScrollToEnd();
            };
            var refresh = CommandButton(Texts.T("settings.log_refresh"));
            var copy = CommandButton(Texts.T("settings.log_copy"));
            var close = CommandButton(Texts.T("monitor.close"));
            copy.Margin = close.Margin = new Thickness(8, 0, 0, 0);
            close.IsCancel = true;
            AutomationId(close, "LogViewerClose");
            refresh.Click += (s, e) => load();
            copy.Click += (s, e) =>
            {
                try { Clipboard.SetText(text.Text); }
                catch (System.Runtime.InteropServices.ExternalException) { }
            };
            close.Click += (s, e) => dialog.DialogResult = false;
            actions.Children.Add(refresh);
            actions.Children.Add(copy);
            actions.Children.Add(close);
            load();
            dialog.ShowDialog();
        }

        // ---- direct configuration key editor ---------------------------------------------------

        private static readonly Regex RawKeyPattern = new Regex(@"^[A-Za-z0-9_][A-Za-z0-9_.:\-{}]{0,255}$");

        private void ShowRawConfig(RowParts parts)
        {
            StackPanel form, actions;
            TextBlock error;
            var dialog = FormWindow(Texts.T("settings.raw_config"), out form, out actions, out error, 720);
            form.Children.Add(FieldHint(Texts.T("settings.raw_config_desc")));
            form.Children.Add(FieldLabel(Texts.T("settings.raw_key")));
            var key = FormTextBox("", 256);
            AutomationLabel(key, Texts.T("settings.raw_key"));
            AutomationId(key, "RawConfigKey");
            form.Children.Add(key);
            form.Children.Add(FieldLabel(Texts.T("settings.raw_value")));
            var value = new TextBox
            {
                Style = (Style)FindResource("SettingsTextBox"),
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                FontFamily = new FontFamily("Consolas, Courier New"),
                MinHeight = 160,
                MaxHeight = 360,
                VerticalContentAlignment = VerticalAlignment.Top,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            };
            AutomationLabel(value, Texts.T("settings.raw_value"));
            AutomationId(value, "RawConfigValue");
            form.Children.Add(value);

            Action<string, bool> say = (message, bad) =>
            {
                error.Text = message;
                error.SetResourceReference(TextBlock.ForegroundProperty, bad ? "NegativeText" : "Ok");
                error.Visibility = Visibility.Visible;
            };
            Func<string> wantedKey = () =>
            {
                string name = key.Text.Trim();
                if (RawKeyPattern.IsMatch(name)) return name;
                say(Texts.T("settings.err_required"), true);
                return null;
            };
            var serializer = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
            var read = CommandButton(Texts.T("settings.raw_read"));
            var write = CommandButton(Texts.T("settings.raw_write"));
            var delete = CommandButton(Texts.T("settings.raw_delete"));
            var close = CommandButton(Texts.T("monitor.close"));
            write.Margin = delete.Margin = close.Margin = new Thickness(8, 0, 0, 0);
            DoorbellApp.Ui.Fluent.MakeDestructive(delete);
            close.IsCancel = true;
            AutomationId(close, "RawConfigClose");
            read.Click += (s, e) =>
            {
                string name = wantedKey();
                if (name == null) return;
                object stored = _store.Get(name);
                if (stored == null)
                {
                    value.Text = "";
                    say(Texts.T("settings.raw_absent"), false);
                    return;
                }
                value.Text = serializer.Serialize(stored);
                error.Visibility = Visibility.Collapsed;
            };
            write.Click += (s, e) =>
            {
                string name = wantedKey();
                if (name == null) return;
                object parsed;
                try { parsed = serializer.DeserializeObject(value.Text); }
                catch (ArgumentException) { say(Texts.T("settings.raw_invalid_json"), true); return; }
                catch (InvalidOperationException) { say(Texts.T("settings.raw_invalid_json"), true); return; }
                // JSON null is a deletion; that has its own button and its own confirmation.
                if (parsed == null) { say(Texts.T("settings.raw_invalid_json"), true); return; }
                if (!Confirm(Texts.T("settings.raw_write_confirm", name), true)) return;
                var result = _store.Set(name, parsed);
                if (result.Ok) say(Texts.T("admin.saved"), false);
                else say(Texts.T("settings.save_failed_reason", ErrorText(result.Error)), true);
            };
            delete.Click += (s, e) =>
            {
                string name = wantedKey();
                if (name == null) return;
                if (!Confirm(Texts.T("settings.raw_delete_confirm", name), true)) return;
                var result = _store.Delete(name);
                if (result.Ok)
                {
                    value.Text = "";
                    say(Texts.T("admin.saved"), false);
                }
                else say(Texts.T("settings.save_failed_reason", ErrorText(result.Error)), true);
            };
            close.Click += (s, e) => dialog.DialogResult = false;
            actions.Children.Add(read);
            actions.Children.Add(write);
            actions.Children.Add(delete);
            actions.Children.Add(close);
            dialog.ShowDialog();
            Refresh();
        }
    }
}
