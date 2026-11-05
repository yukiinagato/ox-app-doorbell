using System;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DoorbellApp.Util;

namespace DoorbellApp.Pairing
{
    /// <summary>
    /// Asks for the eight-digit confirmation code the new device shows on its own pairing screen
    /// (security protocol v3). Approving without it would trust a public key that arrived in an
    /// unauthenticated beacon.
    /// </summary>
    internal static class ConfirmCodeDialog
    {
        public const int CodeLength = 8;

        /// <summary>Returns the eight digits, or null when cancelled.</summary>
        public static string Ask(Window owner, string deviceName)
        {
            var dialog = new Window
            {
                Owner = owner,
                Topmost = owner != null && owner.Topmost,
                WindowStyle = WindowStyle.None,
                ResizeMode = ResizeMode.NoResize,
                SizeToContent = SizeToContent.Height,
                Width = 480,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                ShowInTaskbar = false,
            };
            if (owner != null) dialog.FontFamily = owner.FontFamily;
            dialog.SetResourceReference(Control.BackgroundProperty, "Card");
            dialog.SetResourceReference(Control.ForegroundProperty, "Fg");
            var form = new StackPanel { Margin = new Thickness(28) };
            form.Children.Add(new TextBlock
            {
                Text = Texts.T("pair.confirm_code_title", deviceName ?? ""),
                FontSize = 22,
                FontWeight = FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            var hint = new TextBlock
            {
                Text = Texts.T("pair.confirm_code_hint"),
                FontSize = 15,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 8, 0, 16),
            };
            hint.SetResourceReference(TextBlock.ForegroundProperty, "Dim");
            form.Children.Add(hint);
            var box = new TextBox
            {
                Style = (Style)dialog.FindResource("SettingsTextBox"),
                FontSize = 34,
                MaxLength = 9,
                TextAlignment = TextAlignment.Center,
                InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Number) } },
            };
            form.Children.Add(box);
            var error = new TextBlock
            {
                Text = Texts.T("pair.confirm_code_invalid"),
                FontSize = 14,
                Visibility = Visibility.Collapsed,
                Margin = new Thickness(0, 8, 0, 0),
            };
            error.SetResourceReference(TextBlock.ForegroundProperty, "Danger");
            form.Children.Add(error);
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 22, 0, 0),
            };
            var cancel = new Button
            {
                Style = (Style)dialog.FindResource("SettingsCommandButton"),
                Content = Texts.T("calling.cancel"),
                IsCancel = true,
            };
            var ok = new Button
            {
                Style = (Style)dialog.FindResource("SettingsCommandButton"),
                Content = Texts.T("pair.add"),
                IsDefault = true,
                Margin = new Thickness(10, 0, 0, 0),
            };
            ok.SetResourceReference(Control.BackgroundProperty, "Accent");
            ok.SetResourceReference(Control.ForegroundProperty, "OnAccent");
            actions.Children.Add(cancel);
            actions.Children.Add(ok);
            form.Children.Add(actions);
            dialog.Content = form;
            string result = null;
            cancel.Click += (s, e) => dialog.DialogResult = false;
            ok.Click += (s, e) =>
            {
                string digits = Digits(box.Text);
                if (digits.Length != CodeLength)
                {
                    error.Visibility = Visibility.Visible;
                    box.Focus();
                    return;
                }
                result = digits;
                dialog.DialogResult = true;
            };
            dialog.Loaded += (s, e) => box.Focus();
            return dialog.ShowDialog() == true ? result : null;
        }

        /// <summary>Keeps ASCII and full-width digits; spaces and hyphens are separators.</summary>
        public static string Digits(string text)
        {
            var digits = new StringBuilder();
            foreach (char c in text ?? "")
            {
                if (c >= '0' && c <= '9') digits.Append(c);
                else if (c >= '０' && c <= '９') digits.Append((char)('0' + (c - '０')));
            }
            return digits.ToString();
        }
    }
}
