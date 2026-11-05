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
    // Home refresh: reading Core status off the UI thread and applying it.
    public partial class MainWindow
    {
        /// <summary>
        /// Asks for a home refresh. Several events inside the same second cost one refresh, which
        /// is what keeps core's run loop free while peers gossip.
        /// </summary>
        private void RequestHomeRefresh(HomeRefresh kinds)
        {
            _pendingRefresh |= kinds;
            if (!_homeRefresh.IsEnabled) _homeRefresh.Start();
        }

        private void RunHomeRefresh(HomeRefresh extra = HomeRefresh.None)
        {
            _pendingRefresh |= extra;
            HomeRefresh kinds = _pendingRefresh;
            if (kinds == HomeRefresh.None) return;
            if (_homeRefreshBusy)
            {
                // A read is still in flight; try again on the next turn of the coalescer.
                if (!_homeRefresh.IsEnabled) _homeRefresh.Start();
                return;
            }
            _pendingRefresh = HomeRefresh.None;
            _homeRefreshBusy = true;
            Task.Run(() =>
            {
                HomeSnapshot snapshot = ReadHomeSnapshot(kinds);
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    _homeRefreshBusy = false;
                    ApplyHomeSnapshot(snapshot, kinds);
                }));
            });
        }

        /// <summary>
        /// Runs on a worker. status/config/audio are served from run-loop snapshots and never
        /// enter the loop; pairing and the call log do marshal into it, which is exactly why they
        /// are read here rather than on the dispatcher.
        /// </summary>
        private HomeSnapshot ReadHomeSnapshot(HomeRefresh kinds)
        {
            var snapshot = new HomeSnapshot();
            try
            {
                snapshot.Status = App.Core.Status();
                snapshot.Config = App.Core.Config();
                snapshot.Audio = App.Core.AudioVolumes(_nodeId);
                snapshot.SipBackend = App.Core.SipBackend;
                snapshot.SipAvailable = App.Core.SipAvailable;
                if ((kinds & HomeRefresh.Pairing) != 0) snapshot.Pairing = App.Core.PairingInfo();
                if ((kinds & HomeRefresh.History) != 0)
                    snapshot.CallLog = App.Core.CallLog(0, RecentCallRows);
            }
            catch (Exception ex)
            {
                Debug.WriteLine("home refresh read failed: " + ex.Message);
            }
            return snapshot;
        }

        private void ApplyHomeSnapshot(HomeSnapshot snapshot, HomeRefresh kinds)
        {
            if (snapshot == null) return;
            // One status document for this refresh, shared by every consumer below.
            if (snapshot.Status != null) _status = snapshot.Status;
            if (snapshot.Config != null) RefreshConfigCache(snapshot.Config);
            if ((kinds & HomeRefresh.Node) != 0) RefreshNodeInfo(snapshot);
            if ((kinds & HomeRefresh.Notice) != 0) RefreshNoticeSurfaces();
            if ((kinds & HomeRefresh.Tiles) != 0) RefreshDoorTiles(snapshot.Status);
            if ((kinds & HomeRefresh.History) != 0) RefreshCallHistory(snapshot.CallLog);
            if ((kinds & HomeRefresh.Pairing) != 0) RefreshPairingState(snapshot.Pairing);
        }

        private void RefreshNodeInfo(HomeSnapshot snapshot)
        {
            var st = snapshot.Status;
            if (st != null)
            {
                try
                {
                    var node = st["node"] as Dictionary<string, object>;
                    if (node != null)
                    {
                        object id;
                        if (node.TryGetValue("id", out id) && id != null) _nodeId = id.ToString();
                        ReadPowerFromStatus(st);
                        ReadCallStateFromStatus(st);
                        ApplyVersionLine(DictStr(node, "name"), DictStr(node, "version"));
                    }
                }
                catch { }
                ApplyDisplayFromStatus(st);
            }
            if (st != null && App.Boot.Role == "door_station" && !string.IsNullOrEmpty(App.Boot.Door))
            {
                var vl = CoreClient.Dig(st, "visitor_lang." + App.Boot.Door);
                SetVisitorLang(vl != null ? vl.ToString() : "ja");
            }
            RefreshSosConfig(_cfg);
            ApplyAudioVolumes(snapshot.Audio);
            var dp = CoreClient.Dig(_cfg, "sip.direct_port");
            if (dp != null)
            {
                int p;
                if (int.TryParse(dp.ToString(), out p) && p > 0) _directPort = p;
            }
            // v2 contract is a top-level string. Keep the historical ui.call_flow
            // read only so a staged fleet upgrade does not change behaviour mid-call.
            var flow = CoreClient.Dig(_cfg, "call_flow") ??
                       CoreClient.Dig(_cfg, "ui.call_flow");
            _callFlow = flow != null && flow.ToString() == "ring_then_purpose" ?
                "ring_then_purpose" : "purpose_first";
            ApplyTheme();
            ApplyAppearance();
            BuildPurposeButtons();
            BuildLangBar();
            ApplyStrings();
            ApplyRoleHome();
            RefreshAdminLink();
            RefreshDeviceCounters();
            _semanticStyles = SemanticUiOverrides.Load(_cfg, _nodeId, App.DataDir);
            ApplySemanticStyles();
            PublishUiStyleWithAdvisories();
            OpenMonitorButton.Visibility = App.Boot.Role == "indoor_panel" ?
                Visibility.Visible : Visibility.Collapsed;
            MicButton.Visibility = App.Core.SipMicMuteAvailable ?
                Visibility.Visible : Visibility.Collapsed;
            InCallMicButton.Visibility = MicButton.Visibility;
            bool sip = snapshot.SipAvailable;
            AnswerButton.IsEnabled = sip && !_suppressLosingSipIdle;
            MonitorButton.IsEnabled = sip;
            OpenDoorButton.IsEnabled = sip;
            InCallOpenDoorButton.IsEnabled = sip;
        }


        private void RefreshConfigCache(Dictionary<string, object> config)
        {
            _cfg = config;
            Texts.SetConfig(_cfg);
        }
    }
}
