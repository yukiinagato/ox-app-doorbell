using System.Linq;
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
    // Incoming-call controls: badges, quick replies, return countdown, answer, monitor and unlock.
    public partial class MainWindow
    {
        private void UpdateIncomingBadges()
        {
            var purposes = CoreClient.Dig(_cfg, "visit_purposes") as Dictionary<string, object>;
            var entry = purposes != null && !string.IsNullOrEmpty(_incomingPurpose) &&
                        purposes.ContainsKey(_incomingPurpose)
                ? purposes[_incomingPurpose] as Dictionary<string, object> : null;
            if (string.IsNullOrEmpty(_incomingPurpose))
            {
                PurposeBadge.Visibility = Visibility.Collapsed;
            }
            else
            {
                string label = LabelOf(entry, App.Boot.UiLang, _incomingPurpose);
                FillPurposeBadge(PurposeBadgeContent, entry, _incomingPurpose, label);
                PurposeBadge.ToolTip = Texts.T("ring.purpose_badge", label);
                PurposeBadge.Visibility = Visibility.Visible;
            }

            if (string.IsNullOrEmpty(_incomingLang) || _incomingLang == "ja")
            {
                LangBadge.Visibility = Visibility.Collapsed;
            }
            else
            {
                LangBadgeText.Text = _incomingLang.ToUpperInvariant();
                LangBadge.ToolTip = Texts.T("ring.lang_badge", LangDisplayName(_incomingLang));
                LangBadge.Visibility = Visibility.Visible;
            }
        }

        /// <summary>
        /// One purpose badge: the Tabler icon for a seeded purpose, or an administrator's own
        /// icon text when there is nothing to map, then the label.
        /// </summary>
        private void FillPurposeBadge(System.Windows.Controls.Panel into,
                                      Dictionary<string, object> entry, string id, string label)
        {
            if (into == null) return;
            into.Children.Clear();
            var stroke = ThemeContrast.Brush(Color.FromRgb(0xF2, 0xF5, 0xF8));
            FrameworkElement glyph = TablerIcon(PurposeIconKey(id), 18, stroke);
            if (glyph != null)
            {
                into.Children.Add(glyph);
            }
            else
            {
                object icon;
                string iconText = entry != null && entry.TryGetValue("icon", out icon) &&
                                  icon != null ? icon.ToString() : "";
                if (iconText.Length != 0)
                    into.Children.Add(new TextBlock
                    {
                        Text = iconText,
                        FontSize = 18,
                        VerticalAlignment = VerticalAlignment.Center,
                        Foreground = stroke,
                    });
            }
            into.Children.Add(new TextBlock
            {
                Text = label,
                FontSize = 18,
                Margin = new Thickness(into.Children.Count == 0 ? 0 : 8, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = stroke,
            });
        }

        private void BuildQuickReplies()
        {
            QuickReplyPanel.Children.Clear();
            if (_inCall)
            {
                QuickReplyPanel.Visibility = Visibility.Collapsed;
                return;
            }
            var replies = CoreClient.Dig(_cfg, "quick_replies") as Dictionary<string, object>;
            if (replies == null || replies.Count == 0)
            {
                QuickReplyPanel.Visibility = Visibility.Collapsed;
                return;
            }
            string lang = string.IsNullOrEmpty(_incomingLang) ? "ja" : _incomingLang;
            foreach (var id in SortedByOrder(replies))
            {
                var entry = replies[id] as Dictionary<string, object>;
                var b = new Button
                {
                    Content = LabelOf(entry, lang, id),
                    FontSize = 22,
                    Padding = new Thickness(26, 12, 26, 12),
                    Margin = new Thickness(8),
                    Cursor = Cursors.Hand,
                    Tag = id,
                };
                b.Click += OnQuickReplyClick;
                if (_semanticStyles != null)
                    _semanticApplier.Apply(b, _semanticStyles.Get("reply.button"), false);
                QuickReplyPanel.Children.Add(b);
            }
            ApplyQuickReplyVisibility();
        }

        private void ApplyQuickReplyVisibility()
        {
            QuickReplyPanel.Visibility = _quickRepliesOpen && !_inCall &&
                QuickReplyPanel.Children.Count != 0 ?
                Visibility.Visible : Visibility.Collapsed;
            UpdateQuickReplySheet();
            ApplyLiveOverlayMode();
        }

        private void OnQuickReplyClick(object sender, RoutedEventArgs e)
        {
            if (_inCall) return;
            var b = sender as Button;
            if (b == null) return;
            bool accepted = App.Core.QuickReplyV2(b.Tag as string, _incomingDoor,
                                                  _incomingCallId, _incomingStageRevision);
            IncomingHint.Text = accepted ? Texts.T("reply.sent", b.Content) :
                                           Texts.T("reply.failed");
            IncomingHint.Visibility = Visibility.Visible;
        }

        /// <summary>
        /// Seconds the incoming page stays up before returning home. Core reports it as
        /// status.call.return_s; call.indoor.return_s is the configured value behind it.
        /// </summary>
        private int ReturnSeconds()
        {
            object value = CoreClient.Dig(_status, "call.return_s");
            if (value == null) value = CoreClient.Dig(_cfg, "call.indoor.return_s");
            int seconds;
            if (value != null && int.TryParse(value.ToString(), out seconds) &&
                seconds > 0 && seconds <= 3600) return seconds;
            return 60;
        }

        /// <summary>Starts the return countdown for a newly opened page.</summary>
        private void StartReturnCountdown()
        {
            _returnCancelled = false;
            _returnSecondsLeft = ReturnSeconds();
            _returnTimer.Stop();
            _returnTimer.Start();
            RenderReturnCountdown();
        }

        /// <summary>
        /// Holds the countdown while the resident is talking. The page shows no number then, and
        /// the count starts again from the full value once the call ends.
        /// </summary>
        private void PauseReturnCountdown()
        {
            _returnTimer.Stop();
            RenderReturnCountdown();
        }

        private void StopReturnCountdown()
        {
            _returnTimer.Stop();
            _returnSecondsLeft = 0;
            _returnCancelled = false;
            RenderReturnCountdown();
        }

        private void OnReturnTick()
        {
            if (_visitQueue.Count > 1) return;
            _returnSecondsLeft--;
            if (_returnSecondsLeft > 0)
            {
                RenderReturnCountdown();
                return;
            }
            _returnTimer.Stop();
            _returnSecondsLeft = 0;
            LeaveConversations();
            CloseIncoming(true);
        }

        /// <summary>Tapping the number stops the return; the live view stays until it is left.</summary>
        private void OnReturnCountdownClick(object sender, MouseButtonEventArgs e)
        {
            _returnCancelled = true;
            _returnTimer.Stop();
            RenderReturnCountdown();
        }

        private void RenderReturnCountdown()
        {
            bool showing = _returnTimer.IsEnabled && !_returnCancelled &&
                           _returnSecondsLeft > 0 && !_inCall &&
                           IncomingView.Visibility == Visibility.Visible;
            ReturnCountdown.Visibility = showing ? Visibility.Visible : Visibility.Collapsed;
            if (showing) ReturnCountdownText.Text = "(" + _returnSecondsLeft + ")";
        }

        /// <summary>
        /// The call is over — the visitor cancelled, or nobody answered — but the page is not.
        /// The live view stays until the countdown ends or the resident leaves it, so a visitor
        /// who gives up and walks away can still be seen.
        /// </summary>
        private void EndIncomingCall(bool hangup, string message)
        {
            if (IncomingView.Visibility != Visibility.Visible) return;
            _incomingTimeout.Stop();
            _answerDelay.Stop();
            StopPlayer(ref _callFeedback);
            if (hangup && _sipMode != "" && !_inCall)
            {
                App.Core.SipHangup();
                _sipMode = "";
                _monitorAudioOn = false;
                ApplyMonitorLabel();
            }
            _incomingCallId = "";
            _monitorOnly = true;
            AnswerButton.Visibility = Visibility.Collapsed;
            OpenDoorButton.IsEnabled = false;
            _quickRepliesOpen = false;
            ApplyQuickReplyVisibility();
            QuickReplyToggle.Visibility = Visibility.Collapsed;
            IgnoreButton.Content = IconStack("IconX", Texts.T("monitor.close"), (Brush)FindResource("Negative"));
            IncomingHint.Text = message ?? "";
            IncomingHint.Visibility = string.IsNullOrEmpty(message) ?
                Visibility.Collapsed : Visibility.Visible;
            RenderReturnCountdown();
        }

        private void CloseIncoming(bool hangup)
        {
            StopReturnCountdown();
            _incomingTimeout.Stop();
            _answerDelay.Stop();
            StopIncomingVideo();
            IncomingView.Visibility = Visibility.Collapsed;
            if (InCallView.Visibility != Visibility.Visible) HideCallOverlay();
            AnswerButton.IsEnabled = true;
            if (hangup && _sipMode != "" && !_inCall)
            {
                App.Core.SipHangup();
                _sipMode = "";
            }
            _incomingCallId = "";
            _monitorOnly = false;
            _quickRepliesOpen = false;
            _monitorAudioOn = false;
            ApplyQuickReplyVisibility();
            ApplyMonitorLabel();
            AnswerButton.Visibility = Visibility.Visible;
            MonitorButton.Visibility = Visibility.Visible;
            IgnoreButton.Visibility = Visibility.Visible;
            IgnoreButton.Content = IconStack("IconBellOff", Texts.T("ring.ignore"), (Brush)FindResource("Negative"));
            OpenDoorButton.IsEnabled = false;
        }

        private void OnAnswerClick(object sender, RoutedEventArgs e)
        {
            if (!ConversationTargetMatches()) return;
            if (UsesConversation())
            {
                var me = OwnConversationMember(ConversationDocument(SelectedConversationCall()));
                SendConversation(me == null || DictStr(me, "state") == "waiting" ? "answer" : "leave");
                return;
            }
            if (_inCall)
            {
                App.Core.SipHangup();
                ReportLifecycleEndedIfNeeded();
                OnSipIdle();
                return;
            }
            if (!App.Core.SipAvailable)
            {
                IncomingHint.Text = Texts.T("sip.unavailable");
                IncomingHint.Visibility = Visibility.Visible;
                return;
            }
            if (string.IsNullOrEmpty(_incomingHost)) return;
            _lifecycleDoor = _incomingDoor;
            _lifecycleCallId = _incomingCallId;
            _lifecycleStageRevision = _incomingStageRevision;
            _callLifecycle.Reset();
            _lifecycleCoreGeneration = App.Core.Generation;
            AnswerButton.IsEnabled = false;
            if (_sipMode == "monitor")
            {
                App.Core.SipHangup();
                _answerDelay.Stop();
                _answerDelay.Start();
                return;
            }
            PlaceAnswerCall();
        }

        private void PlaceAnswerCall()
        {
            if (!App.Core.SipAvailable) return;
            _sipMode = "answer";
            _lifecycleDoor = _incomingDoor;
            _lifecycleCallId = _incomingCallId;
            _lifecycleStageRevision = _incomingStageRevision;
            _callLifecycle.Reset();
            _lifecycleCoreGeneration = App.Core.Generation;
            App.Core.SipCall("sip:" + _incomingHost + ":" + _directPort, "answer");
            OpenDoorButton.IsEnabled = true;
        }

        private void OnMonitorClick(object sender, RoutedEventArgs e)
        {
            if (!App.Core.SipAvailable)
            {
                IncomingHint.Text = Texts.T("sip.unavailable");
                IncomingHint.Visibility = Visibility.Visible;
                return;
            }
            if (_sipMode == "monitor")
            {
                // Visible ON/OFF state: turning it off stops door audio without ending the call.
                App.Core.SipHangup();
                _sipMode = "";
                _monitorAudioOn = false;
                OpenDoorButton.IsEnabled = false;
                ApplyMonitorLabel();
                return;
            }
            if (string.IsNullOrEmpty(_incomingHost) || _sipMode != "") return;
            _sipMode = "monitor";
            _monitorAudioOn = true;
            ApplyMonitorLabel();
            App.Core.SipCall("sip:" + _incomingHost + ":" + _directPort, "monitor");
            IncomingHint.Text = Texts.T("ring.monitoring");
            IncomingHint.Visibility = Visibility.Visible;
            OpenDoorButton.IsEnabled = true;
        }

        private void OnIgnoreClick(object sender, RoutedEventArgs e)
        {
            string key = _incomingDoor + ":" + _incomingCallId;
            _retiredVisits[key] = _incomingStageRevision;
            _visitQueue.Remove(key); _visitOrder.Remove(key);
            if (_visitQueue.Count == 0) { LeaveConversations(); CloseIncoming(true); }
            else { AnswerButton.IsEnabled = false; RefreshConversations(); }
        }

        private void OnOpenDoorClick(object sender, RoutedEventArgs e)
        {
            // db_core_open_door publishes the same ha_command the SIP feature code does, so the
            // control works from the monitor page too. -3 means nothing is configured and -4 that
            // the configured command failed: the shell says which, rather than reporting a
            // success that did nothing.
            if (!ConversationTargetMatches()) return;
            string targetDoor = CurrentCallDoor(), targetCall = _incomingCallId;
            int targetRevision = _incomingStageRevision;
            int result = string.IsNullOrEmpty(targetCall) ? App.Core.OpenDoor(targetDoor) :
                App.Core.OpenDoorForCall(targetDoor, targetCall, targetRevision);
            if (result == -3)
            {
                ShowCallMessage(Texts.T("unlock.not_configured"));
                return;
            }
            if (result == -4)
            {
                ShowCallMessage(Texts.T("unlock.command_failed"));
                return;
            }
            ShowCallMessage(Texts.T(result == 0 ? "ring.open_sent" : "ring.open_failed"));
        }

        private string CurrentCallDoor()
        {
            if (InCallView.Visibility == Visibility.Visible &&
                !string.IsNullOrEmpty(_lifecycleDoor)) return _lifecycleDoor;
            return _incomingDoor;
        }

        private void ShowCallMessage(string message)
        {
            if (InCallView.Visibility == Visibility.Visible) InCallTitle.Text = message;
            else { IncomingHint.Text = message; IncomingHint.Visibility = Visibility.Visible; }
        }

        /// <summary>
        /// status.doors.&lt;id&gt;.unlock.show_button decides whether the control is offered at
        /// all. Core defaults it to "show it when it does something" and an administrator may
        /// force either answer, so the shell never re-derives it.
        /// </summary>
        private bool UnlockShown(string door)
        {
            if (App.Boot.Role != "indoor_panel") return false;
            var value = CoreClient.Dig(_status,
                "doors." + (door ?? "") + ".unlock.show_button");
            if (value is bool) return (bool)value;
            // Older core: fall back to the configured visibility, then to "is it configured".
            value = CoreClient.Dig(_cfg, "doors." + (door ?? "") + ".unlock.show_button");
            if (value is bool) return (bool)value;
            return UnlockConfigured(door);
        }

        private bool UnlockConfigured(string door)
        {
            var value = CoreClient.Dig(_status, "doors." + (door ?? "") + ".unlock.configured");
            if (value is bool) return (bool)value;
            var actions = CoreClient.Dig(_cfg, "sip.dtmf_actions") as Dictionary<string, object>;
            return actions != null && actions.Count != 0;
        }

        private void OnOpenMonitorClick(object sender, RoutedEventArgs e)
        {
            MonitorDoorList.Children.Clear();
            var status = App.Core.Status();
            var peers = status != null && status.ContainsKey("peers") ?
                status["peers"] as System.Collections.IEnumerable : null;
            if (peers != null)
                foreach (object raw in peers)
                {
                    var peer = raw as Dictionary<string, object>;
                    if (peer == null || DictStr(peer, "role") != "door_station" ||
                        DictStr(peer, "status") == "dead") continue;
                    string door = DictStr(peer, "door");
                    if (string.IsNullOrEmpty(door)) continue;
                    var button = new Button
                    {
                        Content = DoorLabel(door), Tag = door, FontSize = 26,
                        Padding = new Thickness(34, 16, 34, 16), Margin = new Thickness(6),
                    };
                    button.Click += OnMonitorDoorClick;
                    MonitorDoorList.Children.Add(button);
                }
            if (MonitorDoorList.Children.Count == 0)
                MonitorDoorList.Children.Add(new TextBlock
                {
                    Text = Texts.T("ring.no_video"), FontSize = 20,
                    Foreground = (Brush)FindResource("Dim"), TextAlignment = TextAlignment.Center,
                });
            MonitorPickerView.Visibility = Visibility.Visible;
            _semanticApplier.Apply(MonitorPickerClose,
                _semanticStyles == null ? null : _semanticStyles.Get("monitor.close"), true);
        }

        private void OnMonitorDoorClick(object sender, RoutedEventArgs e)
        {
            string door = (sender as Button)?.Tag as string;
            if (string.IsNullOrEmpty(door)) return;
            MonitorPickerView.Visibility = Visibility.Collapsed;
            ShowIncoming(new UiEvent
            {
                T = "monitor",
                Data = new Dictionary<string, object> { { "door", door } },
            }, true);
        }

        private void OnMonitorPickerClose(object sender, RoutedEventArgs e) =>
            MonitorPickerView.Visibility = Visibility.Collapsed;

        private void OnEndCallClick(object sender, RoutedEventArgs e)
        {
            if (!AllowVisitorAction(Ui.VisitorActionKind.End)) return;
            var call = ConversationCalls().FirstOrDefault(item => DictStr(item, "door") == App.Boot.Door &&
                DictStr(item, "call_id") == _activeCallId);
            if (ConversationDocument(call) != null)
                App.Core.Conversation(new Dictionary<string, object> { {"action", "end"},
                    {"door", App.Boot.Door}, {"call_id", _activeCallId},
                    {"stage_revision", DictInt(call, "stage_revision", 0)} });
            else App.Core.SipHangup();
            ReportLifecycleEndedIfNeeded();
            OnSipIdle();
        }

        private void OnSipInCall(UiEvent ev)
        {
            System.Threading.Interlocked.Increment(ref _callViewRevision);
            RetirePeerFrame();
            _inCall = true;
            BuildQuickReplies();
            _incomingTimeout.Stop();
            CallingText.Text = Texts.T("incall.title");
            string stream = ev.Str("peer_stream");
            if (App.Boot.Role == "door_station")
            {
                _callTimeout.Stop();
                _peerPoll.Stop();
                ShowInCall(stream);
                if (string.IsNullOrEmpty(stream))
                {
                    _peerPollBusy = false;
                    _peerPoll.Start();
                }
            }
            else if (_sipMode == "answer")
            {
                if (!_callLifecycle.AnswerReported)
                {
                    var answer = App.Core.ReportCallAnsweredResult(
                        _lifecycleDoor, _lifecycleCallId, _lifecycleStageRevision,
                        _lifecycleCoreGeneration);
                    if (_callLifecycle.RecordAnswer(answer))
                    {
                        _inCall = false;
                        _sipMode = "";
                        App.Core.SipHangup(_lifecycleCoreGeneration);
                        CloseInCall();
                        ShowIdle();
                        return;
                    }
                }
                EnterIncomingInCall();
            }
        }

        /// <summary>
        /// Keep the preview transport and MediaElement alive when the resident answers. Replacing
        /// the incoming page used to close a healthy HTTP/TCP stream and wait for another decoder
        /// startup even though the video source had not changed.
        /// </summary>
        private void EnterIncomingInCall()
        {
            if (IncomingView.Visibility != Visibility.Visible) return;
            StopReturnCountdown();
            _incomingTimeout.Stop();
            _answerDelay.Stop();
            _monitorOnly = false;
            _quickRepliesOpen = false;
            ApplyQuickReplyVisibility();
            QuickReplyToggle.Visibility = Visibility.Collapsed;
            MonitorButton.Visibility = Visibility.Collapsed;
            IgnoreButton.Visibility = Visibility.Collapsed;
            IncomingTitle.Text = Texts.T("incall.title");
            IncomingHint.Visibility = Visibility.Collapsed;
            AnswerButton.Content = IconStack("IconPhoneOff", Texts.T("incall.end_call"),
                (Brush)FindResource("OnNegative"));
            PaintAnswerSlot(true);
            AnswerButton.Visibility = Visibility.Visible;
            AnswerButton.IsEnabled = true;
            OpenDoorButton.IsEnabled = true;
        }

        private void RestoreIncomingMonitorAfterCall()
        {
            _incomingCallId = "";
            _monitorOnly = true;
            _quickRepliesOpen = false;
            ApplyQuickReplyVisibility();
            QuickReplyToggle.Visibility = Visibility.Collapsed;
            MonitorButton.Visibility = Visibility.Visible;
            IgnoreButton.Visibility = Visibility.Visible;
            IgnoreButton.Content = IconStack("IconX", Texts.T("monitor.close"), (Brush)FindResource("Negative"));
            IncomingTitle.Text = Texts.T("monitor.title", DoorLabel(_incomingDoor));
            IncomingHint.Visibility = Visibility.Collapsed;
            AnswerButton.Content = IconStack("IconPhone", Texts.T("ring.answer"),
                (Brush)FindResource("OnPositive"));
            PaintAnswerSlot(false);
            AnswerButton.Visibility = Visibility.Collapsed;
            AnswerButton.IsEnabled = App.Core.SipAvailable &&
                !string.IsNullOrEmpty(_incomingHost);
            OpenDoorButton.IsEnabled = false;
            StartReturnCountdown();
        }

        private void OnSipIdle()
        {
            if (_suppressLosingSipIdle)
            {
                _suppressLosingSipIdle = false;
                _inCall = false;
                _sipMode = "";
                CloseInCall();
                if (IncomingView.Visibility == Visibility.Visible)
                {
                    AnswerButton.IsEnabled = App.Core.SipAvailable &&
                        !string.IsNullOrEmpty(_incomingHost);
                    _incomingTimeout.Stop();
                    _incomingTimeout.Start();
                }
                return;
            }
            bool wasInCall = _inCall;
            if (wasInCall) ReportLifecycleEndedIfNeeded();
            _inCall = false;
            _sipMode = "";
            CloseInCall();
            if (wasInCall && IncomingView.Visibility == Visibility.Visible)
                RestoreIncomingMonitorAfterCall();
            if (App.Boot.Role == "door_station") ShowIdle();
            else if (wasInCall && IncomingView.Visibility != Visibility.Visible)
                ResumeLiveViewAfterCall();
        }

        /// <summary>
        /// After a call ends the panel goes back to the live view for that door with a fresh
        /// countdown, rather than dropping straight to the home screen.
        /// </summary>
        private void ResumeLiveViewAfterCall()
        {
            string door = !string.IsNullOrEmpty(_lifecycleDoor) ? _lifecycleDoor : _returnDoor;
            if (string.IsNullOrEmpty(door) || _emergencyActive) return;
            ShowIncoming(new UiEvent
            {
                T = "monitor",
                Data = new Dictionary<string, object> { { "door", door } },
            }, true);
        }

        private void ReportLifecycleEndedIfNeeded()
        {
            if (!_inCall || _sipMode != "answer" || !_callLifecycle.MayReportEnd ||
                string.IsNullOrEmpty(_lifecycleCallId)) return;
            var result = App.Core.ReportCallEndedResult(
                _lifecycleDoor, _lifecycleCallId, _lifecycleStageRevision, "sip_ended",
                _lifecycleCoreGeneration);
            _callLifecycle.RecordEnd(result);
        }
    }
}
