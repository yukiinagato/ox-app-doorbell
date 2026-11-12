using System;
using System.Windows;
using System.Windows.Controls;
using DoorbellApp.Ui;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>First-run setup: a Fluent form for the device name, its role and the door id.</summary>
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
            Fluent.StyleWindow(this);
            Content = BuildContent();
        }

        private UIElement BuildContent()
        {
            var root = new StackPanel { Margin = new Thickness(32, 24, 32, 32) };
            root.Children.Add(new TextBlock
            {
                Text = L10n.T("setup.title"), FontSize = 28, FontWeight = FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8)
            });
            root.Children.Add(new TextBlock
            {
                Text = L10n.T("setup.message"), FontSize = 15, TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 20)
            });

            _name.Text = _initial.Name ?? "";
            _name.FontSize = 16;
            _name.MinHeight = Fluent.TouchMin;
            _name.Margin = new Thickness(0, 0, 0, 16);
            root.Children.Add(Fluent.WithHeader(_name, L10n.T("setup.name")));

            _role.FontSize = 16;
            _role.MinHeight = Fluent.TouchMin;
            _role.HorizontalAlignment = HorizontalAlignment.Stretch;
            _role.Margin = new Thickness(0, 0, 0, 16);
            _role.Items.Add(new ComboBoxItem
                { Content = L10n.T("admin.role_door"), Tag = "door_station",
                  MinHeight = Fluent.TouchMin });
            _role.Items.Add(new ComboBoxItem
                { Content = L10n.T("admin.role_indoor"), Tag = "indoor_panel",
                  MinHeight = Fluent.TouchMin });
            _role.SelectedIndex = _initial.Role == "indoor_panel" ? 1 : 0;
            _role.SelectionChanged += (sender, args) => UpdateRole();
            root.Children.Add(Fluent.WithHeader(_role, L10n.T("setup.role")));

            _door.Text = _initial.SuggestedDoor ?? "";
            _door.FontSize = 16;
            _door.MinHeight = Fluent.TouchMin;
            _door.Margin = new Thickness(0, 0, 0, 4);
            _doorRow.Children.Add(Fluent.WithHeader(_door, L10n.T("setup.door")));
            var hint = new TextBlock
            {
                Text = L10n.T("setup.door_hint"), TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 16)
            };
            hint.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
            _doorRow.Children.Add(hint);
            root.Children.Add(_doorRow);

            _error.Text = L10n.T("setup.invalid_door");
            _error.SetResourceReference(TextBlock.ForegroundProperty, "NegativeText");
            _error.TextWrapping = TextWrapping.Wrap;
            _error.Visibility = Visibility.Collapsed;
            _error.Margin = new Thickness(0, 0, 0, 12);
            root.Children.Add(_error);

            var save = new Button
            {
                Content = L10n.T("setup.finish"), FontSize = 18, IsDefault = true,
                MinHeight = 52, Padding = new Thickness(24, 8, 24, 8),
                HorizontalAlignment = HorizontalAlignment.Right
            };
            Fluent.MakeAccent(save);
            save.Click += Save;
            root.Children.Add(save);
            UpdateRole();
            return root;
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
