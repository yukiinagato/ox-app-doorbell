using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Ui;
using DoorbellApp.Util;

namespace DoorbellApp
{
    // The door station's visitor flow: Core publishes the resolved document, VisitorFlowWalker
    // (Core/VisitorFlow.cs) holds the navigation state, and this file draws the page, keeps the
    // options in the fixed bottom zone, and turns the walker's two terminal actions into the
    // existing press and notify calls. Without a flow the classic purpose screen is unchanged.
    public partial class MainWindow
    {
        private static readonly Regex AssetHash = new Regex("^[0-9a-f]{64}$");
        private const int MaxFlowImageBytes = 4 * 1024 * 1024;

        private VisitorFlowWalker _flow;
        private string _flowRevision = "";
        private bool _flowFetched;
        // Core has answered at least once (with a document or with nothing).
        private bool _flowAsked;
        private bool _flowFetchBusy;
        private bool _flowFetchAgain;
        private bool _flowBusy;
        private bool _flowWired;
        // Set by the call-end paths just before ShowIdle: why the call ended ("timeout" = unanswered).
        private string _flowEndReason;
        // True while the UI test suite shows its own document instead of Core's.
        private bool _flowTestDocument;
        private readonly DispatcherTimer _flowTimer = new DispatcherTimer();
        private readonly Dictionary<string, ImageSource> _flowImages = new Dictionary<string, ImageSource>();
        private readonly List<Image> _flowPictures = new List<Image>();
        private readonly List<TextBlock> _flowBodyBlocks = new List<TextBlock>();

        /// <summary>True while the flow, not the classic screen, is the visitor home.</summary>
        private bool FlowHomeActive
        {
            get
            {
                return App.Boot.Role == "door_station" && _flow != null &&
                       _flow.Mode != FlowMode.Legacy;
            }
        }

        /// <summary>
        /// A door station whose Core publishes a flow has not been told yet whether there is one:
        /// the visitor sees an empty home rather than the classic screen flashing before the
        /// start page replaces it.
        /// </summary>
        private bool FlowPending
        {
            get
            {
                return App.Boot.Role == "door_station" && !_flowFetched && !_flowAsked &&
                       !_flowTestDocument && App.Core != null && App.Core.VisitorFlowAvailable;
            }
        }

        // ---- the document ---------------------------------------------------------------------

