using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // One row per setting: label, description and reach on the left, the control on the right
    // (or underneath on a narrow window for wide controls such as sliders and text boxes).
    internal sealed partial class SettingsWindow
    {
        private const double ControlWidth = 340;
        private static readonly Regex TimePattern = new Regex(@"^([01]\d|2[0-3]):[0-5]\d$");

        private sealed class RowParts
        {
            public Grid Root;
            public TextBlock Error;
        }

        private FrameworkElement BuildRow(SettingItem item)
        {
            if (item.Kind == SettingKind.ListEditor) return BuildListEditor(item);
            if (item.Kind == SettingKind.Editor) return BuildEditor(item);
            var parts = new RowParts();
            FrameworkElement control = BuildControl(item, parts);
            if (control == null) return null;
            bool wideControl = item.Kind == SettingKind.Slider || item.Kind == SettingKind.Text ||
                               item.Kind == SettingKind.MultiChoice;
            bool stacked = wideControl && ActualWidth < 700;

            var root = new Grid { Margin = new Thickness(16, 10, 12, 10), MinHeight = 52 };
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center,
                                        Margin = new Thickness(0, 0, 16, 0) };
            var label = new TextBlock
            {
                Text = Texts.T(item.LabelKey),
                FontSize = 17,
                TextWrapping = TextWrapping.Wrap,
            };
            if (item.Destructive) label.SetResourceReference(TextBlock.ForegroundProperty, "Negative");
            text.Children.Add(label);
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
            root.Children.Add(text);

            if (stacked)
            {
                Grid.SetRow(control, 1);
                Grid.SetColumnSpan(control, 2);
                control.Margin = new Thickness(0, 10, 0, 0);
                control.HorizontalAlignment = HorizontalAlignment.Stretch;
            }
            else
            {
                Grid.SetColumn(control, 1);
                control.VerticalAlignment = VerticalAlignment.Center;
            }
            root.Children.Add(control);

            parts.Error = new TextBlock
            {
                FontSize = 13,
                TextWrapping = TextWrapping.Wrap,
                Visibility = Visibility.Collapsed,
                Margin = new Thickness(0, 6, 0, 0),
            };
            parts.Error.SetResourceReference(TextBlock.ForegroundProperty, "Negative");
            Grid.SetRow(parts.Error, 2);
            Grid.SetColumnSpan(parts.Error, 2);
            root.Children.Add(parts.Error);
            parts.Root = root;
            AutomationLabel(control, Texts.T(item.LabelKey));
            return root;
        }

        /// <summary>Description, then where the value applies and whether a restart follows.</summary>
        private string Detail(SettingItem item)
        {
            var parts = new List<string>();
            if (!string.IsNullOrEmpty(item.DescriptionKey)) parts.Add(Texts.T(item.DescriptionKey));
            if (item.Kind != SettingKind.Info && item.Kind != SettingKind.Action &&
                item.Kind != SettingKind.Editor)
            {
                if (item.Scope == SettingScope.ThisDevice) parts.Add(Texts.T("settings.scope_device"));
                else if (item.Scope == SettingScope.AllDevices) parts.Add(Texts.T("settings.scope_all"));
            }
            if (item.RequiresRestart) parts.Add(Texts.T("settings.requires_restart"));
            return string.Join(" · ", parts);
        }

        private FrameworkElement BuildControl(SettingItem item, RowParts parts)
        {
            switch (item.Kind)
            {
                case SettingKind.Toggle: return BuildToggle(item, parts);
                case SettingKind.Slider: return BuildSlider(item, parts);
                case SettingKind.Stepper: return BuildStepper(item, parts);
                case SettingKind.Choice: return BuildChoice(item, parts);
                case SettingKind.MultiChoice: return BuildMulti(item, parts);
                case SettingKind.Text:
                case SettingKind.Time: return BuildText(item, parts);
                case SettingKind.Info: return BuildInfo(item);
                case SettingKind.Action: return BuildAction(item, parts);
                default: return null;
            }
        }

        // ---- writing --------------------------------------------------------------------------

        /// <summary>
        /// Writes one value. Returns false (and shows why) when Core refused it; the caller then
        /// puts its control back to the stored value.
        /// </summary>
        private bool Write(SettingItem item, object value, RowParts parts)
        {
            parts.Error.Visibility = Visibility.Collapsed;
            if (item.Handler == "identity" || item.Handler == "ui_lang" ||
                item.Key.StartsWith(SettingsStore.BootPrefix, StringComparison.Ordinal) ||
                item.Key.StartsWith(LocalPrefix, StringComparison.Ordinal))
                return WriteSpecial(item, value, parts);
            var sets = new List<KeyValuePair<string, object>>
            {
                new KeyValuePair<string, object>(item.Key, value),
            };
            if (item.AlsoWrites != null)
                foreach (string key in item.AlsoWrites)
                    sets.Add(new KeyValuePair<string, object>(key, value));
            return Report(_store.Commit(sets, null), parts);
        }

        private bool Report(SettingsWriteResult result, RowParts parts)
        {
            if (result.Ok)
            {
                ShowStatus(result.Warnings.Length > 0
                    ? Texts.T("settings.saved_with_warning", result.Warnings)
                    : Texts.T("admin.saved"), false);
                return true;
            }
            string message = Texts.T("settings.save_failed_reason", ErrorText(result.Error));
            if (parts != null && parts.Error != null)
            {
                parts.Error.Text = message;
                parts.Error.Visibility = Visibility.Visible;
            }
            ShowStatus(message, true);
            return false;
        }

        private static string ErrorText(string error)
        {
            if (error == "core_unavailable") return Texts.T("settings.err_core_unavailable");
            if (error == "admin_required") return Texts.T("settings.err_admin_required");
            return error ?? "";
        }

        // ---- controls -------------------------------------------------------------------------

        private FrameworkElement BuildToggle(SettingItem item, RowParts parts)
        {
            bool stored = item.Key.StartsWith(LocalPrefix, StringComparison.Ordinal)
                ? _main.VideoStatsVisibleForSettings
                : SettingsStore.AsBool(_store.Effective(item), (bool)item.Default);
            var toggle = new ToggleButton
            {
                Style = (Style)FindResource("SettingsSwitch"),
                IsChecked = stored,
            };
            toggle.Click += (s, e) =>
            {
                bool next = toggle.IsChecked == true;
                if (!Write(item, next, parts)) toggle.IsChecked = !next;
            };
            return toggle;
        }

        private FrameworkElement BuildSlider(SettingItem item, RowParts parts)
        {
            double stored = Clamp(SettingsStore.AsNumber(_store.Effective(item),
                                                         Convert.ToDouble(item.Default)), item);
            var panel = new DockPanel { Width = ActualWidth < 700 ? double.NaN : ControlWidth };
            var value = new TextBlock
            {
                FontSize = 16,
                MinWidth = 64,
                TextAlignment = TextAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
                Text = FormatNumber(stored, item),
            };
            DockPanel.SetDock(value, Dock.Right);
            panel.Children.Add(value);
            var slider = new Slider
            {
                Style = (Style)FindResource("SettingsSlider"),
                Minimum = item.Min,
                Maximum = item.Max,
                SmallChange = item.Step,
                LargeChange = Math.Max(item.Step, (item.Max - item.Min) / 10),
                TickFrequency = item.Step,
                IsSnapToTickEnabled = true,
                Value = stored,
                Margin = new Thickness(0, 0, 12, 0),
            };
            panel.Children.Add(slider);
            double committed = stored;
            // Writes once the finger or mouse rests: half a second after the last movement, so
            // dragging does not produce one replicated configuration change per pixel.
            var settle = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
            settle.Tick += (s, e) =>
            {
                settle.Stop();
                double next = slider.Value;
                if (Math.Abs(next - committed) < 1e-9) return;
                if (Write(item, SettingsStore.NumberValue(next, item.Step), parts)) committed = next;
                else
                {
                    slider.Value = committed;
                    value.Text = FormatNumber(committed, item);
                }
            };
            slider.ValueChanged += (s, e) =>
            {
                value.Text = FormatNumber(slider.Value, item);
                settle.Stop();
                settle.Start();
            };
            Unloaded += (s, e) => settle.Stop();
            return panel;
        }

        private FrameworkElement BuildStepper(SettingItem item, RowParts parts)
        {
            double stored = Clamp(SettingsStore.AsNumber(_store.Effective(item),
                                                         Convert.ToDouble(item.Default)), item);
            var panel = new StackPanel { Orientation = Orientation.Horizontal };
            var minus = CommandButton("−");
            var plus = CommandButton("+");
            var box = new TextBox
            {
                Style = (Style)FindResource("SettingsTextBox"),
                Width = 110,
                TextAlignment = TextAlignment.Center,
                Margin = new Thickness(8, 0, 8, 0),
                Text = FormatNumber(stored, item, false),
                InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Number) } },
            };
            AutomationLabel(minus, Texts.T("settings.decrease"));
            AutomationLabel(plus, Texts.T("settings.increase"));
            double committed = stored;
            Action<double> commit = next =>
            {
                next = Clamp(next, item);
                box.Text = FormatNumber(next, item, false);
                if (Math.Abs(next - committed) < 1e-9) return;
                if (Write(item, SettingsStore.NumberValue(next, item.Step), parts)) committed = next;
                else box.Text = FormatNumber(committed, item, false);
            };
            minus.Click += (s, e) => commit(committed - item.Step);
            plus.Click += (s, e) => commit(committed + item.Step);
            Action fromBox = () =>
            {
                double typed;
                if (double.TryParse(box.Text.Trim(), NumberStyles.Float, CultureInfo.CurrentCulture,
                                    out typed) ||
                    double.TryParse(box.Text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture,
                                    out typed))
                    commit(Math.Round(typed / item.Step) * item.Step);
                else box.Text = FormatNumber(committed, item, false);
            };
            box.LostKeyboardFocus += (s, e) => fromBox();
            box.KeyDown += (s, e) => { if (e.Key == Key.Enter) fromBox(); };
            panel.Children.Add(minus);
            panel.Children.Add(box);
            panel.Children.Add(plus);
            if (!string.IsNullOrEmpty(item.UnitKey))
                panel.Children.Add(new TextBlock
                {
                    Text = Texts.T(item.UnitKey, ""),
                    FontSize = 15,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(8, 0, 0, 0),
                });
            return panel;
        }

        private FrameworkElement BuildChoice(SettingItem item, RowParts parts)
        {
            if (item.Handler == "sound" || item.Handler == "media_source")
                item = WithConfiguredOptions(item);
            object stored = _store.Effective(item);
            if (item.Handler == "identity" && item.Id == "device_role") stored = _store.Context.Role;
            if (item.Handler == "ui_lang" && App.Boot != null) stored = App.Boot.UiLang;
            int selected = IndexOf(item.Options, stored);
            if (item.Options.Count <= 3 && ActualWidth >= 600) return Segmented(item, parts, selected);
            return Picker(item, parts, selected);
        }

        /// <summary>Two or three short options side by side, like a segmented control.</summary>
        private FrameworkElement Segmented(SettingItem item, RowParts parts, int selected)
        {
            var panel = new StackPanel { Orientation = Orientation.Horizontal };
            var buttons = new List<Button>();
            int current = selected;
            Action paint = () =>
            {
                for (int i = 0; i < buttons.Count; i++)
                {
                    bool on = i == current;
                    buttons[i].SetResourceReference(BackgroundProperty, on ? "Accent" : "Pill");
                    buttons[i].SetResourceReference(ForegroundProperty, on ? "OnAccent" : "Fg");
                }
            };
            for (int i = 0; i < item.Options.Count; i++)
            {
                int index = i;
                var button = CommandButton(OptionText(item.Options[i]));
                button.Margin = new Thickness(i == 0 ? 0 : 6, 0, 0, 0);
                button.Click += (s, e) =>
                {
                    if (index == current) return;
                    if (!Write(item, item.Options[index].Value, parts)) return;
                    current = index;
                    paint();
                };
                buttons.Add(button);
                panel.Children.Add(button);
            }
            paint();
            return panel;
        }

        /// <summary>A button showing the current value; tapping it opens a touch-sized list.</summary>
        private FrameworkElement Picker(SettingItem item, RowParts parts, int selected)
        {
            int current = selected;
            var label = new TextBlock
            {
                FontSize = 16,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            var row = new DockPanel();
            var chevron = _main.IconGlyph("IconChevronDown", 18);
            chevron.Margin = new Thickness(10, 0, 0, 0);
            DockPanel.SetDock(chevron, Dock.Right);
            row.Children.Add(chevron);
            row.Children.Add(label);
            var button = new Button
            {
                Style = (Style)FindResource("SettingsCommandButton"),
                Content = row,
                MinWidth = 220,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
            };
            Action paint = () => label.Text = current >= 0
                ? OptionText(item.Options[current]) : Texts.T("settings.not_set");
            paint();
            var list = new StackPanel();
            var popup = new Popup
            {
                PlacementTarget = button,
                Placement = PlacementMode.Bottom,
                StaysOpen = false,
                AllowsTransparency = true,
                PopupAnimation = PopupAnimation.Fade,
            };
            var frame = new Border
            {
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(6),
                BorderThickness = new Thickness(1),
                MinWidth = 260,
                Child = new ScrollViewer
                {
                    Content = list,
                    MaxHeight = 440,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    PanningMode = PanningMode.VerticalOnly,
                },
            };
            frame.SetResourceReference(Border.BackgroundProperty, "Card");
            frame.SetResourceReference(Border.BorderBrushProperty, "Line");
            popup.Child = frame;
            button.Click += (s, e) =>
            {
                list.Children.Clear();
                for (int i = 0; i < item.Options.Count; i++)
                {
                    int index = i;
                    var line = new DockPanel();
                    if (index == current)
                    {
                        var check = _main.IconGlyph("IconCheck", 18, Brush("Accent"));
                        DockPanel.SetDock(check, Dock.Right);
                        line.Children.Add(check);
                    }
                    line.Children.Add(new TextBlock
                    {
                        Text = OptionText(item.Options[index]),
                        FontSize = 16,
                        VerticalAlignment = VerticalAlignment.Center,
                    });
                    var option = new Button
                    {
                        Style = (Style)FindResource("SettingsFlatButton"),
                        Content = line,
                    };
                    option.Click += (s2, e2) =>
                    {
                        popup.IsOpen = false;
                        if (index == current) return;
                        if (!Write(item, item.Options[index].Value, parts)) return;
                        current = index;
                        paint();
                    };
                    list.Children.Add(option);
                }
                popup.IsOpen = true;
            };
            return button;
        }

        private FrameworkElement BuildMulti(SettingItem item, RowParts parts)
        {
            var chosen = new List<string>(SettingsStore.AsStringList(_store.Get(item.Key)));
            var panel = new WrapPanel { MaxWidth = ActualWidth < 700 ? double.PositiveInfinity : 460 };
            foreach (var option in item.Options)
            {
                string value = option.Value.ToString();
                var chip = new ToggleButton
                {
                    Content = OptionText(option),
                    IsChecked = chosen.Contains(value),
                    MinHeight = MinTouchTarget,
                    Padding = new Thickness(14, 6, 14, 6),
                    Margin = new Thickness(0, 0, 6, 6),
                    FontSize = 15,
                };
                chip.Click += (s, e) =>
                {
                    var next = new List<string>(chosen);
                    if (chip.IsChecked == true) { if (!next.Contains(value)) next.Add(value); }
                    else next.Remove(value);
                    // Keep the option order so the first language stays the default.
                    var ordered = new List<object>();
                    foreach (var o in item.Options)
                        if (next.Contains(o.Value.ToString())) ordered.Add(o.Value.ToString());
                    foreach (string extra in next)
                        if (!ordered.Contains(extra)) ordered.Add(extra);
                    if (Write(item, ordered, parts))
                    {
                        chosen.Clear();
                        foreach (object o in ordered) chosen.Add(o.ToString());
                    }
                    else chip.IsChecked = !(chip.IsChecked == true);
                };
                panel.Children.Add(chip);
            }
            return panel;
        }

        private FrameworkElement BuildText(SettingItem item, RowParts parts)
        {
            object raw = _store.Get(item.Key);
            string stored;
            if (item.Handler == "string_list") stored = string.Join(", ", SettingsStore.AsStringList(raw));
            else stored = raw == null ? (item.Default ?? "").ToString() : raw.ToString();
            if (item.Handler == "identity")
                stored = item.Id == "device_name" ? (App.Boot == null ? stored : App.Boot.Name)
                       : (App.Boot == null ? stored : App.Boot.Door);
            var box = new TextBox
            {
                Style = (Style)FindResource("SettingsTextBox"),
                Text = stored,
                Width = item.Kind == SettingKind.Time ? 120 :
                        (ActualWidth < 700 ? double.NaN : ControlWidth),
                MaxLength = 256,
            };
            if (item.Kind == SettingKind.Time) box.TextAlignment = TextAlignment.Center;
            string committed = stored;
            Action commit = () =>
            {
                string next = box.Text.Trim();
                if (next == committed) return;
                object value = next;
                if (item.Kind == SettingKind.Time && !TimePattern.IsMatch(next))
                {
                    parts.Error.Text = Texts.T("settings.err_time_format");
                    parts.Error.Visibility = Visibility.Visible;
                    box.Text = committed;
                    return;
                }
                if (item.Handler == "string_list")
                {
                    var list = new List<object>();
                    foreach (string piece in next.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
                        if (piece.Trim().Length > 0) list.Add(piece.Trim());
                    value = list;
                }
                if (Write(item, value, parts)) committed = next;
                else box.Text = committed;
            };
            box.LostKeyboardFocus += (s, e) => commit();
            box.KeyDown += (s, e) => { if (e.Key == Key.Enter) commit(); };
            return box;
        }

        // ---- helpers --------------------------------------------------------------------------

        private Button CommandButton(string text)
        {
            return new Button
            {
                Style = (Style)FindResource("SettingsCommandButton"),
                Content = text,
            };
        }

        internal static string OptionText(SettingOption option)
        {
            return option.Text ?? Texts.T(option.LabelKey);
        }

        private static int IndexOf(List<SettingOption> options, object value)
        {
            string wanted = value == null ? null : Convert.ToString(value, CultureInfo.InvariantCulture);
            for (int i = 0; i < options.Count; i++)
                if (Convert.ToString(options[i].Value, CultureInfo.InvariantCulture) == wanted) return i;
            return -1;
        }

        private static double Clamp(double value, SettingItem item)
        {
            return Math.Max(item.Min, Math.Min(item.Max, value));
        }

        private static string FormatNumber(double value, SettingItem item, bool withUnit = true)
        {
            string number = Math.Abs(item.Step - Math.Round(item.Step)) < 1e-9
                ? Math.Round(value).ToString(CultureInfo.CurrentCulture)
                : value.ToString("0.##", CultureInfo.CurrentCulture);
            return withUnit && !string.IsNullOrEmpty(item.UnitKey) ? Texts.T(item.UnitKey, number) : number;
        }
    }
}
