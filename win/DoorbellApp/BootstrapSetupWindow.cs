using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DoorbellApp.Util;

namespace DoorbellApp
{
    public sealed class BootstrapSetupWindow : Window
    {
        private readonly BootConfig _initial;
        private readonly TextBox _name = new TextBox();
        private readonly ComboBox _role = new ComboBox();
        private readonly TextBox _door = new TextBox();
        private readonly StackPanel _doorRow = new StackPanel();
        private readonly TextBlock _error = new TextBlock();

        public BootConfig ResultConfig { get; private set; }

        public BootstrapSetupWindow(BootConfig initial)
        {
            _initial = initial ?? new BootConfig();
            Title = L10n.T("setup.title");
            Width = 620;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = Brushes.White;
            Content = BuildContent();
        }

        private UIElement BuildContent()
        {
            var root = new StackPanel { Margin = new Thickness(36) };
            root.Children.Add(new TextBlock
            {
                Text = L10n.T("setup.title"), FontSize = 30, FontWeight = FontWeights.Bold,
                TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 0, 0, 14)
            });
            root.Children.Add(new TextBlock
            {
                Text = L10n.T("setup.message"), FontSize = 16, TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 0, 0, 20)
            });

            root.Children.Add(Label(L10n.T("setup.name")));
            _name.Text = _initial.Name ?? "";
            _name.FontSize = 18;
            _name.Margin = new Thickness(0, 4, 0, 14);
            root.Children.Add(_name);

            root.Children.Add(Label(L10n.T("setup.role")));
            _role.FontSize = 18;
            _role.Margin = new Thickness(0, 4, 0, 14);
            _role.Items.Add(new ComboBoxItem
                { Content = L10n.T("admin.role_door"), Tag = "door_station" });
            _role.Items.Add(new ComboBoxItem
                { Content = L10n.T("admin.role_indoor"), Tag = "indoor_panel" });
            _role.SelectedIndex = _initial.Role == "indoor_panel" ? 1 : 0;
            _role.SelectionChanged += (sender, args) => UpdateRole();
            root.Children.Add(_role);

            _doorRow.Children.Add(Label(L10n.T("setup.door")));
            _door.Text = _initial.SuggestedDoor ?? "";
            _door.FontSize = 18;
            _door.Margin = new Thickness(0, 4, 0, 3);
            _doorRow.Children.Add(_door);
            _doorRow.Children.Add(new TextBlock
            {
                Text = L10n.T("setup.door_hint"), Foreground = Brushes.DimGray,
                Margin = new Thickness(0, 0, 0, 14)
            });
            root.Children.Add(_doorRow);

            _error.Text = L10n.T("setup.invalid_door");
            _error.Foreground = Brushes.DarkRed;
            _error.TextAlignment = TextAlignment.Center;
            _error.Visibility = Visibility.Collapsed;
            _error.Margin = new Thickness(0, 0, 0, 10);
            root.Children.Add(_error);

            var save = new Button
            {
                Content = L10n.T("setup.finish"), FontSize = 20, FontWeight = FontWeights.Bold,
                MinHeight = 52, Padding = new Thickness(20, 8, 20, 8)
            };
            save.Click += Save;
            root.Children.Add(save);
            UpdateRole();
            return root;
        }

        private static TextBlock Label(string value)
        {
            return new TextBlock { Text = value, FontSize = 15, FontWeight = FontWeights.SemiBold };
        }

        private string SelectedRole()
        {
            var item = _role.SelectedItem as ComboBoxItem;
            return item == null || item.Tag == null ? "" : item.Tag.ToString();
        }

        private void UpdateRole()
        {
            _doorRow.Visibility = SelectedRole() == "door_station" ?
                                  Visibility.Visible : Visibility.Collapsed;
            _error.Visibility = Visibility.Collapsed;
        }

        private void Save(object sender, RoutedEventArgs args)
        {
            string role = SelectedRole();
            string door = role == "door_station" ? _door.Text : "";
            ResultConfig = BootConfig.PersistSetup(_initial.FilePath, _name.Text, role, door);
            if (ResultConfig == null)
            {
                _error.Visibility = Visibility.Visible;
                return;
            }
            DialogResult = true;
        }
    }
}
