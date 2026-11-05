using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // List editors for quick replies, visit purposes and announcement presets. Each change is one
    // batch: an edited entry is written as its whole object, a reorder rewrites both orders, and
    // the preset array is written as one value.
    internal sealed partial class SettingsWindow
    {
        private sealed class ListEntry
        {
            public string Id;
            public Dictionary<string, object> Data;
            public double Order;
        }

        private FrameworkElement BuildListEditor(SettingItem item)
        {
            var parts = new RowParts();
            var panel = new StackPanel { Margin = new Thickness(16, 10, 12, 10) };
            var head = new DockPanel();
            var add = CommandButton(Texts.T("admin.add"));
            DockPanel.SetDock(add, Dock.Right);
            head.Children.Add(add);
            var description = new TextBlock
            {
                Text = Detail(item),
                FontSize = 13,
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center,
            };
            description.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
            head.Children.Add(description);
            panel.Children.Add(head);
            parts.Error = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap,
                                          Visibility = Visibility.Collapsed };
            parts.Error.SetResourceReference(TextBlock.ForegroundProperty, "Danger");

            List<ListEntry> entries = ReadEntries(item);
            for (int i = 0; i < entries.Count; i++)
                panel.Children.Add(EntryRow(item, entries, i, parts));
            if (entries.Count == 0)
            {
                var empty = new TextBlock
                {
                    Text = Texts.T("settings.list_empty"),
                    FontSize = 15,
                    Margin = new Thickness(0, 12, 0, 0),
                };
                empty.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
                panel.Children.Add(empty);
            }
            panel.Children.Add(parts.Error);
            add.Click += (s, e) =>
            {
                var created = EditEntry(item, null);
                if (created == null) return;
                double order = entries.Count == 0 ? 1 : entries[entries.Count - 1].Order + 1;
                created.Order = order;
                if (item.Handler != "notice_presets") created.Data["order"] = (long)order;
                entries.Add(created);
                if (SaveEntry(item, entries, created, parts)) Refresh();
            };
            return panel;
        }

        private FrameworkElement EntryRow(SettingItem item, List<ListEntry> entries, int index,
                                          RowParts parts)
        {
            var entry = entries[index];
            var row = new DockPanel { Margin = new Thickness(0, 10, 0, 0), MinHeight = 52 };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal };
            DockPanel.SetDock(buttons, Dock.Right);
            var up = CommandButton("↑");
            var down = CommandButton("↓");
            var edit = CommandButton(Texts.T("admin.edit"));
            var remove = CommandButton(Texts.T("admin.delete"));
            AutomationLabel(up, Texts.T("settings.move_up"));
            AutomationLabel(down, Texts.T("settings.move_down"));
            up.IsEnabled = index > 0;
            down.IsEnabled = index < entries.Count - 1;
            foreach (var b in new[] { up, down, edit, remove })
            {
                b.Margin = new Thickness(6, 0, 0, 0);
                buttons.Children.Add(b);
            }
            row.Children.Add(buttons);
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock
            {
                Text = EntryTitle(item, entry),
                FontSize = 16,
                TextWrapping = TextWrapping.Wrap,
            });
            string sub = EntrySubtitle(item, entry);
            if (sub.Length > 0)
            {
                var subText = new TextBlock { Text = sub, FontSize = 13 };
                subText.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
                text.Children.Add(subText);
            }
            row.Children.Add(text);

            up.Click += (s, e) => { if (Swap(item, entries, index, index - 1, parts)) Refresh(); };
            down.Click += (s, e) => { if (Swap(item, entries, index, index + 1, parts)) Refresh(); };
            edit.Click += (s, e) =>
            {
                var edited = EditEntry(item, entry);
                if (edited == null) return;
                edited.Order = entry.Order;
                entries[index] = edited;
                if (SaveEntry(item, entries, edited, parts)) Refresh();
            };
            remove.Click += (s, e) =>
            {
                if (!Confirm(Texts.T("admin.confirm_delete", EntryTitle(item, entry)))) return;
                bool ok;
                if (item.Handler == "notice_presets")
                {
                    entries.RemoveAt(index);
                    ok = Report(_store.Set(item.Key, PresetArray(entries)), parts);
                }
                else ok = Report(_store.Delete(item.Key + "." + entry.Id), parts);
                if (ok) Refresh();
            };
            return row;
        }

        private List<ListEntry> ReadEntries(SettingItem item)
        {
            var entries = new List<ListEntry>();
            object raw = _store.Get(item.Key);
            if (item.Handler == "notice_presets")
            {
                var list = raw as IEnumerable;
                if (list == null || raw is string) return entries;
                int n = 0;
                foreach (object value in list)
                {
                    var data = value as Dictionary<string, object>;
                    if (data == null) continue;
                    entries.Add(new ListEntry { Id = Str(data, "id"), Data = Copy(data), Order = n++ });
                }
                return entries;
            }
            var map = raw as Dictionary<string, object>;
            if (map == null) return entries;
            foreach (var pair in map)
            {
                var data = pair.Value as Dictionary<string, object>;
                if (data == null) continue;
                entries.Add(new ListEntry
                {
                    Id = pair.Key,
                    Data = Copy(data),
                    Order = SettingsStore.AsNumber(data.ContainsKey("order") ? data["order"] : null, 999),
                });
            }
            entries.Sort((a, b) =>
            {
                int byOrder = a.Order.CompareTo(b.Order);
                return byOrder != 0 ? byOrder : string.CompareOrdinal(a.Id, b.Id);
            });
            return entries;
        }

        private bool SaveEntry(SettingItem item, List<ListEntry> entries, ListEntry entry,
                               RowParts parts)
        {
            if (item.Handler == "notice_presets")
                return Report(_store.Set(item.Key, PresetArray(entries)), parts);
            return Report(_store.Set(item.Key + "." + entry.Id, entry.Data), parts);
        }

        private bool Swap(SettingItem item, List<ListEntry> entries, int a, int b, RowParts parts)
        {
            if (a < 0 || b < 0 || a >= entries.Count || b >= entries.Count) return false;
            var first = entries[a];
            var second = entries[b];
            entries[a] = second;
            entries[b] = first;
            if (item.Handler == "notice_presets")
                return Report(_store.Set(item.Key, PresetArray(entries)), parts);
            // Renumber densely so equal or missing orders cannot keep two entries tied.
            var sets = new List<KeyValuePair<string, object>>();
            for (int i = 0; i < entries.Count; i++)
                sets.Add(new KeyValuePair<string, object>(
                    item.Key + "." + entries[i].Id + ".order", (long)(i + 1)));
            return Report(_store.Commit(sets, null), parts);
        }

        private static List<object> PresetArray(List<ListEntry> entries)
        {
            var list = new List<object>();
            foreach (var entry in entries)
                list.Add(new Dictionary<string, object>
                {
                    { "id", entry.Id }, { "text", Str(entry.Data, "text") },
                });
            return list;
        }

        private static string EntryTitle(SettingItem item, ListEntry entry)
        {
            if (item.Handler == "notice_presets") return Str(entry.Data, "text");
            var label = entry.Data.ContainsKey("label") ? entry.Data["label"] as Dictionary<string, object> : null;
            string text = label == null ? "" : Str(label, Texts.Lang ?? "ja");
            if (text.Length == 0 && label != null)
                foreach (string lang in new[] { "ja", "en", "zh" })
                    if ((text = Str(label, lang)).Length > 0) break;
            string icon = Str(entry.Data, "icon");
            return (icon.Length > 0 ? icon + "  " : "") + (text.Length > 0 ? text : entry.Id);
        }

        private static string EntrySubtitle(SettingItem item, ListEntry entry)
        {
            if (item.Handler == "quick_replies")
                return SettingsStore.AsBool(entry.Data.ContainsKey("speak") ? entry.Data["speak"] : null, true)
                    ? Texts.T("admin.qr_speak") : "";
            if (item.Handler == "visit_purposes")
                return SettingsStore.AsBool(entry.Data.ContainsKey("enabled") ? entry.Data["enabled"] : null, true)
                    ? "" : Texts.T("admin.disabled");
            return "";
        }

        /// <summary>Opens the entry editor; returns the edited copy, or null when cancelled.</summary>
        private ListEntry EditEntry(SettingItem item, ListEntry existing)
        {
            var data = existing == null ? new Dictionary<string, object>() : Copy(existing.Data);
            string id = existing != null ? existing.Id : NewId(item.Handler);
            var dialog = new Window
            {
                Owner = this,
                Topmost = Topmost,
                WindowStyle = WindowStyle.None,
                ResizeMode = ResizeMode.NoResize,
                SizeToContent = SizeToContent.Height,
                Width = Math.Min(560, Math.Max(320, ActualWidth - 32)),
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                ShowInTaskbar = false,
                FontFamily = FontFamily,
            };
            dialog.SetResourceReference(BackgroundProperty, "Card");
            dialog.SetResourceReference(ForegroundProperty, "Fg");
            var form = new StackPanel { Margin = new Thickness(24) };
            form.Children.Add(new TextBlock
            {
                Text = Texts.T(existing == null ? "admin.add" : "admin.edit"),
                FontSize = 22,
                FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(0, 0, 0, 12),
            });
            var fields = new Dictionary<string, TextBox>();
            var flags = new Dictionary<string, ToggleButton>();
            Func<string, string, TextBox> field = (labelKey, value) =>
            {
                form.Children.Add(new TextBlock
                {
                    Text = Texts.T(labelKey),
                    FontSize = 14,
                    Margin = new Thickness(0, 8, 0, 4),
                });
                var box = new TextBox
                {
                    Style = (Style)FindResource("SettingsTextBox"),
                    Text = value ?? "",
                    MaxLength = 200,
                };
                form.Children.Add(box);
                return box;
            };
            Func<string, bool, ToggleButton> flag = (labelKey, value) =>
            {
                var line = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
                var toggle = new ToggleButton
                {
                    Style = (Style)FindResource("SettingsSwitch"),
                    IsChecked = value,
                };
                DockPanel.SetDock(toggle, Dock.Right);
                line.Children.Add(toggle);
                line.Children.Add(new TextBlock
                {
                    Text = Texts.T(labelKey),
                    FontSize = 16,
                    VerticalAlignment = VerticalAlignment.Center,
                });
                form.Children.Add(line);
                return toggle;
            };

            if (item.Handler == "notice_presets")
            {
                fields["text"] = field("settings.preset_text", Str(data, "text"));
            }
            else
            {
                var label = data.ContainsKey("label") ? data["label"] as Dictionary<string, object> : null;
                foreach (string lang in new[] { "ja", "en", "zh" })
                    fields[lang] = field("admin.label_" + lang, label == null ? "" : Str(label, lang));
                if (item.Handler == "visit_purposes")
                {
                    fields["icon"] = field("admin.purpose_icon", Str(data, "icon"));
                    flags["enabled"] = flag("admin.enabled",
                        SettingsStore.AsBool(data.ContainsKey("enabled") ? data["enabled"] : null, true));
                }
                else
                {
                    flags["speak"] = flag("admin.qr_speak",
                        SettingsStore.AsBool(data.ContainsKey("speak") ? data["speak"] : null, true));
                }
            }
            var error = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap,
                                        Visibility = Visibility.Collapsed,
                                        Margin = new Thickness(0, 8, 0, 0) };
            error.SetResourceReference(TextBlock.ForegroundProperty, "Danger");
            form.Children.Add(error);
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 20, 0, 0),
            };
            var cancel = CommandButton(Texts.T("admin.cancel"));
            var save = CommandButton(Texts.T("admin.save"));
            save.Margin = new Thickness(8, 0, 0, 0);
            save.SetResourceReference(BackgroundProperty, "Accent");
            save.SetResourceReference(ForegroundProperty, "OnAccent");
            save.IsDefault = true;
            cancel.IsCancel = true;
            actions.Children.Add(cancel);
            actions.Children.Add(save);
            form.Children.Add(actions);
            dialog.Content = form;
            cancel.Click += (s, e) => dialog.DialogResult = false;
            save.Click += (s, e) =>
            {
                if (item.Handler == "notice_presets")
                {
                    string text = fields["text"].Text.Trim();
                    if (text.Length == 0)
                    {
                        error.Text = Texts.T("settings.err_required");
                        error.Visibility = Visibility.Visible;
                        return;
                    }
                    data["id"] = id;
                    data["text"] = text;
                }
                else
                {
                    var label = new Dictionary<string, object>();
                    foreach (string lang in new[] { "ja", "en", "zh" })
                    {
                        string text = fields[lang].Text.Trim();
                        if (text.Length > 0) label[lang] = text;
                    }
                    if (label.Count == 0)
                    {
                        error.Text = Texts.T("settings.err_required");
                        error.Visibility = Visibility.Visible;
                        return;
                    }
                    data["label"] = label;
                    if (fields.ContainsKey("icon")) data["icon"] = fields["icon"].Text.Trim();
                    foreach (var pair in flags) data[pair.Key] = pair.Value.IsChecked == true;
                }
                dialog.DialogResult = true;
            };
            if (dialog.ShowDialog() != true) return null;
            return new ListEntry { Id = id, Data = data };
        }

        private static string NewId(string handler)
        {
            var bytes = new byte[4];
            using (var random = RandomNumberGenerator.Create()) random.GetBytes(bytes);
            string suffix = BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
            if (handler == "visit_purposes") return "p_" + suffix;
            if (handler == "quick_replies") return "qr_" + suffix;
            return "np_" + suffix;
        }

        private static string Str(Dictionary<string, object> data, string key)
        {
            object value;
            return data != null && data.TryGetValue(key, out value) && value != null
                ? Convert.ToString(value, CultureInfo.InvariantCulture) : "";
        }

        private static Dictionary<string, object> Copy(Dictionary<string, object> source)
        {
            var copy = new Dictionary<string, object>();
            foreach (var pair in source)
            {
                var nested = pair.Value as Dictionary<string, object>;
                copy[pair.Key] = nested != null ? Copy(nested) : pair.Value;
            }
            return copy;
        }
    }
}
