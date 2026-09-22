import UIKit

@UIApplicationMain
final class PeerFrameRunnerDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let bridge = CoreBridge()
    private var screen: MainViewController?
    private var checks: [[String: Any]] = []
    private var ownedDirectory: URL!
    private let output = URL(fileURLWithPath: "/var/mobile/Library/DoorbellT15UIKit", isDirectory: true)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.isIdleTimerDisabled = true
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        ownedDirectory = output.appendingPathComponent("core-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: ownedDirectory, withIntermediateDirectories: true)
        let host = UIWindow(frame: UIScreen.main.bounds)
        host.rootViewController = UIViewController()
        window = host
        host.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runPeerFrame() }
        return true
    }
    private func save(_ value: Any, _ name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]) else { return }
        try? data.write(to: output.appendingPathComponent(name), options: .atomic)
    }
    @discardableResult private func check(_ value: Bool, _ name: String) -> Bool {
        checks.append(["name": name, "pass": value])
        save(["checks": checks, "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""], "progress.json")
        return value
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func capture(_ name: String) {
        guard let view = screen?.view else { return }
        view.setNeedsLayout(); view.layoutIfNeeded()
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 1)
        if let context = UIGraphicsGetCurrentContext() { view.layer.render(in: context) }
        let image = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext()
        if let data = image?.pngData() { try? data.write(to: output.appendingPathComponent(name + ".png")) }
        let rows: [[String: Any]] = descendants(view).map { element in
            var row: [String: Any] = ["class": NSStringFromClass(type(of: element)), "frame": NSCoder.string(for: element.convert(element.bounds, to: view)), "hidden": element.isHidden, "alpha": element.alpha]
            if let id = element.accessibilityIdentifier { row["identifier"] = id }
            if let label = element as? UILabel { row["text"] = label.text ?? "" }
            if let image = element as? UIImageView { row["has_image"] = image.image != nil }
            return row
        }
        save(rows, name + ".json")
    }
    private func runPeerFrame() {
        var hooks = CoreBridge.LifecycleTestHooks(); hooks.enqueueUi = { _ in }; bridge.setLifecycleTestHooks(hooks)
        let bootJson = "{\"name\":\"T15 isolated UIKit\",\"role\":\"indoor_panel\",\"listen_port\":0,\"http_port\":0}"
        guard check(bridge.start(dataDir: ownedDirectory.path, bootJson: bootJson), "Production CoreBridge starts in owned empty directory") else { finish(); return }
        check(bridge.isRunning, "Production CoreBridge running")
        var boot = BootConfig(); boot.door = "front"; boot.role = "door_station"
        let controller = MainViewController(core: bridge, boot: boot, runtime: nil)
        controller.suppressVisitorMediaForTesting = true
        var currentCall = "call-A"
        controller.callTimingSnapshotForTesting = { [weak bridge] in
            guard let generation = bridge?.runningGeneration else { return nil }
            return CallTiming.Snapshot(document: ["active_calls": [["call_id": currentCall, "door": "front", "state": "in_call", "stage_revision": 0, "dialog_owner": "web-owner"]]], coreGeneration: generation, requestedAt: 0)
        }
        var requests: [(URLRequest, (Data?, URLResponse?) -> Void)] = []
        controller.peerFrameLoadForTesting = { requests.append(($0, $1)) }
        screen = controller
        window?.rootViewController = controller
        controller.loadViewIfNeeded(); controller.view.layoutIfNeeded()
        UIGraphicsBeginImageContext(CGSize(width: 2, height: 2)); UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = UIGraphicsGetImageFromCurrentImageContext()?.pngData(); UIGraphicsEndImageContext()
        guard check(image != nil, "UIKit encodes controlled image") else { finish(); return }
        func reply(_ index: Int, _ call: String, _ sequence: String = "10", _ owner: String = "web-owner") {
            guard self.check(requests.count > index, "Expected intercepted production request \(index)") else { return }
            let headers = ["X-Doorbell-Call-Id": call, "X-Doorbell-Stage-Revision": "0", "X-Doorbell-Dialog-Owner": owner, "X-Doorbell-Media-Generation": "0123456789abcdef0123456789abcdef", "X-Doorbell-Frame-Sequence": sequence]
            requests[index].1(image, HTTPURLResponse(url: requests[index].0.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers))
        }
        controller.setPeerCallForTesting(currentCall); controller.pollPeerFrameForTesting()
        guard check(requests.count == 1, "Call A starts exactly one request") else { finish(); return }
        check(requests[0].0.url!.absoluteString.contains("call_id=call-A"), "Request binds call A")
        check(requests[0].0.url!.absoluteString.contains("stage_revision=0"), "Request binds revision zero")
        currentCall = "call-B"; controller.setPeerCallForTesting(currentCall); controller.pollPeerFrameForTesting()
        check(requests.count == 2, "Call B owns its successor request")
        var accepted: UIImage?
        var step = 0
        func advance() {
            DispatchQueue.main.async {
                switch step {
                case 0:
                    reply(0, "call-A")
                case 1:
                    self.check(controller.peerFrameForTesting == nil, "Late A cannot display in B")
                    self.check(controller.peerPollBusyForTesting, "Late A cannot clear B busy")
                    reply(1, "call-B", "10", "other-owner")
                case 2:
                    self.check(controller.peerFrameForTesting == nil, "Mismatched owner cannot display")
                    self.check(!controller.peerPollBusyForTesting, "Current invalid response settles its own busy")
                    controller.pollPeerFrameForTesting(); reply(2, "call-B")
                case 3:
                    accepted = controller.peerFrameForTesting
                    self.check(accepted != nil, "Call B sequence ten displays an actual UIImage")
                    let visible = self.descendants(controller.view).compactMap { $0 as? UIImageView }.first { $0.image === accepted && accepted != nil }
                    var shown = visible != nil
                    var parent: UIView? = visible
                    while let current = parent { shown = shown && !current.isHidden && current.alpha > 0; parent = current.superview }
                    self.check(shown && visible?.window === self.window && (visible?.bounds.width ?? 0) > 0, "Accepted UIImage is attached to the actual visible UIKit hierarchy")
                    self.capture("accepted-sequence-ten")
                    controller.pollPeerFrameForTesting(); reply(3, "call-B", "10")
                case 4:
                    self.check(controller.peerFrameForTesting === accepted, "Duplicate ten cannot redraw")
                    controller.pollPeerFrameForTesting(); reply(4, "call-B", "9")
                case 5:
                    self.check(controller.peerFrameForTesting === accepted, "Out-of-order nine cannot replace ten")
                    self.capture("duplicate-and-nine-rejected")
                    controller.pollPeerFrameForTesting(); currentCall = ""; controller.setPeerCallForTesting("")
                    reply(5, "call-B", "11")
                default:
                    self.check(controller.peerFrameForTesting == nil, "End clears image and rejects late B delivery")
                    self.capture("ended-late-eleven-rejected")
                    self.finish()
                    return
                }
                step += 1
                advance()
            }
        }
        advance()
    }

    private func finish() {
        bridge.stop { [self] in
            check(!bridge.isRunning, "Owned production CoreBridge stopped")
            let result: [String: Any] = ["checks": checks, "failed": checks.filter { ($0["pass"] as? Bool) != true }.count, "bundle": Bundle.main.bundleIdentifier ?? "", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "", "system_version": UIDevice.current.systemVersion, "source_manifest": Bundle.main.object(forInfoDictionaryKey: "T15SourceManifest") ?? "", "pid": ProcessInfo.processInfo.processIdentifier, "scope": "Unmodified production CoreBridge and MainViewController; production UIImage delivery on physical UIKit. Only network completions and call snapshot inputs are controlled. No real call/SOS/door action."]
            save(result, "result.json")
        }
    }
}
