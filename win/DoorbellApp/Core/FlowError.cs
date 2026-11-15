using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace DoorbellApp.Core
{
    internal enum FlowErrorPlace { None, Step, Option, Field, Image, Start }

    /// <summary>
    /// A refused flow write: "visitor_flow.code[: location]" with the numbers of Core's detail
    /// object (docs/en/visitor-flow-contract.md, section 8.1). Location grammar: "start",
    /// "doors.door.start", "step", "step.option", "step.option.label.lang",
    /// "step.title.lang" (also body, message), "step.images[n]", "step.images[n].alt.lang".
    /// </summary>
    internal sealed class FlowErrorInfo
    {
        public bool IsFlow;
        public string Code = "";
        public string Location = "";
        public FlowErrorPlace Place = FlowErrorPlace.None;
        public string Step = "";
        // The option id; for a door start, the door id.
        public string Option = "";
        public string Field = "";
        public string Lang = "";
        public int Image = -1;
        public Dictionary<string, string> Detail = new Dictionary<string, string>();
    }

    internal static class FlowError
    {
        private const string Prefix = "visitor_flow.";
        private static readonly Regex ImageIndex = new Regex(@"^images\[(\d+)\]$", RegexOptions.Compiled);
        private static readonly Regex Placeholder = new Regex(@"\{([a-z_]+)\}", RegexOptions.Compiled);

        public static FlowErrorInfo Parse(string err, IDictionary<string, object> detail)
        {
            var info = new FlowErrorInfo();
            if (string.IsNullOrEmpty(err) || !err.StartsWith(Prefix, StringComparison.Ordinal)) return info;
            info.IsFlow = true;
            int cut = err.IndexOf(": ", StringComparison.Ordinal);
            info.Code = (cut < 0 ? err : err.Substring(0, cut)).Substring(Prefix.Length);
            info.Location = cut < 0 ? "" : err.Substring(cut + 2).Trim();
            if (detail != null)
                foreach (var pair in detail)
                    if (pair.Value != null)
                        info.Detail[pair.Key] = Convert.ToString(pair.Value, CultureInfo.InvariantCulture);
            if (info.Detail.ContainsKey("lang")) info.Lang = info.Detail["lang"];
            Locate(info);
            return info;
        }

        private static void Locate(FlowErrorInfo info)
        {
            if (info.Location.Length == 0) return;
            string[] parts = info.Location.Split('.');
            if (parts.Length == 1 && parts[0] == "start") { info.Place = FlowErrorPlace.Start; return; }
            if (parts.Length == 3 && parts[0] == "doors" && parts[2] == "start")
            {
                info.Place = FlowErrorPlace.Start;
                info.Option = parts[1];
                return;
            }
            if (parts[0] == "visitor_flow" || parts[0] == "doors") return;
            info.Step = parts[0];
            info.Place = FlowErrorPlace.Step;
            if (parts.Length == 1) return;
            Match image = ImageIndex.Match(parts[1]);
            if (image.Success)
            {
                info.Place = FlowErrorPlace.Image;
                info.Image = int.Parse(image.Groups[1].Value, CultureInfo.InvariantCulture);
                if (parts.Length >= 4 && parts[2] == "alt") info.Lang = parts[3];
                return;
            }
            if (parts[1] == "title" || parts[1] == "body" || parts[1] == "message")
            {
                info.Place = FlowErrorPlace.Field;
                info.Field = parts[1];
                if (parts.Length >= 3) info.Lang = parts[2];
                return;
            }
            info.Place = FlowErrorPlace.Option;
            info.Option = parts[1];
            if (parts.Length >= 3 && parts[2] == "label")
            {
                info.Field = "label";
                if (parts.Length >= 4) info.Lang = parts[3];
            }
        }

        /// <summary>Fills {limit}, {value}, {min}, {max} and {lang} (as the language's name).</summary>
        public static string Fill(string template, FlowErrorInfo info, Func<string, string> languageName)
        {
            return Placeholder.Replace(template ?? "", m =>
            {
                string name = m.Groups[1].Value;
                string value;
                if (name == "lang")
                    return info.Lang.Length == 0 ? "" : (languageName == null ? info.Lang : languageName(info.Lang));
                return info.Detail.TryGetValue(name, out value) ? value : "";
            });
        }
    }
}
