using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using DoorbellApp.Core;
using DoorbellApp.Util;

namespace DoorbellApp.Settings
{
    // The visitor flow editor (door-station wizard). It reads raw configuration (visitor_flow.*)
    // and writes exactly what docs/en/config-schema.md allows: scalar leaves for the top-level
    // keys, one whole object per step, one batch per save. Every write runs on the settings write
    // lane, and Core's validation error is shown in the dialog or row that caused it.
    internal sealed partial class SettingsWindow
    {
        private const int MaxFlowSteps = 32;
        private const int MaxFlowOptions = 12;
        private const int MaxFlowImages = 2;

        /// <summary>The window a nested dialog or file picker is owned by (the open step dialog).</summary>
        private Window _formOwner;

        private delegate string FlowReader(Dictionary<string, object> step);

        // ---- reading the configuration --------------------------------------------------------

        private Dictionary<string, object> FlowSteps()
        {
            var map = new Dictionary<string, object>();
            var steps = _store.Get("visitor_flow.steps") as Dictionary<string, object>;
            if (steps == null) return map;
            foreach (var pair in steps)
                if (pair.Value is Dictionary<string, object>) map[pair.Key] = pair.Value;
            return map;
        }

        private bool FlowHasExplicitSteps()
        {
            return FlowSteps().Count > 0;
        }

        private List<string> FlowLanguages()
        {
            var languages = SettingsStore.AsStringList(_store.Get("ui.languages"));
            if (languages.Count == 0) languages = new List<string> { "ja", "en", "zh" };
            return languages;
        }

        private static string LangName(string lang)
        {
            string key = "language.name_" + lang;
            string name = Texts.T(key);
            return string.IsNullOrEmpty(name) || name == key ? lang : name;
        }

        private static IEnumerable<string> FlowLinks(Dictionary<string, object> step)
        {
            string kind = Str(step, "kind");
            if (kind == "page")
            {
                var options = step.ContainsKey("options") ? step["options"] as IEnumerable : null;
                if (options == null) yield break;
                foreach (object entry in options)
                {
                    string to = Str(entry as Dictionary<string, object>, "to");
                    if (to.Length > 0) yield return to;
                }
            }
            else if (kind == "call")
            {
                string unanswered = Str(step, "on_unanswered");
                if (unanswered.Length > 0) yield return unanswered;
            }
            else if (kind == "notify")
            {
                string to = Str(step, "to");
                if (to.Length > 0) yield return to;
            }
        }

        /// <summary>The start page first, then in the order the steps are reached, then the rest.</summary>
        private List<string> FlowStepOrder(Dictionary<string, object> steps)
        {
            var order = new List<string>();
            var seen = new HashSet<string>();
            var queue = new Queue<string>();
            string start = Convert.ToString(_store.Get("visitor_flow.start") ?? "", CultureInfo.InvariantCulture);
            if (steps.ContainsKey(start)) queue.Enqueue(start);
            while (queue.Count > 0)
            {
                string id = queue.Dequeue();
                if (!seen.Add(id)) continue;
                order.Add(id);
                foreach (string next in FlowLinks((Dictionary<string, object>)steps[id]))
                    if (steps.ContainsKey(next) && !seen.Contains(next)) queue.Enqueue(next);
            }
            var rest = new List<string>(steps.Keys);
            rest.Sort(StringComparer.Ordinal);
            foreach (string id in rest) if (!seen.Contains(id)) order.Add(id);
            return order;
        }

        private string FlowPurposeName(string purposeId)
        {
            if (string.IsNullOrEmpty(purposeId)) return Texts.T("flow_editor.purpose_none");
            var purposes = ReadRecords("visit_purposes");
            return purposes.ContainsKey(purposeId)
                ? LabelText(purposes[purposeId].ContainsKey("label") ? purposes[purposeId]["label"] : null, purposeId)
                : purposeId;
        }

        private static string FlowKindName(string kind)
        {
            switch (kind)
            {
                case "page": return Texts.T("flow_editor.kind_page");
                case "call": return Texts.T("flow_editor.kind_call");
                case "notify": return Texts.T("flow_editor.kind_notify");
                case "end": return Texts.T("flow_editor.kind_end");
                default: return kind;
            }
        }

        private string FlowStepLabel(string id, Dictionary<string, object> step)
        {
            string kind = Str(step, "kind");
            string detail;
            switch (kind)
            {
                case "page":
                case "end":
                    detail = LabelText(step.ContainsKey("title") ? step["title"] : null, "");
                    break;
                case "notify":
                    detail = LabelText(step.ContainsKey("message") ? step["message"] : null, "");
                    break;
                case "call":
                    detail = FlowPurposeName(Str(step, "purpose"));
                    break;
                default:
                    detail = kind;
                    break;
            }
            string name = FlowKindName(kind);
            return detail.Length == 0 ? name + " · " + id : name + " · " + detail;
        }

        private List<SettingOption> FlowStepOptions(Dictionary<string, object> steps, string kind,
                                                    string exclude)
        {
            var options = new List<SettingOption>();
            foreach (string id in FlowStepOrder(steps))
            {
                var step = (Dictionary<string, object>)steps[id];
                if (id == exclude || (kind != null && Str(step, "kind") != kind)) continue;
                options.Add(new SettingOption(id, null, FlowStepLabel(id, step) + " (" + id + ")"));
            }
            return options;
        }

        private List<SettingOption> FlowPurposeOptions()
        {
            var options = new List<SettingOption> { new SettingOption("", "flow_editor.option_purpose_none") };
            options.AddRange(PurposeOptions());
            return options;
        }

        private static string FlowNewId(string prefix, IDictionary<string, object> taken)
        {
            for (int attempt = 0; attempt < 50; attempt++)
            {
                string id = prefix + Guid.NewGuid().ToString("N").Substring(0, 6);
                if (taken == null || !taken.ContainsKey(id)) return id;
            }
            return prefix + Guid.NewGuid().ToString("N").Substring(0, 12);
        }

