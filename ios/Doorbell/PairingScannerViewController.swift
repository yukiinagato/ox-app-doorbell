// Full-screen Add-QR scanner (spec §5.1 item 4).
//
// AVFoundation metadata detection reads the QR; the payload Core defines is `doorbell-pair:`.
// The earlier implementation looked for `doorbell-join:`, which no device has ever produced.
// A camera-less or camera-denied device gets a message, never a blank preview.
//
// The screen is presented as itself and hosts its own navigation controller: Cancel and the
// camera switch are bar button items, and only the viewfinder over the preview is custom.
#if os(iOS)
import AVFoundation
import UIKit

final class PairingScannerViewController: UIViewController,
                                          AVCaptureMetadataOutputObjectsDelegate {

    private let texts: Texts
    private let onPayload: ((addr: String, id: String, pk: String)) -> Void
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    private let stage = PairingScannerStage()
    private let viewfinder = UIView()
    private let card = MaterialCardView(cornerRadius: 14)
    private let hintLabel = SystemStyle.label(.body, weight: .semibold)
    private let messageLabel = SystemStyle.label(.subheadline, color: SystemStyle.negative)
    private lazy var switchItem: UIBarButtonItem = {
        // Opens on the back camera; a panel on a wall or a stand can flip to the front one.
        let item = UIBarButtonItem(title: texts.t("pair.scan_switch_camera"), style: .plain,
                                   target: self, action: #selector(switchCamera))
        item.accessibilityIdentifier = "pair_scan_switch_camera"
        return item
    }()
    private var currentInput: AVCaptureDeviceInput?

    init(texts: Texts, onPayload: @escaping ((addr: String, id: String, pk: String)) -> Void) {
        self.texts = texts
        self.onPayload = onPayload
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUi()
        requestAccessAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override var childForStatusBarStyle: UIViewController? { return children.first }

    private func buildUi() {
        let nav = SystemStyle.navigation(stage, largeTitles: false)
        // A camera screen is dark whatever the household appearance is, so the bar keeps its
        // material over the preview and its text stays legible.
        if #available(iOS 13.0, *) {
            overrideUserInterfaceStyle = .dark
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            nav.navigationBar.standardAppearance = appearance
            nav.navigationBar.scrollEdgeAppearance = appearance
        } else {
            nav.navigationBar.barStyle = .black
        }
        addChild(nav)
        nav.view.frame = view.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(nav.view)
        nav.didMove(toParent: self)

        stage.title = texts.t("pair.scan_qr")
        let cancelItem = UIBarButtonItem(title: texts.t("admin.cancel"), style: .plain,
                                         target: self, action: #selector(cancel))
        cancelItem.accessibilityIdentifier = "pair_scan_cancel"
        stage.navigationItem.leftBarButtonItem = cancelItem
        stage.view.backgroundColor = .black
        stage.onLayout = { [weak self] in
            guard let self = self else { return }
            self.preview?.frame = self.stage.view.bounds
        }

        viewfinder.layer.borderColor = UIColor.white.cgColor
        viewfinder.layer.borderWidth = 3
        viewfinder.layer.cornerRadius = 16
        viewfinder.backgroundColor = .clear
        viewfinder.translatesAutoresizingMaskIntoConstraints = false
        viewfinder.accessibilityIdentifier = "pair_scan_viewfinder"
        stage.view.addSubview(viewfinder)

        hintLabel.text = texts.t("pair.scan_hint")
        hintLabel.textAlignment = .center
        messageLabel.textAlignment = .center
        messageLabel.isHidden = true
        messageLabel.accessibilityIdentifier = "pair_scan_message"
        let stack = UIStackView(arrangedSubviews: [hintLabel, messageLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        stage.view.addSubview(card)

        let guide = IOSAvailability.safeAreaLayoutGuide(for: stage.view)
        let side = viewfinder.widthAnchor.constraint(equalTo: stage.view.widthAnchor,
                                                     multiplier: 0.62)
        side.priority = .defaultHigh
        let centered = viewfinder.centerYAnchor.constraint(equalTo: stage.view.centerYAnchor)
        centered.priority = .defaultLow
        NSLayoutConstraint.activate([
            viewfinder.centerXAnchor.constraint(equalTo: stage.view.centerXAnchor),
            centered,
            side,
            viewfinder.heightAnchor.constraint(equalTo: viewfinder.widthAnchor),
            viewfinder.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 16),
            viewfinder.bottomAnchor.constraint(lessThanOrEqualTo: card.topAnchor, constant: -16),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor,
                                          constant: 16),
            card.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor,
                                           constant: -16),
            card.centerXAnchor.constraint(equalTo: stage.view.centerXAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            card.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor,
                                          constant: -14),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor,
                                           constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor,
                                            constant: -16),
        ])
    }

    private func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted { self.startSession() } else { self.showUnavailable(denied: true) }
                }
            }
        default:
            showUnavailable(denied: true)
        }
    }

    private func startSession() {
        guard let device = IOSAvailability.qrScanCaptureDevice(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showUnavailable(denied: false)
            return
        }
        session.addInput(input)
        currentInput = input
        let canSwitch = Self.device(at: .front) != nil && Self.device(at: .back) != nil
        stage.navigationItem.rightBarButtonItem = canSwitch ? switchItem : nil
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showUnavailable(denied: false)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = stage.view.bounds
        stage.view.layer.insertSublayer(layer, at: 0)
        preview = layer
        session.startRunning()
    }

    private static func device(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
#if IOS9_COMPAT
        return AVCaptureDevice.devices(for: .video).first(where: { $0.position == position })
#else
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
#endif
    }

    @objc private func switchCamera() {
        guard let current = currentInput else { return }
        let next: AVCaptureDevice.Position = current.device.position == .front ? .back : .front
        guard let device = Self.device(at: next),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.removeInput(current)
        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        } else {
            session.addInput(current)
        }
        session.commitConfiguration()
        messageLabel.isHidden = true
    }

    private func showUnavailable(denied: Bool) {
        stage.navigationItem.rightBarButtonItem = nil
        viewfinder.isHidden = true
        hintLabel.isHidden = true
        messageLabel.text = texts.t(denied ? "pair.scan_camera_denied" : "pair.scan_no_camera")
        messageLabel.isHidden = false
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivered else { return }
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let value = code.stringValue else { continue }
            // An invitation QR carries the same doorbell://pair link a tapped one does, so both
            // arrive at the one screen that knows how to confirm it.
            if value.lowercased().hasPrefix("\(PairUri.scheme)://\(PairUri.action)") {
                delivered = true
                session.stopRunning()
                dismiss(animated: true) {
                    NotificationCenter.default.post(name: .doorbellPairInvitation, object: value)
                }
                return
            }
            guard let payload = PairingQR.parse(value) else {
                // Keep scanning: a foreign QR is a mis-aim, not a failure of the flow.
                messageLabel.text = texts.t("pair.scan_not_device_qr")
                messageLabel.isHidden = false
                continue
            }
            delivered = true
            session.stopRunning()
            dismiss(animated: true) { [onPayload] in onPayload(payload) }
            return
        }
    }

    @objc private func cancel() {
        session.stopRunning()
        dismiss(animated: true)
    }
}

/// The scanner's content controller: it only reports its layout so the preview layer follows.
private final class PairingScannerStage: UIViewController {
    var onLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}
#endif
