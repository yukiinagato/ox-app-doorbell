using System;
using System.Collections;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace DoorbellApp.Core
{
    /// <summary>
    /// The editor's view of step order, as pure functions over raw configuration steps. The
    /// sequence is Core's step_order: steps with a usable "order" first by ascending value, then
    /// steps without one, each group in reading order (start page, breadth first through option
    /// targets, notify "to" and "on_unanswered", then unreachable steps by id). A move or an
    /// insertion renumbers the whole sequence 0, 1, 2, ... and returns only the steps whose
    /// stored order changed, each as a whole step, so the caller writes them in one batch.
    /// </summary>
    internal static class FlowEditorModel
    {
        public const int MaxOrder = 9999;

        public static IEnumerable<string> Links(Dictionary<string, object> step)
        {
            string kind = Text(step, "kind");
            if (kind == "page")
            {
                var options = step.ContainsKey("options") ? step["options"] as IEnumerable : null;
                if (options == null || options is string) yield break;
                foreach (object entry in options)
                {
                    string to = Text(entry as Dictionary<string, object>, "to");
                    if (to.Length > 0) yield return to;
                }
            }
            else if (kind == "call")
            {
                string unanswered = Text(step, "on_unanswered");
                if (unanswered.Length > 0) yield return unanswered;
            }
            else if (kind == "notify")
            {
                string to = Text(step, "to");
                if (to.Length > 0) yield return to;
            }
        }

        public static List<string> ReadingOrder(Dictionary<string, object> steps, string start)
        {
            var order = new List<string>();
            var seen = new HashSet<string>();
            var queue = new Queue<string>();
            if (start != null && steps.ContainsKey(start)) queue.Enqueue(start);
            while (queue.Count > 0)
            {
                string id = queue.Dequeue();
                if (!seen.Add(id)) continue;
                order.Add(id);
                foreach (string next in Links(Step(steps, id)))
                    if (steps.ContainsKey(next) && !seen.Contains(next)) queue.Enqueue(next);
            }
            var rest = new List<string>(steps.Keys);
            rest.Sort(StringComparer.Ordinal);
            foreach (string id in rest) if (!seen.Contains(id)) order.Add(id);
            return order;
        }

        /// <summary>The stored order when it is an integer 0..9999, otherwise -1.</summary>
        public static int OrderOf(Dictionary<string, object> step)
        {
            object value;
            if (step == null || !step.TryGetValue("order", out value) || value == null || value is bool ||
                value is string) return -1;
            double number;
            try { number = Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture); }
            catch (FormatException) { return -1; }
            catch (InvalidCastException) { return -1; }
            catch (OverflowException) { return -1; }
            if (number != Math.Floor(number) || number < 0 || number > MaxOrder) return -1;
            return (int)number;
        }

        /// <summary>Core's step_order for the steps as configured.</summary>
        public static List<string> Sequence(Dictionary<string, object> steps, string start)
        {
            var reading = ReadingOrder(steps, start);
            var ordered = new List<KeyValuePair<int, string>>();
            var plain = new List<string>();
            for (int i = 0; i < reading.Count; i++)
            {
                int order = OrderOf(Step(steps, reading[i]));
                if (order >= 0) ordered.Add(new KeyValuePair<int, string>(order, reading[i]));
                else plain.Add(reading[i]);
            }
            var index = new Dictionary<string, int>();
            for (int i = 0; i < reading.Count; i++) index[reading[i]] = i;
            ordered.Sort((a, b) =>
            {
                int byOrder = a.Key.CompareTo(b.Key);
                return byOrder != 0 ? byOrder : index[a.Value].CompareTo(index[b.Value]);
            });
            var result = new List<string>();
            foreach (var pair in ordered) result.Add(pair.Value);
            result.AddRange(plain);
            return result;
        }

        /// <summary>The sequence with one step moved by delta places (clamped), or unchanged.</summary>
        public static List<string> Move(List<string> sequence, string id, int delta)
        {
            var next = new List<string>(sequence);
            int from = next.IndexOf(id);
            if (from < 0) return next;
            int to = Math.Max(0, Math.Min(next.Count - 1, from + delta));
            if (to == from) return next;
            next.RemoveAt(from);
            next.Insert(to, id);
            return next;
        }

        /// <summary>The sequence with a new id right after another one (at the end when it is unknown).</summary>
        public static List<string> InsertAfter(List<string> sequence, string after, string id)
        {
            var next = new List<string>(sequence);
            next.Remove(id);
            int at = next.IndexOf(after);
            next.Insert(at < 0 ? next.Count : at + 1, id);
            return next;
        }

        /// <summary>
        /// Consecutive order values 0, 1, 2, ... in the given sequence. Returns each step whose
        /// stored order differs (a step without one included), as a whole-step copy carrying its
        /// new order. A new step is renumbered by putting it into the map first.
        /// </summary>
        public static List<KeyValuePair<string, Dictionary<string, object>>> Renumber(
            Dictionary<string, object> steps, List<string> sequence)
        {
            var writes = new List<KeyValuePair<string, Dictionary<string, object>>>();
            for (int i = 0; i < sequence.Count && i <= MaxOrder; i++)
            {
                Dictionary<string, object> step = Step(steps, sequence[i]);
                if (step == null) continue;
                if (OrderOf(step) == i) continue;
                var copy = Copy(step);
                copy["order"] = (long)i;
                writes.Add(new KeyValuePair<string, Dictionary<string, object>>(sequence[i], copy));
            }
            return writes;
        }

        public static Dictionary<string, object> Copy(Dictionary<string, object> source)
        {
            var json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
            return json.Deserialize<Dictionary<string, object>>(json.Serialize(source)) ??
                   new Dictionary<string, object>();
        }

        private static Dictionary<string, object> Step(Dictionary<string, object> steps, string id)
        {
            object step;
            return steps.TryGetValue(id, out step) ? step as Dictionary<string, object> : null;
        }

        private static string Text(Dictionary<string, object> map, string key)
        {
            object value;
            return map != null && map.TryGetValue(key, out value) && value is string ? (string)value : "";
        }
    }
}