        /// <summary>Steps (and the start leaves) that lead to a step, named for the operator.</summary>
        private List<string> FlowReferrers(string id, Dictionary<string, object> steps)
        {
            var names = new List<string>();
            foreach (var pair in steps)
            {
                if (pair.Key == id) continue;
                foreach (string link in FlowLinks((Dictionary<string, object>)pair.Value))
                    if (link == id)
                    {
                        names.Add(FlowStepLabel(pair.Key, (Dictionary<string, object>)pair.Value));
                        break;
                    }
            }
            if (Convert.ToString(_store.Get("visitor_flow.start")) == id) names.Add(Texts.T("flow_editor.start"));
            foreach (var door in ReadRecords("doors"))
                if (Convert.ToString(_store.Get("doors." + door.Key + ".visitor_flow.start")) == id)
                    names.Add(Texts.T("flow_editor.door_start") + " " + LabelText(
                        door.Value.ContainsKey("label") ? door.Value["label"] : null, door.Key));
            return names;
        }

        /// <summary>Core's error text for a refused flow write: the code is an i18n key.</summary>
        internal static string FlowErrorText(string error)
        {
            if (string.IsNullOrEmpty(error)) return "";
            if (error == "unresolved_config_conflict") return Texts.T("flow_editor.conflict");
            if (!error.StartsWith("visitor_flow.", StringComparison.Ordinal)) return error;
            int cut = error.IndexOf(": ", StringComparison.Ordinal);
            string code = cut < 0 ? error : error.Substring(0, cut);
            string detail = cut < 0 ? "" : error.Substring(cut + 2);
            string text = Texts.T(code);
            if (string.IsNullOrEmpty(text) || text == code) return Texts.T("visitor_flow.invalid", error);
            return detail.Length == 0 ? text : text + " (" + detail + ")";
        }

        // ---- writing ----------------------------------------------------------------------------

        private static List<KeyValuePair<string, object>> FlowSet(string key, object value)
        {
            return new List<KeyValuePair<string, object>> { new KeyValuePair<string, object>(key, value) };
        }

        /// <summary>One batch on the write lane; the result comes back on the dispatcher.</summary>
        private void FlowCommit(List<KeyValuePair<string, object>> sets, List<string> deletes,
                                Action<SettingsWriteResult> done)
        {
            _writes.Run(() =>
            {
                SettingsWriteResult result = _store.Commit(sets, deletes);
                Dispatcher.BeginInvoke(new Action(() => done(result)));
            });
        }

        // ---- the panel --------------------------------------------------------------------------

        private FrameworkElement BuildFlowEditor(SettingItem item)
        {
            var parts = new RowParts();
            var panel = EditorPanel(item, parts, out var head);
            var steps = FlowSteps();
            bool explicitSteps = steps.Count > 0;

            var enabled = DoorbellApp.Ui.Fluent.Switch(SettingsStore.AsBool(_store.Get("visitor_flow.enabled"), true));
            AutomationLabel(enabled, Texts.T("flow_editor.enabled"));
            AutomationId(enabled, "FlowEnabled");
            DockPanel.SetDock(enabled, Dock.Right);
            head.Children.Insert(0, enabled);
            bool reverting = false;
            enabled.Toggled += (s, e) =>
            {
                if (reverting) return;
                bool next = enabled.IsOn;
                FlowCommit(FlowSet("visitor_flow.enabled", next), null, result =>
                {
                    if (Report(result, parts)) return;
                    reverting = true;
                    enabled.IsOn = !next;
                    reverting = false;
                });
            };
            panel.Children.Add(parts.Error);

            if (!explicitSteps)
            {
                panel.Children.Add(FieldHint(Texts.T("flow_editor.default_note")));
                panel.Children.Add(FlowTemplateButtons(parts, false));
                return panel;
            }

            // Start page and idle return.
            var pages = FlowStepOptions(steps, "page", null);
            var start = FlowCombo(pages, _store.Get("visitor_flow.start"), value =>
                FlowCommit(FlowSet("visitor_flow.start", value), null, result =>
                {
                    if (!Report(result, parts)) Refresh();
                }));
            AutomationId(start, "FlowStart");
            panel.Children.Add(FlowField(Texts.T("flow_editor.start"), start, null));

            var idle = FormTextBox(Convert.ToString(_store.Get("visitor_flow.idle_s") ?? 45, CultureInfo.InvariantCulture), 3);
            idle.Width = 120;
            idle.HorizontalAlignment = HorizontalAlignment.Left;
            AutomationLabel(idle, Texts.T("flow_editor.idle_s"));
            AutomationId(idle, "FlowIdle");
            string idleShown = idle.Text;
            Action commitIdle = () =>
            {
                string text = idle.Text.Trim();
                int seconds;
                if (text == idleShown) return;
                if (!int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out seconds) ||
                    seconds < 15 || seconds > 300)
                {
                    parts.Error.Text = Texts.T("settings.form_number_range", Texts.T("flow_editor.idle_s"), "15", "300");
                    parts.Error.Visibility = Visibility.Visible;
                    idle.Text = idleShown;
                    return;
                }
                idleShown = text;
                FlowCommit(FlowSet("visitor_flow.idle_s", (long)seconds), null, result => Report(result, parts));
            };
            idle.LostFocus += (s, e) => commitIdle();
            idle.KeyDown += (s, e) => { if (e.Key == System.Windows.Input.Key.Enter) commitIdle(); };
            panel.Children.Add(FlowField(Texts.T("flow_editor.idle_s"), idle, null));

