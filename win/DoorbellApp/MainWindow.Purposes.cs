using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Media;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Kiosk;
using DoorbellApp.Pairing;
using DoorbellApp.Util;


namespace DoorbellApp
{
    // Visit purposes and the visitor language bar.
    public partial class MainWindow
    {
        private static List<string> SortedByOrder(Dictionary<string, object> map)
        {
            var ids = new List<string>();
            if (map == null) return ids;
            ids.AddRange(map.Keys);
            ids.Sort((a, b) =>
            {
                int c = OrderOf(map, a).CompareTo(OrderOf(map, b));
                return c != 0 ? c : string.CompareOrdinal(a, b);
            });
            return ids;
        }

        private static int OrderOf(Dictionary<string, object> map, string id)
        {
            var e = map[id] as Dictionary<string, object>;
            object v;
            if (e != null && e.TryGetValue("order", out v) && v != null)
            {
                int i;
                if (int.TryParse(v.ToString(), out i)) return i;
            }
            return 999;
        }

        private static string LabelOf(Dictionary<string, object> entry, string lang, string fallback)
        {
            var label = entry != null && entry.ContainsKey("label")
                ? entry["label"] as Dictionary<string, object> : null;
            if (label != null)
            {
                object v;
                if (label.TryGetValue(lang, out v) && v != null && !string.IsNullOrEmpty(v.ToString()))
                    return v.ToString();
                if (label.TryGetValue("ja", out v) && v != null && !string.IsNullOrEmpty(v.ToString()))
                    return v.ToString();
            }
            return fallback;
        }

        private bool ShowsHomePurposes()
        {
            return App.Boot.Role == "door_station" && _callFlow == "purpose_first" &&
                PurposeGrid.Children.Count > 0;
        }

        private bool ShowsCallingPurposes()
        {
            return _activeCallFlow == "ring_then_purpose" && CallingPurposeGrid.Children.Count > 0 &&
                !string.IsNullOrEmpty(_activeCallId) && _purposeChosenCallId != _activeCallId;
        }

        private void BuildPurposeButtons()
        {
            PurposeGrid.Children.Clear();
            CallingPurposeGrid.Children.Clear();
            var purposes = CoreClient.Dig(_cfg, "visit_purposes") as Dictionary<string, object>;
            if (App.Boot.Role != "door_station" || purposes == null || purposes.Count == 0)
            {
                PurposeSection.Visibility = Visibility.Collapsed;
                CallingPurposeSection.Visibility = Visibility.Collapsed;
                return;
            }
            foreach (var id in SortedByOrder(purposes))
            {
                var entry = purposes[id] as Dictionary<string, object>;
                if (entry != null && entry.ContainsKey("enabled") && entry["enabled"] is bool &&
                    !(bool)entry["enabled"]) continue;
                string label = LabelOf(entry, Texts.Lang, id);
                object icon;
                string iconText = entry != null && entry.TryGetValue("icon", out icon) && icon != null
                    ? icon.ToString() : "";
                PurposeGrid.Children.Add(MakePurposeButton(id, iconText, label));
                CallingPurposeGrid.Children.Add(MakePurposeButton(id, iconText, label));
            }
            PurposeGrid.Columns = Ui.LayoutMetrics.PurposeColumns(_sizeClass,
                ActualWidth > 0 ? ActualWidth : SystemParameters.PrimaryScreenWidth,
                PurposeGrid.Children.Count);
            CallingPurposeGrid.Columns = PurposeGrid.Columns;
            PurposeSection.Visibility = ShowsHomePurposes() ? Visibility.Visible : Visibility.Collapsed;
            CallingPurposeSection.Visibility = ShowsCallingPurposes() ? Visibility.Visible : Visibility.Collapsed;
        }

        /// <summary>
        /// The Tabler icon for a purpose core seeds. An administrator's own purpose keeps whatever
        /// icon they typed, because there is nothing to map it to.
        /// </summary>
        private static string PurposeIconKey(string id)
        {
            switch (id)
            {
                case "p_visit": return "IconHome";
                case "p_delivery": return "IconPackage";
                case "p_mail": return "IconMail";
                default: return null;
            }
        }

