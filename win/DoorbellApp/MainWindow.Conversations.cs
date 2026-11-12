using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp
{
    public partial class MainWindow
    {
        private readonly Dictionary<string, Dictionary<string, object>> _visitQueue = new Dictionary<string, Dictionary<string, object>>();
        private readonly List<string> _visitOrder = new List<string>();
        private readonly Dictionary<string, int> _retiredVisits = new Dictionary<string, int>();
        private readonly Dictionary<string, Dictionary<string, object>> _conversationEvents = new Dictionary<string, Dictionary<string, object>>();
        private bool _selectingVisit;
        private string _visitSignature = "", _conversationSignature = "", _heldConversationTarget;
        private long? _heldConversationVersion;
        private static Dictionary<string, object> ConversationObject(Dictionary<string, object> value, string key) =>
            value != null && value.TryGetValue(key, out var result) ? result as Dictionary<string, object> : null;
        private static IEnumerable<Dictionary<string, object>> ConversationRows(Dictionary<string, object> value, string key)
        {
            if (value == null || !value.TryGetValue(key, out var rows) || !(rows is IEnumerable sequence)) yield break;
            foreach (var row in sequence) if (row is Dictionary<string, object> item) yield return item;
        }
        private IEnumerable<Dictionary<string, object>> ConversationCalls() => ConversationRows(App.Core.Status(), "active_calls");
        private Dictionary<string, object> SelectedConversationCall() => ConversationCalls().FirstOrDefault(
            call => DictStr(call, "door") == _incomingDoor && DictStr(call, "call_id") == _incomingCallId);
        private bool UsesConversation() => DictBool(SelectedConversationCall(), "conversation_supported");
        private Dictionary<string, object> ConversationDocument(Dictionary<string, object> call)
        {
            var snapshot = ConversationObject(call, "conversation");
            _conversationEvents.TryGetValue(DictStr(call, "call_id"), out var update);
            return DictLong(update, "version", 0) > DictLong(snapshot, "version", 0) ? update : snapshot;
        }
        private Dictionary<string, object> OwnConversationMember(Dictionary<string, object> room) =>
            ConversationRows(room, "participants").FirstOrDefault(member => DictStr(member, "device") == _nodeId);
        private string SelectedConversationTarget() => _incomingDoor + ":" + _incomingCallId + ":" + _incomingStageRevision;
        private void OnConversationActionDown(object sender, MouseButtonEventArgs e)
        {
            _heldConversationTarget = SelectedConversationTarget();
            _heldConversationVersion = DictLong(ConversationDocument(SelectedConversationCall()), "version", 0);
        }
        private bool ConversationTargetMatches()
        {
            var target = _heldConversationTarget;
            _heldConversationTarget = null;
            return target == null || target == SelectedConversationTarget();
        }
        private Dictionary<string, object> ConversationRequest(string action) => new Dictionary<string, object> {
            {"door", _incomingDoor}, {"call_id", _incomingCallId}, {"stage_revision", _incomingStageRevision},
            {"expected_version", _heldConversationVersion ?? DictLong(ConversationDocument(SelectedConversationCall()), "version", 0)}, {"action", action} };
        private void SendConversation(string action)
        {
            var request = ConversationRequest(action);
            _heldConversationVersion = null;
            // Nothing is touched until a takeover is confirmed: cancelling keeps the live call.
            if (action == "takeover" && MessageBox.Show(this, Texts.T("conversation.takeover_confirm"),
                Texts.T("conversation.takeover"), MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
            if (_sipMode.Length != 0) { App.Core.SipHangup(); _sipMode = ""; _inCall = false; }
            var result = App.Core.Conversation(request);
            IncomingHint.Text = Texts.T(DictBool(result, "ok") ? "conversation.pending" : "conversation.failed");
            IncomingHint.Visibility = Visibility.Visible;
        }
        /// <summary>
        /// Leaving the call screen for good (Ignore on the last visit, the return countdown,
        /// closing the app) leaves every conversation this device is still a member of, so the
        /// door station does not keep a participant whose screen is gone. The other shells do
        /// the same when their incoming screen is destroyed.
        /// </summary>
        private void LeaveConversations()
        {
            if (App.Core == null) return;
            foreach (var call in ConversationCalls().ToList())
            {
                if (!DictBool(call, "conversation_supported")) continue;
                var room = ConversationDocument(call);
                if (room == null || OwnConversationMember(room) == null) continue;
                App.Core.Conversation(new Dictionary<string, object> {
                    {"action", "leave"}, {"door", DictStr(call, "door")}, {"call_id", DictStr(call, "call_id")},
                    {"stage_revision", DictInt(call, "stage_revision", 0)},
                    {"expected_version", DictLong(room, "version", 0)} });
            }
        }
        private bool AdmitIncomingVisit(UiEvent ev, bool monitorOnly)
        {
            if (monitorOnly || _selectingVisit) return false;
            var id = ev.Str("door") + ":" + ev.Str("call_id");
            var revision = DictInt(ev.Data, "stage_revision", 0);
            if (ev.Str("call_id").Length == 0) return false;
            if (_retiredVisits.TryGetValue(id, out var retired) && revision <= retired) return true;
            if (!_visitQueue.TryGetValue(id, out var old) || revision >= DictInt(old, "stage_revision", 0))
            {
                if (!_visitQueue.ContainsKey(id)) _visitOrder.Add(id);
                _visitQueue[id] = ev.Data;
            }
            if (IncomingView.Visibility == Visibility.Visible &&
                (ev.Str("door") != _incomingDoor || ev.Str("call_id") != _incomingCallId))
            {
                RefreshConversations();
                return true;
            }
            return false;
        }
        private void RetireVisit(UiEvent ev)
        {
            if (ev.Str("type") != "call_ended" && ev.Str("type") != "call_cancelled" && ev.Str("type") != "reply") return;
            var key = ev.Str("door") + ":" + ev.Str("call_id");
            int revision = DictInt(ev.Data, "stage_revision", -1);
            if (ev.Str("door").Length == 0 || ev.Str("call_id").Length == 0 || revision < 0) return;
            if (!_retiredVisits.TryGetValue(key, out var retired) || revision > retired) _retiredVisits[key] = revision;
            if (_visitQueue.TryGetValue(key, out var call) && revision >= DictInt(call, "stage_revision", 0))
            { _visitQueue.Remove(key); _visitOrder.Remove(key); }
        }
        private void SelectVisit(Dictionary<string, object> call)
        {
            if (_inCall && !UsesConversation() || _sipMode == "answer")
            {
                // Say why nothing happened instead of ignoring the tap.
                IncomingHint.Text = Texts.T("ring.queue_finish_first");
                IncomingHint.Visibility = Visibility.Visible;
                return;
            }
            // Only a call core runs as a conversation has a selection to record.
            if (UsesConversation()) App.Core.Conversation(new Dictionary<string, object> { {"action", "select"},
                {"door", DictStr(call, "door")}, {"call_id", DictStr(call, "call_id")} });
            _selectingVisit = true;
            try { _inCall = false; CloseIncoming(true); ShowIncoming(new UiEvent { Data = call, T = "chime" }); }
            finally { _selectingVisit = false; }
        }
        private void RefreshConversations()
        {
            if (IncomingView.Visibility != Visibility.Visible || App.Boot.Role != "indoor_panel") return;
            var summaries = new List<string>();
            foreach (var call in ConversationCalls())
            {
                if (DictBool(call, "notification_eligible"))
                {
                    string key = DictStr(call, "door") + ":" + DictStr(call, "call_id");
                    int revision = DictInt(call, "stage_revision", 0);
                    if (!_retiredVisits.TryGetValue(key, out var retired) || revision > retired)
                    {
                        if (!_visitQueue.ContainsKey(key)) _visitOrder.Add(key);
                        _visitQueue[key] = call;
                    }
                }
                foreach (var member in ConversationRows(ConversationDocument(call), "participants"))
                {
                    string device = DictStr(member, "device"), state = DictStr(member, "state");
                    string name = LabelOf(CoreClient.Dig(_cfg, "devices." + device) as Dictionary<string, object>, App.Boot.UiLang, device);
                    summaries.Add(DoorLabel(DictStr(call, "door")) + " · " + Texts.T(
                        state == "waiting" ? "conversation.queued" : "conversation." + state, name));
                }
            }
            ConversationSummary.Text = string.Join("\n", summaries);
            // Each queue row says who is already speaking at that door, when someone is.
            var rowTexts = new List<string>();
            foreach (string key in _visitOrder)
            {
                var call = _visitQueue[key];
                var visitRoom = ConversationDocument(call);
                string owner = DictStr(visitRoom, "owner"), phase = DictStr(visitRoom, "phase");
                string door = DoorLabel(DictStr(call, "door"));
                if (owner.Length != 0 && owner != _nodeId && (phase == "connected" || phase == "held"))
                    rowTexts.Add(Texts.T("ring.queue_in_call", LabelOf(
                        CoreClient.Dig(_cfg, "devices." + owner) as Dictionary<string, object>,
                        App.Boot.UiLang, owner), door));
                else
                    rowTexts.Add(Texts.T(DictStr(call, "call_id") == _incomingCallId ?
                        "ring.queue_selected" : "ring.queue_waiting", door));
            }
            // One visit needs no list to choose from.
            IncomingVisitQueue.Visibility = _visitOrder.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
            string signature = string.Join("|", _visitOrder) + SelectedConversationTarget() +
                               string.Join("|", rowTexts);
            if (signature != _visitSignature)
            {
                _visitSignature = signature; IncomingVisitQueue.Children.Clear();
                for (int i = 0; i < _visitOrder.Count; i++)
                {
                    var call = _visitQueue[_visitOrder[i]];
                    var button = new Button { Content = rowTexts[i], MinHeight = 48 };
                    button.Click += (sender, args) => SelectVisit(call);
                    IncomingVisitQueue.Children.Add(button);
                }
            }
            var selected = SelectedConversationCall();
            var room = ConversationDocument(selected);
            var me = OwnConversationMember(room);
            var ownState = DictStr(me, "state");
            bool enabled = DictBool(selected, "conversation_supported");
            bool localMedia = DictBool(selected, "conversation_local_media");
            string roomSignature = enabled + ":" + localMedia + ":" + ownState + ":" + DictLong(room, "version", 0) + _incomingCallId;
            if (enabled)
            {
                _inCall = ownState == "connected" && localMedia;
                AnswerButton.Content = Texts.T(me == null || ownState == "waiting" ? "conversation.answer" : "conversation.leave");
                AnswerButton.IsEnabled = me != null || DictStr(room, "owner").Length == 0;
                OpenDoorButton.IsEnabled = true;
                MonitorButton.Visibility = Visibility.Collapsed;
                if (ownState == "held" || ownState == "dialing" || _inCall) StopReturnCountdown();
            }
            if (roomSignature == _conversationSignature) return;
            _conversationSignature = roomSignature; ConversationActions.Children.Clear();
            if (!enabled) return;
            var actions = ownState == "connected" && localMedia ? new[] { "hold" } :
                ownState == "held" || ownState == "connected" && !localMedia ? new[] { "resume" } :
                me == null && DictStr(room, "owner").Length != 0 ? new[] { "join", "takeover" } : me == null ? new[] { "respond" } : new string[0];
            foreach (string action in actions)
            {
                var button = new Button { Content = Texts.T("conversation." + action), MinHeight = 48, Margin = new Thickness(4) };
                button.PreviewMouseDown += OnConversationActionDown;
                button.Click += (sender, args) => { if (ConversationTargetMatches()) SendConversation(action); };
                ConversationActions.Children.Add(button);
            }
        }
        private void HandleConversation(UiEvent ev)
        {
            // Events can arrive out of order; only a newer room document replaces the cached one.
            if (ev.T == "conversation" &&
                (!_conversationEvents.TryGetValue(ev.Str("call_id"), out var cached) ||
                 DictLong(ev.Data, "version", 0) >= DictLong(cached, "version", 0)))
                _conversationEvents[ev.Str("call_id")] = ev.Data;
            if (App.Boot.Role == "door_station" && ev.Str("door") == App.Boot.Door && ev.Str("call_id") == _activeCallId)
            {
                string phase = ev.Str("phase");
                if ((phase == "connected" || phase == "held") && !_inCall) { _inCall = true; ShowInCall(null); }
                string text = string.Join("\n", ConversationRows(ev.Data, "participants").Select(member => Texts.T(
                    DictStr(member, "state") == "waiting" ? "conversation.queued" : "conversation." + DictStr(member, "state"),
                    LabelOf(CoreClient.Dig(_cfg, "devices." + DictStr(member, "device")) as Dictionary<string, object>, App.Boot.UiLang, DictStr(member, "device")))));
                // Before any resident has responded there is nobody to name.
                if (text.Length == 0) text = Texts.T("conversation.waiting");
                CallingText.Text = text;
                InCallTitle.Text = text;
            }
            if (ev.T == "conversation_result" && !DictBool(ev.Data, "ok"))
            { IncomingHint.Text = Texts.T("conversation.failed"); IncomingHint.Visibility = Visibility.Visible; }
            RefreshConversations();
        }
    }
}
