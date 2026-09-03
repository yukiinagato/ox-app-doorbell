import UIKit

/// The admin page's QR and URL. It stays visible on indoor panels because opening the page still
/// needs the admin password.
final class AdminQrView: UIView {

    /// The caption and the URL sit straight on the screen background — the footer of the
    /// dashboard, the corner of the incoming screen — so they take the footer region's automatic
    /// ink. The code itself is always drawn on white, because that is what a camera reads.
    var skin = DoorbellSkin.plain(.dark) {
        didSet { applySkin() }
    }

    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts
    private let compact: Bool
    private let imageView = UIImageView()
    private let urlLabel = HaloLabel()
    private let captionLabel = HaloLabel()
    private let detailLabel = HaloLabel()
    private var renderedUrl = ""

    init(core: CoreBridge, boot: BootConfig, texts: Texts, compact: Bool) {
        self.core = core
        self.boot = boot
        self.texts = texts
        self.compact = compact
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "admin_qr"

        imageView.backgroundColor = .white
        imageView.layer.cornerRadius = 6
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.text = texts.t("web_admin.open")
        captionLabel.font = .systemFont(ofSize: compact ? 12 : 15, weight: .semibold)
        captionLabel.numberOfLines = 1
        captionLabel.isHidden = !compact

        urlLabel.font = .monospacedDigitSystemFont(ofSize: compact ? 11 : 13, weight: .regular)
        urlLabel.numberOfLines = 1
        urlLabel.adjustsFontSizeToFitWidth = true
        urlLabel.minimumScaleFactor = 0.6
        urlLabel.accessibilityIdentifier = "admin_qr_url"

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        detailLabel.numberOfLines = 1
        detailLabel.adjustsFontSizeToFitWidth = true
        detailLabel.minimumScaleFactor = 0.6
        detailLabel.accessibilityIdentifier = "app_version"
        detailLabel.isHidden = compact

        let column = UIStackView(arrangedSubviews: [captionLabel, urlLabel, detailLabel])
        column.axis = .vertical
        column.spacing = 2

        let row = UIStackView(arrangedSubviews: [imageView, column])
        row.axis = .horizontal
        row.spacing = compact ? 8 : 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let side: CGFloat = compact ? 64 : 72
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.widthAnchor.constraint(equalToConstant: side),
            imageView.heightAnchor.constraint(equalToConstant: side),
        ])
        applySkin()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func applySkin() {
        if compact {
            skin.apply("footer", to: captionLabel, quiet: true)
            skin.apply("footer", to: urlLabel)
        } else {
            let ink = skin.cardInk("footer")
            urlLabel.textColor = ink
            detailLabel.textColor = ink
        }
    }

    func setDetailText(_ text: String) {
        detailLabel.text = text
    }

    /// Rebuilds the QR when the node's reachable address changes. Rendering is cheap enough to run
    /// inline, and the encoder is Core's, so every shell produces the same payload.
    func reload(status: [String: Any]? = nil) {
        let url = adminUrl(status: status)
        guard url != renderedUrl else { return }
        renderedUrl = url
        guard !url.isEmpty else {
            imageView.image = nil
            urlLabel.text = texts.t("web_admin.no_address")
            return
        }
        urlLabel.text = url
        // Encoding is a nested module loop and a bitmap context. It only runs when the address
        // actually changed, but when it does it has no business blocking a frame.
        let points: CGFloat = compact ? 128 : 144
        let core = self.core
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = PairingQR.image(core: core, text: url, points: points)
            DispatchQueue.main.async {
                guard let self = self, self.renderedUrl == url else { return }
                self.imageView.image = image
            }
        }
    }

    /// This node's own admin page. IPv4 is preferred because it is what a phone camera can act on
    /// without extra typing; IPv6 is used only when there is nothing else.
    /// `status` is the snapshot the page already took. Fetching another one here — plus the
    /// debug document — meant two more Core round-trips and two more JSON parses on every reload,
    /// to almost always arrive at the address it had last time.
    private func adminUrl(status: [String: Any]? = nil) -> String {
        var addresses = Set<String>()
        let snapshot = status ?? core.status()
        if let node = snapshot?["node"] as? [String: Any],
           let local = node["local_addrs"] as? [String] {
            for value in local where !value.isEmpty { addresses.insert(value) }
        }
        // The debug document is only consulted when the status carried no usable address.
        if addresses.filter({ !$0.contains(":") }).isEmpty,
           let debug = core.debugInfo(), let list = debug["addresses"] as? [String] {
            for value in list where !value.isEmpty { addresses.insert(value) }
        }
        let ipv4 = addresses.filter { !$0.contains(":") }.sorted()
        if let first = ipv4.first {
            return "http://\(first):\(boot.httpPort)/admin/"
        }
        guard let first = addresses.sorted().first else { return "" }
        return "http://[\(first)]:\(boot.httpPort)/admin/"
    }
}