            // Per-door start pages.
            var doors = ReadRecords("doors");
            var doorIds = new List<string>(doors.Keys);
            doorIds.Sort(StringComparer.Ordinal);
            foreach (string doorId in doorIds)
            {
                string door = doorId;
                var options = new List<SettingOption> { new SettingOption("", "flow_editor.door_start_inherit") };
                options.AddRange(pages);
                var combo = FlowCombo(options, _store.Get("doors." + door + ".visitor_flow.start") ?? "", value =>
                {
                    string chosen = Convert.ToString(value, CultureInfo.InvariantCulture);
                    FlowCommit(chosen.Length == 0 ? null : FlowSet("doors." + door + ".visitor_flow.start", chosen),
                               chosen.Length == 0 ? new List<string> { "doors." + door + ".visitor_flow.start" } : null,
                               result => { if (!Report(result, parts)) Refresh(); });
                });
                panel.Children.Add(FlowField(Texts.T("flow_editor.door_start") + ": " +
                    LabelText(doors[door].ContainsKey("label") ? doors[door]["label"] : null, door), combo, null));
            }

            // require_call: an administrator setting, with the warning when it is off.
            bool requireCall = SettingsStore.AsBool(_store.Get("visitor_flow.require_call"), true);
            var requireSwitch = DoorbellApp.Ui.Fluent.Switch(requireCall);
            AutomationLabel(requireSwitch, Texts.T("flow_editor.require_call"));
            AutomationId(requireSwitch, "FlowRequireCall");
            var warning = FieldHint(Texts.T("flow_editor.require_call_off_warning"));
            warning.Visibility = requireCall ? Visibility.Collapsed : Visibility.Visible;
            bool revertingRequire = false;
            requireSwitch.Toggled += (s, e) =>
            {
                if (revertingRequire) return;
                bool next = requireSwitch.IsOn;
                FlowCommit(FlowSet("visitor_flow.require_call", next), null, result =>
                {
                    if (Report(result, parts))
                    {
                        warning.Visibility = next ? Visibility.Collapsed : Visibility.Visible;
                        return;
                    }
                    revertingRequire = true;
                    requireSwitch.IsOn = !next;
                    revertingRequire = false;
                });
            };
            var requireLine = new DockPanel { Margin = new Thickness(0, 14, 0, 0) };
            DockPanel.SetDock(requireSwitch, Dock.Right);
            requireLine.Children.Add(requireSwitch);
            requireLine.Children.Add(new TextBlock
            {
                Text = Texts.T("flow_editor.require_call"),
                FontSize = 15,
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center,
            });
            panel.Children.Add(requireLine);
            panel.Children.Add(warning);

            // Steps.
            var stepsHead = new DockPanel { Margin = new Thickness(0, 22, 0, 0) };
            var add = CommandButton(Texts.T("flow_editor.add_step"));
            AutomationId(add, "FlowAddStep");
            add.IsEnabled = steps.Count < MaxFlowSteps;
            DockPanel.SetDock(add, Dock.Right);
            stepsHead.Children.Add(add);
            stepsHead.Children.Add(new TextBlock
            {
                Text = Texts.T("flow_editor.steps"),
                FontSize = 17,
                VerticalAlignment = VerticalAlignment.Center,
            });
            panel.Children.Add(stepsHead);
            add.Click += (s, e) => AddFlowStep(parts);
            foreach (string id in FlowStepOrder(steps))
                panel.Children.Add(FlowStepLine(id, (Dictionary<string, object>)steps[id], steps, parts));

            panel.Children.Add(FlowTemplateButtons(parts, true));
            return panel;
        }

        private FrameworkElement FlowStepLine(string id, Dictionary<string, object> step,
                                              Dictionary<string, object> steps, RowParts parts)
        {
            string kind = Str(step, "kind");
            string subtitle = id;
            if (kind == "page")
            {
                int count = step.ContainsKey("options") && step["options"] is IList ? ((IList)step["options"]).Count : 0;
                subtitle = id + " · " + Texts.T("flow_editor.field_options") + " " + count;
            }
            var edit = CommandButton(Texts.T("admin.edit"));
            var copy = CommandButton(Texts.T("flow_editor.duplicate_step"));
            var remove = CommandButton(Texts.T("flow_editor.delete_step"));
            DoorbellApp.Ui.Fluent.MakeDestructive(remove);
            edit.IsEnabled = kind == "page" || kind == "call" || kind == "notify" || kind == "end";
            copy.IsEnabled = steps.Count < MaxFlowSteps;
            AutomationId(edit, "FlowStepEdit");
            AutomationLabel(edit, Texts.T("admin.edit") + " " + id);
            AutomationLabel(copy, Texts.T("flow_editor.duplicate_step") + " " + id);
            AutomationLabel(remove, Texts.T("flow_editor.delete_step") + " " + id);
            edit.Click += (s, e) =>
            {
                if (EditFlowStep(id, step, false, null)) Refresh();
            };
            copy.Click += (s, e) =>
            {
                var duplicate = DeepCopy(step);
                string copyId = FlowNewId(id.Length > 24 ? "s_" : id + "_", steps);
                if (copyId.Length > 32) copyId = FlowNewId("s_", steps);
                FlowCommit(FlowSet("visitor_flow.steps." + copyId, duplicate), null, result =>
                {
                    if (Report(result, parts)) Refresh();
                });
            };
            remove.Click += (s, e) =>
            {
                var users = FlowReferrers(id, steps);
                if (users.Count > 0)
                {
                    parts.Error.Text = Texts.T("flow_editor.step_in_use", string.Join(", ", users));
                    parts.Error.Visibility = Visibility.Visible;
                    return;
                }
                if (!Confirm(Texts.T("admin.confirm_delete", FlowStepLabel(id, step)), true)) return;
                FlowCommit(null, new List<string> { "visitor_flow.steps." + id }, result =>
                {
                    if (Report(result, parts)) Refresh();
                });
            };
            return ItemLine(FlowStepLabel(id, step), subtitle, new[] { edit, copy, remove });
        }

