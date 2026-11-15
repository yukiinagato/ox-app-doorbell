using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;
using DoorbellApp.Core;

// Runs every walk case of tools/conformance/fixtures/visitor-flow-v1.json against the shell-side
// flow model, so it must agree with the reference walker (tools/conformance/visitor_flow.py).
internal static class VisitorFlowTests
{
    private static int _assertions;

    private static void Check(bool value, string message)
    {
        ++_assertions;
        if (!value) throw new Exception(message);
    }

    private static Dictionary<string, object> Map(object value)
    {
        return (Dictionary<string, object>)value;
    }

    private static IList List(object value)
    {
        return (IList)value;
    }

    private static string Describe(object value)
    {
        return new JavaScriptSerializer().Serialize(value);
    }

    private static Dictionary<string, object> ToMap(FlowSnapshot s)
    {
        var options = new List<object>();
        foreach (var option in s.Options)
            options.Add(new Dictionary<string, object>
            {
                { "id", option.Id }, { "semantic_id", option.SemanticId }, { "label", option.Label },
            });
        return new Dictionary<string, object>
        {
            { "mode", s.Mode }, { "page", s.Page }, { "title", s.Title }, { "options", options },
            { "back", s.Back }, { "done", s.Done }, { "notice", s.Notice }, { "reply", s.Reply },
        };
    }

    private static bool Same(object a, object b)
    {
        if (a == null || b == null) return a == null && b == null;
        var ma = a as Dictionary<string, object>;
        var mb = b as Dictionary<string, object>;
        if (ma != null || mb != null)
        {
            if (ma == null || mb == null || ma.Count != mb.Count) return false;
            foreach (var pair in ma)
            {
                object other;
                if (!mb.TryGetValue(pair.Key, out other) || !Same(pair.Value, other)) return false;
            }
            return true;
        }
        if (a is string || b is string) return a is string && b is string && (string)a == (string)b;
        if (a is bool || b is bool) return a is bool && b is bool && (bool)a == (bool)b;
        var la = a as IList;
        var lb = b as IList;
        if (la != null || lb != null)
        {
            if (la == null || lb == null || la.Count != lb.Count) return false;
            for (int i = 0; i < la.Count; i++) if (!Same(la[i], lb[i])) return false;
            return true;
        }
        return a.Equals(b);
    }

    private static List<string> Calls(object expected)
    {
        var calls = new List<string>();
        foreach (object entry in List(expected))
            foreach (var pair in Map(entry)) calls.Add(pair.Key + ":" + pair.Value);
        return calls;
    }

    private static List<string> Apply(VisitorFlowWalker walker, Dictionary<string, object> ev,
                                       Dictionary<string, VisitorFlowDocument> docs)
    {
        var calls = new List<string>();
        if (ev.ContainsKey("reply")) { walker.SetReply((bool)ev["reply"]); return calls; }
        if (ev.ContainsKey("lang")) { walker.SetLang((string)ev["lang"]); return calls; }
        if (ev.ContainsKey("flow_changed")) { walker.Replace(docs[(string)ev["flow_changed"]]); return calls; }
        if (ev.ContainsKey("tap"))
        {
            FlowAction action = walker.Tap((string)ev["tap"]);
            bool pressFails = ev.ContainsKey("press_result") && (string)ev["press_result"] == "failed";
            bool notifyOk = true;
            if (ev.ContainsKey("notify_result"))
                notifyOk = Map(ev["notify_result"]).ContainsKey("ok") &&
                           (bool)Map(ev["notify_result"])["ok"];
            while (action.Kind != FlowActionKind.None)
            {
                if (action.Kind == FlowActionKind.Press)
                {
                    calls.Add("press:" + action.Purpose);
                    walker.PressResult(!pressFails);
                    action = FlowAction.Nothing;
                }
                else
                {
                    calls.Add("notify:" + action.Step);
                    action = walker.NotifyResult(notifyOk);
                }
            }
            return calls;
        }
        if (ev.ContainsKey("back")) { walker.Back(); return calls; }
        if (ev.ContainsKey("idle_timeout")) { walker.IdleTimeout(); return calls; }
        if (ev.ContainsKey("done") || ev.ContainsKey("end_timeout")) { walker.Done(); return calls; }
        if (ev.ContainsKey("call_ended")) { walker.CallEnded((string)ev["call_ended"]); return calls; }
        throw new Exception("unknown walk event " + Describe(ev));
    }

    private static void RunWalk(Dictionary<string, object> walk,
                                Dictionary<string, VisitorFlowDocument> docs)
    {
        string name = (string)walk["name"];
        string lang = walk.ContainsKey("lang") ? (string)walk["lang"] : "ja";
        var walker = new VisitorFlowWalker(docs[(string)walk["flow"]], lang);
        if (walk.ContainsKey("start"))
            Check(Same(ToMap(walker.Snapshot()), walk["start"]),
                  name + ": start: expected " + Describe(walk["start"]) + ", got " +
                  Describe(ToMap(walker.Snapshot())));
        int index = 0;
        foreach (object raw in List(walk["steps"]))
        {
            var entry = Map(raw);
            var ev = Map(entry["event"]);
            List<string> calls = Apply(walker, ev, docs);
            List<string> wanted = entry.ContainsKey("calls") ? Calls(entry["calls"]) : new List<string>();
            Check(string.Join(",", calls) == string.Join(",", wanted),
                  name + "[" + index + "]: expected calls " + string.Join(",", wanted) + ", got " +
                  string.Join(",", calls));
            Check(Same(ToMap(walker.Snapshot()), entry["expect"]),
                  name + "[" + index + "]: expected " + Describe(entry["expect"]) + ", got " +
                  Describe(ToMap(walker.Snapshot())));
            index++;
        }
    }

