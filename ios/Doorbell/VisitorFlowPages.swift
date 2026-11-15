import Foundation

/// The visitor-flow editor as settings pages: one page for the wizard, a step list, and a page per
/// step with its options and images. Every commit is a whole-step write (or a scalar leaf), so one
/// edit is one Core batch (docs/en/visitor-flow-contract.md, section 8). Core's refusal text is
/// shown by the settings host next to the field that was edited.
struct VisitorFlowPages {

    let ctx: SettingsContext
    let texts: Texts
    let editor: VisitorFlowEditor

    init(_ ctx: SettingsContext, texts: Texts) {
        self.ctx = ctx
        self.texts = texts
        let offered = (ConfigUtil.dig(ctx.config, "ui.languages") as? [Any])?.compactMap { $0 as? String }
        self.editor = VisitorFlowEditor(config: ctx.config, languages: offered ?? ["ja", "en", "zh"])
    }

    private func t(_ key: String) -> String { return texts.t(key) }

    private var languages: [String] { return editor.languages }

    // MARK: Summary and shared choices

    /// What the Calls page shows next to the wizard row.
    func summary() -> String {
        return editor.isBuiltIn ? "" : "\(editor.steps.count)"
    }

    private func stepOptions(kinds: [String], includeNone: String? = nil) -> [SettingOption] {
        var options: [SettingOption] = []
        if let none = includeNone { options.append(SettingOption(value: "", title: none)) }
        for id in editor.orderedStepIds() where kinds.contains(editor.kind(id)) {
            options.append(SettingOption(value: id, title: stepTitle(id)))
        }
        return options
    }

    private func stepTitle(_ id: String) -> String {
        let title = editor.displayTitle(id, lang: ctx.uiLang)
        let kind = t("flow_editor.kind_" + editor.kind(id))
        return title == id ? "\(kind) · \(id)" : "\(title) · \(kind)"
    }

    private func purposeOptions() -> [SettingOption] {
        let purposes = ConfigUtil.dig(ctx.config, "visit_purposes") as? [String: Any] ?? [:]
        return ConfigUtil.allPurposeIds(ctx.config).map {
            SettingOption(value: $0, title: ConfigUtil.labelOf(purposes[$0] as? [String: Any], ctx.uiLang, $0))
        }
    }

    private func defaults(_ key: String) -> [String: Any] {
        var map: [String: Any] = [:]
        for lang in languages {
            let text = Texts.builtinStrings(lang)[key] ?? Texts.builtinStrings("en")[key] ?? ""
            if !text.isEmpty { map[lang] = text }
        }
        return map
    }

    private func langTitle(_ key: String, _ lang: String) -> String {
        return languages.count > 1 ? "\(t(key)) · \(Texts.langDisplayName(lang))" : t(key)
    }

    // MARK: Wizard page

