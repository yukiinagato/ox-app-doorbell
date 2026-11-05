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
    // Visitor call button and cancellation.
    public partial class MainWindow
    {
        private void OnCallClick(object sender, RoutedEventArgs e)
        {
            if (!string.IsNullOrEmpty(_activeCallId)) return;
            _activeCallFlow = _callFlow;
            _callFeedback = PlayConfigured(_callFeedback,
                SoundValue("call_sound", "outdoor_call_alert"),
                ConfigBool("ui.call_sound_loop", false), null, _volumeCall);
            _activeCallId = App.Core.Press(App.Boot.Door) ?? "";
            if (string.IsNullOrEmpty(_activeCallId))
            {
                ShowOffline();
                return;
            }
            ShowCalling();
        }

        private void OnCancelClick(object sender, RoutedEventArgs e)
        {
            if (!AllowVisitorAction(Ui.VisitorActionKind.Cancel)) return;
            if (CancelActiveCall("visitor"))
            {
                _callTimeout.Stop();
                ShowIdle();
            }
            else
            {
                CallingDetail.Text = Texts.T("calling.cancel_failed");
            }
        }

        private bool CancelActiveCall(string reason)
        {
            if (_inCall) return false;
            string callId = _activeCallId;
            if (string.IsNullOrEmpty(callId)) return false;
            bool ok = App.Core.CancelCall(App.Boot.Door, callId, reason);
            if (ok)
            {
                _activeCallId = "";
                System.Threading.Interlocked.Increment(ref _callViewRevision);
            }
            return ok;
        }
    }
}
