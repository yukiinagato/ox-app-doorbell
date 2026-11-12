using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Ui;
using DoorbellApp.Util;
using InfoBar = ModernWpf.Controls.InfoBar;
using InfoBarSeverity = ModernWpf.Controls.InfoBarSeverity;
using NavigationView = ModernWpf.Controls.NavigationView;
using NavigationViewBackButtonVisible = ModernWpf.Controls.NavigationViewBackButtonVisible;
using NavigationViewItem = ModernWpf.Controls.NavigationViewItem;
using NavigationViewPaneDisplayMode = ModernWpf.Controls.NavigationViewPaneDisplayMode;

namespace DoorbellApp.Settings
{
    /// <summary>
    /// Native settings as a Fluent settings app: a NavigationView carries the categories (open
    /// pane from 900 effective pixels, icon rail from 600, a menu button below that) and the
    /// selected category shows as titled cards of rows. A search box in the page header replaces
    /// the page with every matching row. Widths are WPF device-independent pixels, so the
    /// breakpoints follow the system DPI scale.
    ///
    /// Every row writes through SettingsStore, i.e. one Core config batch per change, and saves
    /// immediately; there is no separate Save step. Admin-required answers are prompted for by
    /// this window while it is open.
    /// </summary>
    internal sealed partial class SettingsWindow : Window
    {
        public const double WideBreakpoint = 900;
        public const double CompactBreakpoint = 600;
        public const double MinTouchTarget = 44;

        private readonly MainWindow _main;
        private readonly SettingsStore _store;
        private readonly List<SettingCategory> _catalog;
        private readonly Func<bool> _previousPrompt;
        private readonly DispatcherTimer _statusTimer = new DispatcherTimer();
        private string _categoryId;
        private string _query = "";
        private bool? _stackedRows;

        private NavigationView _navigation;
        private Grid _header;
        private TextBlock _title;
        private TextBox _search;
        private StackPanel _content;
        private ScrollViewer _contentScroll;
        private InfoBar _status;

        public SettingsWindow(MainWindow main, string nodeId, string role)
        {
            _main = main;
            Owner = main;
            Topmost = main.Topmost;
            // A kiosk surface like the main window: borderless and maximized.
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            WindowState = WindowState.Maximized;
            ShowInTaskbar = false;
            FontFamily = main.FontFamily;
            SetResourceReference(BackgroundProperty, "Bg");
            SetResourceReference(ForegroundProperty, "Fg");
            Title = Texts.T("settings.title");

            _store = new SettingsStore(nodeId, role);
            _catalog = SettingsCatalog.Build();
            _categoryId = _catalog[0].Id;
            _previousPrompt = CoreClient.AdminPrompt;
            CoreClient.AdminPrompt = PromptAdmin;
            AdminHttpSession.PasswordPrompt = PromptSessionPassword;
            Closed += (s, e) =>
            {
                CoreClient.AdminPrompt = _previousPrompt;
                // The loopback admin session lives exactly as long as this window.
                AdminHttpSession.PasswordPrompt = null;
                AdminHttpSession.Clear();
                _statusTimer.Stop();
            };
            _statusTimer.Interval = TimeSpan.FromSeconds(4);
            _statusTimer.Tick += (s, e) =>
            {
                _statusTimer.Stop();
                if (_status != null) _status.IsOpen = false;
            };
            PreviewKeyDown += OnKey;
            SizeChanged += (s, e) => ApplyLayoutMode(false);
            Loaded += (s, e) => ApplyLayoutMode(true);
        }

        // ---- layout ---------------------------------------------------------------------------

        /// <summary>
        /// The NavigationView adapts its own pane to the width. What this window still decides is
        /// where the header starts (clear of the menu button on a compact window) and whether wide
        /// controls stack under their label, which means rebuilding the rows.
        /// </summary>
        private void ApplyLayoutMode(bool force)
        {
            if (_navigation == null) BuildShell();
            _header.Margin = new Thickness(ActualWidth < CompactBreakpoint ? 56 : 24, 8, 16, 4);
            bool stacked = ActualWidth < 700;
            if (!force && _stackedRows == stacked) return;
            _stackedRows = stacked;
            RenderContent();
        }

