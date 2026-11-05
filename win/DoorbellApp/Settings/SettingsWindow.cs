using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    /// <summary>
    /// Native settings, laid out like the system Settings app. At 900 effective pixels and wider
    /// (landscape tablets, desktops) it is two panes: categories with icons and a search box on
    /// the left, grouped cards of rows on the right. Narrower (portrait tablets) it drills down:
    /// the category list, then one category with a back button. Widths are WPF device-independent
    /// pixels, so the breakpoint follows the system DPI scale.
    ///
    /// Every row writes through SettingsStore, i.e. one Core config batch per change, and saves
    /// immediately; there is no separate Save step. Admin-required answers are prompted for by
    /// this window while it is open.
    /// </summary>
    internal sealed partial class SettingsWindow : Window
    {
        public const double WideBreakpoint = 900;
        public const double MinTouchTarget = 44;

        private readonly MainWindow _main;
        private readonly SettingsStore _store;
        private readonly List<SettingCategory> _catalog;
        private readonly Func<bool> _previousPrompt;
        private readonly DispatcherTimer _statusTimer = new DispatcherTimer();
        private bool? _wide;
        private string _categoryId;
        private bool _showingCategory;
        private string _query = "";

        private DockPanel _shell;
        private Button _back;
        private TextBlock _title;
        private TextBox _search;
        private FrameworkElement _searchHost;
        private StackPanel _nav;
        private StackPanel _content;
        private ScrollViewer _contentScroll;
        private TextBlock _status;

        public SettingsWindow(MainWindow main, string nodeId, string role)
        {
            _main = main;
            Owner = main;
            Topmost = main.Topmost;
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
            Closed += (s, e) =>
            {
                CoreClient.AdminPrompt = _previousPrompt;
                _statusTimer.Stop();
            };
            _statusTimer.Interval = TimeSpan.FromSeconds(4);
            _statusTimer.Tick += (s, e) =>
            {
                _statusTimer.Stop();
                if (_status != null) _status.Visibility = Visibility.Collapsed;
            };
            PreviewKeyDown += OnKey;
            SizeChanged += (s, e) => ApplyLayoutMode(false);
            Loaded += (s, e) => ApplyLayoutMode(true);
        }

        // ---- layout ---------------------------------------------------------------------------

        private bool IsWide { get { return ActualWidth >= WideBreakpoint; } }

        private void ApplyLayoutMode(bool force)
        {
            bool wide = IsWide;
            if (!force && _wide == wide) return;
            _wide = wide;
            BuildShell();
        }

        private void BuildShell()
        {
            _shell = new DockPanel { LastChildFill = true };
            var header = BuildHeader();
            DockPanel.SetDock(header, Dock.Top);
            _shell.Children.Add(header);

            _status = new TextBlock
            {
                FontSize = 15,
                Margin = new Thickness(24, 8, 24, 12),
                TextWrapping = TextWrapping.Wrap,
                Visibility = Visibility.Collapsed,
            };
            DockPanel.SetDock(_status, Dock.Bottom);
            _shell.Children.Add(_status);

            _search = new TextBox
            {
                Style = (Style)FindResource("SettingsTextBox"),
                Text = _query,
            };
            _search.TextChanged += (s, e) =>
            {
                _query = _search.Text.Trim();
                if (_wide == true) RenderContent();
                else
                {
                    _showingCategory = false;
                    RenderNarrowBody();
                }
            };
            AutomationLabel(_search, Texts.T("settings.search"));
            _searchHost = WithPlaceholder(_search, Texts.T("settings.search"));

            if (_wide == true)
            {
                var body = new Grid();
                body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(320) });
                body.ColumnDefinitions.Add(new ColumnDefinition
                    { Width = new GridLength(1, GridUnitType.Star) });
                var left = new DockPanel { Margin = new Thickness(16, 4, 8, 16) };
                DockPanel.SetDock(_searchHost, Dock.Top);
                left.Children.Add(_searchHost);
                _nav = new StackPanel();
                left.Children.Add(new ScrollViewer
                {
                    Content = _nav,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    PanningMode = PanningMode.VerticalOnly,
                });
                Grid.SetColumn(left, 0);
                body.Children.Add(left);
                _contentScroll = ContentScroll();
                Grid.SetColumn(_contentScroll, 1);
                body.Children.Add(_contentScroll);
                _shell.Children.Add(body);
                RenderNav();
                RenderContent();
            }
            else
            {
                // Narrow: the search box stays put above the page, so typing (including IME
                // composition) never loses its text box to a re-render.
                ((FrameworkElement)_searchHost).Margin = new Thickness(16, 4, 16, 8);
                DockPanel.SetDock(_searchHost, Dock.Top);
                _shell.Children.Add(_searchHost);
                _contentScroll = ContentScroll();
                _shell.Children.Add(_contentScroll);
                RenderNarrowBody();
            }
            Content = _shell;
        }

        private ScrollViewer ContentScroll()
        {
            _content = new StackPanel { Margin = new Thickness(16, 4, 16, 24), MaxWidth = 980 };
            return new ScrollViewer
            {
                Content = _content,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                PanningMode = PanningMode.VerticalOnly,
            };
        }

        private FrameworkElement BuildHeader()
        {
            var bar = new Grid { Margin = new Thickness(8, 8, 8, 4), MinHeight = 60 };
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _back = new Button
            {
                Style = (Style)FindResource("SettingsFlatButton"),
                Content = _main.IconGlyph("IconChevronRight", 22),
                MinWidth = 56,
                Visibility = Visibility.Collapsed,
            };
            // The chevron points right in the icon set; mirrored it reads as "back".
            _back.RenderTransformOrigin = new Point(0.5, 0.5);
            _back.RenderTransform = new ScaleTransform(-1, 1);
            AutomationLabel(_back, Texts.T("settings.back"));
            _back.Click += (s, e) => GoBack();
            Grid.SetColumn(_back, 0);
            bar.Children.Add(_back);
            _title = new TextBlock
            {
                FontSize = 26,
                FontWeight = FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(12, 0, 12, 0),
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Grid.SetColumn(_title, 1);
            bar.Children.Add(_title);
            var close = new Button
            {
                Style = (Style)FindResource("SettingsCommandButton"),
                Content = Texts.T("monitor.close"),
            };
            close.Click += (s, e) => Close();
            Grid.SetColumn(close, 2);
            bar.Children.Add(close);
            UpdateHeader();
            return bar;
        }

        private void UpdateHeader()
        {
            if (_title == null) return;
            bool inside = _wide != true && (_showingCategory || _query.Length > 0);
            _back.Visibility = inside ? Visibility.Visible : Visibility.Collapsed;
            _title.Text = inside && _query.Length == 0 ? Texts.T(Category(_categoryId).TitleKey)
                                                       : Texts.T("settings.title");
        }

        private void GoBack()
        {
            if (_query.Length > 0)
            {
                _query = "";
                _search.Text = "";
            }
            _showingCategory = false;
            RenderNarrowBody();
        }

        private void OnKey(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Escape)
            {
                if (_wide != true && (_showingCategory || _query.Length > 0)) GoBack();
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

        private void RenderNav()
        {
            _nav.Children.Clear();
            foreach (var category in _catalog)
            {
                if (!HasVisibleItems(category)) continue;
                var button = NavButton(category, _wide == true && category.Id == _categoryId);
                string id = category.Id;
                button.Click += (s, e) =>
                {
                    _categoryId = id;
                    if (_query.Length > 0) _search.Text = "";
                    RenderNav();
                    RenderContent();
                };
                _nav.Children.Add(button);
            }
        }

        private Button NavButton(SettingCategory category, bool selected)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var glyph = _main.IconGlyph(category.IconKey, 22, selected ? Brush("Accent") : null);
            glyph.Margin = new Thickness(0, 0, 14, 0);
            row.Children.Add(glyph);
            var label = new TextBlock
            {
                Text = Texts.T(category.TitleKey),
                FontSize = 17,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Grid.SetColumn(label, 1);
            row.Children.Add(label);
            if (_wide != true)
            {
                var chevron = _main.IconGlyph("IconChevronRight", 18, Brush("Dim"));
                Grid.SetColumn(chevron, 2);
                row.Children.Add(chevron);
            }
            var button = new Button
            {
                Style = (Style)FindResource("SettingsFlatButton"),
                Content = row,
                MinHeight = 52,
                Margin = new Thickness(0, 0, 0, 2),
            };
            if (selected) button.SetResourceReference(BackgroundProperty, "Row");
            AutomationLabel(button, label.Text);
            return button;
        }

        private void RenderNarrowBody()
        {
            UpdateHeader();
            _content.Children.Clear();
            _searchHost.Visibility = _showingCategory && _query.Length == 0
                ? Visibility.Collapsed : Visibility.Visible;
            if (_query.Length > 0)
            {
                RenderSearchResults();
                return;
            }
            if (_showingCategory)
            {
                RenderCategory(Category(_categoryId));
                _contentScroll.ScrollToTop();
                return;
            }
            var card = Card();
            var list = (StackPanel)card.Child;
            foreach (var category in _catalog)
            {
                if (!HasVisibleItems(category)) continue;
                var button = NavButton(category, false);
                string id = category.Id;
                button.Click += (s, e) =>
                {
                    _categoryId = id;
                    _showingCategory = true;
                    RenderNarrowBody();
                };
                list.Children.Add(button);
            }
            _content.Children.Add(card);
            _contentScroll.ScrollToTop();
        }

        private void RenderContent()
        {
            UpdateHeader();
            if (_wide != true)
            {
                RenderNarrowBody();
                return;
            }
            _content.Children.Clear();
            if (_query.Length > 0) RenderSearchResults();
            else RenderCategory(Category(_categoryId));
            _contentScroll.ScrollToTop();
        }

        /// <summary>Re-renders the current page after a write changed what other rows show.</summary>
        private void Refresh()
        {
            double offset = _contentScroll == null ? 0 : _contentScroll.VerticalOffset;
            if (_wide == true) RenderContent();
            else RenderNarrowBody();
            if (_contentScroll != null) _contentScroll.ScrollToVerticalOffset(offset);
        }

        private void RenderCategory(SettingCategory category)
        {
            if (_wide == true)
                _content.Children.Add(new TextBlock
                {
                    Text = Texts.T(category.TitleKey),
                    FontSize = 30,
                    FontWeight = FontWeights.SemiBold,
                    Margin = new Thickness(4, 4, 0, 16),
                });
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
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(4),
                Child = new StackPanel(),
            };
            border.SetResourceReference(Border.BackgroundProperty, "Card");
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

        /// <summary>A search box with its hint drawn underneath while it is empty.</summary>
        private FrameworkElement WithPlaceholder(TextBox box, string hint)
        {
            var host = new Grid { Margin = new Thickness(0, 0, 0, 12) };
            var hintText = new TextBlock
            {
                Text = hint,
                FontSize = 16,
                Margin = new Thickness(14, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false,
                Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed,
            };
            hintText.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
            box.TextChanged += (s, e) =>
                hintText.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            host.Children.Add(box);
            host.Children.Add(hintText);
            return host;
        }

        internal void ShowStatus(string text, bool error)
        {
            if (_status == null) return;
            _status.Text = text;
            _status.SetResourceReference(TextBlock.ForegroundProperty, error ? "Danger" : "Ok");
            _status.Visibility = Visibility.Visible;
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
