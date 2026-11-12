using System;
using System.Collections;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // The "Change role" form (ui-guidelines 4, Settings; settings parity audit 1.5). One form for
    // role and door; nothing is written until it is confirmed. boot.json is persisted first and
    // the app then restarts, because Core reads role and door once at start and republishes
    // devices.<self> from them.
    internal sealed partial class SettingsWindow
    {
        private const string NewDoorChoice = "\u0000new";

        /// <summary>Doors a live door station other than this device is serving right now.</summary>
        private HashSet<string> DoorsServedByOthers()
        {
            var served = new HashSet<string>(StringComparer.Ordinal);
            var status = App.Core == null ? null : App.Core.Status();
            var peers = status != null && status.ContainsKey("peers")
                ? status["peers"] as IEnumerable : null;
            if (peers == null) return served;
            foreach (object raw in peers)
            {
                var peer = raw as Dictionary<string, object>;
                if (peer == null || Str(peer, "role") != "door_station") continue;
                if (Str(peer, "id") == _store.Context.NodeId) continue;
                object self;
                if (peer.TryGetValue("self", out self) && self is bool && (bool)self) continue;
                if (Str(peer, "status") == "dead") continue;
                string door = Str(peer, "door");
                if (door.Length != 0) served.Add(door);
            }
            return served;
        }

        /// <summary>Another configured door station already bound to this door, or null.</summary>
        private string OtherStationBoundTo(string door)
        {
            foreach (var pair in ReadRecords("devices"))
            {
                if (pair.Key == _store.Context.NodeId) continue;
                if (Str(pair.Value, "role") != "door_station" || Str(pair.Value, "door") != door)
                    continue;
                string name = Str(pair.Value, "name");
                return name.Length != 0 ? name : pair.Key;
            }
            return null;
        }

        private string DoorTitle(string door)
        {
            if (string.IsNullOrEmpty(door)) return "";
            foreach (var option in DoorOptions())
                if (Convert.ToString(option.Value) == door)
                    return option.Text == door ? door : option.Text + " (" + door + ")";
            return door;
        }

        private void ShowRoleForm(RowParts parts)
        {
            if (App.Boot == null) return;
            StackPanel form, actions;
            TextBlock error;
            var dialog = FormWindow(Texts.T("settings.change_role"), out form, out actions,
                                    out error, 560);

            form.Children.Add(FieldLabel(Texts.T("settings.device_role")));
            var role = new ComboBox { Style = (Style)FindResource("SettingsComboBox") };
            role.Items.Add(new ComboBoxItem { Content = Texts.T("admin.role_door"), Tag = "door_station" });
            role.Items.Add(new ComboBoxItem { Content = Texts.T("admin.role_indoor"), Tag = "indoor_panel" });
            role.SelectedIndex = App.Boot.Role == "door_station" ? 0 : 1;
            AutomationLabel(role, Texts.T("settings.device_role"));
            AutomationId(role, "RoleFormRole");
            form.Children.Add(role);

            // Door picker: configured doors no other live door station serves, this device's
            // own door, then "New door".
            var doorPanel = new StackPanel();
            doorPanel.Children.Add(FieldLabel(Texts.T("settings.device_door")));
            var door = new ComboBox { Style = (Style)FindResource("SettingsComboBox") };
            AutomationLabel(door, Texts.T("settings.device_door"));
            AutomationId(door, "RoleFormDoor");
            var served = DoorsServedByOthers();
            int selected = -1;
            foreach (var option in DoorOptions())
            {
                string id = Convert.ToString(option.Value);
                if (served.Contains(id) && id != App.Boot.Door) continue;
                door.Items.Add(new ComboBoxItem
                    { Content = option.Text == id ? id : option.Text + " (" + id + ")", Tag = id });
                if (id == App.Boot.Door) selected = door.Items.Count - 1;
            }
            if (selected < 0 && BootConfig.ValidDoor(App.Boot.Door))
            {
                // This device's door has no configuration entry yet (unpaired, or just founded).
                door.Items.Add(new ComboBoxItem { Content = App.Boot.Door, Tag = App.Boot.Door });
                selected = door.Items.Count - 1;
            }
            door.Items.Add(new ComboBoxItem { Content = Texts.T("settings.role_new_door"), Tag = NewDoorChoice });
            door.SelectedIndex = selected >= 0 ? selected : door.Items.Count - 1;
            doorPanel.Children.Add(door);

            var newDoorPanel = new StackPanel();
            newDoorPanel.Children.Add(FieldLabel(Texts.T("settings.role_new_door_id")));
            var newDoor = FormTextBox(BootConfig.SuggestedDoorId(), 64);
            AutomationLabel(newDoor, Texts.T("settings.role_new_door_id"));
            AutomationId(newDoor, "RoleFormNewDoor");
            newDoorPanel.Children.Add(newDoor);
            newDoorPanel.Children.Add(FieldHint(Texts.T("settings.device_door_desc")));
            doorPanel.Children.Add(newDoorPanel);
            var inUse = FieldHint("");
            inUse.SetResourceReference(TextBlock.ForegroundProperty, "Warning");
            doorPanel.Children.Add(inUse);
            form.Children.Add(doorPanel);

            var indoorNote = FieldHint(Texts.T("settings.role_indoor_note"));
            indoorNote.Margin = new Thickness(0, 12, 0, 0);
            form.Children.Add(indoorNote);

            Func<string> chosenRole = () =>
                Convert.ToString(((ComboBoxItem)role.SelectedItem).Tag);
            Func<string> chosenDoor = () =>
            {
                var item = door.SelectedItem as ComboBoxItem;
                string tag = item == null ? NewDoorChoice : Convert.ToString(item.Tag);
                return tag == NewDoorChoice ? newDoor.Text.Trim() : tag;
            };
            Action refresh = () =>
            {
                bool station = chosenRole() == "door_station";
                doorPanel.Visibility = station ? Visibility.Visible : Visibility.Collapsed;
                indoorNote.Visibility = station ? Visibility.Collapsed : Visibility.Visible;
                var item = door.SelectedItem as ComboBoxItem;
                newDoorPanel.Visibility = item != null && Convert.ToString(item.Tag) == NewDoorChoice
                    ? Visibility.Visible : Visibility.Collapsed;
                // A door bound to another (offline) door station is a warning, not a refusal.
                string other = station ? OtherStationBoundTo(chosenDoor()) : null;
                inUse.Text = other == null ? "" : Texts.T("settings.role_door_in_use", other);
                inUse.Visibility = other == null ? Visibility.Collapsed : Visibility.Visible;
                error.Visibility = Visibility.Collapsed;
            };
            role.SelectionChanged += (s, e) => refresh();
            door.SelectionChanged += (s, e) => refresh();
            newDoor.TextChanged += (s, e) => refresh();
            refresh();

            var cancel = CommandButton(Texts.T("admin.cancel"));
            // Not the default button: Enter in the form must not restart the device.
            var apply = PrimaryButton(Texts.T("settings.change_role"));
            apply.Margin = new Thickness(8, 0, 0, 0);
            cancel.IsCancel = true;
            AutomationId(cancel, "RoleFormCancel");
            AutomationId(apply, "RoleFormApply");
            actions.Children.Add(cancel);
            actions.Children.Add(apply);
            cancel.Click += (s, e) => dialog.DialogResult = false;
            apply.Click += (s, e) =>
            {
                Action<string> refuse = message =>
                {
                    error.Text = message;
                    error.Visibility = Visibility.Visible;
                };
                string wantedRole = chosenRole();
                string wantedDoor = wantedRole == "door_station" ? chosenDoor() : "";
                if (!BootConfig.ValidRole(wantedRole)) return;
                if (wantedRole == "door_station" && !BootConfig.ValidDoor(wantedDoor))
                {
                    refuse(Texts.T("settings.err_door_id"));
                    return;
                }
                if (wantedRole == App.Boot.Role && wantedDoor == (App.Boot.Door ?? ""))
                {
                    refuse(Texts.T("settings.role_unchanged"));
                    return;
                }
                // A restart would cut a call, an SOS or a pairing short.
                if (_main.IdentityChangeBlocked)
                {
                    refuse(Texts.T("settings.role_busy"));
                    return;
                }
                if (MessageBox.Show(dialog, Texts.T("settings.role_restart_confirm"),
                                    Texts.T("settings.change_role"), MessageBoxButton.YesNo,
                                    MessageBoxImage.Warning, MessageBoxResult.No)
                    != MessageBoxResult.Yes) return;
                if (BootConfig.PersistSetup(App.Boot.FilePath, App.Boot.Name, wantedRole, wantedDoor)
                    == null)
                {
                    refuse(Texts.T("settings.save_failed_reason", Texts.T("settings.err_door_id")));
                    return;
                }
                dialog.DialogResult = true;
                App.RestartApp("identity_changed");
            };
            dialog.ShowDialog();
        }
    }
}