        private void BuildShell()
        {
            _navigation = new NavigationView
            {
                PaneDisplayMode = NavigationViewPaneDisplayMode.Auto,
                CompactModeThresholdWidth = CompactBreakpoint,
                ExpandedModeThresholdWidth = WideBreakpoint,
                OpenPaneLength = 300,
                IsSettingsVisible = false,
                IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            };
            foreach (var category in _catalog)
            {
                string label = Texts.T(category.TitleKey);
                var item = new NavigationViewItem
                {
                    Content = label,
                    Icon = Fluent.Icon(category.IconKey),
                    Tag = category.Id,
                    MinHeight = 48,
                };
                AutomationLabel(item, label);
                _navigation.MenuItems.Add(item);
            }
            // ItemInvoked rather than SelectionChanged: tapping the category that is already
            // selected still has to leave the search results.
            _navigation.ItemInvoked += (s, e) =>
            {
                var item = e.InvokedItemContainer as NavigationViewItem;
                string id = item == null ? null : item.Tag as string;
                if (id == null) return;
                _categoryId = id;
                // Choosing a category leaves the search results.
                if (_query.Length > 0) _search.Text = "";
                else RenderContent();
            };

            var page = new Grid();
            page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            _header = BuildHeader();
            page.Children.Add(_header);
            _content = new StackPanel { Margin = new Thickness(24, 4, 24, 24), MaxWidth = 980 };
            _contentScroll = new ScrollViewer
            {
                Content = _content,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                PanningMode = PanningMode.VerticalOnly,
            };
            Grid.SetRow(_contentScroll, 1);
            page.Children.Add(_contentScroll);
            _status = new InfoBar
            {
                IsOpen = false,
                IsClosable = true,
                Margin = new Thickness(24, 0, 24, 12),
            };
            Grid.SetRow(_status, 2);
            page.Children.Add(_status);
            _navigation.Content = page;
            Content = _navigation;
            SyncNavigation();
        }

        private Grid BuildHeader()
        {
            var bar = new Grid { MinHeight = 60 };
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _title = new TextBlock
            {
                FontSize = 28,
                FontWeight = FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 16, 0),
                TextWrapping = TextWrapping.Wrap,
            };
            bar.Children.Add(_title);
            _search = new TextBox
            {
                Style = (Style)FindResource("SettingsTextBox"),
                Text = _query,
                MaxWidth = 360,
                MinWidth = 120,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Fluent.Placeholder(_search, Texts.T("settings.search"));
            AutomationLabel(_search, Texts.T("settings.search"));
            _search.TextChanged += (s, e) =>
            {
                _query = _search.Text.Trim();
                RenderContent();
            };
            Grid.SetColumn(_search, 1);
            bar.Children.Add(_search);
            var close = new Button
            {
                Style = (Style)FindResource("SettingsCommandButton"),
                Content = Texts.T("monitor.close"),
                Margin = new Thickness(12, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
            };
            close.Click += (s, e) => Close();
            Grid.SetColumn(close, 2);
            bar.Children.Add(close);
            return bar;
        }

        private void OnKey(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Escape)
            {
                if (_query.Length > 0) _search.Text = "";
                else Close();
                e.Handled = true;
            }
            else if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control && _search != null)
            {
                _search.Focus();
                e.Handled = true;
            }
        }

        private SettingCategory Category(string id)
        {
            foreach (var category in _catalog) if (category.Id == id) return category;
            return _catalog[0];
        }

        // ---- navigation -----------------------------------------------------------------------

        /// <summary>
        /// Shows only the categories that have something to show on this device and keeps the
        /// selection on the current one.
        /// </summary>
        private void SyncNavigation()
        {
            if (_navigation == null) return;
            {
                object selected = null;
                foreach (object entry in _navigation.MenuItems)
                {
                    var item = entry as NavigationViewItem;
                    if (item == null) continue;
                    string id = item.Tag as string;
                    item.Visibility = HasVisibleItems(Category(id))
                        ? Visibility.Visible : Visibility.Collapsed;
                    if (id == _categoryId) selected = item;
                }
                if (selected != null && !ReferenceEquals(_navigation.SelectedItem, selected))
                    _navigation.SelectedItem = selected;
            }
        }

        private void RenderContent()
        {
            if (_content == null) return;
            SyncNavigation();
            _title.Text = _query.Length > 0 ? Texts.T("settings.title")
                                            : Texts.T(Category(_categoryId).TitleKey);
            _content.Children.Clear();
            if (_query.Length > 0) RenderSearchResults();
            else RenderCategory(Category(_categoryId));
            _contentScroll.ScrollToTop();
        }

