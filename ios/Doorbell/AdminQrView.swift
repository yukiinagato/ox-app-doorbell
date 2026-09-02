import UIKit

/// The admin page's QR and URL. The owner asked for it to be permanently visible on indoor
/// panels — small in a corner of the incoming/monitor screen, larger in the dashboard footer and
/// in settings — because opening the page still needs the admin password.
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
    private let urlLabel = UILabel()
    private let captionLabel = UILabel()
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

        urlLabel.font = .monospacedDigitSystemFont(ofSize: compact ? 11 : 15, weight: .regular)
        urlLabel.numberOfLines = compact ? 1 : 2
        urlLabel.adjustsFontSizeToFitWidth = true
        urlLabel.minimumScaleFactor = 0.6
        urlLabel.accessibilityIdentifier = "admin_qr_url"

        let column = UIStackView(arrangedSubviews: [captionLabel, urlLabel])
        column.axis = .vertical
        column.spacing = 2

        let row = UIStackView(arrangedSubviews: [imageView, column])
        row.axis = .horizontal
        row.spacing = compact ? 8 : 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let side: CGFloat = compact ? 64 : 160
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
        skin.apply("footer", to: captionLabel, quiet: true)
        skin.apply("footer", to: urlLabel)
    }

    /// Rebuilds the QR when the node's reachable address changes. Rendering is cheap enough to run
    /// inline, and the encoder is Core's, so every shell produces the same payload.
    func reload() {
        let url = adminUrl()
        guard url != renderedUrl else { return }
        renderedUrl = url
        guard !url.isEmpty else {
            imageView.image = nil
            urlLabel.text = texts.t("web_admin.no_address")
            return
        }
        urlLabel.text = url
        imageView.image = PairingQR.image(core: core, text: url,
                                          points: compact ? 128 : 320)
    }

    /// This node's own admin page. IPv4 is preferred because it is what a phone camera can act on
    /// without extra typing; IPv6 is used only when there is nothing else.
    private func adminUrl() -> String {
        var addresses = Set<String>()
        if let node = core.status()?["node"] as? [String: Any],
           let local = node["local_addrs"] as? [String] {
            for value in local where !value.isEmpty { addresses.insert(value) }
        }
        if let debug = core.debugInfo(), let list = debug["addresses"] as? [String] {
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
