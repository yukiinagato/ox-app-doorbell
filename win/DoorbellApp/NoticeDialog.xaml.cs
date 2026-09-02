using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// Announcement editor (spec 4.3): text, the target selector 「全体 / この門口機」, the expiry
    /// presets, and the administrator-editable quick presets from notice.presets.
    /// </summary>
    public partial class NoticeDialog : Window
    {
        private const int MaxCharacters = 200;

        private readonly List<KeyValuePair<string, string>> _doors;
        private readonly List<Button> _targetButtons = new List<Button>();
        private readonly List<Button> _expiryButtons = new List<Button>();
        private string _target;
        private string _expiry = "until_cleared";

        /// <summary>Empty means every door; otherwise the door the announcement is written to.</summary>
        public string TargetDoor { get { return _target ?? ""; } }

        public string NoticeBody { get; private set; }

        /// <summary>Absolute wall-clock deadline; zero means "until cleared".</summary>
        public long ExpiresMs { get; private set; }

        public bool ClearRequested { get; private set; }

        public NoticeDialog(List<KeyValuePair<string, string>> doors, string preselectedDoor,
                            string existingText, List<string> presets)
        {
            InitializeComponent();
            _doors = doors ?? new List<KeyValuePair<string, string>>();
            _target = preselectedDoor ?? "";
            NoticeBody = "";

            Title = Texts.T("notice.title");
            TitleText.Text = Texts.T("notice.dialog_title");
            ExpiryLabel.Text = Texts.T("notice.expiry");
            LimitText.Text = Texts.T("notice.limit");
            CustomHoursLabel.Text = Texts.T("notice.expiry_hours");
            CustomHoursBox.Text = "3";
            PublishButton.Content = Texts.T("notice.publish");
            ClearButton.Content = Texts.T("notice.clear");
            CancelButton.Content = Texts.T("admin.cancel");
            BodyBox.Text = existingText ?? "";
            BodyBox.TextChanged += (sender, args) => ErrorText.Visibility = Visibility.Collapsed;
            ClearButton.Visibility = string.IsNullOrEmpty(existingText) ?
                Visibility.Collapsed : Visibility.Visible;

            BuildTargets();
            BuildExpiries();
            BuildPresets(presets);
            Loaded += (sender, args) => BodyBox.Focus();
        }

        private void BuildTargets()
        {
            TargetRow.Children.Clear();
            _targetButtons.Clear();
            AddTarget("", Texts.T("notice.target_global"));
            foreach (KeyValuePair<string, string> door in _doors)
                AddTarget(door.Key, door.Value);
            HighlightTargets();
        }

        private void AddTarget(string id, string label)
        {
            var button = new Button
            {
                Content = label,
                Tag = id,
                Style = (Style)FindResource("ChipButton"),
                BorderBrush = (Brush)FindResource("Line"),
            };
            button.Click += OnTargetClick;
            _targetButtons.Add(button);
            TargetRow.Children.Add(button);
        }

        private void OnTargetClick(object sender, RoutedEventArgs e)
        {
            var button = sender as Button;
            if (button == null) return;
            _target = (button.Tag as string) ?? "";
            HighlightTargets();
        }

        private void HighlightTargets()
        {
            foreach (Button button in _targetButtons)
                Select(button, ((button.Tag as string) ?? "") == (_target ?? ""));
        }

        private void BuildExpiries()
        {
            ExpiryRow.Children.Clear();
            _expiryButtons.Clear();
            AddExpiry("1h", Texts.T("notice.expiry_1h"));
            AddExpiry("today", Texts.T("notice.expiry_today"));
            AddExpiry("until_cleared", Texts.T("notice.expiry_until_cleared"));
            AddExpiry("custom", Texts.T("notice.expiry_custom"));
            HighlightExpiries();
        }

        private void AddExpiry(string id, string label)
        {
            var button = new Button
            {
                Content = label,
                Tag = id,
                Style = (Style)FindResource("ChipButton"),
                BorderBrush = (Brush)FindResource("Line"),
            };
            button.Click += OnExpiryClick;
            _expiryButtons.Add(button);
            ExpiryRow.Children.Add(button);
        }

        private void OnExpiryClick(object sender, RoutedEventArgs e)
        {
            var button = sender as Button;
            if (button == null) return;
            _expiry = (button.Tag as string) ?? "until_cleared";
            CustomHoursRow.Visibility = _expiry == "custom" ?
                Visibility.Visible : Visibility.Collapsed;
            HighlightExpiries();
        }

        private void HighlightExpiries()
        {
            foreach (Button button in _expiryButtons)
                Select(button, (button.Tag as string) == _expiry);
        }

        private void BuildPresets(List<string> presets)
        {
            PresetRow.Children.Clear();
            if (presets == null) return;
            foreach (string preset in presets)
            {
                if (string.IsNullOrEmpty(preset)) continue;
                var button = new Button
                {
                    Content = preset,
                    Tag = preset,
                    Style = (Style)FindResource("ChipButton"),
                    BorderBrush = (Brush)FindResource("Line"),
                    Margin = new Thickness(0, 0, 6, 6),
                };
                button.Click += OnPresetClick;
                PresetRow.Children.Add(button);
            }
        }

        private void OnPresetClick(object sender, RoutedEventArgs e)
        {
            var button = sender as Button;
            string text = button == null ? null : button.Tag as string;
            if (string.IsNullOrEmpty(text)) return;
            BodyBox.Text = text;
            BodyBox.CaretIndex = BodyBox.Text.Length;
            BodyBox.Focus();
        }

        private void Select(Button button, bool selected)
        {
            button.Background = selected ?
                (Brush)FindResource("Accent") : (Brush)FindResource("Card");
            button.Foreground = selected ?
                (Brush)FindResource("OnAccent") : (Brush)FindResource("Fg");
        }

        private void OnPublishClick(object sender, RoutedEventArgs e)
        {
            string text = (BodyBox.Text ?? "").Trim();
            if (text.Length == 0)
            {
                ShowError(Texts.T("notice.empty"));
                return;
            }
            if (text.Length > MaxCharacters)
            {
                ShowError(Texts.T("notice.too_long", text.Length));
                return;
            }
            long expires;
            if (!TryResolveExpiry(out expires))
            {
                ShowError(Texts.T("notice.expiry_hours"));
                return;
            }
            NoticeBody = text;
            ExpiresMs = expires;
            ClearRequested = false;
            DialogResult = true;
        }

        private bool TryResolveExpiry(out long expiresMs)
        {
            expiresMs = 0;
            DateTime now = DateTime.Now;
            switch (_expiry)
            {
                case "1h":
                    expiresMs = ToWallMs(now.AddHours(1));
                    return true;
                case "today":
                    expiresMs = ToWallMs(now.Date.AddDays(1));
                    return true;
                case "custom":
                    int hours;
                    if (!int.TryParse((CustomHoursBox.Text ?? "").Trim(), out hours) ||
                        hours <= 0 || hours > 24 * 30) return false;
                    expiresMs = ToWallMs(now.AddHours(hours));
                    return true;
                default:
                    expiresMs = 0;  // Until cleared.
                    return true;
            }
        }

        private static long ToWallMs(DateTime local)
        {
            DateTime epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
            return (long)(local.ToUniversalTime() - epoch).TotalMilliseconds;
        }

        private void ShowError(string message)
        {
            ErrorText.Text = message;
            ErrorText.Visibility = Visibility.Visible;
        }

        private void OnClearClick(object sender, RoutedEventArgs e)
        {
            ClearRequested = true;
            NoticeBody = "";
            ExpiresMs = 0;
            DialogResult = true;
        }

        private void OnCancelClick(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
        }
    }
}