        /// <summary>Re-renders the current page after a write changed what other rows show.</summary>
        private void Refresh()
        {
            double offset = _contentScroll == null ? 0 : _contentScroll.VerticalOffset;
            RenderContent();
            if (_contentScroll != null) _contentScroll.ScrollToVerticalOffset(offset);
        }

        private void RenderCategory(SettingCategory category)
        {
            foreach (var group in category.Groups)
            {
                var rows = new List<FrameworkElement>();
                foreach (var item in group.Items)
                {
                    if (!IsVisible(item)) continue;
                    var row = BuildRow(item);
                    if (row != null) rows.Add(row);
                }
                if (rows.Count == 0) continue;
                _content.Children.Add(GroupTitle(Texts.T(group.TitleKey)));
                _content.Children.Add(CardOf(rows));
            }
        }

        private void RenderSearchResults()
        {
            string needle = _query.ToLowerInvariant();
            bool any = false;
            foreach (var category in _catalog)
            {
                var rows = new List<FrameworkElement>();
                foreach (var group in category.Groups)
                    foreach (var item in group.Items)
                    {
                        if (!IsVisible(item) || !Matches(item, category, needle)) continue;
                        var row = BuildRow(item);
                        if (row != null) rows.Add(row);
                    }
                if (rows.Count == 0) continue;
                any = true;
                _content.Children.Add(GroupTitle(Texts.T(category.TitleKey)));
                _content.Children.Add(CardOf(rows));
            }
            if (!any)
                _content.Children.Add(new TextBlock
                {
                    Text = Texts.T("settings.search_none"),
                    FontSize = 16,
                    Margin = new Thickness(8, 24, 8, 0),
                    Foreground = Brush("Dim"),
                });
        }

        internal static bool Matches(SettingItem item, SettingCategory category, string needle)
        {
            if (string.IsNullOrEmpty(needle)) return true;
            foreach (string key in new[] { item.LabelKey, item.DescriptionKey, category.TitleKey })
            {
                if (string.IsNullOrEmpty(key)) continue;
                string text = Texts.T(key);
                if (text != null && text.ToLowerInvariant().Contains(needle)) return true;
            }
            return item.Key != null && item.Key.ToLowerInvariant().Contains(needle);
        }

        private bool IsVisible(SettingItem item)
        {
            return item.Visible == null || item.Visible(_store.Context);
        }

        private bool HasVisibleItems(SettingCategory category)
        {
            foreach (var group in category.Groups)
                foreach (var item in group.Items)
                    if (IsVisible(item)) return true;
            return false;
        }

        // ---- shared visuals -------------------------------------------------------------------

        private Brush Brush(string key)
        {
            return (Brush)FindResource(key);
        }

        private TextBlock GroupTitle(string text)
        {
            var title = new TextBlock
            {
                Text = text,
                FontSize = 14,
                FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(8, 18, 8, 8),
            };
            title.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
            return title;
        }

        private Border Card()
        {
            var border = new Border
            {
                CornerRadius = new CornerRadius(4),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(4),
                Child = new StackPanel(),
            };
            border.SetResourceReference(Border.BackgroundProperty, "Card");
            border.SetResourceReference(Border.BorderBrushProperty, "Line");
            return border;
        }

        private Border CardOf(List<FrameworkElement> rows)
        {
            var card = Card();
            var stack = (StackPanel)card.Child;
            for (int i = 0; i < rows.Count; i++)
            {
                if (i > 0)
                {
                    var line = new Border { Height = 1, Margin = new Thickness(16, 0, 16, 0) };
                    line.SetResourceReference(Border.BackgroundProperty, "Line");
                    stack.Children.Add(line);
                }
                stack.Children.Add(rows[i]);
            }
            return card;
        }

        private static void AutomationLabel(UIElement element, string name)
        {
            System.Windows.Automation.AutomationProperties.SetName(element, name ?? "");
        }

        internal void ShowStatus(string text, bool error)
        {
            if (_status == null) return;
            _status.Message = text;
            _status.Severity = error ? InfoBarSeverity.Error : InfoBarSeverity.Success;
            _status.IsOpen = true;
            _statusTimer.Stop();
            if (!error) _statusTimer.Start();
        }

        private bool PromptAdmin()
        {
            if (!Dispatcher.CheckAccess())
                return (bool)Dispatcher.Invoke(new Func<bool>(PromptAdmin));
            var prompt = new AdminDialog { Owner = this, Topmost = Topmost };
            return prompt.ShowDialog() == true;
        }
    }
}