    // Structural promises Core makes to a shell (check_resolved_document in the reference).
    private static void CheckResolved(string name, VisitorFlowDocument doc, Dictionary<string, object> expect)
    {
        if (!(bool)expect["enabled"])
        {
            Check(!doc.Enabled, name + ": a disabled document is not enabled");
            return;
        }
        Check(doc.Enabled, name + ": enabled");
        foreach (var pair in Map(expect["steps"]))
        {
            string kind = doc.Kind(pair.Key);
            Check(VisitorFlowDocument.IsKnownKind(kind), name + ": " + pair.Key + " has a known kind");
            if (kind != "page") continue;
            var view = doc.View(pair.Key, "ja");
            Check(view.Options.Count > 0, name + ": page " + pair.Key + " has nothing to press");
            int primaries = 0;
            foreach (var option in view.Options)
            {
                if (option.Primary) primaries++;
                Check(option.SemanticId == (option.Primary ? "call.primary" : "purpose.button"),
                      name + ": " + pair.Key + "." + option.Id + " semantic id");
                Check(option.ToKind.Length > 0, name + ": " + pair.Key + "." + option.Id + " leads nowhere");
            }
            Check(primaries <= 1, name + ": page " + pair.Key + " has two primary options");
        }
    }

    private static void RunUnits()
    {
        Check(VisitorFlowDocument.Parse(null) == null, "no text is no document");
        Check(VisitorFlowDocument.Parse("{not json") == null, "broken JSON is no document");
        Check(VisitorFlowDocument.Parse("[1,2]") == null, "a non-object is no document");
        var broken = new VisitorFlowWalker(null, "ja");
        Check(broken.Mode == FlowMode.Legacy && broken.Page == "", "no document shows the classic screen");
        Check(broken.Tap("x").Kind == FlowActionKind.None, "a legacy walker ignores taps");

        var labels = new Dictionary<string, object> { { "ja", "a" }, { "en", "" }, { "zh", "c" } };
        Check(VisitorFlowDocument.TextIn(labels, "zh") == "c", "the language wins");
        Check(VisitorFlowDocument.TextIn(labels, "en") == "a", "an empty entry falls back to Japanese");
        Check(VisitorFlowDocument.TextIn(labels, "ko") == "a", "an unknown language falls back to Japanese");
        var onlyEn = new Dictionary<string, object> { { "en", "x" } };
        Check(VisitorFlowDocument.TextIn(onlyEn, "zh") == "x", "any value is better than none");
        Check(VisitorFlowDocument.TextIn(null, "ja") == null, "no map has no text");

        // A flow whose start is not a page is not enabled: the classic screen stays.
        var noStart = VisitorFlowDocument.Parse(
            "{\"schema_version\":1,\"enabled\":true,\"start\":\"c\",\"steps\":{\"c\":{\"kind\":\"call\"}}}");
        Check(noStart != null && !noStart.Enabled, "a start that is not a page is not enabled");

        var tooMany = new System.Text.StringBuilder("{\"enabled\":true,\"start\":\"s0\",\"steps\":{");
        for (int i = 0; i < 40; i++)
            tooMany.Append(i == 0 ? "" : ",").Append("\"s").Append(i).Append("\":{\"kind\":\"call\"}");
        tooMany.Append("}}");
        Check(VisitorFlowDocument.Parse(tooMany.ToString()) == null, "an unbounded step pool is refused");

        var idle = VisitorFlowDocument.Parse(
            "{\"enabled\":true,\"start\":\"s\",\"idle_s\":3,\"steps\":{\"s\":{\"kind\":\"page\",\"options\":" +
            "[{\"id\":\"o\",\"semantic_id\":\"call.primary\",\"label\":{\"ja\":\"x\"},\"style\":\"primary\",\"to\":\"c\"}]}," +
            "\"c\":{\"kind\":\"call\"},\"e\":{\"kind\":\"end\",\"return_s\":900}}}");
        Check(idle.IdleSeconds == 15, "idle_s is clamped to 15");
        Check(idle.ReturnSeconds("e") == 60, "return_s is clamped to 60");
        Check(idle.ReturnSeconds("missing") == 8, "return_s defaults to 8");
    }

    public static int Main(string[] args)
    {
        string path = args.Length > 0 ? args[0] : "tools/conformance/fixtures/visitor-flow-v1.json";
        var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        var suite = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
        Check(Convert.ToInt32(suite["schema_version"]) == 1, "fixture schema");

        var docs = new Dictionary<string, VisitorFlowDocument>();
        foreach (object raw in List(suite["resolve"]))
        {
            var entry = Map(raw);
            string name = (string)entry["name"];
            var expect = Map(entry["expect"]);
            var doc = VisitorFlowDocument.FromRoot(expect);
            Check(doc != null, name + ": the resolved document parses");
            CheckResolved(name, doc, expect);
            docs[name] = doc;
        }
        int walks = 0;
        foreach (object raw in List(suite["walk"]))
        {
            RunWalk(Map(raw), docs);
            walks++;
        }
        Check(walks >= 20, "the fixture's walk cases ran");
        RunUnits();
        Console.WriteLine("Windows visitor flow tests: " + docs.Count + " documents, " + walks +
                          " walks, " + _assertions + " assertions passed");
        return 0;
    }
}