        /// <summary>
        /// A Tabler geometry drawn the way the whole fleet draws them: stroked, never filled,
        /// two units thick with round caps and joins, inside a Viewbox so the stroke scales with
        /// the icon. Returns null when the key is not in the generated dictionary.
        /// </summary>
        private FrameworkElement TablerIcon(string key, double size, Brush stroke)
        {
            if (string.IsNullOrEmpty(key)) return null;
            object geometry = TryFindResource(key);
            if (!(geometry is Geometry)) return null;
            var path = new System.Windows.Shapes.Path
            {
                Data = (Geometry)geometry,
                Stroke = stroke,
                StrokeThickness = 2,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                StrokeLineJoin = PenLineJoin.Round,
            };
            return new Viewbox
            {
                Width = size,
                Height = size,
                Child = path,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
        }

        private Button MakePurposeButton(string id, string icon, string label)
        {
            var panel = new StackPanel
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            FrameworkElement glyph = TablerIcon(PurposeIconKey(id), 34,
                                                (Brush)FindResource("Fg"));
            if (glyph != null) panel.Children.Add(glyph);
            else if (!string.IsNullOrEmpty(icon))
                panel.Children.Add(new TextBlock
                {
                    Text = icon,
                    FontSize = 34,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    TextAlignment = TextAlignment.Center,
                });
            panel.Children.Add(new TextBlock
            {
                Text = label,
                FontSize = 22,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Foreground = (Brush)FindResource("Fg"),
            });
            var b = new Button
            {
                Content = panel,
                MinWidth = 0,
                MinHeight = 96,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Margin = new Thickness(8),
                Padding = new Thickness(12, 10, 12, 10),
                Cursor = Cursors.Hand,
                Tag = id,
            };
            b.Click += OnPurposeClick;
            if (_semanticStyles != null)
                _semanticApplier.Apply(b, _semanticStyles.Get("purpose.button"), false);
            return b;
        }

        private void OnPurposeClick(object sender, RoutedEventArgs e)
        {
            if (_inCall) return;
            if (!string.IsNullOrEmpty(_activeCallId) && !ShowsCallingPurposes()) return;
            if (string.IsNullOrEmpty(_activeCallId) && !ShowsHomePurposes()) return;
            var b = sender as Button;
            if (b == null) return;
            string id = b.Tag as string;
            if (string.IsNullOrEmpty(id)) return;
            var purposes = CoreClient.Dig(_cfg, "visit_purposes") as Dictionary<string, object>;
            var entry = purposes != null && purposes.ContainsKey(id)
                ? purposes[id] as Dictionary<string, object> : null;
            string label = LabelOf(entry, Texts.Lang, id);
            if (!string.IsNullOrEmpty(_activeCallId))
            {
                if (!App.Core.SelectPurpose(App.Boot.Door, _activeCallId, id))
                {
                    CallingDetail.Text = Texts.T("purpose.select_failed");
                    return;
                }
                CallingPurposeSection.Visibility = Visibility.Collapsed;
                _purposeChosenCallId = _activeCallId;
            }
            else
            {
                _activeCallFlow = "purpose_first";
                _activeCallId = App.Core.PressPurpose(App.Boot.Door, id) ?? "";
                if (string.IsNullOrEmpty(_activeCallId))
                {
                    ShowOffline();
                    return;
                }
                }
            ShowCalling(Texts.T("purpose.sent", label));
        }

        private void BuildLangBar()
        {
            LangBar.Children.Clear();
            var langs = CoreClient.Dig(_cfg, "ui.languages") as System.Collections.IEnumerable;
            var list = new List<string>();
            if (langs != null && !(langs is string))
                foreach (var l in langs)
                    if (l != null && !string.IsNullOrEmpty(l.ToString())) list.Add(l.ToString());
            if (App.Boot.Role != "door_station" || list.Count < 2)
            {
                LangBar.Visibility = Visibility.Collapsed;
                return;
            }
            foreach (var lang in list)
            {
                var b = new Button
                {
                    Content = LangDisplayName(lang),
                    FontSize = 20,
                    Padding = new Thickness(22, 8, 22, 8),
                    Margin = new Thickness(6, 0, 6, 0),
                    MinHeight = Ui.LayoutMetrics.VisitorTouchMin,
                    Tag = lang,
                };
                b.Click += OnLangClick;
                LangBar.Children.Add(b);
            }
            LangBar.Visibility = Visibility.Visible;
            LangBar.ToolTip = Texts.T("door.lang_switch");
            UpdateLangBarSelection();
        }

        private static string LangDisplayName(string lang)
        {
            switch (lang)
            {
                case "ja": return "日本語";
                case "en": return "English";
                case "zh": return "中文";
                default: return lang;
            }
        }

        private void UpdateLangBarSelection()
        {
            foreach (var child in LangBar.Children)
            {
                var b = child as Button;
                if (b == null) continue;
                bool on = (b.Tag as string) == _visitorLang;
                // The language in use is the accent button; the others stay standard.
                if (on) Ui.Fluent.MakeAccent(b);
                else b.ClearValue(StyleProperty);
            }
        }

        private void OnLangClick(object sender, RoutedEventArgs e)
        {
            var b = sender as Button;
            if (b == null) return;
            string lang = b.Tag as string;
            App.Core.SetVisitorLang(App.Boot.Door, lang);
            SetVisitorLang(lang);
        }

        private void SetVisitorLang(string lang)
        {
            if (string.IsNullOrEmpty(lang)) lang = "ja";
            if (_visitorLang == lang) return;
            _visitorLang = lang;
            Texts.SetLang(lang);
            ApplyStrings();
            BuildPurposeButtons();
            UpdateLangBarSelection();
        }
    }
}