    func page() -> SettingsPage {
        var sections: [SettingSection] = []
        var wizard: [SettingItem] = [
            SettingItem("flow_enabled", t("flow_editor.enabled"), .toggle(editor.enabled)) { value in
                .write([.set("visitor_flow.enabled", value.boolValue ?? true)])
            },
        ]
        if editor.isBuiltIn {
            wizard.append(SettingItem("flow_customize", t("flow_editor.customize"),
                                      .action(destructive: false)) { _ in .local("flow.template|default") })
        } else {
            let pages = stepOptions(kinds: ["page"])
            wizard.append(SettingItem("flow_start", t("flow_editor.start"),
                                      .choice(value: editor.start, options: pages, searchable: false)) { value in
                .write([.set("visitor_flow.start", value.stringValue ?? "")])
            })
        }
        wizard.append(SettingItem("flow_idle", t("flow_editor.idle_short"),
                                  .stepper(value: editor.idleSeconds, minimum: 15, maximum: 300, step: 5,
                                           unit: t("prefs.unit_seconds"))) { value in
            .write([.set("visitor_flow.idle_s", SettingValidation.clamp(value.intValue ?? 45, 15, 300))])
        })
        wizard.append(SettingItem("flow_require_call", t("flow_editor.require_call"),
                                  .toggle(editor.requireCall)) { value in
            .write([.set("visitor_flow.require_call", value.boolValue ?? true)])
        })
        sections.append(SettingSection(t("flow_editor.title"),
                                       footer: (editor.isBuiltIn ? t("flow_editor.default_note") + " " : "")
                                           + t("flow_editor.enabled_hint")
                                           + (editor.requireCall ? "" : "\n" + t("flow_editor.require_call_off_warning")),
                                       wizard))

        sections.append(SettingSection(footer: t("flow_editor.preview_hint"), [
            SettingItem("flow_preview", t("flow_editor.preview"), .action(destructive: false)) { _ in
                .local("flow.preview")
            },
        ]))

        if !editor.isBuiltIn {
            sections.append(SettingSection(t("flow_editor.steps"), [
                SettingItem("flow_steps", t("flow_editor.steps"), detail: "\(editor.steps.count)",
                            .page({ self.stepsPage() })),
            ]))
            let doors = ConfigUtil.dig(ctx.config, "doors") as? [String: Any] ?? [:]
            let pages = stepOptions(kinds: ["page"], includeNone: t("flow_editor.door_start_inherit"))
            if !doors.isEmpty {
                let items = doors.keys.sorted().map { door -> SettingItem in
                    let label = ConfigUtil.labelOf(doors[door] as? [String: Any], ctx.uiLang, door)
                    return SettingItem("flow_door_start_\(door)", "\(t("flow_editor.door_start")) · \(label)",
                                       .choice(value: editor.doorStart(door), options: pages, searchable: false)) { value in
                        let id = value.stringValue ?? ""
                        return .write([id.isEmpty ? .delete("doors.\(door).visitor_flow.start")
                                                  : .set("doors.\(door).visitor_flow.start", id)])
                    }
                }
                sections.append(SettingSection(items))
            }
        }

        var templates: [SettingItem] = []
        for name in ["purposes", "delivery"] {
            templates.append(SettingItem("flow_template_\(name)", t("flow_editor.template_" + name),
                                         detail: editor.isBuiltIn ? "" : t("flow_editor.template_confirm"),
                                         .action(destructive: !editor.isBuiltIn)) { _ in
                .local("flow.template|\(name)")
            })
        }
        if !editor.isBuiltIn {
            templates.append(SettingItem("flow_reset", t("flow_editor.reset_default"),
                                         detail: t("flow_editor.reset_default_confirm"),
                                         .action(destructive: true)) { _ in .local("flow.reset") })
        }
        sections.append(SettingSection(t("flow_editor.templates"), templates))
        return SettingsPage(id: "visitor_flow", title: t("flow_editor.title"), sections: sections)
    }

    // MARK: Steps

    func stepsPage() -> SettingsPage {
        let rows = editor.orderedStepIds().map { id -> SettingItem in
            SettingItem("step_\(id)", stepTitle(id), detail: id == editor.start ? t("flow_editor.start") : "",
                        .page({ self.stepPage(id) }))
        }
        let atLimit = editor.steps.count >= VisitorFlowEditor.maxSteps
        let adds = ["page", "call", "notify", "end"].map { kind -> SettingItem in
            SettingItem("flow_add_\(kind)", "\(t("flow_editor.add_step")) · \(t("flow_editor.kind_" + kind))",
                        .action(destructive: false)) { _ in
                guard !atLimit else { return .invalid("visitor_flow.too_many_steps") }
                return .write(self.editor.newStep(kind: kind, defaults: self.defaults).ops)
            }
        }
        let order = SettingItem("flow_step_order", t("flow_editor.reorder_steps"), detail: "\(editor.steps.count)",
                                .list({ self.stepOrderList() }))
        return SettingsPage(id: "flow_steps", title: t("flow_editor.steps"), sections: [
            SettingSection(footer: t("flow_editor.reorder_hint"), [order]), SettingSection(rows), SettingSection(adds),
        ])
    }

    /// The steps in Core's `step_order` with the stock reorder control: a drop writes consecutive
    /// `order` values for the new sequence, one whole-step write per changed step, in one batch.
    func stepOrderList() -> SettingsListModel {
        let ids = editor.orderedStepIds()
        let rows = ids.map { id in
            SettingsListRow(id: id, title: stepTitle(id), detail: id == editor.start ? t("flow_editor.start") : "",
                            enabled: nil, toggle: nil, edit: nil)
        }
        return SettingsListModel(id: "flow_step_order", title: t("flow_editor.reorder_steps"),
                                 footer: t("flow_editor.reorder_hint"), rows: rows,
                                 reorder: { sequence in .write(self.editor.reorderOperations(sequence)) },
                                 delete: nil)
    }

