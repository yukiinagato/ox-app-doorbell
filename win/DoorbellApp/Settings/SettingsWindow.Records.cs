using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // A configuration map edited as a list of records (doors, buildings, households, external
    // cameras, DTMF codes, rules). Each change is one batch: a saved record is written as its
    // whole object under <map>.<id>, a removal tombstones that key. Maps whose ids are not dot
    // path safe (DTMF codes) are written as one value.
    internal sealed partial class SettingsWindow
    {
        internal sealed class RecordSpec
        {
            public string Key;
            /// <summary>New ids are generated with this prefix; null asks the operator for one.</summary>
            public string IdPrefix;
            public string IdLabelKey;
            public Regex IdPattern;
            public bool WholeMap;
            public Func<List<Field>> Fields;
            public Func<string, Dictionary<string, object>, string> Title;
            public Func<string, Dictionary<string, object>, string> Subtitle;
            public Func<string, Dictionary<string, object>, string> Validate;
            /// <summary>Runs after a record committed (for writes outside the record).</summary>
            public Action<string, Dictionary<string, object>> AfterSave;
            /// <summary>Optional custom editor replacing ShowForm (returns false when cancelled).</summary>
            public Func<string, Dictionary<string, object>, bool, bool> Edit;
            /// <summary>Default contents for a new record.</summary>
            public Func<Dictionary<string, object>> Seed;
            /// <summary>Extra per-record buttons.</summary>
            public Func<string, Dictionary<string, object>, IEnumerable<Button>> Extra;
        }

        private Dictionary<string, Dictionary<string, object>> ReadRecords(string key)
        {
            var records = new Dictionary<string, Dictionary<string, object>>();
            var map = _store.Get(key) as Dictionary<string, object>;
            if (map == null) return records;
            foreach (var pair in map)
            {
                var data = pair.Value as Dictionary<string, object>;
                if (data != null) records[pair.Key] = data;
            }
            return records;
        }

        private FrameworkElement BuildRecords(SettingItem item, RecordSpec spec)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var add = CommandButton(Texts.T("admin.add"));
            head.Children.Insert(0, add);
            DockPanel.SetDock(add, Dock.Right);
            var records = ReadRecords(spec.Key);
            var ids = new List<string>(records.Keys);
            ids.Sort((a, b) => string.Compare(spec.Title(a, records[a]), spec.Title(b, records[b]),
                                              StringComparison.CurrentCulture));
            foreach (string id in ids) panel.Children.Add(RecordRow(spec, id, records, parts));
            if (ids.Count == 0) panel.Children.Add(EmptyLine());
            panel.Children.Add(parts.Error);
            add.Click += (s, e) =>
            {
                var data = spec.Seed != null ? spec.Seed() : new Dictionary<string, object>();
                string id = spec.IdPrefix == null ? AskId(spec, records) : NewRecordId(spec.IdPrefix);
                if (id == null) return;
                if (!EditRecord(spec, id, data, true)) return;
                if (SaveRecord(spec, id, data, records, parts)) Refresh();
            };
            return panel;
        }

        private FrameworkElement RecordRow(RecordSpec spec, string id,
                                           Dictionary<string, Dictionary<string, object>> records,
                                           RowParts parts)
        {
            var data = records[id];
            var buttons = new List<Button>();
            if (spec.Extra != null) buttons.AddRange(spec.Extra(id, data));
            var edit = CommandButton(Texts.T("admin.edit"));
            var remove = CommandButton(Texts.T("admin.delete"));
            remove.SetResourceReference(ForegroundProperty, "Negative");
            buttons.Add(edit);
            buttons.Add(remove);
            edit.Click += (s, e) =>
            {
                var copy = DeepCopy(data);
                if (!EditRecord(spec, id, copy, false)) return;
                if (SaveRecord(spec, id, copy, records, parts)) Refresh();
            };
            remove.Click += (s, e) =>
            {
                if (!Confirm(Texts.T("admin.confirm_delete", spec.Title(id, data)), true)) return;
                SettingsWriteResult result;
                if (spec.WholeMap)
                {
                    var map = new Dictionary<string, object>();
                    foreach (var pair in records) if (pair.Key != id) map[pair.Key] = pair.Value;
                    result = _store.Set(spec.Key, map);
                }
                else result = _store.Delete(spec.Key + "." + id);
                if (Report(result, parts)) Refresh();
            };
            return ItemLine(spec.Title(id, data), spec.Subtitle == null ? "" : spec.Subtitle(id, data),
                            buttons);
        }

        private bool EditRecord(RecordSpec spec, string id, Dictionary<string, object> data, bool isNew)
        {
            if (spec.Edit != null) return spec.Edit(id, data, isNew);
            string title = Texts.T(isNew ? "admin.add" : "admin.edit") + " · " +
                           (isNew ? id : spec.Title(id, data));
            return ShowForm(title, spec.Fields(), data,
                            spec.Validate == null ? null : (Func<Dictionary<string, object>, string>)
                                (draft => spec.Validate(id, draft)));
        }

        private bool SaveRecord(RecordSpec spec, string id, Dictionary<string, object> data,
                                Dictionary<string, Dictionary<string, object>> records, RowParts parts)
        {
            SettingsWriteResult result;
            if (spec.WholeMap)
            {
                var map = new Dictionary<string, object>();
                foreach (var pair in records) map[pair.Key] = pair.Value;
                map[id] = data;
                result = _store.Set(spec.Key, map);
            }
            else result = _store.Set(spec.Key + "." + id, data);
            if (!Report(result, parts)) return false;
            if (spec.AfterSave != null) spec.AfterSave(id, data);
            return true;
        }

        private string AskId(RecordSpec spec, Dictionary<string, Dictionary<string, object>> records)
        {
            var data = new Dictionary<string, object>();
            var field = Fld("id", FieldKind.Text, spec.IdLabelKey ?? "admin.key");
            field.Required = true;
            field.Pattern = spec.IdPattern;
            field.MaxLength = 64;
            if (!ShowForm(Texts.T("admin.add"), new List<Field> { field }, data, draft =>
                    records.ContainsKey(Str(draft, "id")) ? Texts.T("settings.form_id_taken") : null))
                return null;
            return Str(data, "id");
        }

        private static string NewRecordId(string prefix)
        {
            return prefix + NewId("x").Substring(3);
        }

        // ---- shared editor layout -----------------------------------------------------------

        /// <summary>A full-width editor section: description and a right-aligned header area.</summary>
        private StackPanel EditorPanel(SettingItem item, RowParts parts, out DockPanel head)
        {
            var panel = new StackPanel { Margin = new Thickness(16, 10, 12, 10) };
            head = new DockPanel();
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center,
                                        Margin = new Thickness(0, 0, 12, 0) };
            text.Children.Add(new TextBlock
            {
                Text = Texts.T(item.LabelKey),
                FontSize = 17,
                TextWrapping = TextWrapping.Wrap,
            });
            string detail = Detail(item);
            if (detail.Length > 0)
            {
                var description = new TextBlock
                {
                    Text = detail,
                    FontSize = 13,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 3, 0, 0),
                };
                description.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
                text.Children.Add(description);
            }
            head.Children.Add(text);
            panel.Children.Add(head);
            parts.Error = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap,
                                          Visibility = Visibility.Collapsed,
                                          Margin = new Thickness(0, 8, 0, 0) };
            parts.Error.SetResourceReference(TextBlock.ForegroundProperty, "Negative");
            return panel;
        }

        private TextBlock EmptyLine(string key = "settings.list_empty")
        {
            var empty = new TextBlock
            {
                Text = Texts.T(key),
                FontSize = 15,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 12, 0, 0),
            };
            empty.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
            return empty;
        }

        /// <summary>
        /// One item: title and subtitle, buttons on the right. On a narrow window the buttons
        /// wrap underneath so the text is never covered.
        /// </summary>
        private FrameworkElement ItemLine(string title, string subtitle, IEnumerable<Button> buttons)
        {
            bool narrow = ActualWidth < 700;
            var row = new Grid { Margin = new Thickness(0, 10, 0, 0), MinHeight = 52 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center,
                                        Margin = new Thickness(0, 0, 12, 0) };
            text.Children.Add(new TextBlock { Text = title, FontSize = 16, TextWrapping = TextWrapping.Wrap });
            if (!string.IsNullOrEmpty(subtitle))
            {
                var sub = new TextBlock { Text = subtitle, FontSize = 13, TextWrapping = TextWrapping.Wrap };
                sub.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
                text.Children.Add(sub);
            }
            row.Children.Add(text);
            var bar = new WrapPanel { VerticalAlignment = VerticalAlignment.Center };
            foreach (var button in buttons)
            {
                button.Margin = new Thickness(narrow ? 0 : 6, 4, narrow ? 6 : 0, 0);
                bar.Children.Add(button);
            }
            if (narrow)
            {
                Grid.SetRow(bar, 1);
                bar.Margin = new Thickness(0, 6, 0, 0);
            }
            else Grid.SetColumn(bar, 1);
            row.Children.Add(bar);
            return row;
        }

        // ---- option sources from configuration -----------------------------------------------

        internal static string LabelText(object label, string fallback)
        {
            var map = label as Dictionary<string, object>;
            if (map == null) return fallback;
            string text = Str(map, Texts.Lang ?? "ja");
            if (text.Length == 0)
                foreach (string lang in new[] { "ja", "en", "zh" })
                    if ((text = Str(map, lang)).Length > 0) break;
            return text.Length > 0 ? text : fallback;
        }

        private List<SettingOption> RecordOptions(string key, Func<string, Dictionary<string, object>, string> title)
        {
            var options = new List<SettingOption>();
            var records = ReadRecords(key);
            var ids = new List<string>(records.Keys);
            ids.Sort(StringComparer.Ordinal);
            foreach (string id in ids) options.Add(new SettingOption(id, null, title(id, records[id])));
            return options;
        }

        private List<SettingOption> DoorOptions()
        {
            return RecordOptions("doors", (id, d) => LabelText(d.ContainsKey("label") ? d["label"] : null, id));
        }

        private List<SettingOption> BuildingOptions()
        {
            return RecordOptions("buildings", (id, d) => LabelText(d.ContainsKey("label") ? d["label"] : null, id));
        }

        private List<SettingOption> HouseholdOptions()
        {
            return RecordOptions("households", (id, d) => LabelText(d.ContainsKey("label") ? d["label"] : null, id));
        }

        private List<SettingOption> DeviceOptions(string role = null)
        {
            var options = new List<SettingOption>();
            foreach (var pair in ReadRecords("devices"))
            {
                if (role != null && Str(pair.Value, "role") != role) continue;
                string name = Str(pair.Value, "name");
                options.Add(new SettingOption(pair.Key, null, name.Length > 0 ? name : pair.Key));
            }
            options.Sort((a, b) => string.Compare(a.Text, b.Text, StringComparison.CurrentCulture));
            return options;
        }

        private List<SettingOption> ReplyOptions()
        {
            return RecordOptions("quick_replies", (id, d) => LabelText(d.ContainsKey("label") ? d["label"] : null, id));
        }

        private List<SettingOption> PurposeOptions()
        {
            return RecordOptions("visit_purposes", (id, d) =>
                (Str(d, "icon").Length > 0 ? Str(d, "icon") + " " : "") +
                LabelText(d.ContainsKey("label") ? d["label"] : null, id));
        }

        private static string Joined(IEnumerable<SettingOption> options, object values)
        {
            var chosen = StringList(values);
            var names = new List<string>();
            foreach (var option in options)
                if (chosen.Contains(Convert.ToString(option.Value))) names.Add(OptionText(option));
            foreach (string value in chosen)
            {
                bool known = false;
                foreach (var option in options) if (Convert.ToString(option.Value) == value) known = true;
                if (!known) names.Add(value);
            }
            return string.Join(", ", names);
        }
    }
}