        private FrameworkElement FlowTemplateButtons(RowParts parts, bool explicitSteps)
        {
            var panel = new StackPanel { Margin = new Thickness(0, 22, 0, 0) };
            panel.Children.Add(new TextBlock { Text = Texts.T("flow_editor.templates"), FontSize = 17 });
            var bar = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
            if (!explicitSteps)
            {
                var customize = CommandButton(Texts.T("flow_editor.customize"));
                AutomationId(customize, "FlowTemplateDefault");
                customize.Click += (s, e) => ApplyFlowTemplate("default", parts);
                bar.Children.Add(customize);
            }
            var purposes = CommandButton(Texts.T("flow_editor.template_purposes"));
            var delivery = CommandButton(Texts.T("flow_editor.template_delivery"));
            AutomationId(purposes, "FlowTemplatePurposes");
            AutomationId(delivery, "FlowTemplateDelivery");
            purposes.Click += (s, e) => ApplyFlowTemplate("purposes", parts);
            delivery.Click += (s, e) => ApplyFlowTemplate("delivery", parts);
            bar.Children.Add(purposes);
            bar.Children.Add(delivery);
            if (_store.Get("visitor_flow") != null)
            {
                var reset = CommandButton(Texts.T("flow_editor.reset_default"));
                DoorbellApp.Ui.Fluent.MakeDestructive(reset);
                AutomationId(reset, "FlowReset");
                reset.Click += (s, e) =>
                {
                    if (!Confirm(Texts.T("flow_editor.reset_default_confirm"), true)) return;
                    // Deleting visitor_flow is one delete operation: the built-in wizard returns.
                    FlowCommit(null, new List<string> { "visitor_flow" }, result =>
                    {
                        if (Report(result, parts)) Refresh();
                    });
                };
                bar.Children.Add(reset);
            }
            foreach (UIElement child in bar.Children)
                ((FrameworkElement)child).Margin = new Thickness(0, 0, 8, 8);
            panel.Children.Add(bar);
            return panel;
        }

