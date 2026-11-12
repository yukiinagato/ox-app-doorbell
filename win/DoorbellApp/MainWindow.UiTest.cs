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
                case "quit":
                    AllowClose();
                    Dispatcher.BeginInvoke(new Action(Close));
                    return "ok";
                default:
                    return "error: unknown command";
            }
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
