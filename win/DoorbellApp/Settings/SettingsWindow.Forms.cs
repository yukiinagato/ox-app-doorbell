using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // The structured form every native editor shares: a modal card with one control per field,
    // read from and written back into a configuration object by dot path. Secret fields never
    // show a stored value; a typed value is provisioned into the secure store and the object
    // receives only its "secret:<name>" reference.
    internal sealed partial class SettingsWindow
    {
        internal enum FieldKind
        {
            Text, Number, Bool, Choice, Multi, Secret, Langs, List, NumberList, Windows, Color,
            Note,
        }

        internal sealed class Field
        {
            public string Path;
            public FieldKind Kind;
            public string LabelKey;
            /// <summary>A literal label, for one composed from several strings.</summary>
            public string Label;
            public string HintKey;
            public List<SettingOption> Options;
            public bool Required;
            public double Min = double.MinValue, Max = double.MaxValue;
            /// <summary>Secure-store name for a Secret field.</summary>
            public string SecretName;
            /// <summary>Converts the stored value before editing, and the edited value back.</summary>
            public Func<object, object> Load, Store;
            public Regex Pattern;
            public int MaxLength = 400;
        }

        private static Field Fld(string path, FieldKind kind, string labelKey)
        {
            return new Field { Path = path, Kind = kind, LabelKey = labelKey };
        }

        internal static readonly string[] Weekdays = { "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

        // ---- dot paths inside a configuration object ----------------------------------------

        internal static object GetPath(Dictionary<string, object> data, string path)
        {
            if (data == null || string.IsNullOrEmpty(path)) return null;
            object current = data;
            foreach (string part in path.Split('.'))
            {
                var map = current as Dictionary<string, object>;
                if (map == null || !map.TryGetValue(part, out current)) return null;
            }
            return current;
        }

        internal static void SetPath(Dictionary<string, object> data, string path, object value)
        {
            string[] parts = path.Split('.');
            var map = data;
            for (int i = 0; i < parts.Length - 1; i++)
            {
                object next;
                var child = map.TryGetValue(parts[i], out next) ? next as Dictionary<string, object> : null;
                if (child == null)
                {
                    if (value == null) return;
                    child = new Dictionary<string, object>();
                    map[parts[i]] = child;
                }
                map = child;
            }
            if (value == null) map.Remove(parts[parts.Length - 1]);
            else map[parts[parts.Length - 1]] = value;
        }

        internal static Dictionary<string, object> DeepCopy(Dictionary<string, object> source)
        {
            if (source == null) return new Dictionary<string, object>();
            var json = new JavaScriptSerializer();
            return json.Deserialize<Dictionary<string, object>>(json.Serialize(source)) ??
                   new Dictionary<string, object>();
        }

        private static List<string> StringList(object value)
        {
            var list = new List<string>();
            var items = value as IEnumerable;
            if (items == null || value is string)
            {
                if (value is string && ((string)value).Length > 0) list.Add((string)value);
                return list;
            }
            foreach (object item in items)
                if (item != null) list.Add(Convert.ToString(item, CultureInfo.InvariantCulture));
            return list;
        }

        // ---- the dialog ---------------------------------------------------------------------

        private Window FormWindow(string title, out StackPanel form, out StackPanel actions,
                                  out TextBlock error, double width = 600)
        {
            var dialog = new Window
            {
                Owner = this,
                Topmost = Topmost,
                Title = title ?? "",
                ResizeMode = ResizeMode.NoResize,
                SizeToContent = SizeToContent.Height,
                Width = Math.Min(width, Math.Max(320, ActualWidth - 32)),
                MaxHeight = Math.Max(360, ActualHeight - 48),
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                ShowInTaskbar = false,
                FontFamily = FontFamily,
            };
            DoorbellApp.Ui.Fluent.StyleWindow(dialog);
            var outer = new DockPanel { Margin = new Thickness(24) };
            var heading = new TextBlock
            {
                Text = title,
                FontSize = 22,
                FontWeight = FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 12),
            };
            DockPanel.SetDock(heading, Dock.Top);
            outer.Children.Add(heading);
            actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 16, 0, 0),
            };
            DockPanel.SetDock(actions, Dock.Bottom);
            outer.Children.Add(actions);
            error = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap,
                                    Visibility = Visibility.Collapsed,
                                    Margin = new Thickness(0, 8, 0, 0) };
            error.SetResourceReference(TextBlock.ForegroundProperty, "NegativeText");
            DockPanel.SetDock(error, Dock.Bottom);
            outer.Children.Add(error);
            form = new StackPanel();
            outer.Children.Add(new ScrollViewer
            {
                Content = form,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                PanningMode = PanningMode.VerticalOnly,
            });
            dialog.Content = outer;
            return dialog;
        }

        private Button PrimaryButton(string text)
        {
            // The dialog's one primary action: the Fluent accent button at touch size.
            var button = new Button
            {
                Content = text,
                FontSize = 15,
                MinHeight = MinTouchTarget,
                MinWidth = MinTouchTarget,
                Padding = new Thickness(16, 6, 16, 6),
            };
            DoorbellApp.Ui.Fluent.MakeAccent(button);
            return button;
        }

        private TextBlock FieldLabel(string text)
        {
            return new TextBlock
            {
                Text = text,
                FontSize = 14,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 12, 0, 4),
            };
        }

        private TextBlock FieldHint(string text)
        {
            var hint = new TextBlock
            {
                Text = text,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 3, 0, 0),
            };
            hint.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
            return hint;
        }

        private TextBox FormTextBox(string value, int maxLength = 400)
        {
            return new TextBox
            {
                Style = (Style)FindResource("SettingsTextBox"),
                Text = value ?? "",
                MaxLength = maxLength,
            };
        }

        /// <summary>
        /// Shows the form for data (edited in place on Save). validate returns an error message,
        /// or null when the object may be saved. Returns false when cancelled.
        /// </summary>
        internal bool ShowForm(string title, List<Field> fields, Dictionary<string, object> data,
                               Func<Dictionary<string, object>, string> validate = null,
                               Func<StackPanel, Dictionary<string, object>,
                                    Func<Dictionary<string, object>, string>> extra = null)
        {
            StackPanel form, actions;
            TextBlock error;
            var dialog = FormWindow(title, out form, out actions, out error);
            // Each field contributes a reader that returns false (with a message) on bad input.
            var readers = new List<Func<Dictionary<string, object>, string>>();
            foreach (var field in fields)
            {
                object raw = GetPath(data, field.Path);
                object value = field.Load != null ? field.Load(raw) : raw;
                readers.Add(BuildField(form, field, value));
            }
            if (extra != null) readers.Add(extra(form, data));
            var cancel = CommandButton(Texts.T("admin.cancel"));
            var save = PrimaryButton(Texts.T("admin.save"));
            save.Margin = new Thickness(8, 0, 0, 0);
            save.IsDefault = true;
            cancel.IsCancel = true;
            actions.Children.Add(cancel);
            actions.Children.Add(save);
            cancel.Click += (s, e) => dialog.DialogResult = false;
            save.Click += (s, e) =>
            {
                var draft = DeepCopy(data);
                foreach (var read in readers)
                {
                    string problem = read(draft);
                    if (problem == null) continue;
                    error.Text = problem;
                    error.Visibility = Visibility.Visible;
                    return;
                }
                string invalid = validate == null ? null : validate(draft);
                if (invalid != null)
                {
                    error.Text = invalid;
                    error.Visibility = Visibility.Visible;
                    return;
                }
                data.Clear();
                foreach (var pair in draft) data[pair.Key] = pair.Value;
                dialog.DialogResult = true;
            };
            return dialog.ShowDialog() == true;
        }

        private Func<Dictionary<string, object>, string> BuildField(StackPanel form, Field field,
                                                                   object value)
        {
            string label = field.Label ?? Texts.T(field.LabelKey);
            Func<object, object> store = field.Store ?? (v => v);
            Func<Dictionary<string, object>, object, string> put = (draft, v) =>
            {
                SetPath(draft, field.Path, store(v));
                return null;
            };
            if (field.Kind != FieldKind.Bool) form.Children.Add(FieldLabel(label));
            Func<Dictionary<string, object>, string> reader;
            switch (field.Kind)
            {
                case FieldKind.Note:
                    reader = draft => null;
                    break;
                case FieldKind.Bool:
                {
                    var line = new DockPanel { Margin = new Thickness(0, 14, 0, 0) };
                    var toggle = DoorbellApp.Ui.Fluent.Switch(SettingsStore.AsBool(value, false));
                    AutomationLabel(toggle, label);
                    DockPanel.SetDock(toggle, Dock.Right);
                    line.Children.Add(toggle);
                    line.Children.Add(new TextBlock
                    {
                        Text = label,
                        FontSize = 16,
                        TextWrapping = TextWrapping.Wrap,
                        VerticalAlignment = VerticalAlignment.Center,
                    });
                    form.Children.Add(line);
                    reader = draft => put(draft, toggle.IsOn);
                    break;
                }
                case FieldKind.Number:
                {
                    var box = FormTextBox(value == null ? "" :
                        Convert.ToString(value, CultureInfo.InvariantCulture), 16);
                    AutomationLabel(box, label);
                    form.Children.Add(box);
                    reader = draft =>
                    {
                        string text = box.Text.Trim();
                        if (text.Length == 0)
                            return field.Required ? Texts.T("settings.err_required") : put(draft, null);
                        double number;
                        if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture,
                                             out number) || number < field.Min || number > field.Max)
                            return Texts.T("settings.form_number_range", label,
                                field.Min == double.MinValue ? "" : field.Min.ToString(CultureInfo.InvariantCulture),
                                field.Max == double.MaxValue ? "" : field.Max.ToString(CultureInfo.InvariantCulture));
                        return put(draft, Math.Abs(number - Math.Round(number)) < 1e-9
                            ? (object)(long)Math.Round(number) : number);
                    };
                    break;
                }
                case FieldKind.Choice:
                {
                    var combo = new ComboBox { Style = (Style)FindResource("SettingsComboBox") };
                    AutomationLabel(combo, label);
                    int selected = -1;
                    string wanted = value == null ? null : Convert.ToString(value, CultureInfo.InvariantCulture);
                    for (int i = 0; i < field.Options.Count; i++)
                    {
                        combo.Items.Add(new ComboBoxItem { Content = OptionText(field.Options[i]),
                                                           MinHeight = MinTouchTarget });
                        if (Convert.ToString(field.Options[i].Value, CultureInfo.InvariantCulture) == wanted)
                            selected = i;
                    }
                    if (selected < 0 && !field.Required && field.Options.Count > 0 && wanted == null)
                        selected = -1;
                    combo.SelectedIndex = selected;
                    form.Children.Add(combo);
                    reader = draft =>
                    {
                        if (combo.SelectedIndex < 0)
                            return field.Required ? Texts.T("settings.err_required") : put(draft, null);
                        return put(draft, field.Options[combo.SelectedIndex].Value);
                    };
                    break;
                }
                case FieldKind.Multi:
                {
                    var chosen = StringList(value);
                    var wrap = new WrapPanel();
                    var boxes = new List<CheckBox>();
                    foreach (var option in field.Options)
                    {
                        var box = new CheckBox
                        {
                            Content = OptionText(option),
                            IsChecked = chosen.Contains(Convert.ToString(option.Value, CultureInfo.InvariantCulture)),
                            FontSize = 15,
                            MinHeight = MinTouchTarget,
                            VerticalContentAlignment = VerticalAlignment.Center,
                            Margin = new Thickness(0, 0, 18, 0),
                        };
                        boxes.Add(box);
                        wrap.Children.Add(box);
                    }
                    if (field.Options.Count == 0) wrap.Children.Add(FieldHint(Texts.T("settings.list_empty")));
                    form.Children.Add(wrap);
                    reader = draft =>
                    {
                        var list = new List<object>();
                        for (int i = 0; i < boxes.Count; i++)
                            if (boxes[i].IsChecked == true) list.Add(field.Options[i].Value);
                        if (list.Count == 0 && field.Required) return Texts.T("settings.err_required");
                        return put(draft, list);
                    };
                    break;
                }
                case FieldKind.Secret:
                {
                    string reference = value as string;
                    string name = ExpandSecretName(field.SecretName);
                    bool stored = !string.IsNullOrEmpty(reference) && App.Core != null &&
                                  App.Core.HasSecret(SecretNameOf(reference));
                    var box = new PasswordBox { FontSize = 16, MinHeight = MinTouchTarget,
                                                MaxLength = 512 };
                    AutomationLabel(box, label);
                    form.Children.Add(box);
                    form.Children.Add(FieldHint(Texts.T(stored ? "settings.secret_stored"
                        : string.IsNullOrEmpty(reference) ? "settings.secret_none"
                                                          : "settings.secret_missing_here")));
                    reader = draft =>
                    {
                        string typed = box.Password ?? "";
                        if (typed.Length == 0)
                        {
                            if (field.Required && string.IsNullOrEmpty(reference))
                                return Texts.T("settings.err_required");
                            return null;
                        }
                        string target = string.IsNullOrEmpty(reference) ? "secret:" + name : reference;
                        string failure = ProvisionSecret(target, typed);
                        if (failure != null) return failure;
                        SetPath(draft, field.Path, target);
                        return null;
                    };
                    break;
                }
                case FieldKind.Langs:
                {
                    var map = value as Dictionary<string, object>;
                    var boxes = new Dictionary<string, TextBox>();
                    foreach (string lang in new[] { "ja", "en", "zh" })
                    {
                        string langKey = "language.name_" + lang;
                        form.Children.Add(FieldHint(Texts.T(langKey)));
                        var box = FormTextBox(map == null ? "" : Str(map, lang), field.MaxLength);
                        AutomationLabel(box, label + " " + lang);
                        boxes[lang] = box;
                        form.Children.Add(box);
                    }
                    reader = draft =>
                    {
                        var labels = map == null ? new Dictionary<string, object>()
                                                 : new Dictionary<string, object>(map);
                        foreach (var pair in boxes)
                        {
                            string text = pair.Value.Text.Trim();
                            if (text.Length > 0) labels[pair.Key] = text;
                            else labels.Remove(pair.Key);
                        }
                        if (labels.Count == 0)
                            return field.Required ? Texts.T("settings.err_required") : put(draft, null);
                        return put(draft, labels);
                    };
                    break;
                }
                case FieldKind.List:
                case FieldKind.NumberList:
                {
                    var box = FormTextBox(string.Join(", ", StringList(value)), 2000);
                    AutomationLabel(box, label);
                    form.Children.Add(box);
                    form.Children.Add(FieldHint(Texts.T("settings.form_list_hint")));
                    reader = draft =>
                    {
                        var list = new List<object>();
                        foreach (string piece in box.Text.Split(new[] { ',', '\n', ';' },
                                                                StringSplitOptions.RemoveEmptyEntries))
                        {
                            string text = piece.Trim();
                            if (text.Length == 0) continue;
                            if (field.Kind == FieldKind.NumberList)
                            {
                                long number;
                                if (!long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture,
                                                   out number))
                                    return Texts.T("settings.form_number_list", label);
                                list.Add(number);
                            }
                            else
                            {
                                if (field.Pattern != null && !field.Pattern.IsMatch(text))
                                    return Texts.T("settings.form_invalid", label, text);
                                list.Add(text);
                            }
                        }
                        if (list.Count == 0 && field.Required) return Texts.T("settings.err_required");
                        return put(draft, list.Count == 0 ? null : list);
                    };
                    break;
                }
                case FieldKind.Windows:
                    reader = BuildWindowsField(form, field, value, put);
                    break;
                case FieldKind.Color:
                {
                    var line = new DockPanel();
                    var pick = CommandButton(Texts.T("settings.color_pick"));
                    pick.Margin = new Thickness(8, 0, 0, 0);
                    DockPanel.SetDock(pick, Dock.Right);
                    line.Children.Add(pick);
                    var box = FormTextBox(value as string, 9);
                    AutomationLabel(box, label);
                    line.Children.Add(box);
                    pick.Click += (s, e) =>
                    {
                        string chosen = PickColor(box.Text);
                        if (chosen != null) box.Text = chosen;
                    };
                    form.Children.Add(line);
                    reader = draft =>
                    {
                        string text = box.Text.Trim();
                        if (text.Length == 0)
                            return field.Required ? Texts.T("settings.err_required") : put(draft, null);
                        if (!ColorPattern.IsMatch(text)) return Texts.T("prefs.invalid_color");
                        return put(draft, text.ToUpperInvariant());
                    };
                    break;
                }
                default:
                {
                    var box = FormTextBox(value == null ? "" :
                        Convert.ToString(value, CultureInfo.InvariantCulture), field.MaxLength);
                    AutomationLabel(box, label);
                    form.Children.Add(box);
                    reader = draft =>
                    {
                        string text = box.Text.Trim();
                        if (text.Length == 0)
                            return field.Required ? Texts.T("settings.err_required") : put(draft, null);
                        if (field.Pattern != null && !field.Pattern.IsMatch(text))
                            return Texts.T("settings.form_invalid", label, text);
                        return put(draft, text);
                    };
                    break;
                }
            }
            if (!string.IsNullOrEmpty(field.HintKey)) form.Children.Add(FieldHint(Texts.T(field.HintKey)));
            return reader;
        }

        internal static readonly Regex ColorPattern = new Regex("^#[0-9A-Fa-f]{6}$");

        /// <summary>The Windows colour dialog, seeded with the current value.</summary>
        private static string PickColor(string current)
        {
            using (var dialog = new System.Windows.Forms.ColorDialog { FullOpen = true, AnyColor = true })
            {
                if (current != null && ColorPattern.IsMatch(current.Trim()))
                {
                    int rgb = int.Parse(current.Trim().Substring(1), NumberStyles.HexNumber,
                                        CultureInfo.InvariantCulture);
                    dialog.Color = System.Drawing.Color.FromArgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF,
                                                                 rgb & 0xFF);
                }
                if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return null;
                return "#" + dialog.Color.R.ToString("X2") + dialog.Color.G.ToString("X2") +
                       dialog.Color.B.ToString("X2");
            }
        }

        /// <summary>
        /// Time windows ({from,to,days}) with weekday chips. A window on every day is stored
        /// without days, which is how Core reads "daily".
        /// </summary>
        private Func<Dictionary<string, object>, string> BuildWindowsField(
            StackPanel form, Field field, object value,
            Func<Dictionary<string, object>, object, string> put)
        {
            var rows = new List<Tuple<TextBox, TextBox, List<ToggleButton>>>();
            var host = new StackPanel();
            form.Children.Add(host);
            Action<Dictionary<string, object>> addRow = null;
            addRow = window =>
            {
                var line = new StackPanel { Margin = new Thickness(0, 6, 0, 6) };
                var times = new StackPanel { Orientation = Orientation.Horizontal };
                var start = FormTextBox(window == null ? "22:00" : Str(window, "from"), 5);
                var end = FormTextBox(window == null ? "06:00" : Str(window, "to"), 5);
                start.Width = 96;
                end.Width = 96;
                AutomationLabel(start, Texts.T("prefs.from"));
                AutomationLabel(end, Texts.T("prefs.to"));
                times.Children.Add(start);
                times.Children.Add(new TextBlock { Text = "–", FontSize = 18, Margin = new Thickness(8, 0, 8, 0),
                                                   VerticalAlignment = VerticalAlignment.Center });
                times.Children.Add(end);
                var remove = CommandButton(Texts.T("admin.delete"));
                DoorbellApp.Ui.Fluent.MakeDestructive(remove);
                remove.Margin = new Thickness(12, 0, 0, 0);
                times.Children.Add(remove);
                line.Children.Add(times);
                var days = new List<ToggleButton>();
                var chosen = window == null ? new List<string>() : StringList(window.ContainsKey("days") ? window["days"] : null);
                var dayRow = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
                foreach (string day in Weekdays)
                {
                    var chip = new ToggleButton
                    {
                        Content = Texts.T("day." + day),
                        IsChecked = chosen.Count == 0 || chosen.Contains(day),
                        MinHeight = MinTouchTarget,
                        MinWidth = MinTouchTarget,
                        Margin = new Thickness(0, 0, 4, 4),
                        FontSize = 14,
                    };
                    days.Add(chip);
                    dayRow.Children.Add(chip);
                }
                line.Children.Add(dayRow);
                var entry = Tuple.Create(start, end, days);
                rows.Add(entry);
                host.Children.Add(line);
                remove.Click += (s, e) =>
                {
                    rows.Remove(entry);
                    host.Children.Remove(line);
                };
            };
            var items = value as IEnumerable;
            if (items != null && !(value is string))
                foreach (object item in items)
                    addRow(item as Dictionary<string, object> ?? new Dictionary<string, object>());
            var add = CommandButton(Texts.T("admin.add_window"));
            add.HorizontalAlignment = HorizontalAlignment.Left;
            add.Click += (s, e) => addRow(null);
            form.Children.Add(add);
            return draft =>
            {
                var list = new List<object>();
                foreach (var row in rows)
                {
                    string start = row.Item1.Text.Trim(), end = row.Item2.Text.Trim();
                    if (!TimePattern.IsMatch(start) || !TimePattern.IsMatch(end))
                        return Texts.T("prefs.invalid_time");
                    var window = new Dictionary<string, object> { { "from", start }, { "to", end } };
                    var days = new List<object>();
                    for (int i = 0; i < Weekdays.Length; i++)
                        if (row.Item3[i].IsChecked == true) days.Add(Weekdays[i]);
                    if (days.Count == 0) return Texts.T("settings.form_days_required");
                    if (days.Count < Weekdays.Length) window["days"] = days;
                    list.Add(window);
                }
                if (list.Count == 0 && field.Required) return Texts.T("settings.err_required");
                return put(draft, list);
            };
        }

        // ---- secrets ------------------------------------------------------------------------

        private string ExpandSecretName(string name)
        {
            return string.IsNullOrEmpty(name) ? "custom." + NewId("secret").Substring(3)
                                              : name.Replace("{self}", _store.Context.NodeId);
        }

        internal static string SecretNameOf(string reference)
        {
            return reference != null && reference.StartsWith("secret:", StringComparison.Ordinal)
                ? reference.Substring(7) : reference;
        }

        private static readonly Regex SecretRefPattern = new Regex(@"^secret:[A-Za-z0-9._-]{1,128}$");

        /// <summary>
        /// Writes one secret value on this device. The loopback admin API is preferred because
        /// Core then reapplies SIP, MQTT and speech at once; without a session the value goes
        /// straight into the DPAPI store, and the following configuration write reapplies it.
        /// Returns an error message, or null on success. The value is never logged.
        /// </summary>
        internal string ProvisionSecret(string reference, string value)
        {
            if (!SecretRefPattern.IsMatch(reference ?? "")) return Texts.T("settings.secret_bad_name");
            string body = new JavaScriptSerializer().Serialize(new Dictionary<string, object>
                { { "secret_ref", reference }, { "value", value } });
            int status;
            string result = AdminHttpSession.Request("POST", "/api/secrets", body, out status);
            if (status == 200 && result != null && result.Contains("\"ok\":true")) return null;
            if (App.Core != null && App.Core.PutSecret(SecretNameOf(reference), value)) return null;
            return Texts.T("settings.secret_failed");
        }

        internal bool RemoveSecret(string reference)
        {
            if (!SecretRefPattern.IsMatch(reference ?? "")) return false;
            string body = new JavaScriptSerializer().Serialize(new Dictionary<string, object>
                { { "secret_ref", reference } });
            int status;
            string result = AdminHttpSession.Request("DELETE", "/api/secrets", body, out status);
            if (status == 200 && result != null && result.Contains("\"ok\":true")) return true;
            return App.Core != null && App.Core.DeleteSecret(SecretNameOf(reference));
        }

        /// <summary>Asks for the administrator password for the loopback session.</summary>
        private string PromptSessionPassword()
        {
            if (!Dispatcher.CheckAccess())
                return (string)Dispatcher.Invoke(new Func<string>(PromptSessionPassword));
            StackPanel form, actions;
            TextBlock error;
            var dialog = FormWindow(Texts.T("settings.session_title"), out form, out actions, out error, 480);
            form.Children.Add(FieldHint(Texts.T("settings.session_hint")));
            var box = new PasswordBox { FontSize = 16, MinHeight = MinTouchTarget,
                                        Margin = new Thickness(0, 12, 0, 0) };
            AutomationLabel(box, Texts.T("admin.password"));
            form.Children.Add(box);
            var cancel = CommandButton(Texts.T("admin.cancel"));
            var ok = PrimaryButton(Texts.T("admin.login"));
            ok.Margin = new Thickness(8, 0, 0, 0);
            ok.IsDefault = true;
            cancel.IsCancel = true;
            actions.Children.Add(cancel);
            actions.Children.Add(ok);
            string password = null;
            cancel.Click += (s, e) => dialog.DialogResult = false;
            ok.Click += (s, e) =>
            {
                if (string.IsNullOrEmpty(box.Password)) return;
                password = box.Password;
                dialog.DialogResult = true;
            };
            dialog.Loaded += (s, e) => box.Focus();
            return dialog.ShowDialog() == true ? password : null;
        }
    }
}
