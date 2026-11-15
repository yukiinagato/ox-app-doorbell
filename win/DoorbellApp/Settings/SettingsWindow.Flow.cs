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

        /// <summary>
        /// The message lines of the open step dialog, by control: "title.ja", "body.en", "message.zh",
        /// "option.o_id", "image.0", "image.0.ja". Rows that redraw register their lines again.
        /// </summary>
        private sealed class FlowErrorSite
        {
            public TextBlock Header;
            public readonly Dictionary<string, TextBlock> Lines = new Dictionary<string, TextBlock>();
            public readonly Dictionary<string, Control> Inputs = new Dictionary<string, Control>();
        }

        private FlowErrorSite _flowSite;

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
            return FlowEditorModel.Links(step);
        }

        /// <summary>Core's step_order: the steps with an order first, then reading order.</summary>
        private List<string> FlowStepOrder(Dictionary<string, object> steps)
        {
            return FlowEditorModel.Sequence(steps,
                Convert.ToString(_store.Get("visitor_flow.start") ?? "", CultureInfo.InvariantCulture));
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
        internal static string FlowErrorText(string error, Dictionary<string, object> detail = null)
        {
            if (string.IsNullOrEmpty(error)) return "";
            if (error == "unresolved_config_conflict") return Texts.T("flow_editor.conflict");
            FlowErrorInfo info = FlowError.Parse(error, detail);
            return info.IsFlow ? FlowErrorMessage(info) : error;
        }

        /// <summary>
        /// flow_error.code with its numbers and language filled in; a code this build does not
        /// know gets the generic message and the raw code beside it.
        /// </summary>
        private static string FlowErrorMessage(FlowErrorInfo info)
        {
            string key = "flow_error." + info.Code;
            string text = Texts.T(key);
            if (string.IsNullOrEmpty(text) || text == key)
                return Texts.T("visitor_flow.invalid", info.Code + (info.Location.Length > 0 ? ": " + info.Location : ""));
            return FlowError.Fill(text, info, LangName);
        }

        private TextBlock NewFlowLine(string key, Control input)
        {
            var line = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap,
                                       Visibility = Visibility.Collapsed, Margin = new Thickness(0, 2, 0, 0) };
            line.SetResourceReference(TextBlock.ForegroundProperty, "NegativeText");
            AutomationId(line, "FlowFieldError");
            if (_flowSite != null)
            {
                _flowSite.Lines[key] = line;
                if (input != null) _flowSite.Inputs[key] = input;
            }
            return line;
        }

        private static void ShowFlowLine(TextBlock line, string text, bool problem)
        {
            line.SetResourceReference(TextBlock.ForegroundProperty, problem ? "NegativeText" : "AccentText");
            line.Text = text;
            line.Visibility = Visibility.Visible;
            line.BringIntoView();
        }

        /// <summary>
        /// Puts a refused write beside the control Core named in the open step dialog (the
        /// language field, the option row, the image row), else in the header of the form.
        /// </summary>
        private bool ShowFlowFieldError(string stepId, SettingsWriteResult result)
        {
            FlowErrorInfo info = FlowError.Parse(result.Error, result.Detail);
            if (_flowSite == null || !info.IsFlow) return false;
            string text = FlowErrorMessage(info);
            string key = null;
            if (info.Step == stepId)
            {
                if (info.Place == FlowErrorPlace.Field && info.Lang.Length > 0) key = info.Field + "." + info.Lang;
                else if (info.Place == FlowErrorPlace.Option) key = "option." + info.Option;
                else if (info.Place == FlowErrorPlace.Image)
                    key = info.Lang.Length > 0 && _flowSite.Lines.ContainsKey("image." + info.Image + "." + info.Lang)
                        ? "image." + info.Image + "." + info.Lang : "image." + info.Image;
            }
            TextBlock line;
            if (key == null || !_flowSite.Lines.TryGetValue(key, out line)) line = _flowSite.Header;
            ShowFlowLine(line, text, true);
            Control input;
            if (key != null && _flowSite.Inputs.TryGetValue(key, out input)) input.Focus();
            return true;
        }

        /// <summary>
        /// A start page refused by Core shows under its picker (door is "" for the shared start);
        /// anything else goes to the banner at the top of the editor.
        /// </summary>
        private bool ReportFlowStart(SettingsWriteResult result, RowParts parts, TextBlock line, string door)
        {
            line.Visibility = Visibility.Collapsed;
            if (!result.Ok)
            {
                FlowErrorInfo info = FlowError.Parse(result.Error, result.Detail);
                if (info.IsFlow && info.Place == FlowErrorPlace.Start && info.Option == door)
                {
                    ShowFlowLine(line, FlowErrorMessage(info), true);
                    return false;
                }
            }
            return Report(result, parts);
        }

        private TextBlock NewFlowHeader()
        {
            var line = new TextBlock { FontSize = 14, TextWrapping = TextWrapping.Wrap,
                                       Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 10) };
            AutomationId(line, "FlowStepError");
            return line;
        }

        private TextBlock NewStartLine()
        {
            var line = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap,
                                       Visibility = Visibility.Collapsed, Margin = new Thickness(0, 2, 0, 0) };
            AutomationId(line, "FlowFieldError");
            return line;
        }

        /// <summary>Notes for the open step: a warning of a write that succeeded, beside its option.</summary>
        private bool ShowFlowNotes(string stepId, SettingsWriteResult result)
        {
            bool shown = false;
            string head = "visitor_flow.steps." + stepId;
            foreach (var note in result.Notes)
            {
                if (note.Key != head && !note.Key.StartsWith(head + ".", StringComparison.Ordinal)) continue;
                FlowErrorInfo info = FlowError.Parse(note.Value + ": " + note.Key.Substring("visitor_flow.steps.".Length), null);
                TextBlock line;
                string optionKey = info.Place == FlowErrorPlace.Option ? "option." + info.Option : "";
                if (!_flowSite.Lines.TryGetValue(optionKey, out line)) line = _flowSite.Header;
                ShowFlowLine(line, FlowErrorMessage(info), false);
                shown = true;
            }
            return shown;
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
            var startLine = NewStartLine();
            var start = FlowCombo(pages, _store.Get("visitor_flow.start"), value =>
            {
                startLine.Visibility = Visibility.Collapsed;
                FlowCommit(FlowSet("visitor_flow.start", value), null, result =>
                {
                    if (ReportFlowStart(result, parts, startLine, "")) return;
                    if (startLine.Visibility != Visibility.Visible) Refresh();
                });
            });
            AutomationId(start, "FlowStart");
            panel.Children.Add(FlowField(Texts.T("flow_editor.start"), start, null));
            panel.Children.Add(startLine);

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
                var doorLine = NewStartLine();
                var combo = FlowCombo(options, _store.Get("doors." + door + ".visitor_flow.start") ?? "", value =>
                {
                    string chosen = Convert.ToString(value, CultureInfo.InvariantCulture);
                    doorLine.Visibility = Visibility.Collapsed;
                    FlowCommit(chosen.Length == 0 ? null : FlowSet("doors." + door + ".visitor_flow.start", chosen),
                               chosen.Length == 0 ? new List<string> { "doors." + door + ".visitor_flow.start" } : null,
                               result =>
                               {
                                   if (!ReportFlowStart(result, parts, doorLine, door) &&
                                       doorLine.Visibility != Visibility.Visible) Refresh();
                               });
                });
                panel.Children.Add(FlowField(Texts.T("flow_editor.door_start") + ": " +
                    LabelText(doors[door].ContainsKey("label") ? doors[door]["label"] : null, door), combo, null));
                panel.Children.Add(doorLine);
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
            var tryIt = CommandButton(Texts.T("flow_editor.preview"));
            AutomationId(tryIt, "FlowPreview");
            tryIt.Margin = new Thickness(0, 0, 8, 0);
            DockPanel.SetDock(tryIt, Dock.Right);
            stepsHead.Children.Add(tryIt);
            tryIt.Click += (s, e) => ShowFlowPreview(steps,
                Convert.ToString(_store.Get("visitor_flow.start") ?? "", CultureInfo.InvariantCulture),
                null, null, parts.Error);
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
                duplicate.Remove("order");
                string copyId = FlowNewId(id.Length > 24 ? "s_" : id + "_", steps);
                if (copyId.Length > 32) copyId = FlowNewId("s_", steps);
                // The copy lists right after the original: everything from there on is renumbered.
                var sequence = FlowStepOrder(steps);
                var withCopy = new Dictionary<string, object>(steps) { { copyId, duplicate } };
                var writes = FlowEditorModel.Renumber(withCopy,
                    FlowEditorModel.InsertAfter(sequence, id, copyId));
                FlowCommit(FlowWrites(writes), null, result =>
                {
                    if (Report(result, parts)) Refresh();
                });
            };
            var sequenceNow = FlowStepOrder(steps);
            int position = sequenceNow.IndexOf(id);
            var up = MoveButton(true);
            var down = MoveButton(false);
            up.IsEnabled = position > 0;
            down.IsEnabled = position >= 0 && position < sequenceNow.Count - 1;
            AutomationId(up, "FlowStepUp");
            AutomationId(down, "FlowStepDown");
            AutomationLabel(up, Texts.T("settings.move_up") + " " + id);
            AutomationLabel(down, Texts.T("settings.move_down") + " " + id);
            up.Click += (s, e) => MoveFlowStep(steps, id, -1, parts);
            down.Click += (s, e) => MoveFlowStep(steps, id, 1, parts);
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
            return ItemLine(FlowStepLabel(id, step), subtitle, new[] { up, down, edit, copy, remove });
        }

        private static List<KeyValuePair<string, object>> FlowWrites(
            List<KeyValuePair<string, Dictionary<string, object>>> steps)
        {
            var sets = new List<KeyValuePair<string, object>>();
            foreach (var step in steps)
                sets.Add(new KeyValuePair<string, object>("visitor_flow.steps." + step.Key, step.Value));
            return sets;
        }

        /// <summary>
        /// Moves a step one place: the whole sequence gets consecutive order values and every
        /// step whose order changed is rewritten as a whole step, all in one batch.
        /// </summary>
        private void MoveFlowStep(Dictionary<string, object> steps, string id, int delta, RowParts parts)
        {
            var moved = FlowEditorModel.Move(FlowStepOrder(steps), id, delta);
            var writes = FlowEditorModel.Renumber(steps, moved);
            if (writes.Count == 0) return;
            FlowCommit(FlowWrites(writes), null, result =>
            {
                if (Report(result, parts)) Refresh();
            });
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
                TextBlock line = NewFlowLine(key + "." + lang, box);
                box.TextChanged += (s, e) => line.Visibility = Visibility.Collapsed;
                form.Children.Add(line);
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
            FlowErrorSite previousSite = _flowSite;
            _formOwner = dialog;
            _flowSite = new FlowErrorSite { Header = NewFlowHeader() };
            form.Children.Add(_flowSite.Header);
            form.AddHandler(System.Windows.Controls.Primitives.TextBoxBase.TextChangedEvent,
                new TextChangedEventHandler((s, e) => _flowSite.Header.Visibility = Visibility.Collapsed));
            form.AddHandler(System.Windows.Controls.Primitives.Selector.SelectionChangedEvent,
                new SelectionChangedEventHandler((s, e) => _flowSite.Header.Visibility = Visibility.Collapsed));
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
                if (kind == "page")
                {
                    var tryDraft = CommandButton(Texts.T("flow_editor.preview"));
                    AutomationId(tryDraft, "FlowStepPreview");
                    tryDraft.Margin = new Thickness(0, 0, 8, 0);
                    actions.Children.Add(tryDraft);
                    tryDraft.Click += (s, e) =>
                    {
                        var draft = DeepCopy(original);
                        foreach (var read in readers)
                        {
                            string problem = read(draft);
                            if (problem == null) continue;
                            error.Text = problem;
                            error.Visibility = Visibility.Visible;
                            return;
                        }
                        error.Visibility = Visibility.Collapsed;
                        var draftSteps = new Dictionary<string, object>(steps);
                        if (seeds != null)
                            foreach (var seed in seeds) draftSteps[seed.Key] = seed.Value;
                        // The draft page is the start: it may not be reachable from the saved start yet.
                        ShowFlowPreview(draftSteps, id, id, draft, error);
                    };
                }
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
                        ShowFlowLine(_flowSite.Header, problem, true);
                        return;
                    }
                    var sets = new List<KeyValuePair<string, object>>();
                    if (isNew)
                    {
                        // A new step lists last: the sequence is renumbered with it at the end, so
                        // only steps whose order changes are written (all of them the first time).
                        var withNew = new Dictionary<string, object>(steps);
                        var sequence = FlowStepOrder(steps);
                        if (seeds != null)
                            foreach (var seed in seeds)
                            {
                                withNew[seed.Key] = seed.Value;
                                sequence.Add(seed.Key);
                            }
                        withNew[id] = next;
                        sequence.Add(id);
                        sets = FlowWrites(FlowEditorModel.Renumber(withNew, sequence));
                    }
                    else
                    {
                        sets.Add(new KeyValuePair<string, object>("visitor_flow.steps." + id, next));
                    }
                    error.Visibility = Visibility.Collapsed;
                    foreach (TextBlock line in _flowSite.Lines.Values) line.Visibility = Visibility.Collapsed;
                    _flowSite.Header.Visibility = Visibility.Collapsed;
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
                            // A warning is not a refusal: the step is saved. The note stays beside
                            // its option until the dialog is closed.
                            if (ShowFlowNotes(id, result))
                            {
                                cancel.Content = Texts.T("settings.close");
                                return;
                            }
                            dialog.DialogResult = true;
                            return;
                        }
                        if (ShowFlowFieldError(id, result)) return;
                        error.Text = Texts.T("settings.save_failed_reason", FlowErrorText(result.Error, result.Detail));
                        error.Visibility = Visibility.Visible;
                    });
                };
                dialog.ShowDialog();
            }
            finally
            {
                _formOwner = previousOwner;
                _flowSite = previousSite;
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

        // ---- preview ("try it") -------------------------------------------------------------------

        /// <summary>
        /// The configured steps as the document Core would resolve, for the shared walker: an
        /// option bound to a purpose takes the purpose's label and icon, disabled options are
        /// left out. overrideId/overrideStep put an unsaved draft of one step in place of the
        /// saved one. Nothing here reads or writes Core.
        /// </summary>
        private VisitorFlowDocument FlowPreviewDocument(Dictionary<string, object> steps, string start,
                                                        string overrideId, Dictionary<string, object> overrideStep)
        {
            var purposes = ReadRecords("visit_purposes");
            var resolved = new Dictionary<string, object>();
            var ids = new List<string>(steps.Keys);
            if (overrideId != null && !steps.ContainsKey(overrideId)) ids.Add(overrideId);
            foreach (string id in ids)
            {
                var step = id == overrideId ? DeepCopy(overrideStep)
                                            : DeepCopy((Dictionary<string, object>)steps[id]);
                var options = step.ContainsKey("options") ? step["options"] as IList : null;
                if (options != null)
                {
                    var shown = new List<object>();
                    foreach (object entry in options)
                    {
                        var option = entry as Dictionary<string, object>;
                        if (option == null) continue;
                        if (option.ContainsKey("enabled") && !SettingsStore.AsBool(option["enabled"], true)) continue;
                        string purpose = Str(option, "purpose");
                        if (purpose.Length > 0 && purposes.ContainsKey(purpose))
                        {
                            if (!option.ContainsKey("label") && purposes[purpose].ContainsKey("label"))
                                option["label"] = purposes[purpose]["label"];
                            if (Str(option, "icon").Length == 0) option["icon"] = Str(purposes[purpose], "icon");
                        }
                        shown.Add(option);
                    }
                    step["options"] = shown;
                }
                resolved[id] = step;
            }
            return VisitorFlowDocument.FromRoot(new Dictionary<string, object>
            {
                { "enabled", true }, { "start", start }, { "revision", "preview" }, { "steps", resolved },
            });
        }

        /// <summary>
        /// A modal walk through the wizard: the start page, a tap on an option, Back, and what
        /// the terminal action would be. It uses the same walker as the door station and never
        /// calls Core.
        /// </summary>
        private void ShowFlowPreview(Dictionary<string, object> steps, string start, string overrideId,
                                     Dictionary<string, object> overrideStep, TextBlock notice)
        {
            var document = FlowPreviewDocument(steps, start, overrideId, overrideStep);
            if (document == null || !document.Enabled)
            {
                notice.Text = Texts.T("flow_editor.preview_no_start");
                notice.Visibility = Visibility.Visible;
                return;
            }
            StackPanel form, actions;
            TextBlock error;
            Window dialog = FormWindow(Texts.T("flow_editor.preview"), out form, out actions, out error, 620);
            Window previousOwner = _formOwner;
            _formOwner = dialog;
            string lang = Texts.Lang ?? "ja";
            var walker = new VisitorFlowWalker(document, lang);
            string outcome = "";
            var body = new StackPanel();
            var optionButtons = new List<Button>();
            Button backButton = null;
            bool pending = false, dialogClosed = false;
            dialog.Closed += (s, e) => dialogClosed = true;
            Action render = null;

            Action<FlowAction> handle = null;
            handle = action =>
            {
                if (action.Kind == FlowActionKind.Press)
                {
                    walker.PressResult(true);
                    outcome = action.Purpose.Length == 0
                        ? Texts.T("flow_editor.preview_press")
                        : Texts.T("flow_editor.preview_press_purpose", FlowPurposeName(action.Purpose));
                }
                else if (action.Kind == FlowActionKind.Notify)
                {
                    outcome = Texts.T("flow_editor.preview_notify_step", action.Step);
                    handle(walker.NotifyResult(true));
                }
            };

            render = () =>
            {
                body.Children.Clear();
                optionButtons.Clear();
                backButton = null;
                if (outcome.Length > 0)
                {
                    var result = new TextBlock { Text = outcome, FontSize = 15, TextWrapping = TextWrapping.Wrap,
                                                 Margin = new Thickness(0, 0, 0, 10) };
                    result.SetResourceReference(TextBlock.ForegroundProperty, "AccentText");
                    AutomationId(result, "FlowPreviewOutcome");
                    body.Children.Add(result);
                }
                if (walker.Mode == FlowMode.Calling)
                {
                    var again = CommandButton(Texts.T("flow_editor.preview_restart"));
                    AutomationId(again, "FlowPreviewRestart");
                    again.HorizontalAlignment = HorizontalAlignment.Left;
                    again.Click += (s, e) =>
                    {
                        walker.CallEnded("other");
                        outcome = "";
                        render();
                    };
                    body.Children.Add(again);
                    return;
                }
                FlowPageView view = walker.View();
                var title = new TextBlock { Text = view.Title, FontSize = 24, FontWeight = FontWeights.SemiBold,
                                            TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
                body.Children.Add(title);
                foreach (FlowImageView image in view.Images)
                    if (image.Alt.Length > 0)
                        body.Children.Add(FieldHint("[" + image.Alt + "]"));
                if (view.Body.Length > 0)
                    body.Children.Add(new TextBlock { Text = view.Body, FontSize = 16, TextWrapping = TextWrapping.Wrap,
                                                      TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 10, 0, 0) });
                var options = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
                foreach (FlowOptionView option in view.Options)
                {
                    FlowOptionView chosen = option;
                    var content = new StackPanel { Orientation = Orientation.Horizontal,
                                                   HorizontalAlignment = HorizontalAlignment.Center };
                    string key = FlowIcons.KeyFor(option.Purpose, option.Icon);
                    var glyph = key == null ? null : DoorbellApp.Ui.Fluent.Icon(key);
                    if (glyph != null)
                    {
                        glyph.Width = 20;
                        glyph.Height = 20;
                        glyph.Margin = new Thickness(0, 0, 10, 0);
                        content.Children.Add(glyph);
                    }
                    content.Children.Add(new TextBlock { Text = option.Label, VerticalAlignment = VerticalAlignment.Center });
                    Button button = option.Primary ? PrimaryButton(null) : CommandButton(null);
                    button.Content = content;
                    button.HorizontalAlignment = HorizontalAlignment.Stretch;
                    button.HorizontalContentAlignment = HorizontalAlignment.Center;
                    button.Margin = new Thickness(0, 6, 0, 0);
                    AutomationId(button, "FlowPreviewOption");
                    AutomationLabel(button, option.Label);
                    optionButtons.Add(button);
                    button.Click += (s, e) =>
                    {
                        if (pending) return;
                        outcome = "";
                        FlowAction action = walker.Tap(chosen.Id);
                        if (action.Kind == FlowActionKind.None)
                        {
                            render();
                            return;
                        }
                        // What the door station shows while Core works, simulated for about a second.
                        pending = true;
                        foreach (Button other in optionButtons)
                            if (!ReferenceEquals(other, button)) { other.IsEnabled = false; other.Opacity = 0.45; }
                        if (backButton != null) { backButton.IsEnabled = false; backButton.Opacity = 0.45; }
                        var panel = button.Content as StackPanel;
                        if (panel != null)
                        {
                            FrameworkElement ring = DoorbellApp.Ui.Fluent.BusyIndicator(20, button.Foreground);
                            ring.Margin = new Thickness(0, 0, 10, 0);
                            if (panel.Children.Count > 1) panel.Children[0] = ring;
                            else panel.Children.Insert(0, ring);
                        }
                        button.SetResourceReference(Control.BorderBrushProperty, "Accent");
                        button.BorderThickness = new Thickness(3);
                        System.Windows.Automation.AutomationProperties.SetItemStatus(button, Texts.T("flow.pending_notify"));
                        var settle = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
                        settle.Tick += (t, a) =>
                        {
                            settle.Stop();
                            pending = false;
                            if (dialogClosed) return;
                            handle(action);
                            render();
                        };
                        settle.Start();
                    };
                    options.Children.Add(button);
                }
                body.Children.Add(options);
                if (walker.Mode == FlowMode.End)
                {
                    var done = CommandButton(Texts.T("flow.done"));
                    done.Margin = new Thickness(0, 10, 0, 0);
                    done.Click += (s, e) => { walker.Done(); outcome = ""; render(); };
                    body.Children.Add(done);
                }
                else if (walker.CanGoBack)
                {
                    var back = CommandButton(Texts.T("flow.back"));
                    AutomationId(back, "FlowPreviewBack");
                    back.Margin = new Thickness(0, 10, 0, 0);
                    back.HorizontalAlignment = HorizontalAlignment.Left;
                    back.Click += (s, e) => { if (pending) return; walker.Back(); outcome = ""; render(); };
                    backButton = back;
                    body.Children.Add(back);
                }
            };

            form.Children.Add(FieldHint(Texts.T("flow_editor.preview_note_walk")));
            var languages = new WrapPanel { Margin = new Thickness(0, 8, 0, 8) };
            foreach (string code in FlowLanguages())
            {
                string chosenLang = code;
                var button = CommandButton(LangName(code));
                button.Margin = new Thickness(0, 0, 6, 6);
                button.Click += (s, e) => { walker.SetLang(chosenLang); render(); };
                languages.Children.Add(button);
            }
            form.Children.Add(languages);
            var card = new Border
            {
                Padding = new Thickness(16),
                Child = body,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(4),
            };
            card.SetResourceReference(Border.BorderBrushProperty, "Line");
            form.Children.Add(card);
            var closeButton = CommandButton(Texts.T("flow_editor.preview_close"));
            AutomationId(closeButton, "FlowPreviewClose");
            closeButton.IsCancel = true;
            closeButton.Click += (s, e) => dialog.DialogResult = false;
            actions.Children.Add(closeButton);
            render();
            try { dialog.ShowDialog(); }
            finally { _formOwner = previousOwner; }
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
                    box.Children.Add(NewFlowLine("image." + index, null));
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
                        TextBlock altLine = NewFlowLine("image." + index + "." + lang, alt);
                        alt.TextChanged += (s, e) => altLine.Visibility = Visibility.Collapsed;
                        box.Children.Add(altLine);
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
                if (_flowSite != null)
                    foreach (string stale in new List<string>(_flowSite.Lines.Keys))
                        if (stale.StartsWith("option.", StringComparison.Ordinal)) _flowSite.Lines.Remove(stale);
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
                    host.Children.Add(NewFlowLine("option." + Str(option, "id"), edit));
                    up.Click += (s, e) => { Swap(options, index, index - 1); redraw(); };
                    down.Click += (s, e) => { Swap(options, index, index + 1); redraw(); };
                    edit.Click += (s, e) => { if (EditFlowOption(option, steps, selfId, options)) redraw(); };
                    AutomationId(remove, "FlowOptionRemove");
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
                if (options.Count == 0) return Texts.T("flow_error.no_options");
                var written = new List<object>();
                foreach (var option in options) written.Add(option);
                next["options"] = written;
                return null;
            });
        }

        private static readonly string[] FlowIconNames =
        {
            "flow_editor.icon_home", "flow_editor.icon_package", "flow_editor.icon_mail",
            "flow_editor.icon_briefcase", "flow_editor.icon_wrench", "flow_editor.icon_other_ellipsis",
            "flow_editor.icon_person",
        };

        /// <summary>
        /// The icons an option can show, written to configuration as their emoji so the other
        /// shells read them; this shell draws the matching Fluent glyph, never the emoji.
        /// </summary>
        private static List<SettingOption> FlowIconOptions(string current)
        {
            var options = new List<SettingOption> { new SettingOption("", "flow_editor.icon_none") };
            bool known = current.Length == 0;
            for (int i = 0; i < FlowIcons.PickerEmoji.Length; i++)
            {
                options.Add(new SettingOption(FlowIcons.PickerEmoji[i], FlowIconNames[i]));
                if (FlowIcons.PickerEmoji[i] == current) known = true;
            }
            if (!known) options.Add(new SettingOption(current, "flow_editor.icon_current"));
            return options;
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
            var icon = Fld("icon", FieldKind.Choice, "flow_editor.option_icon_pick");
            icon.Options = FlowIconOptions(Str(option, "icon"));
            icon.Load = v => v ?? "";
            icon.Store = v => string.IsNullOrEmpty(Convert.ToString(v)) ? null : v;
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
                    return Texts.T("flow_error.option_needs_label");
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