        /// <summary>
        /// A template arrives in configuration shape and is written as ordinary keys, with delete
        /// operations for the steps that go away, all in one batch.
        /// </summary>
        private void ApplyFlowTemplate(string name, RowParts parts)
        {
            bool explicitSteps = FlowHasExplicitSteps();
            if (explicitSteps && !Confirm(Texts.T("flow_editor.template_confirm"), true)) return;
            var existing = new List<string>(FlowSteps().Keys);
            Task.Run(() =>
            {
                string json = null;
                try { json = App.Core == null ? null : App.Core.VisitorFlowTemplateJson(name); }
                catch (Exception) { }
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    Dictionary<string, object> flow = null;
                    try
                    {
                        var doc = json == null ? null :
                            new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.Deserialize<Dictionary<string, object>>(json);
                        object ok;
                        if (doc != null && doc.TryGetValue("ok", out ok) && ok is bool && (bool)ok && doc.ContainsKey("flow"))
                            flow = doc["flow"] as Dictionary<string, object>;
                    }
                    catch (ArgumentException) { }
                    catch (InvalidOperationException) { }
                    if (flow == null)
                    {
                        Report(new SettingsWriteResult { Error = "visitor_flow.invalid: template" }, parts);
                        return;
                    }
                    var sets = new List<KeyValuePair<string, object>>();
                    foreach (string leaf in new[] { "enabled", "start", "idle_s", "require_call" })
                        if (flow.ContainsKey(leaf) && flow[leaf] != null)
                            sets.Add(new KeyValuePair<string, object>("visitor_flow." + leaf, flow[leaf]));
                    var templateSteps = flow.ContainsKey("steps") ? flow["steps"] as Dictionary<string, object> : null;
                    var deletes = new List<string>();
                    if (templateSteps != null)
                        foreach (var pair in templateSteps)
                            sets.Add(new KeyValuePair<string, object>("visitor_flow.steps." + pair.Key, pair.Value));
                    foreach (string old in existing)
                        if (templateSteps == null || !templateSteps.ContainsKey(old))
                            deletes.Add("visitor_flow.steps." + old);
                    FlowCommit(sets, deletes, result =>
                    {
                        if (Report(result, parts)) Refresh();
                    });
                }));
            });
        }

        // ---- small controls -------------------------------------------------------------------------

        private FrameworkElement FlowField(string label, FrameworkElement control, string hint)
        {
            var stack = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
            stack.Children.Add(new TextBlock { Text = label, FontSize = 15, TextWrapping = TextWrapping.Wrap });
            control.Margin = new Thickness(0, 6, 0, 0);
            stack.Children.Add(control);
            if (!string.IsNullOrEmpty(hint)) stack.Children.Add(FieldHint(hint));
            return stack;
        }

        private ComboBox FlowCombo(List<SettingOption> options, object value, Action<object> changed)
        {
            var combo = new ComboBox { Style = (Style)FindResource("SettingsComboBox"), HorizontalAlignment = HorizontalAlignment.Left,
                                       MinWidth = 280, MaxWidth = 640 };
            foreach (var option in options)
                combo.Items.Add(new ComboBoxItem { Content = OptionText(option), MinHeight = MinTouchTarget });
            combo.SelectedIndex = IndexOf(options, value);
            int current = combo.SelectedIndex;
            combo.SelectionChanged += (s, e) =>
            {
                int index = combo.SelectedIndex;
                if (index < 0 || index == current) return;
                current = index;
                changed(options[index].Value);
            };
            return combo;
        }

        // ---- adding and editing a step ----------------------------------------------------------

        private void AddFlowStep(RowParts parts)
        {
            var steps = FlowSteps();
            if (steps.Count >= MaxFlowSteps) return;
            var data = new Dictionary<string, object> { { "kind", "page" } };
            var field = Fld("kind", FieldKind.Choice, "flow_editor.steps");
            field.Required = true;
            field.Options = new List<SettingOption>
            {
                new SettingOption("page", "flow_editor.kind_page"),
                new SettingOption("call", "flow_editor.kind_call"),
                new SettingOption("notify", "flow_editor.kind_notify"),
                new SettingOption("end", "flow_editor.kind_end"),
            };
            if (!ShowForm(Texts.T("flow_editor.add_step"), new List<Field> { field }, data)) return;
            string kind = Str(data, "kind");
            string prefix = kind == "page" ? "s_" : kind == "call" ? "c_" : kind == "notify" ? "n_" : "e_";
            string id = FlowNewId(prefix, steps);
            var seeds = new Dictionary<string, Dictionary<string, object>>();
            var step = new Dictionary<string, object> { { "kind", kind } };
            if (kind == "page")
            {
                // A page needs something to press: one primary option leading to a call.
                string call = FirstStepOfKind(steps, "call");
                if (call == null)
                {
                    call = FlowNewId("c_", steps);
                    seeds[call] = new Dictionary<string, object> { { "kind", "call" } };
                }
                var labels = new Dictionary<string, object>();
                foreach (string lang in FlowLanguages())
                    labels[lang] = Texts.T("idle.call");
                step["options"] = new List<object>
                {
                    new Dictionary<string, object>
                    {
                        { "id", FlowNewId("o_", null) }, { "label", labels }, { "style", "primary" }, { "to", call },
                    },
                };
            }
            else if (kind == "notify")
            {
                string end = FirstStepOfKind(steps, "end");
                if (end == null)
                {
                    end = FlowNewId("e_", steps);
                    var title = new Dictionary<string, object>();
                    foreach (string lang in FlowLanguages()) title[lang] = Texts.T("flow.sent");
                    seeds[end] = new Dictionary<string, object> { { "kind", "end" }, { "title", title } };
                }
                step["to"] = end;
            }
            EditFlowStep(id, step, true, seeds);
            Refresh();
        }

        private static string FirstStepOfKind(Dictionary<string, object> steps, string kind)
        {
            foreach (var pair in steps)
                if (Str((Dictionary<string, object>)pair.Value, "kind") == kind) return pair.Key;
            return null;
        }

        private TextBox FlowMultiline(string text, int maxLength)
        {
            var box = FormTextBox(text, maxLength);
            box.AcceptsReturn = true;
            box.TextWrapping = TextWrapping.Wrap;
            box.MinHeight = 88;
            box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            return box;
        }

        private void AddFlowTexts(StackPanel form, Dictionary<string, object> step, string key,
                                  string labelKey, int maxLength, bool multiline, List<FlowReader> readers)
        {
            var existing = step.ContainsKey(key) ? step[key] as Dictionary<string, object> : null;
            var boxes = new List<KeyValuePair<string, TextBox>>();
            foreach (string lang in FlowLanguages())
            {
                string label = Texts.T(labelKey) + " (" + LangName(lang) + ")";
                form.Children.Add(FieldLabel(label));
                TextBox box = multiline ? FlowMultiline(Str(existing, lang), maxLength)
                                        : FormTextBox(Str(existing, lang), maxLength);
                AutomationLabel(box, label);
                form.Children.Add(box);
                boxes.Add(new KeyValuePair<string, TextBox>(lang, box));
            }
            readers.Add(next =>
            {
                var map = next.ContainsKey(key) ? next[key] as Dictionary<string, object> : null;
                if (map == null) map = new Dictionary<string, object>();
                foreach (var pair in boxes)
                {
                    string text = pair.Value.Text.Replace("\r\n", "\n").Replace('\r', '\n').Trim();
                    if (text.Length == 0) map.Remove(pair.Key);
                    else map[pair.Key] = text;
                }
                if (map.Count == 0) next.Remove(key);
                else next[key] = map;
                return null;
            });
        }

        private void AddFlowField(StackPanel form, Dictionary<string, object> step, Field field,
                                  List<FlowReader> readers)
        {
            object raw = GetPath(step, field.Path);
            object value = field.Load != null ? field.Load(raw) : raw;
            Func<Dictionary<string, object>, string> reader = BuildField(form, field, value);
            readers.Add(next => reader(next));
        }

        /// <summary>
        /// The step dialog. Save writes the whole step (and any seed step it needs) as one batch on
        /// the write lane and keeps the dialog open, with Core's message, when Core refuses.
        /// Returns true when a write was committed.
        /// </summary>
        private bool EditFlowStep(string id, Dictionary<string, object> original, bool isNew,
                                  Dictionary<string, Dictionary<string, object>> seeds)
        {
            string kind = Str(original, "kind");
            var steps = FlowSteps();
            StackPanel form, actions;
            TextBlock error;
            Window dialog = FormWindow(FlowKindName(kind) + " · " + id, out form, out actions,
                                       out error, 760);
            var readers = new List<FlowReader>();
            var imageOwner = new RowParts { Error = error };
            Window previousOwner = _formOwner;
            _formOwner = dialog;
            SettingsWriteResult committed = null;
            bool closed = false;
            dialog.Closed += (s, e) => closed = true;
            try
            {
                if (kind == "page" || kind == "end")
                {
                    AddFlowTexts(form, original, "title", "flow_editor.field_title", 60, false, readers);
                    AddFlowTexts(form, original, "body", "flow_editor.field_body", 600, true, readers);
                    AddFlowImages(form, original, imageOwner, readers);
                }
                if (kind == "page") AddFlowOptions(form, original, steps, id, readers);
                if (kind == "call")
                {
                    var purpose = Fld("purpose", FieldKind.Choice, "flow_editor.field_purpose");
                    purpose.Options = FlowPurposeOptions();
                    purpose.Load = v => v ?? "";
                    purpose.Store = v => string.IsNullOrEmpty(Convert.ToString(v)) ? null : v;
                    AddFlowField(form, original, purpose, readers);
                    var unanswered = Fld("on_unanswered", FieldKind.Choice, "flow_editor.field_on_unanswered");
                    unanswered.Options = new List<SettingOption> { new SettingOption("", "flow_editor.on_unanswered_none") };
                    unanswered.Options.AddRange(FlowStepOptions(steps, "page", null));
                    unanswered.Load = v => v ?? "";
                    unanswered.Store = v => string.IsNullOrEmpty(Convert.ToString(v)) ? null : v;
                    AddFlowField(form, original, unanswered, readers);
                }
                if (kind == "notify")
                {
                    AddFlowTexts(form, original, "message", "flow_editor.field_message", 200, true, readers);
                    var purpose = Fld("purpose", FieldKind.Choice, "flow_editor.field_purpose");
                    purpose.Options = FlowPurposeOptions();
                    purpose.Load = v => v ?? "";
                    purpose.Store = v => string.IsNullOrEmpty(Convert.ToString(v)) ? null : v;
                    AddFlowField(form, original, purpose, readers);
                    AddFlowField(form, original, FlowSnapshotField(original), readers);
                    var to = Fld("to", FieldKind.Choice, "flow_editor.field_to");
                    to.Required = true;
                    to.Options = FlowStepOptions(steps, "end", null);
                    if (seeds != null)
                        foreach (var seed in seeds)
                            if (Str(seed.Value, "kind") == "end")
                                to.Options.Add(new SettingOption(seed.Key, null,
                                    Texts.T("flow_editor.kind_end") + " (" + seed.Key + ")"));
                    AddFlowField(form, original, to, readers);
                }
                if (kind == "end")
                {
                    var seconds = Fld("return_s", FieldKind.Number, "flow_editor.field_return_s");
                    seconds.Min = 3;
                    seconds.Max = 60;
                    AddFlowField(form, original, seconds, readers);
                }

                var cancel = CommandButton(Texts.T("admin.cancel"));
                var save = PrimaryButton(Texts.T("admin.save"));
                AutomationId(save, "FlowStepSave");
                AutomationId(cancel, "FlowStepCancel");
                save.Margin = new Thickness(8, 0, 0, 0);
                cancel.IsCancel = true;
                actions.Children.Add(cancel);
                actions.Children.Add(save);
                cancel.Click += (s, e) => dialog.DialogResult = false;
                save.Click += (s, e) =>
                {
                    var next = DeepCopy(original);
                    foreach (var read in readers)
                    {
                        string problem = read(next);
                        if (problem == null) continue;
                        error.Text = problem;
                        error.Visibility = Visibility.Visible;
                        return;
                    }
                    var sets = new List<KeyValuePair<string, object>>();
                    if (seeds != null)
                        foreach (var seed in seeds)
                            sets.Add(new KeyValuePair<string, object>("visitor_flow.steps." + seed.Key, seed.Value));
                    sets.Add(new KeyValuePair<string, object>("visitor_flow.steps." + id, next));
                    error.Visibility = Visibility.Collapsed;
                    save.IsEnabled = false;
                    FlowCommit(sets, null, result =>
                    {
                        if (closed)
                        {
                            // Cancelled while the write was in flight: it still counts if it landed.
                            if (result.Ok) committed = result;
                            return;
                        }
                        save.IsEnabled = true;
                        if (result.Ok)
                        {
                            committed = result;
                            dialog.DialogResult = true;
                            return;
                        }
                        error.Text = Texts.T("settings.save_failed_reason", FlowErrorText(result.Error));
                        error.Visibility = Visibility.Visible;
                    });
                };
                dialog.ShowDialog();
            }
            finally
            {
                _formOwner = previousOwner;
            }
            if (committed == null) return false;
            Report(committed, null);
            return true;
        }

        private Field FlowSnapshotField(Dictionary<string, object> step)
        {
            var field = Fld("snapshot", FieldKind.Choice, "flow_editor.field_snapshot");
            field.Options = new List<SettingOption>
            {
                new SettingOption("", "flow_editor.snapshot_none"),
                new SettingOption("door", "flow_editor.snapshot_door_station"),
            };
            var cameras = ReadRecords("media_sources");
            var ids = new List<string>(cameras.Keys);
            ids.Sort(StringComparer.Ordinal);
            bool any = false;
            foreach (string cameraId in ids)
            {
                string url = Convert.ToString(GetPath(cameras[cameraId], "streams.snapshot.url") ?? "");
                if (url.Length == 0) continue;
                any = true;
                field.Options.Add(new SettingOption("media:" + cameraId, null,
                    Texts.T("flow_editor.snapshot_camera", cameraId)));
            }
            var current = step.ContainsKey("snapshot") ? step["snapshot"] as Dictionary<string, object> : null;
            string wanted = current == null ? "" : Str(current, "source") == "door_station" ? "door"
                : Str(current, "source") == "media_source" ? "media:" + Str(current, "id") : "";
            if (wanted.StartsWith("media:", StringComparison.Ordinal) && IndexOf(field.Options, wanted) < 0)
                field.Options.Add(new SettingOption(wanted, null,
                    Texts.T("flow_editor.snapshot_camera", wanted.Substring(6))));
            if (!any) field.HintKey = "flow_editor.snapshot_no_camera";
            field.Load = v => wanted;
            field.Store = v =>
            {
                string chosen = Convert.ToString(v ?? "");
                if (chosen == "door") return new Dictionary<string, object> { { "source", "door_station" } };
                if (chosen.StartsWith("media:", StringComparison.Ordinal))
                    return new Dictionary<string, object> { { "source", "media_source" }, { "id", chosen.Substring(6) } };
                return null;
            };
            return field;
        }

        // ---- images -------------------------------------------------------------------------------

        private sealed class FlowImageRow
        {
            public Dictionary<string, object> Data;
            public Dictionary<string, TextBox> Alt = new Dictionary<string, TextBox>();
            public ComboBox Place;
        }

        private void AddFlowImages(StackPanel form, Dictionary<string, object> step, RowParts parts,
                                   List<FlowReader> readers)
        {
            var rows = new List<FlowImageRow>();
            var list = step.ContainsKey("images") ? step["images"] as IEnumerable : null;
            if (list != null && !(list is string))
                foreach (object entry in list)
                {
                    var data = entry as Dictionary<string, object>;
                    if (data != null) rows.Add(new FlowImageRow { Data = Copy(data) });
                }
            form.Children.Add(FieldLabel(Texts.T("flow_editor.field_images")));
            var host = new StackPanel();
            form.Children.Add(host);
            var bar = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
            var choose = CommandButton(Texts.T("settings.bg_choose_existing"));
            var upload = CommandButton(Texts.T("flow_editor.add_image"));
            AutomationId(choose, "FlowImageChoose");
            AutomationId(upload, "FlowImageUpload");
            choose.Margin = new Thickness(0, 0, 8, 6);
            upload.Margin = new Thickness(0, 0, 8, 6);
            upload.IsEnabled = App.Core != null && App.Core.AssetsAvailable;
            bar.Children.Add(choose);
            bar.Children.Add(upload);
            form.Children.Add(bar);

            Action harvest = () =>
            {
                foreach (var row in rows)
                {
                    var alt = new Dictionary<string, object>();
                    foreach (var pair in row.Alt)
                    {
                        string text = pair.Value.Text.Trim();
                        if (text.Length > 0) alt[pair.Key] = text;
                    }
                    if (alt.Count > 0) row.Data["alt"] = alt;
                    else row.Data.Remove("alt");
                    row.Data["place"] = row.Place.SelectedIndex == 1 ? "below" : "above";
                }
            };
            Action redraw = null;
            redraw = () =>
            {
                host.Children.Clear();
                var assets = ReadRecords("assets");
                for (int i = 0; i < rows.Count; i++)
                {
                    var row = rows[i];
                    int index = i;
                    string hash = Str(row.Data, "asset");
                    row.Alt.Clear();
                    var box = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
                    var top = new DockPanel();
                    var buttons = new StackPanel { Orientation = Orientation.Horizontal };
                    DockPanel.SetDock(buttons, Dock.Right);
                    var up = MoveButton(true);
                    var down = MoveButton(false);
                    var remove = CommandButton(Texts.T("admin.delete"));
                    DoorbellApp.Ui.Fluent.MakeDestructive(remove);
                    up.IsEnabled = index > 0;
                    down.IsEnabled = index < rows.Count - 1;
                    AutomationLabel(up, Texts.T("settings.move_up"));
                    AutomationLabel(down, Texts.T("settings.move_down"));
                    foreach (var b in new[] { up, down, remove })
                    {
                        b.Margin = new Thickness(6, 0, 0, 0);
                        buttons.Children.Add(b);
                    }
                    top.Children.Add(buttons);
                    var picture = AssetThumbnail(hash);
                    if (picture != null)
                    {
                        DockPanel.SetDock(picture, Dock.Left);
                        top.Children.Add(picture);
                    }
                    top.Children.Add(new TextBlock
                    {
                        Text = assets.ContainsKey(hash) ? AssetLabel(hash, assets[hash]) : hash,
                        FontSize = 15,
                        VerticalAlignment = VerticalAlignment.Center,
                        TextWrapping = TextWrapping.Wrap,
                    });
                    box.Children.Add(top);
                    row.Place = new ComboBox { Style = (Style)FindResource("SettingsComboBox"),
                                               HorizontalAlignment = HorizontalAlignment.Left, MinWidth = 220,
                                               Margin = new Thickness(0, 8, 0, 0) };
                    row.Place.Items.Add(new ComboBoxItem { Content = Texts.T("flow_editor.image_above"), MinHeight = MinTouchTarget });
                    row.Place.Items.Add(new ComboBoxItem { Content = Texts.T("flow_editor.image_below"), MinHeight = MinTouchTarget });
                    row.Place.SelectedIndex = Str(row.Data, "place") == "below" ? 1 : 0;
                    box.Children.Add(row.Place);
                    var existing = row.Data.ContainsKey("alt") ? row.Data["alt"] as Dictionary<string, object> : null;
                    foreach (string lang in FlowLanguages())
                    {
                        string label = Texts.T("flow_editor.image_alt") + " (" + LangName(lang) + ")";
                        box.Children.Add(FieldLabel(label));
                        var alt = FormTextBox(Str(existing, lang), 120);
                        AutomationLabel(alt, label);
                        box.Children.Add(alt);
                        row.Alt[lang] = alt;
                    }
                    up.Click += (s, e) => { harvest(); Swap(rows, index, index - 1); redraw(); };
                    down.Click += (s, e) => { harvest(); Swap(rows, index, index + 1); redraw(); };
                    remove.Click += (s, e) => { harvest(); rows.RemoveAt(index); redraw(); };
                    host.Children.Add(box);
                }
                choose.IsEnabled = rows.Count < MaxFlowImages && AssetList("image/").Count > 0;
                upload.IsEnabled = rows.Count < MaxFlowImages && App.Core != null && App.Core.AssetsAvailable;
            };
            choose.Click += (s, e) =>
            {
                var data = new Dictionary<string, object>();
                var field = Fld("hash", FieldKind.Choice, "flow_editor.field_images");
                field.Required = true;
                field.Options = new List<SettingOption>();
                foreach (var asset in AssetList("image/"))
                    field.Options.Add(new SettingOption(asset.Key, null, AssetLabel(asset.Key, asset.Value)));
                if (!ShowForm(Texts.T("flow_editor.add_image"), new List<Field> { field }, data)) return;
                harvest();
                rows.Add(new FlowImageRow { Data = new Dictionary<string, object> { { "asset", Str(data, "hash") }, { "place", "above" } } });
                redraw();
            };
            upload.Click += (s, e) =>
            {
                string hash = UploadAsset("image/", parts, true);
                if (hash == null) return;
                harvest();
                rows.Add(new FlowImageRow { Data = new Dictionary<string, object> { { "asset", hash }, { "place", "above" } } });
                redraw();
            };
            redraw();
            readers.Add(next =>
            {
                harvest();
                var images = new List<object>();
                foreach (var row in rows) images.Add(row.Data);
                if (images.Count == 0) next.Remove("images");
                else next["images"] = images;
                return null;
            });
        }

        // ---- options ------------------------------------------------------------------------------

        private void AddFlowOptions(StackPanel form, Dictionary<string, object> step,
                                    Dictionary<string, object> steps, string selfId, List<FlowReader> readers)
        {
            var options = new List<Dictionary<string, object>>();
            var list = step.ContainsKey("options") ? step["options"] as IEnumerable : null;
            if (list != null && !(list is string))
                foreach (object entry in list)
                {
                    var data = entry as Dictionary<string, object>;
                    if (data != null) options.Add(Copy(data));
                }
            form.Children.Add(FieldLabel(Texts.T("flow_editor.field_options")));
            var host = new StackPanel();
            form.Children.Add(host);
            var add = CommandButton(Texts.T("flow_editor.add_option"));
            AutomationId(add, "FlowAddOption");
            add.Margin = new Thickness(0, 6, 0, 0);
            add.HorizontalAlignment = HorizontalAlignment.Left;
            form.Children.Add(add);

            Action redraw = null;
            redraw = () =>
            {
                host.Children.Clear();
                for (int i = 0; i < options.Count; i++)
                {
                    int index = i;
                    var option = options[i];
                    var up = MoveButton(true);
                    var down = MoveButton(false);
                    var edit = CommandButton(Texts.T("admin.edit"));
                    var remove = CommandButton(Texts.T("admin.delete"));
                    DoorbellApp.Ui.Fluent.MakeDestructive(remove);
                    up.IsEnabled = index > 0;
                    down.IsEnabled = index < options.Count - 1;
                    AutomationLabel(up, Texts.T("settings.move_up"));
                    AutomationLabel(down, Texts.T("settings.move_down"));
                    AutomationId(edit, "FlowOptionEdit");
                    string target = Str(option, "to");
                    string title = LabelText(option.ContainsKey("label") ? option["label"] : null, "");
                    if (title.Length == 0) title = FlowPurposeName(Str(option, "purpose"));
                    if (Str(option, "style") == "primary") title += " *";
                    if (option.ContainsKey("enabled") && !SettingsStore.AsBool(option["enabled"], true)) title += " (-)";
                    string sub = "-> " + (steps.ContainsKey(target) ? FlowStepLabel(target, (Dictionary<string, object>)steps[target]) : target);
                    host.Children.Add(ItemLine(title, sub, new[] { up, down, edit, remove }));
                    up.Click += (s, e) => { Swap(options, index, index - 1); redraw(); };
                    down.Click += (s, e) => { Swap(options, index, index + 1); redraw(); };
                    edit.Click += (s, e) => { if (EditFlowOption(option, steps, selfId, options)) redraw(); };
                    remove.Click += (s, e) => { options.RemoveAt(index); redraw(); };
                }
                add.IsEnabled = options.Count < MaxFlowOptions;
            };
            add.Click += (s, e) =>
            {
                string firstTarget = null;
                var targets = FlowStepOptions(steps, null, selfId);
                if (targets.Count > 0) firstTarget = Convert.ToString(targets[0].Value);
                var created = new Dictionary<string, object>
                {
                    { "id", FlowNewId("o_", null) },
                };
                if (firstTarget != null) created["to"] = firstTarget;
                if (EditFlowOption(created, steps, selfId, options)) { options.Add(created); redraw(); }
            };
            redraw();
            readers.Add(next =>
            {
                if (options.Count == 0) return Texts.T("visitor_flow.no_options");
                var written = new List<object>();
                foreach (var option in options) written.Add(option);
                next["options"] = written;
                return null;
            });
        }

        /// <summary>Edits one option in place (the step is written on Save). False when cancelled.</summary>
        private bool EditFlowOption(Dictionary<string, object> option, Dictionary<string, object> steps,
                                    string selfId, List<Dictionary<string, object>> siblings)
        {
            var fields = new List<Field>();
            var purpose = Fld("purpose", FieldKind.Choice, "flow_editor.option_purpose");
            purpose.Options = FlowPurposeOptions();
            purpose.Load = v => v ?? "";
            purpose.Store = v => string.IsNullOrEmpty(Convert.ToString(v)) ? null : v;
            fields.Add(purpose);
            foreach (string lang in FlowLanguages())
            {
                var label = Fld("label." + lang, FieldKind.Text, null);
                label.Label = Texts.T("flow_editor.option_label") + " (" + LangName(lang) + ")";
                label.MaxLength = 40;
                fields.Add(label);
            }
            var icon = Fld("icon", FieldKind.Text, "flow_editor.option_icon");
            icon.MaxLength = 8;
            fields.Add(icon);
            var primary = Fld("style", FieldKind.Bool, "flow_editor.option_primary");
            primary.Load = v => Convert.ToString(v) == "primary";
            primary.Store = v => (bool)v ? "primary" : null;
            fields.Add(primary);
            var shown = Fld("enabled", FieldKind.Bool, "flow_editor.option_enabled");
            shown.Load = v => v == null || SettingsStore.AsBool(v, true);
            shown.Store = v => (bool)v ? null : (object)false;
            fields.Add(shown);
            var to = Fld("to", FieldKind.Choice, "flow_editor.option_target");
            to.Required = true;
            to.Options = FlowStepOptions(steps, null, selfId);
            fields.Add(to);
            var data = Copy(option);
            bool saved = ShowForm(Texts.T("flow_editor.field_options"), fields, data, draft =>
            {
                var label = draft.ContainsKey("label") ? draft["label"] as Dictionary<string, object> : null;
                bool hasLabel = label != null && label.Count > 0;
                if (!hasLabel && Str(draft, "purpose").Length == 0)
                    return Texts.T("visitor_flow.option_needs_label");
                return null;
            });
            if (!saved) return false;
            option.Clear();
            foreach (var pair in data) option[pair.Key] = pair.Value;
            // At most one primary option on a page.
            if (Str(option, "style") == "primary")
                foreach (var other in siblings)
                    if (!ReferenceEquals(other, option)) other.Remove("style");
            return true;
        }
    }
}
