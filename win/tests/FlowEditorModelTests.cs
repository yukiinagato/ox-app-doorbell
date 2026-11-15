using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using DoorbellApp.Core;

// The editor's step order and the write shape of a reorder (docs/en/visitor-flow-contract.md,
// "Reordering"): consecutive order values in the new sequence, only changed steps rewritten as
// whole steps, order kept when a step is rewritten for another reason.
internal static class FlowEditorModelTests
{
    private static int _assertions;

    private static void Check(bool value, string message)
    {
        ++_assertions;
        if (!value) throw new Exception(message);
    }

    private static Dictionary<string, object> Steps(string json)
    {
        return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
    }

    private static string Join(IEnumerable<string> ids)
    {
        return string.Join(",", ids);
    }

    private const string Flow =
        "{\"s_home\":{\"kind\":\"page\",\"options\":[{\"id\":\"a\",\"to\":\"s_more\"},{\"id\":\"b\",\"to\":\"c_ring\"}]}," +
        "\"s_more\":{\"kind\":\"page\",\"options\":[{\"id\":\"c\",\"to\":\"n_note\"}]}," +
        "\"c_ring\":{\"kind\":\"call\",\"on_unanswered\":\"s_home\"}," +
        "\"n_note\":{\"kind\":\"notify\",\"to\":\"e_done\"}," +
        "\"e_done\":{\"kind\":\"end\"}," +
        "\"z_orphan\":{\"kind\":\"page\"}}";

