using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // Read-only values, commands, and the writes that are not plain Core
    // configuration: boot.json fields, the device identity, the shell language, local flags.
    internal sealed partial class SettingsWindow
    {
        public const string LocalPrefix = "local:";

        private FrameworkElement BuildInfo(SettingItem item)
        {
            var value = new TextBox
            {
                Text = InfoValue(item.Handler),
                IsReadOnly = true,
                BorderThickness = new Thickness(0),
                Background = System.Windows.Media.Brushes.Transparent,
                FontSize = 15,
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 420,
                TextAlignment = TextAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
            };
            value.SetResourceReference(ForegroundProperty, "Dim");
            return value;
        }

        private string InfoValue(string handler)
        {
            switch (handler)
            {
                case "node_id": return _store.Context.NodeId;
                case "pairing_state":
                {
                    var pairing = App.Core == null ? null : App.Core.PairingInfo();
                    object state = pairing == null ? null : CoreClient.Dig(pairing, "state");
                    switch (state == null ? "" : state.ToString())
                    {
                        case "unpaired": return Texts.T("settings.pairing_unpaired");
                        case "joining": return Texts.T("settings.pairing_joining");
                        case "persist_error": return Texts.T("settings.pairing_persist_error");
                        case "ready": return Texts.T("settings.pairing_ready");
                        case "revoked": return Texts.T("settings.pairing_revoked");
                        default: return Texts.T("settings.not_set");
                    }
                }
                case "cluster_key":
                {
                    var snapshot = DoorbellApp.Pairing.PairingSnapshot.From(
                        App.Core == null ? null : App.Core.PairingInfo());
                    if (snapshot.UpgradeRejoinRequired) return Texts.T("pair.upgrade_rejoin_title");
                    if (snapshot.PskId.Length == 0) return Texts.T("settings.not_set");
                    if (snapshot.PrevPskId.Length == 0 || snapshot.PrevPskUntilMs <= 0)
                        return snapshot.PskId;
                    var until = DateTimeOffset.FromUnixTimeMilliseconds(snapshot.PrevPskUntilMs)
                        .ToLocalTime().ToString("g");
                    return Texts.T("settings.cluster_key_previous", snapshot.PskId,
                                   snapshot.PrevPskId, until);
                }
                case "peer_alerts":
                {
                    var snapshot = DoorbellApp.Pairing.PairingSnapshot.From(
                        App.Core == null ? null : App.Core.PairingInfo());
                    var lines = new List<string>();
                    if (snapshot.RekeyRequired.Count > 0)
                        lines.Add(Texts.T("settings.peers_rekey_required",
                                          string.Join(", ", snapshot.RekeyRequired)));
                    if (snapshot.LegacyPeers.Count > 0)
                        lines.Add(Texts.T("settings.peers_legacy",
                                          string.Join(", ", snapshot.LegacyPeers)));
                    return lines.Count == 0 ? Texts.T("settings.peers_ok") : string.Join("\n", lines);
                }
                case "watchdog_state":
                    return Texts.T(App.Watchdog != null && App.Watchdog.Available
                        ? "settings.watchdog_connected" : "settings.watchdog_absent");
                case "safe_mode": return Texts.T(App.SafeMode ? "settings.on" : "settings.off");
                case "app_version":
                {
                    var assembly = Assembly.GetEntryAssembly();
                    var version = assembly == null ? null : assembly.GetName().Version;
                    return version == null ? "" : version.ToString();
                }
                case "core_version": return App.Core == null ? "" : App.Core.CoreVersion;
                case "sip_backend": return App.Core == null ? "" : App.Core.SipBackend;
                case "addresses": return string.Join("\n", AdminLink.Hosts());
                case "admin_urls":
                {
                    var urls = new List<string>();
                    foreach (string host in AdminLink.Hosts())
                        urls.Add(AdminLink.Url(host, AdminLink.HttpsPort));
                    return urls.Count == 0 ? Texts.T("web_admin.none") : string.Join("\n", urls);
                }
                case "tls_fingerprint":
                {
                    object fingerprint = _store.Get("devices.{self}.tls_sha256");
                    return fingerprint == null ? Texts.T("settings.not_set") : fingerprint.ToString();
                }
                default: return "";
            }
        }

        private FrameworkElement BuildAction(SettingItem item, RowParts parts)
        {
            var button = CommandButton(Texts.T(item.LabelKey + "_action"));
            if (item.Destructive)
            {
                button.SetResourceReference(Control.ForegroundProperty, "Negative");
                button.SetResourceReference(Control.BorderBrushProperty, "Negative");
            }
            button.Click += (s, e) => RunAction(item, parts);
            return button;
        }

        private void RunAction(SettingItem item, RowParts parts)
        {
            switch (item.Handler)
            {
                case "volume_reset":
                    if (Report(_store.Delete(item.Key + ".call", item.Key + ".sos", item.Key + ".idle"),
                               parts))
                        Refresh();
                    break;
                case "notice_edit":
                    _main.OpenNoticeDialogFromSettings();
                    break;
                case "rotate_cluster_key":
                    if (!Confirm(Texts.T("settings.rotate_cluster_key_confirm"), true)) break;
                    int rotated = App.Core == null ? -3 : App.Core.RotateClusterKey();
                    ShowStatus(Texts.T(rotated == 0 ? "settings.rotate_cluster_key_done"
                                     : rotated == -3 ? "settings.err_core_unavailable"
                                                     : "settings.rotate_cluster_key_failed"),
                               rotated != 0);
                    if (rotated == 0) Refresh();
                    break;
                case "time_sync":
                    bool synced = App.Core != null && App.Core.TimeSyncNow();
                    ShowStatus(Texts.T(synced ? "settings.time_sync_started" : "settings.time_sync_failed"),
                               !synced);
                    break;
                case "add_device":
                    _main.OpenAddDevicePanelFromSettings();
                    Refresh();
                    break;
                case "kiosk_unlock":
                    _main.UnlockKioskFromSettings();
                    ShowStatus(Texts.T("settings.kiosk_unlocked"), false);
                    break;
                case "kiosk_lock":
                    _main.RelockKioskFromSettings();
                    Close();
                    break;
                case "restart_app":
                    if (Confirm(Texts.T("settings.restart_confirm"), true)) App.RestartApp("operator_restart");
                    break;
                case "open_logs":
                    try
                    {
                        string logs = Path.Combine(App.DataDir, "logs");
                        Directory.CreateDirectory(logs);
                        Process.Start(new ProcessStartInfo("explorer.exe", "\"" + logs + "\"")
                            { UseShellExecute = true });
                    }
                    catch (Exception ex) { ShowStatus(ex.Message, true); }
                    break;
                case "rebuild_cluster":
                    RebuildCluster();
                    break;
                case "telegram_test":
                    TelegramTest();
                    break;
                case "change_password":
                    ChangeAdminPassword();
                    break;
                case "goto_rules":
                    if (_query.Length > 0) _search.Text = "";
                    _categoryId = "rules";
                    RenderContent();
                    break;
            }
        }

        private bool Confirm(string message, bool destructive = false)
        {
            return MessageBox.Show(this, message, Texts.T("settings.title"), MessageBoxButton.YesNo,
                                   destructive ? MessageBoxImage.Warning : MessageBoxImage.Question,
                                   MessageBoxResult.No) == MessageBoxResult.Yes;
        }

        // ---- non-config writes ----------------------------------------------------------------

        private bool WriteSpecial(SettingItem item, object value, RowParts parts)
        {
            if (item.Key == LocalPrefix + "video_stats")
            {
                _main.SetVideoStatsVisibleFromSettings(SettingsStore.AsBool(value, true));
                ShowStatus(Texts.T("admin.saved"), false);
                return true;
            }
            if (item.Key == SettingsStore.BootPrefix + "kiosk")
            {
                if (!Confirm(Texts.T("settings.restart_confirm"))) return false;
                if (App.Boot == null ||
                    BootConfig.PersistField(App.Boot.FilePath, "kiosk", SettingsStore.AsBool(value, true)) == null)
                    return Report(new SettingsWriteResult { Error = "boot_write_failed" }, parts);
                App.RestartApp("kiosk_mode_changed");
                return true;
            }
            if (item.Handler == "ui_lang") return WriteLanguage(value == null ? "" : value.ToString(), parts);
            if (item.Handler == "identity") return WriteIdentity(item, value == null ? "" : value.ToString(), parts);
            return false;
        }

        /// <summary>The shell language: this device's replicated setting and its boot profile.</summary>
        private bool WriteLanguage(string lang, RowParts parts)
        {
            if (!Report(_store.Set("devices.{self}.local.ui_lang", lang), parts)) return false;
            if (App.Boot != null) BootConfig.PersistField(App.Boot.FilePath, "ui_lang", lang);
            L10n.SetLanguage(lang);
            Texts.SetLang(lang);
            _main.ReapplyLanguageFromSettings();
            Title = Texts.T("settings.title");
            Dispatcher.BeginInvoke(new Action(BuildShell));
            return true;
        }

        /// <summary>
        /// Name, role and door are this device's identity: boot.json is the source the shell and
        /// mesh start from, and devices.&lt;self&gt; is the replicated desired identity. Both are
        /// written, then the app restarts so Core advertises the new identity.
        /// </summary>
        private bool WriteIdentity(SettingItem item, string value, RowParts parts)
        {
            if (App.Boot == null) return false;
            string name = App.Boot.Name, role = App.Boot.Role, door = App.Boot.Door;
            if (item.Id == "device_name") name = value;
            else if (item.Id == "device_role") role = value;
            else door = value;
            if (role == "door_station" && !BootConfig.ValidDoor(door))
            {
                if (item.Id == "device_door")
                    return Report(new SettingsWriteResult { Error = Texts.T("settings.err_door_id") }, parts);
                door = BootConfig.ValidDoor(App.Boot.SuggestedDoor) ? App.Boot.SuggestedDoor : "";
            }
            if (!Confirm(Texts.T("settings.identity_restart_confirm"))) return false;
            var sets = new List<KeyValuePair<string, object>>
            {
                new KeyValuePair<string, object>("devices.{self}.name", name),
                new KeyValuePair<string, object>("devices.{self}.role", role),
                new KeyValuePair<string, object>("devices.{self}.door",
                    role == "door_station" ? (object)door : null),
            };
            if (!Report(_store.Commit(sets, null), parts)) return false;
            if (BootConfig.PersistSetup(App.Boot.FilePath, name, role, door) == null)
                return Report(new SettingsWriteResult { Error = Texts.T("settings.err_door_id") }, parts);
            App.RestartApp("identity_changed");
            return true;
        }
    }
}
