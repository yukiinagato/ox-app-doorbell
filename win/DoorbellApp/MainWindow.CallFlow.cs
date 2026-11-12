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
    // Call state: idle, calling, Core UI events, recovery and the incoming screen.
    public partial class MainWindow
    {
        /// <summary>What the idle screen asks for: on a door station it depends on the call flow.</summary>
        private string IdleHintText()
        {
            if (App.Boot.Role != "door_station") return Texts.T("idle.touch_to_call");
            return ShowsHomePurposes() ? Texts.T("door.hint_purpose_first") : Texts.T("door.hint_call");
        }

        private void ShowIdle(string hint = null)
        {
            StopPlayer(ref _callFeedback);
            _callTitleOverride = null;
            _purposeChosenCallId = "";
            CallingView.Visibility = Visibility.Collapsed;
            CallingPurposeSection.Visibility = Visibility.Collapsed;
            OfflineView.Visibility = Visibility.Collapsed;
            IdleView.Visibility = Visibility.Visible;
            _callTimeout.Stop();
            System.Threading.Interlocked.Increment(ref _callViewRevision);
            VisitorStatus.Text = hint ?? "";
            VisitorStatus.Visibility = string.IsNullOrEmpty(hint) ? Visibility.Collapsed : Visibility.Visible;
            TouchHint.Text = IdleHintText();
            VisitorContentScroll.ScrollToTop();
            UpdateVisitorActionHeights(ActualWidth);
        }

        private void ShowOffline()
        {
            StopSosCountdown();
            ExitScreensaver();
            OfflineTitle.Text = Texts.T(string.IsNullOrEmpty(_activeCallId) ? "offline.title" : "visitor.restoring");
            OfflineAction.Visibility = App.Boot.Role == "door_station" ? Visibility.Visible : Visibility.Collapsed;
            OfflineAction.Content = Texts.T(string.IsNullOrEmpty(_activeCallId) ? "idle.call" : "calling.cancel");
            UpdateVisitorActionHeights(ActualWidth);
            IdleView.Visibility = Visibility.Collapsed;
            CallingView.Visibility = Visibility.Collapsed;
            OfflineView.Visibility = Visibility.Visible;
        }

        private void SuspendCallTiming()
        {
            StopSosCountdown();
            _suspendedCallSample = App.Core.CallTimingSnapshot();
            _callTiming.RequireFresh(_suspendedCallSample);
            _callTimeout.Stop();
            System.Threading.Interlocked.Increment(ref _callViewRevision);
        }

        private void ResumeCallTiming()
        {
            _callTiming.RequireFresh(_suspendedCallSample);
            _timedCoreGeneration = App.Core.Generation;
            _timedCallId = _activeCallId;
            System.Threading.Interlocked.Increment(ref _callViewRevision);
            ArmCallTiming();
            RefreshCallTiming(_timedCoreGeneration, _timedCallId, _callViewRevision);
        }

        private void OnPowerModeChanged(object sender, Microsoft.Win32.PowerModeChangedEventArgs args)
        {
            long generation = App.Core.Generation;
            Dispatcher.BeginInvoke(new Action(() => {
                if (generation != App.Core.Generation) return;
                if (args.Mode == Microsoft.Win32.PowerModes.Suspend) SuspendCallTiming();
                else if (args.Mode == Microsoft.Win32.PowerModes.Resume) ResumeCallTiming();
            }));
        }

        private void ArmCallTiming()
        {
            _callTimeout.Stop();
            if (_callTimeoutHandler != null) _callTimeout.Tick -= _callTimeoutHandler;
            long generation = _timedCoreGeneration, revision = _callViewRevision;
            string callId = _timedCallId;
            _callTimeoutHandler = (sender, args) => RefreshCallTiming(generation, callId, revision);
            _callTimeout.Tick += _callTimeoutHandler;
            _callTimeout.Start();
        }

        private void RefreshCallTiming(long generation, string callId, long revision)
        {
            if (!CallTiming.CallbackMatches(generation, callId, revision,
                App.Core.Generation, _activeCallId, _callViewRevision)) return;
            if (string.IsNullOrEmpty(callId)) { RecoverActiveCall(); return; }
            var reading = _callTiming.Observe(App.Core.CallTimingSnapshot(), callId, CallTiming.MonotonicMs);
            if (reading != null && reading.Absent)
            {
                _activeCallId = "";
                ShowIdle(Texts.T("calling.no_answer"));
            }
            else if (!_inCall && CallingView.Visibility == Visibility.Visible)
                CallingText.Text = reading == null || !reading.RemainingMs.HasValue || reading.RemainingMs.Value <= 0
                    ? Texts.T("visitor.restoring") : Texts.T("calling.title");
        }

        private void ShowCalling(string title = null)
        {
            StopSosCountdown();
            ExitScreensaver();
            if (title != null) _callTitleOverride = title;
            CallingText.Text = Texts.T("calling.title");
            CallingDetail.Text = _callTitleOverride ?? "";
            OfflineView.Visibility = Visibility.Collapsed;
            UpdateVisitorActionHeights(ActualWidth);
            IdleView.Visibility = Visibility.Collapsed;
            CallingView.Visibility = Visibility.Visible;
            CallingPurposeSection.Visibility = ShowsCallingPurposes() ? Visibility.Visible : Visibility.Collapsed;
            if (_timedCallId != _activeCallId || _timedCoreGeneration != App.Core.Generation)
            {
                _callTiming.RequireFresh(App.Core.CallTimingSnapshot());
                _timedCallId = _activeCallId;
                _timedCoreGeneration = App.Core.Generation;
                System.Threading.Interlocked.Increment(ref _callViewRevision);
            }
            ArmCallTiming();
            if (App.SafeMode)
            {
                Pulse.BeginAnimation(OpacityProperty, null);
                Pulse.Opacity = 1.0;
            }
            else
            {
                var anim = new DoubleAnimation(0.25, 1.0, TimeSpan.FromSeconds(0.9))
                { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
                Pulse.BeginAnimation(OpacityProperty, anim);
            }
        }

        private void OnUiEvent(UiEvent ev)
        {
            HandlePairingEvent(ev);
            switch (ev.T)
            {
                case "conversation":
                case "conversation_result":
                case "conversation_media":
                    HandleConversation(ev);
                    break;
                case "state":
                    var stv = ev.Str("state");
                    if (stv == "calling") { if (App.Boot.Role == "door_station") ShowCalling(); }
                    else if (stv == "idle") OnSipIdle();
                    else if (stv == "in_call" || stv == "answered")
                    {
                        StopPlayer(ref _callFeedback);
                        OnSipInCall(ev);
                    }
                    else if (stv == "degraded" && App.Boot.Role == "door_station")
                        CallingText.Text = Texts.T("sip.unavailable");
                    else if (stv == "offline") ShowOffline();
                    break;
                case "wake_screen":
                    if (App.Boot.Role == "door_station") OnActivity();
                    break;
                case "event":
                    RetireVisit(ev);
                    string eventType = ev.Str("type");
                    bool purposeApplied = false;
                    // press is replicated to every node. It updates call identity only; the
                    // targeted schema-v2 chime below is the sole trigger for ring UI/audio.
                    if (eventType == "press")
                    {
                        if (App.Boot.Role == "door_station" &&
                            (string.IsNullOrEmpty(ev.Str("door")) || ev.Str("door") == App.Boot.Door) &&
                            string.IsNullOrEmpty(_activeCallId)) _activeCallId = ev.Str("call_id");
                        if (ev.Str("call_id") == _activeCallId &&
                            CallingView.Visibility == Visibility.Visible) ShowCalling();
                        if (App.Boot.Role == "indoor_panel") UpdateIncomingCallData(ev);
                    }
                    else if (eventType == "reply" && !_inCall &&
                             IncomingView.Visibility == Visibility.Visible &&
                             CallMatches(ev.Str("call_id"), ev.Str("door"),
                                         _incomingCallId, _incomingDoor))
                        CloseIncoming(true);
                    if (eventType == "purpose_selected")
                        purposeApplied = HandlePurposeSelected(ev);
                    if (App.Boot.Role == "indoor_panel" &&
                        (eventType == "call_cancelled" || eventType == "call_answered" ||
                         eventType == "call_ended" ||
                         (eventType == "purpose_selected" && purposeApplied)))
                        _effects = PlayConfigured(_effects,
                            SoundValue("update_sound", "indoor_update"), false, null,
                            _volumeIdle);
                    if (eventType == "call_answered" && !UsesConversation())
                    {
                        StopPlayer(ref _callFeedback);
                        int answeredStage = Math.Max(0,
                            DictInt(ev.Data, "stage_revision", 0));
                        string owner = ev.Str("dialog_owner");
                        if (string.IsNullOrEmpty(owner)) owner = ev.Str("device");
                        if (_inCall && ev.Str("call_id") == _lifecycleCallId &&
                            !string.IsNullOrEmpty(owner) && !string.IsNullOrEmpty(_nodeId) &&
                            owner != _nodeId)
                        {
                            // The earliest confirmed claim owns the call. Terminate this losing
                            // SIP leg without publishing call_ended for the winning dialog.
                            _callLifecycle.ConfirmOwner(false);
                            _inCall = false;
                            _sipMode = "";
                            App.Core.SipHangup(_lifecycleCoreGeneration);
                            CloseInCall();
                            ShowIdle();
                        }
                        else if (!string.IsNullOrEmpty(owner) && !string.IsNullOrEmpty(_nodeId) &&
                            owner == _nodeId && ev.Str("call_id") == _lifecycleCallId &&
                            ev.Str("door") == _lifecycleDoor && answeredStage == _lifecycleStageRevision &&
                            ev.CoreGeneration == _lifecycleCoreGeneration)
                        {
                            _callLifecycle.ConfirmOwner(true);
                            if (_callLifecycle.Ended) CloseInCall();
                        }
                        else if (!_inCall && IncomingView.Visibility == Visibility.Visible &&
                            answeredStage >= _incomingStageRevision &&
                            CallMatches(ev.Str("call_id"), ev.Str("door"),
                                        _incomingCallId, _incomingDoor)) CloseIncoming(true);
                    }
                    if (eventType == "call_cancelled" || eventType == "call_ended")
                    {
                        StopPlayer(ref _callFeedback);
                        if (CallMatches(ev.Str("call_id"), ev.Str("door"),
                                        _activeCallId, App.Boot.Door))
                        {
                            _activeCallId = "";
                            System.Threading.Interlocked.Increment(ref _callViewRevision);
                            _callTimeout.Stop();
                            if (App.Boot.Role == "door_station") ShowIdle();
                        }
                        int resolvedStage = Math.Max(0,
                            DictInt(ev.Data, "stage_revision", 0));
                        // A visitor who cancels does not take the page with them: the live view
                        // stays until the return countdown ends or the resident leaves it.
                        if (IncomingView.Visibility == Visibility.Visible &&
                            (eventType == "call_cancelled" ||
                             resolvedStage >= _incomingStageRevision) &&
                            CallMatches(ev.Str("call_id"), ev.Str("door"),
                                        _incomingCallId, _incomingDoor))
                            EndIncomingCall(true, Texts.T("ring.cancelled"));
                    }
                    break;
                case "chime":
                    if (!AcceptChimeRevision(ev)) break;
                    ExitScreensaver();
                    if (App.Boot.Role == "indoor_panel") ShowIncoming(ev);
                    if (!string.IsNullOrEmpty(ev.Str("audio_path")))
                        PlayAudio(ev.Str("audio_path"), () => SystemSounds.Exclamation.Play());
                    else
                        _audio = PlayConfigured(_audio, ev.Str("sound"), false,
                            () => SystemSounds.Exclamation.Play(), _volumeCall);
                    break;
                case "call_recovery_required":
                    RecoverCall(ev);
                    break;
                case "visitor_lang":
                    if (App.Boot.Role == "door_station" &&
                        (ev.Str("door") == App.Boot.Door || string.IsNullOrEmpty(ev.Str("door"))))
                        SetVisitorLang(ev.Str("lang"));
                    if (IncomingView.Visibility == Visibility.Visible &&
                        ev.Str("door") == _incomingDoor)
                    {
                        _incomingLang = ev.Str("lang");
                        UpdateIncomingBadges();
                        BuildQuickReplies();
                    }
                    break;
                case "asset_ready":
                    if (!string.IsNullOrEmpty(_themeHash) && ev.Str("hash") == _themeHash &&
                        ThemeBgImage.Source == null)
                        LoadThemeImage(_themeHash);
                    break;
                case "reply":
                    ExitScreensaver();
                    if (IncomingView.Visibility == Visibility.Visible && !_inCall &&
                        (string.IsNullOrEmpty(ev.Str("door")) || ev.Str("door") == _incomingDoor))
                        CloseIncoming(true);
                    if (!string.IsNullOrEmpty(ev.Str("audio_path")))
                    {
                        string spoken = ev.Str("text");
                        string spokenLang = ev.Str("lang");
                        PlayAudio(ev.Str("audio_path"), () => App.Core.SpeakText(spoken, spokenLang));
                    }
                    ReplyText.Text = ev.Str("text");
                    ReplyBanner.Visibility = Visibility.Visible;
                    double ttl = 30;
                    double.TryParse(ev.Str("ttl_s"), out ttl);
                    _replyTimeout.Interval = TimeSpan.FromSeconds(ttl <= 0 ? 30 : ttl);
                    _replyTimeout.Stop();
                    _replyTimeout.Start();
                    _callTimeout.Stop();
                    _activeCallId = "";
                    ShowIdle();
                    break;
                case "display":
                    if (ev.Data != null) _display = ev.Data;
                    _brightness = DictInt(ev.Data, "brightness", _brightness);
                    _night = IsTrue(ev.Str("night"));
                    _redTint = IsTrue(ev.Str("red_tint"));
                    _screensaverAfterS = DictInt(ev.Data, "screensaver_after_s", _screensaverAfterS);
                    _pixelShiftS = DictInt(ev.Data, "pixel_shift_s", _pixelShiftS);
                    ApplyAppearance();
                    ApplyDisplay();
                    break;
                case "emergency":
                    ShowEmergency(ev);
                    break;
                case "peers_changed":
                    // Core republishes this on gossip, so it is coalesced like everything else.
                    RequestHomeRefresh(HomeRefresh.Node | HomeRefresh.Tiles |
                                       HomeRefresh.Pairing);
                    break;
                case "config_changed":
                    RequestHomeRefresh(HomeRefresh.Node | HomeRefresh.Notice |
                                       HomeRefresh.Tiles);
                    break;
                case "time_changed":
                    // The base is re-read on a worker; the redraw itself touches no core call.
                    SyncClockBase();
                    UpdateClock();
                    ApplyAppearance();
                    break;
                case "power_changed":
                    _batteryPct = DictInt(ev.Data, "battery_pct", _batteryPct);
                    _batteryCharging = EventBool(ev, "charging", _batteryCharging);
                    RequestHomeRefresh(HomeRefresh.Node);
                    break;
                case "notice_changed":
                    RequestHomeRefresh(HomeRefresh.Notice | HomeRefresh.Tiles);
                    break;
                case "call_log_changed":
                    _unreadMissed = DictInt(ev.Data, "unread_missed", _unreadMissed);
                    RequestHomeRefresh(HomeRefresh.History);
                    break;
            }
        }


        private static string DictStr(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) && v != null ? v.ToString() : "";
        }

        private static bool CallMatches(string eventCallId, string eventDoor,
                                        string currentCallId, string currentDoor)
        {
            if (!string.IsNullOrEmpty(eventCallId) && !string.IsNullOrEmpty(currentCallId))
                return eventCallId == currentCallId;
            return string.IsNullOrEmpty(eventDoor) || string.IsNullOrEmpty(currentDoor) ||
                   eventDoor == currentDoor;
        }

        private bool AcceptChimeRevision(UiEvent ev)
        {
            string callId = ev.Str("call_id");
            if (string.IsNullOrEmpty(callId)) return true;
            int revision = Math.Max(0, DictInt(ev.Data, "stage_revision", 0));
            int accepted;
            if (_acceptedChimeRevisions.TryGetValue(callId, out accepted))
            {
                if (revision <= accepted) return false;
                _acceptedChimeRevisions[callId] = revision;
                return true;
            }
            _acceptedChimeRevisions[callId] = revision;
            _acceptedChimeOrder.Enqueue(callId);
            while (_acceptedChimeOrder.Count > AcceptedChimeCapacity)
                _acceptedChimeRevisions.Remove(_acceptedChimeOrder.Dequeue());
            return true;
        }

        private bool HandlePurposeSelected(UiEvent ev)
        {
            if (App.Boot.Role != "indoor_panel") return false;
            string callId = ev.Str("call_id");
            string door = ev.Str("door");
            bool matchesIncoming = CallMatches(callId, door, _incomingCallId, _incomingDoor);
            bool matchesAnswer = !string.IsNullOrEmpty(_lifecycleCallId) &&
                CallMatches(callId, door, _lifecycleCallId, _lifecycleDoor);
            if (!matchesIncoming && !matchesAnswer) return false;

            int revision = Math.Max(0,
                DictInt(ev.Data, "stage_revision", _incomingStageRevision));
            int currentRevision = _incomingStageRevision;
            if (matchesAnswer) currentRevision = Math.Max(currentRevision, _lifecycleStageRevision);
            if (revision <= currentRevision) return false;

            bool supersedesAnswer = matchesAnswer && !_monitorOnly &&
                (_sipMode == "answer" || _answerDelay.IsEnabled || _inCall);
            if (!supersedesAnswer)
            {
                UpdateIncomingCallData(ev);
                return true;
            }

            _answerDelay.Stop();
            _callLifecycle.ConfirmOwner(false);
            _lifecycleCallId = "";
            _lifecycleDoor = "";
            _inCall = false;
            _sipMode = "";
            _suppressLosingSipIdle = true;
            CloseInCall();
            ShowIncoming(ev);
            AnswerButton.IsEnabled = false;
            App.Core.SipHangup();
            return true;
        }

        private void UpdateIncomingCallData(UiEvent ev)
        {
            if (ev == null) return;
            string callId = ev.Str("call_id");
            string door = ev.Str("door");
            if (IncomingView.Visibility == Visibility.Visible &&
                !CallMatches(callId, door, _incomingCallId, _incomingDoor)) return;
            if (!string.IsNullOrEmpty(callId)) _incomingCallId = callId;
            if (!string.IsNullOrEmpty(door)) _incomingDoor = door;
            _incomingStageRevision = Math.Max(_incomingStageRevision,
                DictInt(ev.Data, "stage_revision", _incomingStageRevision));
            if (!string.IsNullOrEmpty(ev.Str("purpose"))) _incomingPurpose = ev.Str("purpose");
            if (!string.IsNullOrEmpty(ev.Str("visitor_lang"))) _incomingLang = ev.Str("visitor_lang");
            if (IncomingView.Visibility == Visibility.Visible)
            {
                UpdateIncomingBadges();
                BuildQuickReplies();
            }
        }

        private void RecoverActiveCall()
        {
            var snapshot = App.Core.CallTimingSnapshot();
            if (!_callTiming.Accepts(snapshot)) return;
            var status = snapshot.Document;
            if (string.IsNullOrEmpty(_nodeId))
                _nodeId = DictStr(CoreClient.Dig(status, "node") as Dictionary<string, object>, "id");
            var calls = status.ContainsKey("active_calls")
                ? status["active_calls"] as System.Collections.IEnumerable : null;
            if (calls == null) return;
            foreach (var item in calls)
            {
                var call = item as Dictionary<string, object>;
                if (!IsOwnedRecovery(call)) continue;
                RecoverCall(new UiEvent { T = "call_recovery_required", Data = call,
                    CoreGeneration = snapshot.CoreGeneration });
            }
        }

        private bool IsOwnedRecovery(Dictionary<string, object> call)
        {
            return CallTiming.OwnedRecovery(call, _nodeId, App.Boot.Role, App.Boot.Door);
        }

        private void RecoverCall(UiEvent ev)
        {
            if (ev == null || ev.CoreGeneration != App.Core.Generation) return;
            string callId = ev.Str("call_id");
            var snapshot = App.Core.CallTimingSnapshot();
            if (snapshot == null || snapshot.CoreGeneration != ev.CoreGeneration) return;
            if (string.IsNullOrEmpty(_nodeId))
                _nodeId = DictStr(CoreClient.Dig(snapshot.Document, "node") as Dictionary<string, object>, "id");
            var calls = snapshot.Document.ContainsKey("active_calls")
                ? snapshot.Document["active_calls"] as System.Collections.IEnumerable : null;
            Dictionary<string, object> candidate = null;
            if (calls != null) foreach (var item in calls)
            {
                var current = item as Dictionary<string, object>;
                if (DictStr(current, "call_id") == callId) { candidate = current; break; }
            }
            if (!IsOwnedRecovery(candidate)) return;
            var reading = _callTiming.Observe(snapshot, callId, CallTiming.MonotonicMs);
            if (reading == null || reading.Absent) return;
            var active = reading.Call;
            if (!active.ContainsKey("recovery_required") || !Equals(active["recovery_required"], true) ||
                !active.ContainsKey("recovery_eligible") || !Equals(active["recovery_eligible"], true) ||
                !reading.RecoveryRemainingMs.HasValue || reading.RecoveryRemainingMs.Value <= 0) return;
            if (string.IsNullOrEmpty(_nodeId))
                _nodeId = DictStr(CoreClient.Dig(snapshot.Document, "node") as Dictionary<string, object>, "id");
            if (string.IsNullOrEmpty(_nodeId)) return;
            if (DictStr(active, "state") == "in_call")
            {
                // A process restart cannot restore the old PJSIP dialog.
                if (DictStr(active, "dialog_owner") == _nodeId)
                    ReportRecoveryOnce(callId, false, snapshot.CoreGeneration);
                return;
            }
            bool waiting = DictStr(active, "state") == "ringing" || DictStr(active, "state") == "purpose_pending";
            if (!waiting || App.Boot.Role != "door_station" || DictStr(active, "origin") != _nodeId ||
                (DictStr(active, "door") != "" && DictStr(active, "door") != App.Boot.Door) ||
                !reading.RemainingMs.HasValue || reading.RemainingMs.Value <= 0) return;
            if (_reportedRecoveryCallId == snapshot.CoreGeneration + ":" + callId) return;
            _activeCallId = callId;
            if (!string.IsNullOrEmpty(DictStr(active, "purpose"))) _purposeChosenCallId = callId;
            string flow = DictStr(active, "call_flow");
            if (flow == "ring_then_purpose" || flow == "purpose_first") _activeCallFlow = flow;
            _callFeedback = PlayConfigured(_callFeedback, SoundValue("call_sound", "outdoor_call_alert"),
                ConfigBool("ui.call_sound_loop", false), null, _volumeCall);
            ShowCalling();
            ReportRecoveryOnce(callId, true, snapshot.CoreGeneration);
        }

        private void ReportRecoveryOnce(string callId, bool restored, long generation)
        {
            string identity = generation + ":" + callId;
            if (string.IsNullOrEmpty(callId) || identity == _reportedRecoveryCallId ||
                generation != App.Core.Generation) return;
            _reportedRecoveryCallId = identity;
            App.Core.ReportCallRecovery(callId, restored, generation);
        }

        private static Dictionary<string, object> FindDoorPeer(Dictionary<string, object> st, string door)
        {
            var peers = (st != null && st.ContainsKey("peers"))
                ? st["peers"] as System.Collections.IEnumerable : null;
            if (peers == null) return null;
            foreach (var o in peers)
            {
                var p = o as Dictionary<string, object>;
                if (p == null) continue;
                object self;
                if (p.TryGetValue("self", out self) && self is bool && (bool)self) continue;
                if (DictStr(p, "role") != "door_station") continue;
                if (!string.IsNullOrEmpty(door) && DictStr(p, "door") != door) continue;
                if (DictStr(p, "status") == "dead") continue;
                return p;
            }
            return null;
        }

        private static string PeerHost(Dictionary<string, object> peer)
        {
            var addrs = (peer != null && peer.ContainsKey("addrs"))
                ? peer["addrs"] as System.Collections.IEnumerable : null;
            if (addrs == null) return null;
            foreach (var a in addrs)
            {
                string s = a as string;
                if (string.IsNullOrEmpty(s)) continue;
                int i = s.LastIndexOf(':');
                return i > 0 ? s.Substring(0, i) : s;
            }
            return null;
        }

        /// <summary>Targeted chime (or an explicit local monitor action) opens the incoming view.</summary>
        private void ShowIncoming(UiEvent ev, bool monitorOnly = false)
        {
            if (AdmitIncomingVisit(ev, monitorOnly)) return;
            if (_emergencyActive || _inCall) return;
            string door = ev.Str("door");
            string callId = ev.Str("call_id");
            if (IncomingView.Visibility == Visibility.Visible)
            {
                if (!_monitorOnly && !monitorOnly &&
                    CallMatches(callId, door, _incomingCallId, _incomingDoor))
                {
                    // A repeated chime from the same door keeps media and refreshes metadata only.
                    if (!string.IsNullOrEmpty(callId)) _incomingCallId = callId;
                    _incomingStageRevision = Math.Max(_incomingStageRevision,
                        DictInt(ev.Data, "stage_revision", _incomingStageRevision));
                    _incomingPurpose = ev.Str("purpose");
                    _incomingLang = ev.Str("visitor_lang");
                    UpdateIncomingBadges();
                    BuildQuickReplies();
                    _incomingTimeout.Stop();
                    _incomingTimeout.Start();
                    // The page keeps the deadline it opened with; a repeat chime is the same call.
                    RenderReturnCountdown();
                    return;
                }
                // A different door stops the old stream and monitor SIP before switching targets.
                CloseIncoming(true);
            }
            ExitScreensaver();
            _monitorOnly = monitorOnly;
            _incomingDoor = door ?? "";
            _incomingCallId = callId ?? "";
            _incomingStageRevision = DictInt(ev.Data, "stage_revision", 0);
            _incomingPurpose = ev.Str("purpose");
            _incomingLang = ev.Str("visitor_lang");
            IncomingTitle.Text = monitorOnly ? Texts.T("monitor.title", DoorLabel(_incomingDoor)) :
                                               Texts.T("ring.incoming", DoorLabel(_incomingDoor));
            _quickRepliesOpen = false;
            _monitorAudioOn = false;
            _micMuted = false;
            ApplyMicLabel();
            ApplyMonitorLabel();
            UpdateIncomingBadges();
            BuildQuickReplies();
            QuickReplyToggle.Visibility = monitorOnly ?
                Visibility.Collapsed : Visibility.Visible;
            MonitorButton.Visibility = Visibility.Visible;
            IgnoreButton.Visibility = Visibility.Visible;
            IncomingHint.Visibility = Visibility.Collapsed;

            // Resolve the door peer into a video URL and direct-call host.
            var peer = FindDoorPeer(App.Core.Status(), _incomingDoor);
            _incomingHost = PeerHost(peer);
            _incomingStreamUrl = DictStr(peer, "stream");
            _incomingStreamMp4Url = DictStr(peer, "stream_mp4");
            bool sip = App.Core.SipAvailable && !string.IsNullOrEmpty(_incomingHost);
            AnswerButton.Visibility = monitorOnly ? Visibility.Collapsed : Visibility.Visible;
            AnswerButton.IsEnabled = sip;
            MonitorButton.IsEnabled = sip;
            OpenDoorButton.IsEnabled = false;
            bool unlock = UnlockShown(_incomingDoor);
            OpenDoorButton.Visibility = unlock ? Visibility.Visible : Visibility.Collapsed;
            InCallOpenDoorButton.Visibility = OpenDoorButton.Visibility;
            IgnoreButton.Content = IconStack(monitorOnly ? "IconX" : "IconBellOff",
                monitorOnly ? Texts.T("monitor.close") : Texts.T("ring.ignore"),
                (Brush)FindResource("NegativeText"));

            StartIncomingVideo();

            // A different door is a different picture: it starts fitted, not at the old zoom.
            if (IncomingView.Visibility != Visibility.Visible || _returnDoor != _incomingDoor)
                IncomingZoom.Reset();
            IncomingView.Visibility = Visibility.Visible;
            ApplyLiveOverlayMode();
            _returnDoor = _incomingDoor;
            StartReturnCountdown();
            ShowCallOverlay(_incomingDoor);
            _statsRefresh.Stop();
            _statsRefresh.Start();
            RefreshVideoStats();
            _incomingTimeout.Stop();
            if (!monitorOnly) _incomingTimeout.Start();  // Proactive monitoring remains until closed.
            RefreshConversations();
        }
    }
}