    private static int Main()
    {
        var steps = Steps(Flow);

        // No order anywhere: reading order, orphans by id last.
        Check(Join(FlowEditorModel.Sequence(steps, "s_home")) == "s_home,s_more,c_ring,n_note,e_done,z_orphan",
              "reading order");
        Check(Join(FlowEditorModel.Sequence(steps, "missing")) == "c_ring,e_done,n_note,s_home,s_more,z_orphan",
              "unknown start falls back to ids");

        // Steps with an order come first by ascending value; the others keep reading order.
        ((Dictionary<string, object>)steps["e_done"])["order"] = 1;
        ((Dictionary<string, object>)steps["c_ring"])["order"] = 0;
        Check(Join(FlowEditorModel.Sequence(steps, "s_home")) == "c_ring,e_done,s_home,s_more,n_note,z_orphan",
              "ordered steps first");
        ((Dictionary<string, object>)steps["s_more"])["order"] = 1;
        Check(Join(FlowEditorModel.Sequence(steps, "s_home")) == "c_ring,s_more,e_done,s_home,n_note,z_orphan",
              "a tie keeps reading order");
        ((Dictionary<string, object>)steps["s_home"])["order"] = "x";
        ((Dictionary<string, object>)steps["n_note"])["order"] = 10000;
        ((Dictionary<string, object>)steps["z_orphan"])["order"] = 1.5;
        Check(Join(FlowEditorModel.Sequence(steps, "s_home")) == "c_ring,s_more,e_done,s_home,n_note,z_orphan",
              "unusable orders count as none");

        // Move and write shape.
        steps = Steps(Flow);
        var sequence = FlowEditorModel.Sequence(steps, "s_home");
        var moved = FlowEditorModel.Move(sequence, "c_ring", -1);
        Check(Join(moved) == "s_home,c_ring,s_more,n_note,e_done,z_orphan", "move up");
        Check(Join(FlowEditorModel.Move(sequence, "s_home", -1)) == Join(sequence), "move up at the top is a no-op");
        Check(Join(FlowEditorModel.Move(sequence, "z_orphan", 1)) == Join(sequence), "move down at the end is a no-op");
        var writes = FlowEditorModel.Renumber(steps, moved);
        // s_home is already index 0 only when it has order 0: nothing is stored, so every step is written.
        Check(writes.Count == 6, "nothing stored yet: every step gets an order");
        for (int i = 0; i < writes.Count; i++)
        {
            Check(writes[i].Key == moved[i], "writes follow the sequence");
            Check(Convert.ToInt32(writes[i].Value["order"]) == i, "consecutive order");
            Check(writes[i].Value["kind"] != null, "a whole step");
        }
        Check(!((Dictionary<string, object>)steps["s_home"]).ContainsKey("order"), "the input is not modified");

        // Once numbered, a move rewrites only the two steps that changed places.
        foreach (var write in writes) steps[write.Key] = write.Value;
        sequence = FlowEditorModel.Sequence(steps, "s_home");
        Check(Join(sequence) == "s_home,c_ring,s_more,n_note,e_done,z_orphan", "stored order wins");
        writes = FlowEditorModel.Renumber(steps, FlowEditorModel.Move(sequence, "s_more", 2));
        Check(Join(KeysOf(writes)) == "n_note,e_done,s_more", "only changed steps are written: " + Join(KeysOf(writes)));
        Check(Convert.ToInt32(writes[0].Value["order"]) == 2 && Convert.ToInt32(writes[2].Value["order"]) == 4,
              "order values");

        // Order survives a rewrite of the step for another reason (a deep copy keeps every member).
        var rewritten = FlowEditorModel.Copy((Dictionary<string, object>)steps["c_ring"]);
        Check(Convert.ToInt32(rewritten["order"]) == 1, "copy keeps order");

        // A duplicate lists right after the original.
        var copy = FlowEditorModel.Copy((Dictionary<string, object>)steps["s_home"]);
        copy.Remove("order");
        steps["s_home_copy"] = copy;
        var after = FlowEditorModel.InsertAfter(FlowEditorModel.Sequence(steps, "s_home"), "s_home", "s_home_copy");
        Check(Join(after) == "s_home,s_home_copy,c_ring,s_more,n_note,e_done,z_orphan",
              "duplicate follows the original: " + Join(after));
        writes = FlowEditorModel.Renumber(steps, after);
        Check(writes.Count == 6, "the copy and everything after it shift");
        Check(writes[0].Key == "s_home_copy" && Convert.ToInt32(writes[0].Value["order"]) == 1, "copy is order 1");

        // Icons: never an emoji, always the same small set.
        Check(FlowIcons.KeyFor("p_visit", "x") == "IconHome", "seeded purpose id wins");
        Check(FlowIcons.KeyFor("p_other", "\U0001F4E6") == "IconDots", "other is the ellipsis");
        Check(FlowIcons.KeyFor("", "\U0001F4E6") == "IconPackage", "package emoji");
        Check(FlowIcons.KeyFor("custom", "\u2709\uFE0F") == "IconMail", "mail with a variation selector");
        Check(FlowIcons.KeyFor("custom", "\U0001F6E0\uFE0F") == "IconWrench", "tools emoji");
        Check(FlowIcons.KeyFor("custom", "\u270D\uFE0F") == "IconUser", "unknown emoji is the person");
        Check(FlowIcons.KeyFor("custom", "") == "IconUser", "unknown purpose without an icon is the person");
        Check(FlowIcons.KeyFor("", "") == null, "no purpose and no icon: no glyph");
        Check(FlowIcons.KeyFor("", "\uD83D") == "IconUser", "a lone surrogate does not throw");
        foreach (string emoji in FlowIcons.PickerEmoji)
            Check(FlowIcons.KeyFor("", emoji) != "IconUser" || emoji == "\U0001F464", "picker emoji map to a glyph: " + emoji);

        // Error codes and locations.
        var detail = new Dictionary<string, object> { { "lang", "ja" }, { "limit", 60L }, { "value", 71 } };
        var tooLong = FlowError.Parse("visitor_flow.text_too_long: s_home.title.ja", detail);
        Check(tooLong.IsFlow && tooLong.Code == "text_too_long", "code");
        Check(tooLong.Place == FlowErrorPlace.Field && tooLong.Step == "s_home" &&
              tooLong.Field == "title" && tooLong.Lang == "ja", "title field location");
        Check(FlowError.Fill("{lang}: {limit}/{value}", tooLong, l => "JA") == "JA: 60/71", "placeholders");
        var label = FlowError.Parse("visitor_flow.text_required: s_home.o_x.label", null);
        Check(label.Place == FlowErrorPlace.Option && label.Option == "o_x" && label.Field == "label", "option label");
        var labelLang = FlowError.Parse("visitor_flow.text_too_long: s_home.o_x.label.en", null);
        Check(labelLang.Option == "o_x" && labelLang.Lang == "en", "option label language");
        var alt = FlowError.Parse("visitor_flow.text_too_long: s_a.images[1].alt.zh", null);
        Check(alt.Place == FlowErrorPlace.Image && alt.Image == 1 && alt.Lang == "zh", "image alt");
        var image = FlowError.Parse("visitor_flow.unknown_asset: s_a.images[0]", null);
        Check(image.Place == FlowErrorPlace.Image && image.Image == 0 && image.Step == "s_a", "image row");
        var option = FlowError.Parse("visitor_flow.unknown_target: s_a.o_b", null);
        Check(option.Place == FlowErrorPlace.Option && option.Step == "s_a" && option.Option == "o_b", "option");
        var stepOnly = FlowError.Parse("visitor_flow.no_options: s_a", null);
        Check(stepOnly.Place == FlowErrorPlace.Step && stepOnly.Step == "s_a", "step");
        var start = FlowError.Parse("visitor_flow.unknown_start: start", null);
        Check(start.Place == FlowErrorPlace.Start && start.Option == "", "global start");
        var doorStart = FlowError.Parse("visitor_flow.start_not_page: doors.front.start", null);
        Check(doorStart.Place == FlowErrorPlace.Start && doorStart.Option == "front", "door start");
        var none = FlowError.Parse("visitor_flow.bad_idle_s", new Dictionary<string, object> { { "min", 15 }, { "max", 300 } });
        Check(none.Place == FlowErrorPlace.None && none.Code == "bad_idle_s", "no location");
        Check(FlowError.Fill("{min}-{max}", none, null) == "15-300", "min and max");
        Check(!FlowError.Parse("unresolved_config_conflict", null).IsFlow, "not a flow error");
        Check(!FlowError.Parse(null, null).IsFlow, "null");
        Check(FlowError.Parse("visitor_flow.container_write: visitor_flow.steps", null).Place == FlowErrorPlace.None,
              "a configuration key is not a step");

        Console.WriteLine("flow editor model tests passed (" + _assertions + " assertions)");
        return 0;
    }

    private static List<string> KeysOf(List<KeyValuePair<string, Dictionary<string, object>>> writes)
    {
        var keys = new List<string>();
        foreach (var write in writes) keys.Add(write.Key);
        return keys;
    }
}
