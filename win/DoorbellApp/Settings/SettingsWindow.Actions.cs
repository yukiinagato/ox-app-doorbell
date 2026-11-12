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
                case "time_status":
                {
                    var time = App.Core == null ? null
                        : CoreClient.Dig(App.Core.Status(), "time") as Dictionary<string, object>;
                    if (time == null) return Texts.T("settings.not_set");
                    object source, last, offset, server;
                    time.TryGetValue("source", out source);
                    time.TryGetValue("last_sync_ms", out last);
                    time.TryGetValue("offset_ms", out offset);
                    time.TryGetValue("server", out server);
                    bool ntp = Convert.ToString(source) == "ntp";
                    long lastMs;
                    long.TryParse(Convert.ToString(last, System.Globalization.CultureInfo.InvariantCulture),
                                  out lastMs);
                    var parts = new List<string>
                    {
                        Texts.T(ntp ? "time.source_ntp" : "time.source_system"),
                        Texts.T("time.last_sync") + " " + (lastMs > 0
                            ? new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)
                                .AddMilliseconds(lastMs).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
                            : Texts.T("time.never")),
                    };
                    if (ntp) parts.Add(Texts.T("time.offset") + " " + Convert.ToString(offset) + " ms");
                    if (!string.IsNullOrEmpty(Convert.ToString(server)))
                        parts.Add(Texts.T("time.server") + " " + Convert.ToString(server));
                    return string.Join(" · ", parts);
                }
                case "role":
                    return Texts.T(App.Boot != null && App.Boot.Role == "door_station"
                        ? "admin.role_door" : "admin.role_indoor");
                case "door":
                    return App.Boot == null ? "" : DoorTitle(App.Boot.Door);
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
                    // The release version and its build number, as the file properties carry them
                    // (0.2.0.22 reads "0.2.0 (22)"): what a deployment is checked against.
                    var assembly = Assembly.GetEntryAssembly();
                    if (assembly == null) return "";
                    Version file;
                    try
                    {
                        string text = FileVersionInfo.GetVersionInfo(assembly.Location).FileVersion;
                        if (!Version.TryParse(text, out file)) file = assembly.GetName().Version;
                    }
                    catch (IOException) { file = assembly.GetName().Version; }
                    catch (ArgumentException) { file = assembly.GetName().Version; }
                    return file.ToString(3) + (file.Revision > 0 ? " (" + file.Revision + ")" : "");
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
            AutomationId(button, "SettingsAction_" + item.Id);
            if (item.Destructive)
            {
                DoorbellApp.Ui.Fluent.MakeDestructive(button);
            }
            button.Click += (s, e) => RunAction(item, parts);
            return button;
        }

        private void RunAction(SettingItem item, RowParts parts)
        {
            switch (item.Handler)
            {
                case "volume_reset":
                    if (!Confirm(Texts.T("settings.reset_confirm"))) break;
                    if (Report(_store.Delete(item.Key + ".call", item.Key + ".sos", item.Key + ".idle"),
                               parts))
                        Refresh();
                    break;
                case "change_role":
                    ShowRoleForm(parts);
                    break;
                case "view_log":
                    ShowLogViewer();
                    break;
                case "raw_config":
                    ShowRawConfig(parts);
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
        /// The device name is part of this device's identity. boot.json is what the shell and
        /// the mesh start from, so it is written first; Core republishes devices.&lt;self&gt; from
        /// it when the app restarts. Role and door change through the role form instead.
        /// </summary>
        private bool WriteIdentity(SettingItem item, string value, RowParts parts)
        {
            if (App.Boot == null || item.Id != "device_name") return false;
            if (_main.IdentityChangeBlocked)
                return Report(new SettingsWriteResult { Error = Texts.T("settings.role_busy") }, parts);
            if (!Confirm(Texts.T("settings.identity_restart_confirm"))) return false;
            if (BootConfig.PersistSetup(App.Boot.FilePath, value, App.Boot.Role, App.Boot.Door) == null)
                return Report(new SettingsWriteResult { Error = "boot_write_failed" }, parts);
            App.RestartApp("identity_changed");
            return true;
        }
    }
}
