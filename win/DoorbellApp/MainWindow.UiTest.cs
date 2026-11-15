using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp
{
    /// <summary>
    /// Command channel for the automated UI smoke suite. Only started when App.UiTest is set,
    /// which needs the switch, a throwaway data directory and the environment flag together
    /// (Util/UiTestMode). The suite writes one command into the data directory; the window runs
    /// it on the dispatcher and answers in the ack file. Commands only present screens that have
    /// no other entry point on an isolated, unpaired instance (a ringing call, a call in
    /// progress) or fix the appearance for a screenshot.
    /// </summary>
    public partial class MainWindow
    {
        private DispatcherTimer _uiTestPoll;

        private void StartUiTestHooks()
        {
            if (!App.UiTest || _uiTestPoll != null) return;
            _uiTestPoll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
            _uiTestPoll.Tick += (s, e) => PollUiTestCommand();
            _uiTestPoll.Start();
            WriteUiTestAck("ready", "ok");
        }

        private void PollUiTestCommand()
        {
            string path = Path.Combine(App.DataDir, UiTestMode.CommandFile);
            string line;
            try
            {
                if (!File.Exists(path)) return;
                line = File.ReadAllText(path);
                File.Delete(path);
            }
            catch (IOException) { return; }            // still being written; next tick
            catch (UnauthorizedAccessException) { return; }
            string verb, argument;
            if (!UiTestMode.ParseCommand(line, out verb, out argument)) return;
            string result;
            try { result = RunUiTestCommand(verb, argument); }
            catch (Exception ex) { result = "error: " + ex.GetType().Name + ": " + ex.Message; }
            WriteUiTestAck(verb, result);
        }

        private string RunUiTestCommand(string verb, string argument)
        {
            string door = string.IsNullOrEmpty(App.Boot.Door) ? "door-uitest" : App.Boot.Door;
            switch (verb)
            {
                case "appearance":
                    if (argument != Appearance.Light && argument != Appearance.Dark)
                        return "error: expected light or dark";
                    Appearance.TestOverride = argument;
                    ApplyAppearance();
                    return "ok";
                case "skip-pairing":
                    OnPairingDismissed();
                    return "ok";
                case "incoming":
                    ShowIncoming(new UiEvent
                    {
                        T = "chime",
                        CoreGeneration = App.Core.Generation,
                        Data = new Dictionary<string, object>
                        {
                            { "door", door }, { "call_id", "uitest-call" }, { "stage_revision", 1 },
                        },
                    });
                    return IncomingView.Visibility == Visibility.Visible ? "ok" : "error: not shown";
                case "monitor":
                    ShowIncoming(new UiEvent
                    {
                        T = "monitor",
                        Data = new Dictionary<string, object> { { "door", door } },
                    }, true);
                    return IncomingView.Visibility == Visibility.Visible ? "ok" : "error: not shown";
                case "incall":
                    ShowInCall(null);
                    return InCallView.Visibility == Visibility.Visible ? "ok" : "error: not shown";
                case "home":
                    if (IncomingView.Visibility == Visibility.Visible) CloseIncoming(false);
                    if (InCallView.Visibility == Visibility.Visible) CloseInCall();
                    // A call the hooks presented never went through the SIP idle path that
                    // normally brings the home screen back.
                    _inCall = false;
                    HideCallOverlay();
                    ShowIdle();
                    return IdleView.Visibility == Visibility.Visible ? "ok" : "error: not home";
                case "zoom-scale":
                    // What the suite reads back after sending mouse-wheel input to the picture.
                    return "ok " + (InCallView.Visibility == Visibility.Visible
                        ? InCallZoom.Scale : IncomingZoom.Scale).ToString(
                            "0.###", System.Globalization.CultureInfo.InvariantCulture);
                case "picture":
                    return ShowUiTestPicture(argument);
                case "settings":
                    // Modal: answered before it opens, so the suite can drive the window.
                    Dispatcher.BeginInvoke(new Action(OpenSettings));
                    return "ok";
                case "flow-sample":
                    return LoadUiTestFlow();
                case "flow-core":
                    _flowTestDocument = false;
                    _flowFetched = false;
                    _flowRevision = "";
                    _flow = null;
                    BuildPurposeButtons();
                    RenderVisitorFlow();
                    RequestFlowRefresh();
                    return "ok";
                case "flow-start":
                    if (_flow == null) return "error: no flow";
                    _flow.IdleTimeout();
                    _flow.Done();
                    RenderVisitorFlow();
                    RestartFlowTimer();
                    return "ok";
                case "flow-state":
                    return _flow == null || _flow.Mode == FlowMode.Legacy
                        ? "ok classic"
                        : "ok flow " + _flow.Mode.ToString().ToLowerInvariant() + " " + _flow.Page;
                case "quit":
                    AllowClose();
                    Dispatcher.BeginInvoke(new Action(Close));
                    return "ok";
                default:
                    return "error: unknown command";
            }
        }

        // A resolved visitor flow for the suite: the delivery branch of Core's built-in wizard in
        // English, with an end page that stays long enough for a screenshot. Notify steps are
        // answered locally while it is loaded, so the suite never sends a message to a household.
        // Single quotes stand for the JSON quotes.
        private const string UiTestFlow =
            "{'schema_version':1,'enabled':true,'door':'door-uitest1','source':'config'," +
            "'revision':'uitest-flow-1','start':'s_home','idle_s':45,'require_call':true,'steps':{" +
            "'s_home':{'kind':'page','title':{'ja':'How can we help?','en':'How can we help?','zh':'How can we help?'}," +
            "'images':[],'options':[" +
            "{'id':'o_p_visit','semantic_id':'purpose.button','label':{'ja':'Visit','en':'Visit','zh':'Visit'},'icon':'','style':'normal','to':'c_visit','purpose':'p_visit'}," +
            "{'id':'o_p_delivery','semantic_id':'purpose.button','label':{'ja':'Delivery','en':'Delivery','zh':'Delivery'},'icon':'','style':'normal','to':'s_parcel','purpose':'p_delivery'}]}," +
            "'s_parcel':{'kind':'page','title':{'ja':'Can you leave it at the door?','en':'Can you leave it at the door?','zh':'Can you leave it at the door?'}," +
            "'body':{'ja':'If no signature is needed, please leave the parcel by the door.\\n\\nOtherwise press Hand over.'," +
            "'en':'If no signature is needed, please leave the parcel by the door.\\n\\nOtherwise press Hand over.'," +
            "'zh':'If no signature is needed, please leave the parcel by the door.\\n\\nOtherwise press Hand over.'}," +
            "'images':[],'options':[" +
            "{'id':'o_leave','semantic_id':'call.primary','label':{'ja':'Leave it','en':'Leave it','zh':'Leave it'},'icon':'','style':'primary','to':'n_left'}," +
            "{'id':'o_hand','semantic_id':'purpose.button','label':{'ja':'Hand over','en':'Hand over','zh':'Hand over'},'icon':'','style':'normal','to':'c_delivery'}]}," +
            "'c_visit':{'kind':'call','purpose':'p_visit'}," +
            "'c_delivery':{'kind':'call','purpose':'p_delivery','on_unanswered':'s_parcel'}," +
            "'n_left':{'kind':'notify','purpose':'p_delivery','to':'e_thanks'}," +
            "'e_thanks':{'kind':'end','title':{'ja':'Thank you','en':'Thank you','zh':'Thank you'}," +
            "'body':{'ja':'The household has been told.','en':'The household has been told.','zh':'The household has been told.'}," +
            "'images':[],'return_s':30}},'issues':[]}";

        private string LoadUiTestFlow()
        {
            if (App.Boot.Role != "door_station") return "error: not a door station";
            var doc = VisitorFlowDocument.Parse(UiTestFlow.Replace('\'', '"'));
            if (doc == null || !doc.Enabled) return "error: the test flow did not parse";
            _flowTestDocument = true;
            _flowFetched = true;
            _flowRevision = doc.Revision;
            _flow = null;
            InstallFlowDocument(doc);
            return FlowHomeActive ? "ok" : "error: the flow is not showing";
        }

        /// <summary>
        /// Puts a generated test card of the given size ("640x480") into the live picture of
        /// the screen that is showing, so the stage, the aspect fit and the zoom clip can be
        /// judged without a camera. The card has a border, a grid and four different corners.
        /// </summary>
        private string ShowUiTestPicture(string size)
        {
            string[] parts = (size ?? "").Split('x');
            int width, height;
            if (parts.Length != 2 || !int.TryParse(parts[0], out width) ||
                !int.TryParse(parts[1], out height) || width < 16 || height < 16 ||
                width > 1920 || height > 1920)
                return "error: expected WIDTHxHEIGHT";
            var pixels = new byte[width * height * 3];
            int cell = Math.Max(8, Math.Min(width, height) / 8);
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++)
                {
                    byte b = 0x50, g = 0x50, r = 0x50;
                    bool edge = x < 6 || y < 6 || x >= width - 6 || y >= height - 6;
                    bool line = x % cell < 2 || y % cell < 2;
                    bool left = x < cell, top = y < cell, right = x >= width - cell, bottom = y >= height - cell;
                    if (edge) { b = g = r = 0xFF; }
                    else if (left && top) { b = 0x30; g = 0x30; r = 0xE0; }
                    else if (right && top) { b = 0x30; g = 0xC0; r = 0x30; }
                    else if (left && bottom) { b = 0xE0; g = 0x60; r = 0x30; }
                    else if (right && bottom) { b = 0x30; g = 0xD0; r = 0xE0; }
                    else if (line) { b = g = r = 0xA0; }
                    int at = (y * width + x) * 3;
                    pixels[at] = b; pixels[at + 1] = g; pixels[at + 2] = r;
                }
            var card = System.Windows.Media.Imaging.BitmapSource.Create(width, height, 96, 96,
                System.Windows.Media.PixelFormats.Bgr24, null, pixels, width * 3);
            card.Freeze();
            if (InCallView.Visibility == Visibility.Visible)
            {
                PeerVideo.Source = card;
                InCallZoom.Reset();
                return "ok";
            }
            if (IncomingView.Visibility != Visibility.Visible) return "error: no live picture on screen";
            IncomingNoVideo.Visibility = Visibility.Collapsed;
            IncomingLive.Source = card;
            IncomingZoom.Reset();
            return "ok";
        }

        private static void WriteUiTestAck(string verb, string result)
        {
            try
            {
                File.AppendAllText(Path.Combine(App.DataDir, UiTestMode.AckFile),
                    DateTime.UtcNow.ToString("o") + " " + verb + " " + result + Environment.NewLine);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