        /// <summary>
        /// Re-reads the resolved flow off the UI thread. Several requests in a row cost one read
        /// plus one more; the answer is applied only to the Core generation that was asked.
        /// </summary>
        private void RequestFlowRefresh()
        {
            if (App.Boot.Role != "door_station" || _flowTestDocument) return;
            if (_flowFetchBusy)
            {
                _flowFetchAgain = true;
                return;
            }
            _flowFetchBusy = true;
            string door = App.Boot.Door ?? "";
            long generation = App.Core.Generation;
            Task.Run(() =>
            {
                string json = null;
                try { json = App.Core.VisitorFlowJson(door); }
                catch (Exception ex) { System.Diagnostics.Debug.WriteLine("visitor flow read failed: " + ex.Message); }
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    _flowFetchBusy = false;
                    if (generation == App.Core.Generation)
                    {
                        _flowAsked = true;
                        ApplyFlowJson(json);
                        if (json == null) RenderVisitorFlow();
                    }
                    if (_flowFetchAgain)
                    {
                        _flowFetchAgain = false;
                        RequestFlowRefresh();
                    }
                }));
            });
        }

        private void ApplyFlowJson(string json)
        {
            if (_flowTestDocument || App.Boot.Role != "door_station") return;
            // No answer (an older Core, or Core not ready): the classic screen stays, and the
            // next home refresh asks again.
            if (json == null) return;
            _flowFetched = true;
            var doc = VisitorFlowDocument.Parse(json);
            string revision = doc == null ? "" : doc.Revision;
            if (_flow != null && revision.Length > 0 && revision == _flowRevision) return;
            _flowRevision = revision;
            InstallFlowDocument(doc);
        }

        private void InstallFlowDocument(VisitorFlowDocument doc)
        {
            try
            {
                if (_flow == null) _flow = new VisitorFlowWalker(doc, _visitorLang);
                else _flow.Replace(doc);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine("visitor flow rejected: " + ex.Message);
                _flow = null;
            }
            BuildPurposeButtons();
            RenderVisitorFlow();
            RestartFlowTimer();
        }

        // ---- drawing --------------------------------------------------------------------------

        private void WireFlowControls()
        {
            if (_flowWired) return;
            _flowWired = true;
            FlowOptionScroll.ScrollChanged += (s, e) => UpdateFlowFade();
            FlowOptionScroll.SizeChanged += (s, e) => UpdateFlowFade();
            _flowTimer.Tick += (s, e) => OnFlowTimer();
        }

        /// <summary>
        /// Draws what the walker shows. Any failure here degrades to the classic screen, whose
        /// Call button is a direct call, so a visitor is never stranded.
        /// </summary>
        private void RenderVisitorFlow()
        {
            WireFlowControls();
            bool active = FlowHomeActive;
            bool hidden = active || FlowPending;
            CallButton.Visibility = hidden ? Visibility.Collapsed : Visibility.Visible;
            TouchHint.Visibility = hidden ? Visibility.Collapsed : Visibility.Visible;
            ApplyVisitorClockSize();
            FlowContent.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
            FlowOptionZone.Visibility = Visibility.Collapsed;
            FlowBackButton.Visibility = Visibility.Collapsed;
            FlowDoneButton.Visibility = Visibility.Collapsed;
            if (!active)
            {
                FlowContent.Visibility = Visibility.Collapsed;
                PurposeSection.Visibility = ShowsHomePurposes() ? Visibility.Visible : Visibility.Collapsed;
                return;
            }
            // A call in progress keeps the last page underneath; the call screens cover it.
            if (_flow.Mode == FlowMode.Calling) return;
            try
            {
                FlowPageView view = _flow.View();
                FlowTitle.Text = view.Title;
                FlowTitle.Visibility = view.Title.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
                _flowPictures.Clear();
                BuildFlowImages(FlowImagesAbove, view.Images, false);
                BuildFlowImages(FlowImagesBelow, view.Images, true);
                BuildFlowBody(view.Body);
                BuildFlowOptions(view);
                bool end = _flow.Mode == FlowMode.End;
                FlowDoneButton.Content = Texts.T("flow.done");
                FlowDoneButton.Visibility = end ? Visibility.Visible : Visibility.Collapsed;
                FlowBackButton.Content = BackContent();
                System.Windows.Automation.AutomationProperties.SetName(FlowBackButton, Texts.T("flow.back"));
                FlowBackButton.Visibility = _flow.CanGoBack ? Visibility.Visible : Visibility.Collapsed;
                string notice = _flow.Notice;
                VisitorStatus.Text = string.IsNullOrEmpty(notice) ? "" : Texts.T(notice);
                VisitorStatus.Visibility = string.IsNullOrEmpty(notice) ? Visibility.Collapsed : Visibility.Visible;
                VisitorContentScroll.ScrollToTop();
                FlowOptionScroll.ScrollToTop();
                LayOutVisitorFlow(ActualWidth > 0 ? ActualWidth : SystemParameters.PrimaryScreenWidth,
                                  ActualHeight > 0 ? ActualHeight : SystemParameters.PrimaryScreenHeight);
                PaintFlowPrimary();
                QueueInkPass();
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine("visitor flow draw failed: " + ex.Message);
                _flow = null;
                BuildPurposeButtons();
                RenderVisitorFlow();
            }
        }

        private UIElement BackContent()
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            FrameworkElement arrow = FluentIcon("IconArrowUp", 20, null);
            if (arrow != null)
            {
                arrow.RenderTransformOrigin = new Point(0.5, 0.5);
                arrow.RenderTransform = new RotateTransform(-90);
                arrow.Margin = new Thickness(0, 0, 8, 0);
                row.Children.Add(arrow);
            }
            row.Children.Add(new TextBlock { Text = Texts.T("flow.back"), VerticalAlignment = VerticalAlignment.Center });
            return row;
        }

        private void BuildFlowBody(string body)
        {
            FlowBody.Children.Clear();
            _flowBodyBlocks.Clear();
            if (string.IsNullOrEmpty(body)) return;
            // Plain text: a newline is a line break, a blank line starts a paragraph.
            string text = body.Replace("\r\n", "\n").Replace('\r', '\n');
            foreach (string paragraph in Regex.Split(text, "\n{2,}"))
            {
                if (paragraph.Length == 0) continue;
                var block = new TextBlock
                {
                    Text = paragraph,
                    FontSize = 24,
                    TextWrapping = TextWrapping.Wrap,
                    TextAlignment = TextAlignment.Center,
                    Margin = new Thickness(0, 0, 0, 14),
                };
                block.SetResourceReference(TextBlock.ForegroundProperty, "OnSurface");
                FlowBody.Children.Add(block);
                _flowBodyBlocks.Add(block);
            }
        }

        private void BuildFlowImages(Panel host, List<FlowImageView> images, bool below)
        {
            host.Children.Clear();
            foreach (FlowImageView image in images)
                if (image.Below == below) host.Children.Add(MakeFlowImage(image));
            host.Visibility = host.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        private UIElement MakeFlowImage(FlowImageView image)
        {
            var host = new Grid { Margin = new Thickness(0, 6, 0, 6) };
            var alt = new TextBlock
            {
                Text = image.Alt,
                FontSize = 18,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            alt.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
            var picture = new Image
            {
                Stretch = Stretch.Uniform,
                HorizontalAlignment = HorizontalAlignment.Center,
                MaxHeight = LayoutMetrics.FlowImageMax(ActualHeight > 0 ? ActualHeight : SystemParameters.PrimaryScreenHeight),
            };
            System.Windows.Automation.AutomationProperties.SetName(picture, image.Alt);
            host.Children.Add(alt);
            host.Children.Add(picture);
            _flowPictures.Add(picture);
            ImageSource cached;
            if (!string.IsNullOrEmpty(image.Asset) && _flowImages.TryGetValue(image.Asset, out cached))
            {
                picture.Source = cached;
                alt.Visibility = Visibility.Collapsed;
            }
            else LoadFlowImage(image, picture, alt);
            return host;
        }

        /// <summary>
        /// The image comes from the file Core cached (path), or from this device's own /asset
        /// route. While neither answers the alternative text stands in; Core publishes a changed
        /// document when the file arrives and the page is drawn again.
        /// </summary>
        private void LoadFlowImage(FlowImageView image, Image picture, TextBlock alt)
        {
            if (!AssetHash.IsMatch(image.Asset ?? "")) return;
            string path = image.Path;
            string asset = image.Asset;
            int port = App.Boot.HttpPort;
            Task.Run(() =>
            {
                byte[] data = null;
                try
                {
                    if (!string.IsNullOrEmpty(path) && File.Exists(path) &&
                        new FileInfo(path).Length <= MaxFlowImageBytes)
                        data = File.ReadAllBytes(path);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                if (data == null && string.IsNullOrEmpty(path))
                    data = LocalMedia.Download("http://127.0.0.1:" + port + "/asset/" + asset, 6000,
                                               MaxFlowImageBytes);
                if (data == null) return;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    try
                    {
                        var bitmap = new BitmapImage();
                        bitmap.BeginInit();
                        bitmap.CacheOption = BitmapCacheOption.OnLoad;
                        bitmap.DecodePixelWidth = 1280;
                        bitmap.StreamSource = new MemoryStream(data);
                        bitmap.EndInit();
                        bitmap.Freeze();
                        if (_flowImages.Count > 16) _flowImages.Clear();
                        _flowImages[asset] = bitmap;
                        picture.Source = bitmap;
                        alt.Visibility = Visibility.Collapsed;
                    }
                    catch (Exception) { }
                }));
            });
        }

        private void BuildFlowOptions(FlowPageView view)
        {
            FlowPrimaryHost.Children.Clear();
            FlowOptionGrid.Children.Clear();
            foreach (FlowOptionView option in view.Options)
            {
                Button button = MakeFlowOptionButton(option);
                if (option.Primary) FlowPrimaryHost.Children.Add(button);
                else FlowOptionGrid.Children.Add(button);
            }
            FlowOptionZone.Visibility = view.Options.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        private Button MakeFlowOptionButton(FlowOptionView option)
        {
            var panel = new StackPanel
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            FrameworkElement glyph = FluentIcon(PurposeIconKey(option.Purpose, option.Icon), 34, null);
            if (glyph != null) panel.Children.Add(glyph);
            panel.Children.Add(new TextBlock
            {
                Text = option.Label,
                FontSize = option.Primary ? 28 : 22,
                FontWeight = option.Primary ? FontWeights.SemiBold : FontWeights.Normal,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            var button = new Button
            {
                Content = panel,
                MinWidth = 0,
                MinHeight = 96,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Margin = new Thickness(8),
                Cursor = Cursors.Hand,
                Tag = option,
            };
            if (option.Primary)
            {
                // The Call button's look: the same large accent style, filling the option zone.
                button.Style = (Style)FindResource("BigButton");
                button.HorizontalAlignment = HorizontalAlignment.Stretch;
                button.HorizontalContentAlignment = HorizontalAlignment.Center;
            }
            else button.Padding = new Thickness(12, 10, 12, 10);
            button.Click += OnFlowOptionClick;
            System.Windows.Automation.AutomationProperties.SetAutomationId(button, "FlowOption_" + option.Id);
            System.Windows.Automation.AutomationProperties.SetName(button, option.Label);
            if (_semanticStyles != null)
                _semanticApplier.Apply(button, _semanticStyles.Get(option.Primary ? "call.primary" : "purpose.button"), false);
            return button;
        }

        /// <summary>The primary options take the Call button's colours, which the ink pass decides.</summary>
        private void PaintFlowPrimary()
        {
            if (CallButton.ReadLocalValue(Control.BackgroundProperty) == DependencyProperty.UnsetValue) return;
            foreach (UIElement child in FlowPrimaryHost.Children)
            {
                var button = child as Button;
                if (button == null) continue;
                button.Background = CallButton.Background;
                button.Foreground = CallButton.Foreground;
            }
        }

        private void InkFlowText()
        {
            InkText(FlowTitle, RegionStatusLine, 0);
            foreach (TextBlock block in _flowBodyBlocks) InkText(block, RegionStatusLine, 0);
        }

        private void LayOutVisitorFlow(double width, double height)
        {
            bool compact = _sizeClass == SizeClass.Compact;
            double scale = LayoutMetrics.TextScale();
            FlowTitle.FontSize = (compact ? 26 : 34) * scale;
            FlowOptionScroll.MaxHeight = LayoutMetrics.FlowOptionZoneMax(height);
            FlowOptionGrid.Columns = LayoutMetrics.FlowOptionColumns(_sizeClass, width, height,
                                                                     FlowOptionGrid.Children.Count);
            double imageMax = LayoutMetrics.FlowImageMax(height);
            foreach (Image picture in _flowPictures) picture.MaxHeight = imageMax;
            foreach (TextBlock block in _flowBodyBlocks) block.FontSize = (compact ? 19 : 24) * scale;
            UpdateFlowFade();
        }

        /// <summary>A fade at the bottom of the option zone marks that more options scroll in.</summary>
        private void UpdateFlowFade()
        {
            bool more = FlowOptionScroll.ScrollableHeight > 1 &&
                        FlowOptionScroll.VerticalOffset < FlowOptionScroll.ScrollableHeight - 1;
            FlowOptionFade.Visibility = more ? Visibility.Visible : Visibility.Collapsed;
            if (!more) return;
            var bg = TryFindResource("Bg") as SolidColorBrush;
            Color c = bg == null ? Colors.Black : bg.Color;
            FlowOptionFade.Background = new LinearGradientBrush(Color.FromArgb(0, c.R, c.G, c.B), c, 90);
        }

        // ---- input ----------------------------------------------------------------------------

        private void OnFlowOptionClick(object sender, RoutedEventArgs e)
        {
            var button = sender as Button;
            var option = button == null ? null : button.Tag as FlowOptionView;
            if (option == null || _flow == null || _flowBusy) return;
            if (_inCall || !string.IsNullOrEmpty(_activeCallId)) return;
            try { HandleFlowAction(_flow.Tap(option.Id)); }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine("visitor flow tap failed: " + ex.Message);
                // Any failure while walking degrades to a direct call.
                DoFlowPress("");
            }
        }

        private void OnFlowBackClick(object sender, RoutedEventArgs e)
        {
            if (_flow == null || _flowBusy) return;
            _flow.Back();
            RenderVisitorFlow();
            RestartFlowTimer();
        }

        private void OnFlowDoneClick(object sender, RoutedEventArgs e)
        {
            if (_flow == null) return;
            _flow.Done();
            RenderVisitorFlow();
            RestartFlowTimer();
        }

        private bool FlowSuppressesClickSound(object source)
        {
            var button = source as Button;
            var option = button == null ? null : button.Tag as FlowOptionView;
            return option != null && (option.ToKind == "call" || option.ToKind == "notify");
        }

        private void HandleFlowAction(FlowAction action)
        {
            if (action.Kind == FlowActionKind.Press) DoFlowPress(action.Purpose);
            else if (action.Kind == FlowActionKind.Notify) DoFlowNotify(action.Step);
            else
            {
                RenderVisitorFlow();
                RestartFlowTimer();
            }
        }

        private void DoFlowPress(string purpose)
        {
            _activeCallFlow = "purpose_first";
            if (string.IsNullOrEmpty(purpose))
                _callFeedback = PlayConfigured(_callFeedback,
                    SoundValue("call_sound", "outdoor_call_alert"),
                    ConfigBool("ui.call_sound_loop", false), null, _volumeCall);
            _activeCallId = App.Core.PressPurpose(App.Boot.Door, purpose ?? "") ?? "";
            bool placed = !string.IsNullOrEmpty(_activeCallId);
            if (_flow != null) _flow.PressResult(placed);
            if (!placed)
            {
                StopPlayer(ref _callFeedback);
                RenderVisitorFlow();
                RestartFlowTimer();
                return;
            }
            _flowTimer.Stop();
            string title = null;
            if (!string.IsNullOrEmpty(purpose))
            {
                var purposes = CoreClient.Dig(_cfg, "visit_purposes") as Dictionary<string, object>;
                var entry = purposes != null && purposes.ContainsKey(purpose)
                    ? purposes[purpose] as Dictionary<string, object> : null;
                title = Texts.T("purpose.sent", LabelOf(entry, Texts.Lang, purpose));
            }
            ShowCalling(title);
        }

        /// <summary>
        /// The notify step: Core is asked off the UI thread with the step id and nothing else.
        /// The visitor sees the closing page whatever the throttle said; a refusal rings instead.
        /// </summary>
        private void DoFlowNotify(string step)
        {
            _flowBusy = true;
            string door = App.Boot.Door ?? "";
            bool local = _flowTestDocument;
            Task.Run(() =>
            {
                bool ok = local;
                if (!local)
                {
                    string answer = null;
                    try { answer = App.Core.VisitorNotifyJson(door, step); }
                    catch (Exception ex) { System.Diagnostics.Debug.WriteLine("visitor notify failed: " + ex.Message); }
                    ok = NotifyAccepted(answer);
                }
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    _flowBusy = false;
                    FinishFlowNotify(ok);
                }));
            });
        }

        private static bool NotifyAccepted(string answer)
        {
            if (string.IsNullOrEmpty(answer)) return false;
            try
            {
                var doc = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(answer);
                object ok;
                return doc != null && doc.TryGetValue("ok", out ok) && ok is bool && (bool)ok;
            }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
        }

        private void FinishFlowNotify(bool ok)
        {
            if (_flow == null) return;
            try { HandleFlowAction(_flow.NotifyResult(ok)); }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine("visitor flow notify failed: " + ex.Message);
                DoFlowPress("");
            }
        }

        // ---- timers and call end --------------------------------------------------------------

        /// <summary>
        /// Back to the start page after idle_s seconds without input on a page that is not the
        /// start; an end page returns after its own return_s.
        /// </summary>
        private void RestartFlowTimer()
        {
            WireFlowControls();
            _flowTimer.Stop();
            if (_flow == null || App.Boot.Role != "door_station") return;
            double seconds;
            if (_flow.Mode == FlowMode.Page && (_flow.Depth > 1 || _flow.Notice != null))
                seconds = _flow.Document.IdleSeconds;
            else if (_flow.Mode == FlowMode.End)
                seconds = _flow.Document.ReturnSeconds(_flow.Page);
            else return;
            _flowTimer.Interval = TimeSpan.FromSeconds(seconds);
            _flowTimer.Start();
        }

        private void OnFlowTimer()
        {
            _flowTimer.Stop();
            if (_flow == null) return;
            if (_flow.Mode == FlowMode.Page) _flow.IdleTimeout();
            else if (_flow.Mode == FlowMode.End) _flow.Done();
            else return;
            RenderVisitorFlow();
            RestartFlowTimer();
        }

        /// <summary>Input restarts the idle countdown of a page; an end page keeps its own time.</summary>
        private void FlowInputSeen()
        {
            if (_flow != null && _flow.Mode == FlowMode.Page) RestartFlowTimer();
        }

        /// <summary>
        /// ShowIdle ends here: a call that was placed from the flow is over, and the walker says
        /// where the visitor goes next (the call step's unanswered page, or the start page).
        /// </summary>
        private void FlowAfterShowIdle()
        {
            string reason = _flowEndReason;
            _flowEndReason = null;
            if (_flow == null) return;
            if (_flow.Mode == FlowMode.Calling) _flow.CallEnded(string.IsNullOrEmpty(reason) ? "other" : reason);
            RenderVisitorFlow();
            RestartFlowTimer();
        }

        private void OnFlowLanguageChanged()
        {
            if (_flow == null) return;
            _flow.SetLang(_visitorLang);
            RenderVisitorFlow();
        }
    }
}
