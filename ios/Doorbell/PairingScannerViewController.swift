// Full-screen Add-QR scanner (spec §5.1 item 4).
//
// AVFoundation metadata detection reads the QR; the payload Core defines is `doorbell-pair:`.
// The earlier implementation looked for `doorbell-join:`, which no device has ever produced.
// A camera-less or camera-denied device gets a message, never a blank preview.
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

    private let viewfinder = UIView()
    private let hintLabel = UILabel()
    private let messageLabel = UILabel()
    private lazy var cancelButton = PairingTheme.button(texts.t("admin.cancel"))

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func buildUi() {
        viewfinder.layer.borderColor = PairingTheme.accent.cgColor
        viewfinder.layer.borderWidth = 3
        viewfinder.layer.cornerRadius = 16
        viewfinder.backgroundColor = .clear
        viewfinder.translatesAutoresizingMaskIntoConstraints = false
        viewfinder.accessibilityIdentifier = "pair_scan_viewfinder"
        view.addSubview(viewfinder)

        hintLabel.text = texts.t("pair.scan_hint")
        hintLabel.font = .systemFont(ofSize: PairingTheme.bodySize, weight: .semibold)
        hintLabel.textColor = .white
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        messageLabel.font = .systemFont(ofSize: PairingTheme.bodySize)
        messageLabel.textColor = PairingTheme.danger
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.accessibilityIdentifier = "pair_scan_message"
        view.addSubview(messageLabel)

        cancelButton.addTarget(self, action: #selector(cancel), for: .primaryActionTriggered)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.accessibilityIdentifier = "pair_scan_cancel"
        view.addSubview(cancelButton)

        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            viewfinder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            viewfinder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            viewfinder.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.62),
            viewfinder.heightAnchor.constraint(equalTo: viewfinder.widthAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: viewfinder.topAnchor, constant: -24),
            hintLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            hintLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),
            messageLabel.topAnchor.constraint(equalTo: viewfinder.bottomAnchor, constant: 24),
            messageLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),
            cancelButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -28),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
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
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer
        session.startRunning()
    }

    private func showUnavailable(denied: Bool) {
        viewfinder.isHidden = true
        hintLabel.isHidden = true
        messageLabel.text = texts.t(denied ? "pair.scan_denied" : "pair.scan_no_camera")
        messageLabel.isHidden = false
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivered else { return }
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let value = code.stringValue else { continue }
            guard let payload = PairingQR.parse(value) else {
                // Keep scanning: a foreign QR is a mis-aim, not a failure of the flow.
                messageLabel.textColor = PairingTheme.danger
                messageLabel.text = texts.t("pair.add_failed")
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
#endif
