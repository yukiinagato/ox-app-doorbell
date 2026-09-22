import UIKit

@UIApplicationMain
final class VisitorRunnerDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let output = URL(fileURLWithPath: "/var/mobile/Library/DoorbellT35ModernUIKit", isDirectory: true)
    private let core = CoreBridge()
    private var checks: [[String: Any]] = []
    private var steps: [() -> Void] = []
    private var index = 0
    private var waiting = false
    private var screen: MainViewController?
    private var group = "setup"
    private let profiles = [CGSize(width: 320, height: 480), CGSize(width: 480, height: 320),
                            CGSize(width: 844, height: 390), CGSize(width: 768, height: 1024),
                            CGSize(width: 1024, height: 768)]
    private let languages = ["en", "zh", "ja"]
    private var savedCall = ""
    private var heldButton: UIButton?
    private var sos: SosSlideControl?
    private var sosHost: UIViewController?
    private var sosTriggers = 0

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.isIdleTimerDisabled = true
        UIView.setAnimationsEnabled(false)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
        return true
    }
    private func save(_ value: Any, _ name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]) else { return }
        try? data.write(to: output.appendingPathComponent(name), options: .atomic)
    }
    @discardableResult private func check(_ value: Bool, _ name: String) -> Bool {
        checks.append(["group": group, "name": name, "pass": value])
        save(["checks": checks, "step": index], "progress.json")
        return value
    }
    private func all(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { all($0) } }
    private func element<T: UIView>(_ id: String, in controller: UIViewController) -> T? {
        return all(controller.view).first { $0.accessibilityIdentifier == id } as? T
    }
    private func capture(_ controller: UIViewController, _ name: String) {
        let view = controller.view!
        view.layoutIfNeeded()
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 1)
        if let context = UIGraphicsGetCurrentContext() { view.layer.render(in: context) }
        let image = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext()
        if let png = image?.pngData() { try? png.write(to: output.appendingPathComponent(name + ".png")) }
        save(all(view).map { item -> [String: Any] in
            var row: [String: Any] = ["class": NSStringFromClass(type(of: item)),
                "frame": NSCoder.string(for: item.convert(item.bounds, to: view)),
                "hidden": item.isHidden, "alpha": item.alpha, "accessibility_element": item.isAccessibilityElement,
                "traits": item.accessibilityTraits.rawValue]
            if let id = item.accessibilityIdentifier { row["identifier"] = id }
            if let label = item.accessibilityLabel { row["accessibility_label"] = label }
            if let label = item as? UILabel { row["text"] = label.text ?? ""; row["font_size"] = label.font.pointSize }
            if let button = item as? UIButton { row["title"] = button.title(for: .normal) ?? ""; row["enabled"] = button.isEnabled }
            if let scroll = item as? UIScrollView { row["content_size"] = NSCoder.string(for: scroll.contentSize) }
            return row
        }, name + ".json")
    }
    private func mount(_ controller: UIViewController, size: CGSize, large: Bool = true) {
        let host = UIViewController()
        window?.rootViewController = host
        host.addChild(controller)
        if #available(iOS 10.0, *) {
            host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory:
                large ? .accessibilityExtraExtraExtraLarge : .large), forChild: controller)
        }
        controller.view.frame = CGRect(origin: .zero, size: size)
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); controller.view.layoutIfNeeded()
    }
    private func advance() {
        if waiting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { self.advance() }
            return
        }
        guard index < steps.count else { finish(); return }
        let step = steps[index]; index += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { step(); self.advance() }
    }
    private func start() {
#if T35_BASELINE
        for language in languages { for size in profiles {
            steps.append { self.purposeLayout(language, size, verify: false) }
        } }
#else
        var hooks = CoreBridge.LifecycleTestHooks(); hooks.enqueueUi = { _ in }; core.setLifecycleTestHooks(hooks)
        let directory = output.appendingPathComponent("core-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard check(core.start(dataDir: directory.path, bootJson: "{\"name\":\"T35 isolated UIKit\",\"role\":\"door_station\",\"door\":\"front\",\"listen_port\":0,\"http_port\":0}"), "Isolated real Core starts") else { finish(); return }
        core.setCapabilities(["features": ["platform_v2": true, "call_flow_v2": true, "call_cancel_v2": true,
            "call_lifecycle_v2": true, "ui_manifest_v1": true]])
        core.setUiManifest(["schema_version": 1, "units": "pt",
            "viewport": ["minimum_touch": 44, "scale_min": 0.75, "scale_max": 2.0],
            "elements": ["purpose.button": ["properties": ["scale"], "defaults": ["scale": 1], "safety_critical": false],
                "cancel.call": ["properties": ["scale"], "defaults": ["scale": 1], "safety_critical": true]]])
        configure("ui.call_sound", "")
        configure("ui.call_flow", "purpose_first")
        let features = core.capabilities()?["features"] as? [String: Any]
        check(features?["ui_manifest_v1"] as? Bool == true, "Core accepts the complete semantic manifest")
        for language in languages { for size in profiles {
            steps.append { self.actionLayout(language, size) }
            steps.append { self.purposeLayout(language, size, verify: true) }
        } }
        appendActions()
        appendHeldActions()
        steps.append { self.offlinePresentation() }
        appendSos()
#endif
        advance()
    }
    private func longText(_ language: String) -> String {
        if language == "zh" { return "预约配送与大楼设备维护来访，请联系住户确认此次来访目的与接通状态" }
        if language == "ja" { return "予約された配達と建物設備の保守点検について、居住者への連絡と通話状態を確認してください" }
        return "Scheduled delivery and building maintenance visit. Please confirm the visitor purpose and connection with the resident."
    }
    private func purposeLayout(_ language: String, _ size: CGSize, verify: Bool) {
        group = "purpose-\(language)-\(Int(size.width))x\(Int(size.height))"
        let texts = Texts(); texts.setLang(language)
        let controller = PurposeChoiceViewController(items: [.init(id: "long", title: longText(language), image: nil)],
            palette: .light, afterRing: true, texts: texts)
        mount(controller, size: size)
        if verify {
            guard let cancel: UIButton = element("purpose_choice_cancel", in: controller),
                  let skip: UIButton = element("purpose_choice_skip", in: controller),
                  let card: UIView = element("purpose_choice_long", in: controller),
                  let scroll = all(controller.view).compactMap({ $0 as? UIScrollView }).first else {
                check(false, "Actual purpose controls exist"); return
            }
            let action = cancel.convert(cancel.bounds, to: controller.view)
            check(action.minY >= 0 && action.maxY <= size.height && action.height >= 64, "Cancel is complete and at least 64 points")
            check(scroll.bounds.height > 0 && scroll.frame.maxY < action.minY, "Scrollable purpose stays above cancel")
            check(cancel !== skip && cancel.accessibilityIdentifier != skip.accessibilityIdentifier, "Skip and cancel are distinct controls")
            card.layoutIfNeeded()
            if let label = all(card).compactMap({ $0 as? UILabel }).first {
                check(label.font.pointSize > 26, "Purpose follows largest accessibility text")
                check(label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height <= label.bounds.height + 1, "Long purpose label is not cropped")
            } else { check(false, "Purpose label exists") }
        }
        capture(controller, group)
    }