    func stepPage(_ id: String) -> SettingsPage {
        guard let step = editor.steps[id] else {
            return SettingsPage(id: "step_\(id)", title: id, sections: [])
        }
        let kind = step["kind"] as? String ?? ""
        var sections: [SettingSection] = []
        sections.append(SettingSection(footer: id, [
            SettingItem("\(id)_kind", t("flow_editor.kind_" + kind), .info(id)),
        ]))
        switch kind {
        case "page":
            sections.append(contentsOf: textSections(id, step, withBody: true))
            sections.append(imagesSection(id, step))
            sections.append(optionsSection(id, step))
        case "call":
            sections.append(callSection(id, step))
        case "notify":
            sections.append(notifySection(id, step))
        default:
            sections.append(contentsOf: textSections(id, step, withBody: true))
            sections.append(imagesSection(id, step))
            let seconds = (step["return_s"] as? NSNumber)?.intValue ?? 8
            sections.append(SettingSection([
                SettingItem("\(id)_return_s", t("flow_editor.idle_short"),
                            .stepper(value: min(60, max(3, seconds)), minimum: 3, maximum: 60, step: 1,
                                     unit: t("prefs.unit_seconds"))) { value in
                    .write(self.editor.update(id) { $0["return_s"] = SettingValidation.clamp(value.intValue ?? 8, 3, 60) })
                },
            ]))
        }
        sections.append(manageSection(id, kind))
        return SettingsPage(id: "step_\(id)", title: stepTitle(id), sections: sections)
    }

