using System;
using System.Collections;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace DoorbellApp.Core
{
    internal enum FlowMode { Legacy, Page, Calling, End }

    internal enum FlowActionKind { None, Press, Notify }

    /// <summary>The Core call a tap asks the shell to make; the shell reports the result back.</summary>
    internal sealed class FlowAction
    {
        public static readonly FlowAction Nothing = new FlowAction(FlowActionKind.None, "", "");

        public readonly FlowActionKind Kind;
        /// <summary>The purpose for a press (empty rings without one).</summary>
        public readonly string Purpose;
        /// <summary>The notify step id for a notify.</summary>
        public readonly string Step;

        public FlowAction(FlowActionKind kind, string purpose, string step)
        {
            Kind = kind;
            Purpose = purpose ?? "";
            Step = step ?? "";
        }
    }

    internal sealed class FlowOptionView
    {
        public string Id = "";
        public string SemanticId = "";
        public string Label = "";
        public string Icon = "";
        public bool Primary;
        public string To = "";
        public string Purpose = "";
        /// <summary>The kind of the step this option leads to ("" when it is not in the document).</summary>
        public string ToKind = "";
    }

    internal sealed class FlowImageView
    {
        public string Asset = "";
        public string Url = "";
        public string Path = "";
        public string Alt = "";
        public bool Below;
    }

    /// <summary>What the page or end step on screen carries, already in the visitor's language.</summary>
    internal sealed class FlowPageView
    {
        public string Page = "";
        public bool IsEnd;
        public string Title = "";
        public string Body = "";
        public List<FlowImageView> Images = new List<FlowImageView>();
        public List<FlowOptionView> Options = new List<FlowOptionView>();
        public int ReturnSeconds = 8;
    }

    internal sealed class FlowSnapshot
    {
        public string Mode = "legacy";
        public string Page;
        public string Title;
        public List<FlowOptionView> Options = new List<FlowOptionView>();
        public bool Back;
        public bool Done;
        public string Notice;
        public bool Reply;
    }

    /// <summary>
    /// The resolved visitor flow Core publishes (db_core_visitor_flow_json). Nothing here reads
    /// raw configuration; every lookup tolerates a missing or mistyped member, because a visitor
    /// must never be stranded by a document the shell cannot read.
    /// </summary>
    internal sealed class VisitorFlowDocument
    {
        public const int MaxSteps = 34;
        private static readonly string[] KnownKinds = { "page", "call", "notify", "end" };

        private readonly Dictionary<string, object> _root;
        private readonly Dictionary<string, object> _steps;

        private VisitorFlowDocument(Dictionary<string, object> root, Dictionary<string, object> steps)
        {
            _root = root;
            _steps = steps;
        }

        /// <summary>Null when the text is not a usable document.</summary>
        public static VisitorFlowDocument Parse(string json)
        {
            if (string.IsNullOrEmpty(json)) return null;
            try
            {
                var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
                return FromRoot(serializer.Deserialize<Dictionary<string, object>>(json));
            }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }

        public static VisitorFlowDocument FromRoot(Dictionary<string, object> root)
        {
            if (root == null) return null;
            object steps;
            var map = root.TryGetValue("steps", out steps) ? steps as Dictionary<string, object> : null;
            if (map == null) map = new Dictionary<string, object>();
            if (map.Count > MaxSteps) return null;
            return new VisitorFlowDocument(root, map);
        }

        public bool Enabled
        {
            get
            {
                object value;
                return _root.TryGetValue("enabled", out value) && value is bool && (bool)value &&
                       Kind(Start) == "page";
            }
        }

        public string Start { get { return Str(_root, "start"); } }
        public string Revision { get { return Str(_root, "revision"); } }
        public string Source { get { return Str(_root, "source"); } }

        public int IdleSeconds
        {
            get
            {
                int seconds = Int(_root, "idle_s", 45);
                return Math.Max(15, Math.Min(300, seconds));
            }
        }

        public Dictionary<string, object> StepOf(string id)
        {
            object step;
            if (string.IsNullOrEmpty(id) || !_steps.TryGetValue(id, out step)) return null;
            return step as Dictionary<string, object>;
        }

        public string Kind(string id)
        {
            var step = StepOf(id);
            return step == null ? "" : Str(step, "kind");
        }

        public static bool IsKnownKind(string kind)
        {
            return Array.IndexOf(KnownKinds, kind) >= 0;
        }

        public string PurposeOf(string stepId)
        {
            var step = StepOf(stepId);
            return step == null ? "" : Str(step, "purpose");
        }

        public string OnUnanswered(string stepId)
        {
            var step = StepOf(stepId);
            return step == null ? "" : Str(step, "on_unanswered");
        }

        public string NextOf(string stepId)
        {
            var step = StepOf(stepId);
            return step == null ? "" : Str(step, "to");
        }

        public int ReturnSeconds(string stepId)
        {
            var step = StepOf(stepId);
            int seconds = step == null ? 8 : Int(step, "return_s", 8);
            return Math.Max(3, Math.Min(60, seconds));
        }

        /// <summary>The language, then Japanese, then whatever the document carries.</summary>
        public static string TextIn(object labels, string lang)
        {
            var map = labels as Dictionary<string, object>;
            if (map == null) return null;
            object value;
            foreach (string key in new[] { lang, "ja" })
                if (key != null && map.TryGetValue(key, out value))
                {
                    string text = value as string;
                    if (!string.IsNullOrEmpty(text)) return text;
                }
            foreach (object other in map.Values)
            {
                string text = other as string;
                if (!string.IsNullOrEmpty(text)) return text;
            }
            return null;
        }

        public FlowPageView View(string pageId, string lang)
        {
            var step = StepOf(pageId);
            var view = new FlowPageView { Page = pageId ?? "" };
            if (step == null) return view;
            view.IsEnd = Str(step, "kind") == "end";
            object titles, bodies;
            view.Title = step.TryGetValue("title", out titles) ? TextIn(titles, lang) ?? "" : "";
            view.Body = step.TryGetValue("body", out bodies) ? TextIn(bodies, lang) ?? "" : "";
            view.ReturnSeconds = ReturnSeconds(pageId);
            foreach (object entry in Items(step, "images"))
            {
                var image = entry as Dictionary<string, object>;
                if (image == null) continue;
                object alt;
                view.Images.Add(new FlowImageView
                {
                    Asset = Str(image, "asset"),
                    Url = Str(image, "url"),
                    Path = Str(image, "path"),
                    Alt = image.TryGetValue("alt", out alt) ? TextIn(alt, lang) ?? "" : "",
                    Below = Str(image, "place") == "below",
                });
            }
            if (!view.IsEnd)
                foreach (object entry in Items(step, "options"))
                {
                    var option = entry as Dictionary<string, object>;
                    if (option == null) continue;
                    object label;
                    string to = Str(option, "to");
                    view.Options.Add(new FlowOptionView
                    {
                        Id = Str(option, "id"),
                        SemanticId = Str(option, "semantic_id"),
                        Label = option.TryGetValue("label", out label) ? TextIn(label, lang) ?? "" : "",
                        Icon = Str(option, "icon"),
                        Primary = Str(option, "style") == "primary",
                        To = to,
                        Purpose = Str(option, "purpose"),
                        ToKind = Kind(to),
                    });
                }
            return view;
        }

        public static string Str(Dictionary<string, object> map, string key)
        {
            object value;
            return map != null && map.TryGetValue(key, out value) && value is string
                ? (string)value : "";
        }

        private static int Int(Dictionary<string, object> map, string key, int fallback)
        {
            object value;
            if (map == null || !map.TryGetValue(key, out value) || value == null) return fallback;
            try { return Convert.ToInt32(value, System.Globalization.CultureInfo.InvariantCulture); }
            catch (FormatException) { return fallback; }
            catch (OverflowException) { return fallback; }
            catch (InvalidCastException) { return fallback; }
        }

        private static IEnumerable<object> Items(Dictionary<string, object> map, string key)
        {
            object value;
            var list = map.TryGetValue(key, out value) ? value as IEnumerable : null;
            if (list == null || value is string) yield break;
            foreach (object item in list) yield return item;
        }
    }

    /// <summary>
    /// Navigation state of one door screen over one resolved document: a stack of page ids, a
    /// tap that becomes the next page or one of the two terminal Core calls, Back, the idle and
    /// end timeouts, an unanswered call, a throttled or failed notify and a replaced document.
    /// This is the shell-side twin of tools/conformance/visitor_flow.py (FlowWalker); the walk
    /// cases of tools/conformance/fixtures/visitor-flow-v1.json run against it.
    /// </summary>
    internal sealed class VisitorFlowWalker
    {
        public const string NoAnswerNotice = "calling.no_answer";
        public const string PressFailedNotice = "flow.call_failed";

        private VisitorFlowDocument _doc;
        private readonly List<string> _stack = new List<string>();
        private string _active;
        private string _pendingNotify;
        private string _pendingPurpose = "";

        public VisitorFlowWalker(VisitorFlowDocument doc, string lang)
        {
            Lang = string.IsNullOrEmpty(lang) ? "ja" : lang;
            _doc = doc;
            Home();
        }

        public string Lang { get; private set; }
        public FlowMode Mode { get; private set; }
        public string Notice { get; private set; }
        public bool Reply { get; private set; }
        public VisitorFlowDocument Document { get { return _doc; } }
        public int Depth { get { return _stack.Count; } }

        /// <summary>The page on screen (the end step on an end page), "" otherwise.</summary>
        public string Page
        {
            get
            {
                if (Mode == FlowMode.Page && _stack.Count > 0) return _stack[_stack.Count - 1];
                if (Mode == FlowMode.End && _active != null) return _active;
                return "";
            }
        }

        public bool CanGoBack { get { return Mode == FlowMode.Page && _stack.Count > 1; } }

        /// <summary>The call step of a call that is placed (its on_unanswered is read at the end).</summary>
        public string ActiveStep { get { return _active; } }

        private void Home()
        {
            _active = null;
            _pendingNotify = null;
            if (_doc != null && _doc.Enabled)
            {
                Mode = FlowMode.Page;
                _stack.Clear();
                _stack.Add(_doc.Start);
            }
            else
            {
                Mode = FlowMode.Legacy;
                _stack.Clear();
            }
        }

        public FlowPageView View()
        {
            return Mode == FlowMode.Legacy || _doc == null
                ? new FlowPageView() : _doc.View(Page, Lang);
        }

        public FlowSnapshot Snapshot()
        {
            var snapshot = new FlowSnapshot { Notice = Notice, Reply = Reply };
            snapshot.Mode = Mode == FlowMode.Page ? "page" : Mode == FlowMode.Calling ? "calling" :
                            Mode == FlowMode.End ? "end" : "legacy";
            string page = Page;
            if (page.Length > 0)
            {
                snapshot.Page = page;
                var view = _doc.View(page, Lang);
                snapshot.Title = view.Title.Length > 0 ? view.Title : null;
                if (Mode == FlowMode.Page) snapshot.Options = view.Options;
            }
            snapshot.Back = CanGoBack;
            snapshot.Done = Mode == FlowMode.End;
            return snapshot;
        }

        public void SetLang(string lang)
        {
            Lang = string.IsNullOrEmpty(lang) ? "ja" : lang;
        }

        public void SetReply(bool shown)
        {
            Reply = shown;
        }

        // ---- input ------------------------------------------------------------------------------

        /// <summary>
        /// A tap on an option. Navigation inside the document returns Nothing; a call or a notify
        /// returns what the shell must ask Core for, and the shell then reports PressResult or
        /// NotifyResult.
        /// </summary>
        public FlowAction Tap(string optionId)
        {
            if (Mode != FlowMode.Page || _doc == null) return FlowAction.Nothing;
            FlowOptionView chosen = null;
            foreach (var option in _doc.View(Page, Lang).Options)
                if (option.Id == optionId) chosen = option;
            if (chosen == null) return FlowAction.Nothing;
            Notice = null;
            string target = chosen.To;
            string kind = _doc.Kind(target);
            if (kind == "page")
            {
                int at = _stack.IndexOf(target);
                if (at >= 0) _stack.RemoveRange(at + 1, _stack.Count - at - 1);
                else _stack.Add(target);
                return FlowAction.Nothing;
            }
            if (kind == "call")
            {
                _active = target;
                return Press(_doc.PurposeOf(target));
            }
            if (kind == "notify")
            {
                _pendingNotify = target;
                _pendingPurpose = _doc.PurposeOf(target);
                return new FlowAction(FlowActionKind.Notify, "", target);
            }
            if (kind == "end")
            {
                Mode = FlowMode.End;
                _active = target;
                return FlowAction.Nothing;
            }
            // Unknown kind or a target that is not in the document: a visitor can always ring.
            _active = null;
            return Press("");
        }

        private FlowAction Press(string purpose)
        {
            return new FlowAction(FlowActionKind.Press, purpose, "");
        }

        /// <summary>The press Core was asked for: true when it placed a call.</summary>
        public void PressResult(bool placed)
        {
            if (placed) Mode = FlowMode.Calling;
            else Notice = PressFailedNotice;
        }

        /// <summary>
        /// Core's answer to the notify. A throttled answer is ok too: the visitor is never told.
        /// A refusal, or a closing step that is not an end page, rings instead.
        /// </summary>
        public FlowAction NotifyResult(bool ok)
        {
            string step = _pendingNotify;
            _pendingNotify = null;
            if (step == null || Mode != FlowMode.Page) return FlowAction.Nothing;
            string after = _doc.NextOf(step);
            if (!ok || _doc.Kind(after) != "end")
            {
                _active = null;
                return Press(_pendingPurpose);
            }
            Mode = FlowMode.End;
            _active = after;
            return FlowAction.Nothing;
        }

        public void Back()
        {
            if (!CanGoBack) return;
            _stack.RemoveAt(_stack.Count - 1);
            Notice = null;
        }

        public void IdleTimeout()
        {
            if (Mode != FlowMode.Page) return;
            if (_stack.Count > 1) _stack.RemoveRange(1, _stack.Count - 1);
            Notice = null;
        }

        /// <summary>Done, or the end page's return time elapsing.</summary>
        public void Done()
        {
            if (Mode == FlowMode.End) Home();
        }

        public void CallEnded(string reason)
        {
            if (Mode != FlowMode.Calling) return;
            string unanswered = _doc == null ? "" : _doc.OnUnanswered(_active);
            Home();
            if (reason != "timeout" || Mode != FlowMode.Page) return;
            if (_doc.Kind(unanswered) == "page")
            {
                if (unanswered != _stack[0]) _stack.Add(unanswered);
            }
            else Notice = NoAnswerNotice;
        }

        /// <summary>
        /// A newly published document: a call in progress goes on, a page stack survives while it
        /// still starts at the start page and every entry is still a page, an end page stays while
        /// it is still an end page; anything else goes to the start page or the classic screen.
        /// </summary>
        public void Replace(VisitorFlowDocument doc)
        {
            FlowMode previousMode = Mode;
            var previousStack = new List<string>(_stack);
            _doc = doc;
            if (_doc == null || !_doc.Enabled)
            {
                if (previousMode != FlowMode.Calling) Home();
                return;
            }
            if (previousMode == FlowMode.Calling) return;
            if (previousMode == FlowMode.End && _active != null && _doc.Kind(_active) == "end") return;
            bool keep = previousMode == FlowMode.Page && previousStack.Count > 0 &&
                        previousStack[0] == _doc.Start;
            if (keep)
                foreach (string id in previousStack)
                    if (_doc.Kind(id) != "page") keep = false;
            Home();
            if (keep)
            {
                _stack.Clear();
                _stack.AddRange(previousStack);
            }
        }
    }
}