#if !T35_BASELINE
    private func configure(_ key: String, _ value: Any) {
        let data = try! JSONSerialization.data(withJSONObject: ["ops": [["op": "set", "key": key, "value": value]]])
        let result = core.applyConfigBatch(String(decoding: data, as: UTF8.self), operations: [])
        check(result?.ok == true, "Real Core configuration " + key)
    }
    private func makeScreen(_ language: String = "en", _ size: CGSize = CGSize(width: 390, height: 844), large: Bool = false) -> MainViewController {
        screen?.suspendCallTimingForTesting()
        var boot = BootConfig(); boot.door = "front"; boot.uiLang = language
        let controller = MainViewController(core: core, boot: boot, runtime: nil)
        controller.suppressVisitorMediaForTesting = true
        controller.peerFrameLoadForTesting = { _, _ in }
        screen = controller
        mount(controller, size: size, large: large)
        controller.refreshVisitorForTesting()
        tap("lang_" + language, on: controller)
        let expected = Texts(); expected.setLang(language)
        let cancel: UIButton? = element("calling_cancel", in: controller)
        check(cancel?.title(for: .normal) == expected.t("calling.cancel"), "Actual language button selects " + language)
        controller.view.layoutIfNeeded(); controller.view.layoutIfNeeded()
        return controller
    }
    private func actionLayout(_ language: String, _ size: CGSize) {
        group = "actions-\(language)-\(Int(size.width))x\(Int(size.height))"
        let controller = makeScreen(language, size, large: true)
        guard let cancel: UIButton = element("calling_cancel", in: controller),
              let end: UIButton = element("incall_end", in: controller),
              let title: UILabel = element("incall_status", in: controller),
              let scroll: UIScrollView = element("incall_status_scroll", in: controller) else {
            check(false, "Actual fixed action and status controls exist"); return
        }
        controller.visitorEventForTesting(["t": "state", "state": "in_call", "call_id": "layout-only"])
        title.text = longText(language)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); controller.view.layoutIfNeeded()
        let c = cancel.convert(cancel.bounds, to: controller.view), e = end.convert(end.bounds, to: controller.view)
        let s = scroll.convert(scroll.bounds, to: controller.view)
        check(controller.view.bounds.size == size, "UIKit child uses requested profile dimensions")
        check(abs(c.minY-e.minY) <= 1 && abs(c.maxY-e.maxY) <= 1, "Cancel and end keep identical fixed vertical position")
        check(e.minY >= 0 && e.maxY <= size.height && e.height >= 56 && !end.isHidden, "End is fully visible with safe touch height")
        check((cancel.titleLabel?.font.pointSize ?? 0) > 24, "Action follows largest accessibility text")
        check((cancel.titleLabel?.sizeThatFits(CGSize(width: cancel.bounds.width-cancel.contentEdgeInsets.left-cancel.contentEdgeInsets.right,
            height: .greatestFiniteMagnitude)).height ?? 0) <= cancel.bounds.height, "Cancel label fits the action")
        check(s.height > 0 && s.maxY + 19 <= e.minY && scroll.clipsToBounds, "Status is clipped above fixed end action")
        check(abs(title.bounds.width-scroll.bounds.width) <= 1, "Status width follows the scroll viewport")
        for offset in [CGFloat(0), max(0, scroll.contentSize.height-scroll.bounds.height)] {
            scroll.contentOffset = CGPoint(x: 0, y: offset)
            let visible = title.convert(title.bounds, to: controller.view).intersection(s)
            check(!visible.isNull && !visible.intersects(e), "Visible long title never covers end at offset \(offset)")
        }
        if size.height == 320 { check(scroll.contentSize.height > scroll.bounds.height, "Short landscape exposes overflowing title by scrolling") }
        scroll.contentOffset = .zero
        capture(controller, group)
        controller.suspendCallTimingForTesting()
    }
    private func calls() -> [[String: Any]] { core.callTimingSnapshot()?.document["active_calls"] as? [[String: Any]] ?? [] }
    private func tap(_ id: String, on controller: UIViewController) {
        guard let button: UIButton = element(id, in: controller) else { check(false, "Target exists: " + id); return }
        button.sendActions(for: .touchUpInside)
    }
    private func appendActions() {
        steps.append {
            self.group = "purpose-first-actions"; self.configure("ui.call_flow", "purpose_first")
            let c = self.makeScreen()
            self.capture(c, "home-purpose-first")
            guard let purpose = self.all(c.view).compactMap({ $0 as? PurposeButton }).first else { self.check(false, "Purpose button exists"); return }
            self.savedCall = String((purpose.accessibilityIdentifier ?? "").dropFirst("purpose_".count))
            purpose.sendActions(for: .touchUpInside)
        }
        steps.append {
            guard let c = self.screen else { return }
            self.check(self.calls().count == 1 && self.calls().first?["purpose"] as? String == self.savedCall, "Purpose-first sends selected purpose to actual Core")
            self.check(self.calls().first?["call_flow"] as? String == "purpose_first", "Actual Core preserves purpose-first mode")
            self.savedCall = c.visibleCallForTimingTest
            self.save(["calls": self.calls(), "capabilities": self.core.capabilities() ?? [:]], "purpose-first-diagnostic.json")
            self.check(!self.savedCall.isEmpty, "Visible call ID exists")
            self.tap("incall_end", on: c)
            self.check(c.visibleCallForTimingTest == self.savedCall, "Hidden end cannot end ringing")
            self.capture(c, "purpose-first-calling")
            self.tap("calling_cancel", on: c)
        }
        steps.append {
            self.check(self.calls().isEmpty && self.screen?.visibleCallForTimingTest.isEmpty == true, "Actual cancel ends only the current ringing call")
            self.group = "ring-then-purpose-actions"; self.configure("ui.call_flow", "ring_then_purpose")
            self.tap("call_primary", on: self.makeScreen())
        }
        steps.append {
            guard let c = self.screen, let choice = c.presentedViewController as? PurposeChoiceViewController else { self.check(false, "Ring-first opens actual purpose sheet"); return }
            self.savedCall = c.visibleCallForTimingTest
            self.save(["calls": self.calls(), "capabilities": self.core.capabilities() ?? [:]], "ring-flow-diagnostic.json")
            self.check(self.calls().count == 1 && self.calls().first?["call_flow"] as? String == "ring_then_purpose", "Actual Core rings before purpose")
            self.capture(choice, "ring-first-purpose-sheet")
            self.tap("purpose_choice_skip", on: choice)
        }
        steps.append {
            guard let c = self.screen else { return }
            self.check(c.presentedViewController == nil && c.visibleCallForTimingTest == self.savedCall && self.calls().first?["call_id"] as? String == self.savedCall, "Skip dismisses purpose while preserving the same call")
            self.tap("calling_cancel", on: c)
        }
        steps.append {
            self.check(self.calls().isEmpty, "Ring-first cancel ends current call")
            if let c = self.screen { self.tap("call_primary", on: c) }
        }
        steps.append {
            guard let choice = self.screen?.presentedViewController as? PurposeChoiceViewController else { self.check(false, "Second purpose sheet exists"); return }
            self.tap("purpose_choice_cancel", on: choice)
        }
        steps.append {
            self.check(self.calls().isEmpty && self.screen?.visibleCallForTimingTest.isEmpty == true, "Purpose-sheet cancel is distinct from skip and ends call")
            self.group = "answered-cancel-permission"; self.configure("ui.call_flow", "purpose_first")
            self.tap("call_primary", on: self.makeScreen())
        }
        steps.append {
            guard let c = self.screen else { return }
            self.savedCall = c.visibleCallForTimingTest
            let revision = (self.calls().first?["stage_revision"] as? NSNumber)?.intValue ?? -1
            self.check(!self.savedCall.isEmpty && self.core.reportCallAnswered(door: "front", callId: self.savedCall, stageRevision: revision), "Actual Core accepts answered transition")
            self.tap("calling_cancel", on: c)
            self.check(c.visibleCallForTimingTest == self.savedCall, "Rejected queued cancel cannot render idle")
        }
        steps.append {
            guard let c = self.screen else { return }
            self.check(self.calls().first?["state"] as? String == "in_call", "Actual Core remains in call after queued cancel")
            c.visitorEventForTesting(["t": "state", "state": "in_call", "call_id": self.savedCall])
            self.tap("calling_cancel", on: c)
            self.check(c.visibleCallForTimingTest == self.savedCall && self.calls().first?["state"] as? String == "in_call", "Visible connected UI cannot grant visitor cancel")
            self.capture(c, "answered-cancel-rejected")
            self.group = "offline-sos-layers"
            let offline: UIView? = self.element("visitor_offline_status", in: c)
            let emergency: UIView? = self.element("visitor_sos_screen", in: c)
            self.check(emergency?.isHidden == true && offline?.accessibilityTraits.contains(.header) == true, "Ordinary status is distinct from initially hidden SOS")
            c.visitorEventForTesting(["t": "emergency", "active": true, "channels": ["in_app"], "visual": true, "alarm_sound": ""])
            self.check(emergency?.isHidden == false && emergency?.backgroundColor != c.view.backgroundColor, "Injected presentation shows distinct emergency layer")
            self.capture(c, "sos-presentation-only")
            let clear: UIButton? = self.element("visitor_sos_clear", in: c)
            self.check((clear?.bounds.height ?? 0) >= 44, "Existing clear control preserves touch target")
            c.visitorEventForTesting(["t": "emergency", "active": false])
            self.check(emergency?.isHidden == true, "Presentation clear input hides only presentation")
            c.suspendCallTimingForTesting()
        }
    }
    private func appendSos() {
        steps.append {
            self.group = "sos-accessible-actions"
            let host = UIViewController(); self.window?.rootViewController = host; self.sosHost = host
            let texts = Texts(); texts.setLang("en")
            let control = SosSlideControl(texts: texts); self.sos = control
            control.frame = CGRect(x: 0, y: 200, width: 390, height: 78)
            control.onTriggered = { self.sosTriggers += 1 }
            host.view.addSubview(control)
            self.check(control.accessibilityActivate(), "Actual accessibility activation opens review")
            self.check(!control.isCountingDown && self.sosTriggers == 0, "Review alone cannot trigger or start countdown")
        }
        steps.append {
            guard let host = self.sosHost, let control = self.sos else { return }
            let review = host.presentedViewController as? UIAlertController
            self.check(review?.actions.count == 2 && review?.actions.filter({ $0.style == .destructive }).count == 1, "Actual UIKit review has cancel and explicit start")
            self.capture(host, "sos-review-underlay")
            if let review = review { self.capture(review, "sos-review") }
            control.cancelCountdown(); host.dismiss(animated: false)
            control.startCountdown()
            self.check(control.isCountingDown && control.accessibilityActivate() && !control.isCountingDown, "Accessible action cancels the same countdown")
            self.check(self.sosTriggers == 0 && !(control.keyCommands?.isEmpty ?? true), "No external trigger and keyboard action exists")
            control.startCountdown(); control.removeFromSuperview(); host.view.addSubview(control)
        }
        steps.append {
            guard let control = self.sos else { return }
            self.check(control.isCountingDown, "Same-pass reparenting preserves cancellable countdown")
            control.removeFromSuperview()
        }
        steps.append {
            guard let control = self.sos else { return }
            self.check(!control.isCountingDown && !control.accessibilityActivate(), "True detachment retires countdown and activation")
            self.sosHost?.view.addSubview(control); control.isEnabled = false
            self.check(!control.accessibilityActivate() && self.sosTriggers == 0, "Disabled SOS cannot trigger")
        }
        steps.append {
            guard let control = self.sos else { return }
            control.isEnabled = true
            control.sendActions(for: .primaryActionTriggered)
            self.check(self.sosHost?.presentedViewController is UIAlertController && !control.isCountingDown,
                       "Actual primary-action target requires review")
            control.cancelCountdown()
            self.sosHost?.dismiss(animated: false)
        }
        steps.append {
            guard let control = self.sos, let command = control.keyCommands?.first,
                  let action = command.action else {
                self.check(false, "Keyboard command exists"); return
            }
            let delivered = UIApplication.shared.sendAction(action, to: control, from: command, for: nil)
            self.check(delivered && self.sosHost?.presentedViewController is UIAlertController && !control.isCountingDown,
                       "Actual keyboard target requires the same review")
            control.cancelCountdown(); self.sosHost?.dismiss(animated: false)
            self.check(self.sosTriggers == 0, "All SOS UI paths stayed inside the counter boundary")
        }
    }
    private func retireLocalCall() {
        if let call = calls().first, let id = call["call_id"] as? String {
            if call["state"] as? String == "in_call" {
                _ = core.reportCallEnded(door: "front", callId: id,
                    stageRevision: (call["stage_revision"] as? NSNumber)?.intValue ?? 0)
            } else { _ = core.cancelCall(door: "front", callId: id) }
        }
        screen?.visitorEventForTesting(["t": "state", "state": "idle"])
    }
    private func appendHeldActions() {
        steps.append {
            self.group = "held-cancel-cross-call"; self.retireLocalCall()
            self.tap("call_primary", on: self.makeScreen())
        }
        steps.append {
            guard let c = self.screen, let button: UIButton = self.element("calling_cancel", in: c) else { self.check(false, "Actual cancel target exists"); return }
            self.savedCall = c.visibleCallForTimingTest; self.heldButton = button
            self.check(!self.savedCall.isEmpty, "Actual Core call A exists before held cancel")
            button.sendActions(for: .touchDown)
            self.check(self.core.cancelCall(door: "front", callId: self.savedCall), "External local test actor ends A")
            c.visitorEventForTesting(["t": "event", "type": "call_cancelled", "call_id": self.savedCall])
            self.tap("call_primary", on: c)
        }
        steps.append {
            guard let c = self.screen else { return }
            let successor = c.visibleCallForTimingTest
            self.check(!successor.isEmpty && successor != self.savedCall && self.calls().first?["call_id"] as? String == successor, "Same screen now owns actual distinct Core call B")
            self.heldButton?.sendActions(for: .touchUpInside)
            self.check(c.visibleCallForTimingTest == successor && self.calls().first?["call_id"] as? String == successor,
                       "Held A cancel release cannot cancel successor B")
            self.capture(c, "held-cancel-cross-call")
            self.retireLocalCall()
            self.tap("call_primary", on: c)
        }
        steps.append {
            self.group = "held-end-cross-call"
            guard let c = self.screen, let button: UIButton = self.element("incall_end", in: c) else { self.check(false, "Actual end target exists"); return }
            self.savedCall = c.visibleCallForTimingTest; self.heldButton = button
            self.check(!self.savedCall.isEmpty && self.core.reportCallAnswered(door: "front", callId: self.savedCall,
                stageRevision: (self.calls().first?["stage_revision"] as? NSNumber)?.intValue ?? 0), "Actual Core call A answered")
            c.visitorEventForTesting(["t": "state", "state": "in_call", "call_id": self.savedCall])
            button.sendActions(for: .touchDown)
            self.retireLocalCall()
            self.tap("call_primary", on: c)
        }
        steps.append {
            guard let c = self.screen else { return }
            let successor = c.visibleCallForTimingTest
            self.check(!successor.isEmpty && successor != self.savedCall && self.core.reportCallAnswered(door: "front", callId: successor,
                stageRevision: (self.calls().first?["stage_revision"] as? NSNumber)?.intValue ?? 0), "Actual distinct Core call B answered")
            c.visitorEventForTesting(["t": "state", "state": "in_call", "call_id": successor])
            self.heldButton?.sendActions(for: .touchUpInside)
            let end: UIButton? = self.element("incall_end", in: c)
            self.check(c.visibleCallForTimingTest == successor && end?.superview?.isHidden == false,
                       "Held A end release cannot dismiss successor B")
            self.capture(c, "held-end-cross-call")
            self.retireLocalCall()
        }
        steps.append {
            self.group = "nil-id-and-assistive-end"
            guard let c = self.screen, let end: UIButton = self.element("incall_end", in: c) else { return }
            c.visitorEventForTesting(["t": "state", "state": "in_call"])
            end.sendActions(for: .touchDown); end.sendActions(for: .touchUpInside)
            self.check(end.superview?.isHidden == true, "Normal held end remains usable for nil-ID SIP UI")
            c.visitorEventForTesting(["t": "state", "state": "in_call"])
            end.sendActions(for: .touchUpInside)
            self.check(end.superview?.isHidden == true, "Assistive end without touchDown remains usable")
            c.visitorEventForTesting(["t": "state", "state": "in_call"])
            end.sendActions(for: .touchDown)
            c.visitorEventForTesting(["t": "state", "state": "idle"])
            c.visitorEventForTesting(["t": "state", "state": "in_call"])
            end.sendActions(for: .touchUpInside)
            self.check(end.superview?.isHidden == false, "Held nil-ID end cannot cross idle into another SIP UI session")
            end.sendActions(for: .touchCancel)
            end.sendActions(for: .touchUpInside)
            self.check(end.superview?.isHidden == true, "Retired physical input permits current assistive end")
        }
        steps.append {
            self.group = "held-end-core-generation"
            guard let c = self.screen, let end: UIButton = self.element("incall_end", in: c) else { return }
            c.visitorEventForTesting(["t": "state", "state": "in_call"])
            end.sendActions(for: .touchDown)
            let previous = self.core.runningGeneration
            self.waiting = true
            self.core.stop {
                let directory = self.output.appendingPathComponent("restart-" + UUID().uuidString)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                self.check(self.core.start(dataDir: directory.path, bootJson: "{\"role\":\"door_station\",\"door\":\"front\",\"listen_port\":0,\"http_port\":0}"), "Owned actual Core restarts")
                self.check(self.core.runningGeneration != previous, "Actual Core generation changes")
                end.sendActions(for: .touchUpInside)
                self.check(end.superview?.isHidden == false, "Held end cannot cross Core restart with same nil-ID UI")
                end.sendActions(for: .touchUpInside)
                self.check(end.superview?.isHidden == true, "Current assistive end works after rejected old Core gesture")
                self.waiting = false
            }
        }
    }
    private func offlinePresentation() {
        group = "actual-offline-presentation"
        screen?.suspendCallTimingForTesting()
        let stoppedCore = CoreBridge()
        var boot = BootConfig(); boot.door = "front"; boot.uiLang = "en"
        let controller = MainViewController(core: stoppedCore, boot: boot, runtime: nil)
        controller.suppressVisitorMediaForTesting = true
        screen = controller
        mount(controller, size: CGSize(width: 768, height: 1024), large: false)
        let title: UILabel? = element("visitor_offline_status", in: controller)
        let emergency: UIView? = element("visitor_sos_screen", in: controller)
        var visible = title != nil
        var ancestor: UIView? = title
        while let current = ancestor { visible = visible && !current.isHidden && current.alpha > 0; ancestor = current.superview }
        check(visible && title?.window === window, "Stopped Core shows actual visible offline status")
        check(emergency?.isHidden == true, "Ordinary offline state does not show SOS")
        let background = title?.superview?.superview?.backgroundColor ?? controller.view.backgroundColor
        check(background != UIColor(red: 0.55, green: 0.10, blue: 0.09, alpha: 1), "Offline surface differs from SOS warning control")
        capture(controller, "actual-offline")
        controller.suspendCallTimingForTesting()
    }
#endif
    private func finish() {
#if !T35_BASELINE
        screen?.suspendCallTimingForTesting()
        core.stop { self.writeResult() }
#else
        writeResult()
#endif
    }
    private func writeResult() {
        save(["checks": checks, "failed": checks.filter { ($0["pass"] as? Bool) != true }.count,
            "bundle": Bundle.main.bundleIdentifier ?? "", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "", "system_version": UIDevice.current.systemVersion,
            "source_manifest": Bundle.main.object(forInfoDictionaryKey: "T35SourceManifest") ?? "", "pid": ProcessInfo.processInfo.processIdentifier,
            "scope": "Physical UIKit with virtual-size child profiles. Production UI unchanged; Core has no peers or family configuration. No camera, real call, SOS or lock action. UIView tree is not a VoiceOver navigation record."], "result.json")
    }
}