    private func textItem(_ itemId: String, _ title: String, step id: String, field: String, lang: String,
                          current: String, limit: Int, multiline: Bool = false) -> SettingItem {
        let control: SettingControl = multiline
            ? .longText(value: current, placeholder: "")
            : .text(value: current, placeholder: "", numeric: false)
        let oneLine = current.replacingOccurrences(of: "\n", with: " ")
        let shown = oneLine.count > 18 ? String(oneLine.prefix(18)) + "\u{2026}" : oneLine
        return SettingItem(itemId, title, detail: shown, control) { value in
            let text = multiline ? (value.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                 : (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            guard text.count <= limit else { return .invalid("visitor_flow.bad_text") }
            if multiline, VisitorFlowEditor.paragraphCount(text) > VisitorFlowEditor.limits.bodyParagraphs {
                return .invalid("visitor_flow.bad_text")
            }
            return .write(self.editor.update(id) { step in
                if let map = VisitorFlowEditor.setting(step[field], lang: lang, to: text) {
                    step[field] = map
                } else {
                    step.removeValue(forKey: field)
                }
            })
        }
    }

    private func textSections(_ id: String, _ step: [String: Any], withBody: Bool) -> [SettingSection] {
        var titles: [SettingItem] = []
        var bodies: [SettingItem] = []
        for lang in languages {
            titles.append(textItem("\(id)_title_\(lang)", langTitle("flow_editor.field_title", lang), step: id,
                                   field: "title", lang: lang,
                                   current: ((step["title"] as? [String: Any])?[lang] as? String) ?? "",
                                   limit: VisitorFlowEditor.limits.title))
            if withBody {
                bodies.append(textItem("\(id)_body_\(lang)", langTitle("flow_editor.field_body", lang), step: id,
                                       field: "body", lang: lang,
                                       current: ((step["body"] as? [String: Any])?[lang] as? String) ?? "",
                                       limit: VisitorFlowEditor.limits.body, multiline: true))
            }
        }
        return [SettingSection(titles), SettingSection(bodies)].filter { !$0.items.isEmpty }
    }

    // MARK: Images

    private func imagesSection(_ id: String, _ step: [String: Any]) -> SettingSection {
        let images = step["images"] as? [[String: Any]] ?? []
        var items: [SettingItem] = images.enumerated().map { index, image in
            let asset = image["asset"] as? String ?? ""
            let label = (ConfigUtil.dig(ctx.config, "assets.\(asset)") as? [String: Any])?["label"] as? String
            return SettingItem("\(id)_img_\(index)", "\(t("flow_editor.field_images")) \(index + 1)",
                               detail: label ?? String(asset.prefix(8)),
                               .page({ self.imagePage(id, index: index) }))
        }
        if images.count < VisitorFlowEditor.maxImages {
            items.append(SettingItem("\(id)_add_image", t("flow_editor.add_image"), .action(destructive: false)) { _ in
                .local("flow.image|\(id)")
            })
        }
        return SettingSection(t("flow_editor.field_images"), items)
    }

    private func imagePage(_ id: String, index: Int) -> SettingsPage {
        let images = editor.steps[id]?["images"] as? [[String: Any]] ?? []
        guard images.indices.contains(index) else {
            return SettingsPage(id: "\(id)_img_\(index)", title: id, sections: [])
        }
        let image = images[index]
        func change(_ body: @escaping (inout [String: Any]) -> Void) -> SettingEffect {
            return .write(editor.update(id) { step in
                var list = step["images"] as? [[String: Any]] ?? []
                guard list.indices.contains(index) else { return }
                body(&list[index])
                step["images"] = list
            })
        }
        let assets = (ConfigUtil.dig(ctx.config, "assets") as? [String: Any]) ?? [:]
        let options = assets.keys.sorted().compactMap { hash -> SettingOption? in
            let entry = assets[hash] as? [String: Any]
            guard (entry?["type"] as? String ?? "").hasPrefix("image/") else { return nil }
            return SettingOption(value: hash, title: entry?["label"] as? String ?? String(hash.prefix(8)))
        }
        var alts: [SettingItem] = []
        for lang in languages {
            let current = ((image["alt"] as? [String: Any])?[lang] as? String) ?? ""
            alts.append(SettingItem("\(id)_img\(index)_alt_\(lang)", langTitle("flow_editor.image_alt", lang),
                                    detail: current, .text(value: current, placeholder: "", numeric: false)) { value in
                let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                guard text.count <= VisitorFlowEditor.limits.alt else { return .invalid("visitor_flow.bad_text") }
                return change { image in
                    if let map = VisitorFlowEditor.setting(image["alt"], lang: lang, to: text) {
                        image["alt"] = map
                    } else {
                        image.removeValue(forKey: "alt")
                    }
                }
            })
        }
        let place = image["place"] as? String == "below" ? "below" : "above"
        return SettingsPage(id: "\(id)_img_\(index)", title: "\(t("flow_editor.field_images")) \(index + 1)", sections: [
            SettingSection([
                SettingItem("\(id)_img\(index)_asset", t("flow_editor.field_images"),
                            .choice(value: image["asset"] as? String ?? "", options: options, searchable: false)) { value in
                    change { $0["asset"] = value.stringValue ?? "" }
                },
                SettingItem("\(id)_img\(index)_place", t("flow_editor.image_above") + " / " + t("flow_editor.image_below"),
                            .segmented(value: place, options: [
                                SettingOption(value: "above", title: t("flow_editor.image_above")),
                                SettingOption(value: "below", title: t("flow_editor.image_below"))])) { value in
                    change { $0["place"] = value.stringValue ?? "above" }
                },
            ]),
            SettingSection(alts),
            SettingSection([
                SettingItem("\(id)_img\(index)_remove", t("flow_editor.remove_image"), .action(destructive: true)) { _ in
                    .write(self.editor.update(id) { step in
                        var list = step["images"] as? [[String: Any]] ?? []
                        if list.indices.contains(index) { list.remove(at: index) }
                        if list.isEmpty { step.removeValue(forKey: "images") } else { step["images"] = list }
                    })
                },
            ]),
        ])
    }

    // MARK: Options

    /// The picker offers the shell's own icon set by name. A stored value that is not one of them
    /// stays selectable as "Custom" so opening the page never loses it.
    private func iconValue(_ icon: String) -> String {
        return icon.isEmpty ? "" : (AppIcon.flowChoiceValue(for: icon) ?? icon)
    }

    private func iconTitle(_ icon: String) -> String {
        if icon.isEmpty { return t("flow_editor.icon_default") }
        let value = iconValue(icon)
        return AppIcon.flowChoices.first { $0.emoji == value }.map { t($0.titleKey) } ?? t("flow_editor.icon_custom")
    }

    private func iconOptions(_ icon: String) -> [SettingOption] {
        var options = [SettingOption(value: "", title: t("flow_editor.icon_default"))]
        options += AppIcon.flowChoices.map { SettingOption(value: $0.emoji, title: t($0.titleKey)) }
        if !icon.isEmpty, !options.contains(where: { $0.value == iconValue(icon) }) {
            options.append(SettingOption(value: icon, title: t("flow_editor.icon_custom")))
        }
        return options
    }

    private func optionTitle(_ option: [String: Any]) -> String {
        if let label = VisitorFlowText.text(option["label"], lang: ctx.uiLang) { return label }
        let purpose = option["purpose"] as? String ?? ""
        let purposes = ConfigUtil.dig(ctx.config, "visit_purposes") as? [String: Any] ?? [:]
        return purpose.isEmpty ? (option["id"] as? String ?? "") :
            ConfigUtil.labelOf(purposes[purpose] as? [String: Any], ctx.uiLang, purpose)
    }

    private func optionsSection(_ id: String, _ step: [String: Any]) -> SettingSection {
        let options = step["options"] as? [[String: Any]] ?? []
        var items: [SettingItem] = options.compactMap { option in
            guard let optionId = option["id"] as? String else { return nil }
            let target = (option["to"] as? String).map { editor.displayTitle($0, lang: ctx.uiLang) } ?? ""
            var detail = "→ " + target
            if option["style"] as? String == "primary" { detail = "★ " + detail }
            if option["enabled"] as? Bool == false { detail = "⏸ " + detail }
            return SettingItem("\(id)_opt_\(optionId)", optionTitle(option), detail: detail,
                               .page({ self.optionPage(id, option: optionId) }))
        }
        if options.count < VisitorFlowEditor.maxOptions {
            items.append(SettingItem("\(id)_add_option", t("flow_editor.add_option"), .action(destructive: false)) { _ in
                let optionId = VisitorFlowEditor.newOptionId(in: options)
                let call = self.editor.ids(ofKind: "call").first
                var created: [(id: String, step: [String: Any])] = []
                var target = call ?? ""
                if call == nil {
                    target = SettingValidation.newId("c")
                    created.append((target, ["kind": "call"]))
                }
                var changed = step
                var list = changed["options"] as? [[String: Any]] ?? []
                list.append(["id": optionId, "label": self.defaults("flow_editor.new_option_label"), "to": target])
                changed["options"] = list
                return .write(self.editor.writes(creating: created, modifying: [(id, changed)]))
            })
        }
        let crowded = options.count > 4 && (step["body"] != nil || step["images"] != nil)
        return SettingSection(t("flow_editor.field_options"),
                              footer: crowded ? t("visitor_flow.crowded_page") : "", items)
    }

    private func optionPage(_ id: String, option optionId: String) -> SettingsPage {
        let options = editor.steps[id]?["options"] as? [[String: Any]] ?? []
        guard let index = options.firstIndex(where: { $0["id"] as? String == optionId }) else {
            return SettingsPage(id: "\(id)_opt_\(optionId)", title: optionId, sections: [])
        }
        let option = options[index]
        let purpose = option["purpose"] as? String ?? ""
        var labels: [SettingItem] = []
        for lang in languages {
            let current = ((option["label"] as? [String: Any])?[lang] as? String) ?? ""
            labels.append(SettingItem("\(id)_\(optionId)_label_\(lang)", langTitle("flow_editor.option_label", lang),
                                      detail: current, .text(value: current, placeholder: "", numeric: false)) { value in
                let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                guard text.count <= VisitorFlowEditor.limits.label else { return .invalid("visitor_flow.bad_text") }
                let remaining = ((option["label"] as? [String: Any]) ?? [:]).filter { $0.key != lang && !(($0.value as? String ?? "").isEmpty) }
                if text.isEmpty, remaining.isEmpty, purpose.isEmpty { return .invalid("visitor_flow.option_needs_label") }
                return .write(self.editor.updateOption(id, option: optionId) { option in
                    if let map = VisitorFlowEditor.setting(option["label"], lang: lang, to: text) {
                        option["label"] = map
                    } else {
                        option.removeValue(forKey: "label")
                    }
                })
            })
        }
        let icon = option["icon"] as? String ?? ""
        let steps = stepOptions(kinds: ["page", "call", "notify", "end"])
        let isPrimary = option["style"] as? String == "primary"
        var move: [SettingItem] = []
        if index > 0 {
            move.append(SettingItem("\(id)_\(optionId)_up", t("settings.move_up"), .action(destructive: false)) { _ in
                .write(self.editor.moveOption(id, option: optionId, by: -1))
            })
        }
        if index < options.count - 1 {
            move.append(SettingItem("\(id)_\(optionId)_down", t("settings.move_down"), .action(destructive: false)) { _ in
                .write(self.editor.moveOption(id, option: optionId, by: 1))
            })
        }
        var sections = [
            SettingSection(t("flow_editor.field_options"), [
                SettingItem("\(id)_\(optionId)_target", t("flow_editor.option_target"),
                            .choice(value: option["to"] as? String ?? "", options: steps.filter { $0.value != id },
                                    searchable: false)) { value in
                    .write(self.editor.updateOption(id, option: optionId) { $0["to"] = value.stringValue ?? "" })
                },
                SettingItem("\(id)_\(optionId)_primary", t("flow_editor.option_primary"), .toggle(isPrimary)) { value in
                    .write(self.editor.setPrimary(id, option: optionId, on: value.boolValue ?? false))
                },
                SettingItem("\(id)_\(optionId)_enabled", t("flow_editor.option_enabled"),
                            .toggle(option["enabled"] as? Bool ?? true)) { value in
                    .write(self.editor.updateOption(id, option: optionId) { option in
                        if value.boolValue == false { option["enabled"] = false } else { option.removeValue(forKey: "enabled") }
                    })
                },
                SettingItem("\(id)_\(optionId)_purpose", t("flow_editor.option_purpose"),
                            .choice(value: purpose, options: [SettingOption(value: "", title: t("flow_editor.option_purpose_none"))]
                                + purposeOptions(), searchable: false)) { value in
                    let chosen = value.stringValue ?? ""
                    if chosen.isEmpty, (option["label"] as? [String: Any] ?? [:]).isEmpty {
                        return .invalid("visitor_flow.option_needs_label")
                    }
                    return .write(self.editor.updateOption(id, option: optionId) { option in
                        if chosen.isEmpty { option.removeValue(forKey: "purpose") } else { option["purpose"] = chosen }
                    })
                },
                SettingItem("\(id)_\(optionId)_icon", t("flow_editor.option_icon"), detail: iconTitle(icon),
                            .choice(value: iconValue(icon), options: iconOptions(icon), searchable: false)) { value in
                    let chosen = value.stringValue ?? ""
                    return .write(self.editor.updateOption(id, option: optionId) { option in
                        if chosen.isEmpty { option.removeValue(forKey: "icon") } else { option["icon"] = chosen }
                    })
                },
            ]),
            SettingSection(labels),
        ]
        if !move.isEmpty { sections.append(SettingSection(move)) }
        sections.append(SettingSection([
            SettingItem("\(id)_\(optionId)_delete", t("flow_editor.delete_option"), .action(destructive: true)) { _ in
                options.count <= 1 ? .invalid("visitor_flow.no_options")
                                   : .write(self.editor.deleteOption(id, option: optionId))
            },
        ]))
        return SettingsPage(id: "\(id)_opt_\(optionId)", title: optionTitle(option), sections: sections)
    }

    // MARK: Call and notify

    private func callSection(_ id: String, _ step: [String: Any]) -> SettingSection {
        let purpose = step["purpose"] as? String ?? ""
        let unanswered = step["on_unanswered"] as? String ?? ""
        return SettingSection([
            SettingItem("\(id)_purpose", t("flow_editor.field_purpose"),
                        .choice(value: purpose, options: [SettingOption(value: "", title: t("flow_editor.purpose_none"))]
                            + purposeOptions(), searchable: false)) { value in
                .write(self.editor.update(id) { step in
                    let chosen = value.stringValue ?? ""
                    if chosen.isEmpty { step.removeValue(forKey: "purpose") } else { step["purpose"] = chosen }
                })
            },
            SettingItem("\(id)_on_unanswered", t("flow_editor.field_on_unanswered"),
                        .choice(value: unanswered, options: stepOptions(kinds: ["page"],
                                                                         includeNone: t("flow_editor.on_unanswered_none")),
                                searchable: false)) { value in
                .write(self.editor.update(id) { step in
                    let chosen = value.stringValue ?? ""
                    if chosen.isEmpty { step.removeValue(forKey: "on_unanswered") } else { step["on_unanswered"] = chosen }
                })
            },
        ])
    }

    private func notifySection(_ id: String, _ step: [String: Any]) -> SettingSection {
        var items: [SettingItem] = []
        for lang in languages {
            items.append(textItem("\(id)_message_\(lang)", langTitle("flow_editor.field_message", lang), step: id,
                                  field: "message", lang: lang,
                                  current: ((step["message"] as? [String: Any])?[lang] as? String) ?? "",
                                  limit: VisitorFlowEditor.limits.message))
        }
        let purpose = step["purpose"] as? String ?? ""
        items.append(SettingItem("\(id)_purpose", t("flow_editor.field_purpose"),
                                 .choice(value: purpose, options: [SettingOption(value: "", title: t("flow_editor.purpose_none"))]
                                     + purposeOptions(), searchable: false)) { value in
            .write(self.editor.update(id) { step in
                let chosen = value.stringValue ?? ""
                if chosen.isEmpty { step.removeValue(forKey: "purpose") } else { step["purpose"] = chosen }
            })
        })
        items.append(SettingItem("\(id)_to", t("flow_editor.field_to"),
                                 .choice(value: step["to"] as? String ?? "", options: stepOptions(kinds: ["end"]),
                                         searchable: false)) { value in
            .write(self.editor.update(id) { $0["to"] = value.stringValue ?? "" })
        })
        let snapshot = step["snapshot"] as? [String: Any]
        let current = snapshot == nil ? "none"
            : (snapshot?["source"] as? String == "door_station" ? "door_station" : "camera:" + (snapshot?["id"] as? String ?? ""))
        let cameras = editor.snapshotCameras()
        var snapshotOptions = [SettingOption(value: "none", title: t("flow_editor.snapshot_none"))]
        for camera in cameras {
            snapshotOptions.append(SettingOption(value: "camera:" + camera,
                                                 title: texts.t("flow_editor.snapshot_camera", camera)))
        }
        snapshotOptions.append(SettingOption(value: "door_station", title: t("flow_editor.snapshot_door_station")))
        if current.hasPrefix("camera:"), !cameras.contains(String(current.dropFirst(7))) {
            snapshotOptions.append(SettingOption(value: current, title: texts.t("flow_editor.snapshot_camera",
                                                                                 String(current.dropFirst(7)))))
        }
        items.append(SettingItem("\(id)_snapshot", t("flow_editor.field_snapshot"),
                                 .choice(value: current, options: snapshotOptions, searchable: false)) { value in
            .write(self.editor.update(id) { step in
                let chosen = value.stringValue ?? "none"
                if chosen == "none" {
                    step.removeValue(forKey: "snapshot")
                } else if chosen == "door_station" {
                    step["snapshot"] = ["source": "door_station"]
                } else {
                    step["snapshot"] = ["source": "media_source", "id": String(chosen.dropFirst("camera:".count))]
                }
            })
        })
        return SettingSection(footer: cameras.isEmpty ? t("flow_editor.snapshot_no_camera") : "", items)
    }

    // MARK: Per-step actions

    private func manageSection(_ id: String, _ kind: String) -> SettingSection {
        var items: [SettingItem] = []
        if kind == "page", editor.start != id {
            items.append(SettingItem("\(id)_make_start", t("flow_editor.make_start"), .action(destructive: false)) { _ in
                .write([.set("visitor_flow.start", id)])
            })
        }
        items.append(SettingItem("\(id)_duplicate", t("flow_editor.duplicate_step"), .action(destructive: false)) { _ in
            guard let copy = self.editor.duplicate(id) else { return .invalid("visitor_flow.too_many_steps") }
            return .write(copy.ops)
        })
        let users = editor.referencers(of: id)
        if users.isEmpty {
            items.append(SettingItem("\(id)_delete", t("flow_editor.delete_step"), .action(destructive: true)) { _ in
                guard let ops = self.editor.delete(id) else { return .none }
                return .write(ops)
            })
        } else {
            items.append(SettingItem("\(id)_in_use", t("flow_editor.delete_step"),
                                     detail: texts.t("flow_editor.step_in_use", users.joined(separator: ", ")),
                                     .info(users.joined(separator: ", "))))
        }
        return SettingSection(items)
    }
}
