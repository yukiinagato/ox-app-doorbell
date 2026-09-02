// Shared pairing presentation layer for the Apple clients.
//
// Core owns the pairing state machine (docs/en/config-schema.md, "Pairing state and events").
// Nothing here infers a state: every screen renders `pairing.state` from the snapshot Core
// returns and reacts to the pairing events delivered through the UI callback. The same types
// back the iOS onboarding gate, the iOS "Add device" panel, and the tvOS display-only variants.
import UIKit

extension Notification.Name {
    /// Posted whenever Core's pairing snapshot may have changed, so a main screen can repaint
    /// its membership status and its "not set up" banner. Shared by the iOS and tvOS shells.
    static let doorbellPairingChanged = Notification.Name("doorbell.pairingChanged")
    /// Posted by a main screen's banner: reopen the onboarding screen the user deferred.
    static let doorbellOpenPairing = Notification.Name("doorbell.openPairing")
}

/// Authoritative pairing state. `unknown` means Core has not published a snapshot yet, which is
/// never rendered as an error and never gates the main UI.
enum PairingState: String {
    case unknown = ""
    case unpaired
    case joining
    case persistError = "persist_error"
    case ready
    case revoked

    var blocksMainUi: Bool {
        return self == .unpaired || self == .joining || self == .persistError
    }
}

/// One entry of `pending.devices[]` on the inviting device.
struct PairingDevice {
    let id: String
    let addr: String
    let name: String
    let role: String
    let model: String
    let platform: String
    let sw: String
    let ageS: Int
    let inviteState: String
    let attempts: Int
    let lastError: String

    init(_ raw: [String: Any]) {
        id = ConfigUtil.evStr(raw, "id")
        addr = ConfigUtil.evStr(raw, "addr")
        name = ConfigUtil.evStr(raw, "name")
        role = ConfigUtil.evStr(raw, "role")
        model = ConfigUtil.evStr(raw, "model")
        platform = ConfigUtil.evStr(raw, "platform")
        sw = ConfigUtil.evStr(raw, "sw")
        ageS = ConfigUtil.int(raw, "age_s", 0)
        inviteState = ConfigUtil.evStr(raw, "invite_state")
        attempts = ConfigUtil.int(raw, "attempts", 0)
        lastError = ConfigUtil.evStr(raw, "last_error")
    }

    /// Human row title. Never a bare machine identifier when a friendlier value exists.
    var displayName: String {
        if !name.isEmpty { return name }
        let short = String(id.prefix(6))
        if !model.isEmpty { return short.isEmpty ? model : "\(model) · \(short)" }
        return short.isEmpty ? id : short
    }

    /// Secondary row line: role, model and platform, whichever Core reported.
    func subtitle(_ texts: Texts) -> String {
        var parts: [String] = []
        let roleLabel = PairingCopy.roleLabel(texts, role)
        if !roleLabel.isEmpty { parts.append(roleLabel) }
        if PairingCopy.isMeaningful(model) { parts.append(model) }
        if PairingCopy.isMeaningful(platform) { parts.append(platform) }
        if PairingCopy.isMeaningful(sw) { parts.append("v" + sw) }
        return parts.joined(separator: " · ")
    }
}

/// One decoded `db_core_pairing_json` snapshot.
struct PairingSnapshot {
    let hasSnapshot: Bool
    let state: PairingState
    let paired: Bool
    let persistenceReady: Bool
    let isFounder: Bool
    let pskSource: String
    let role: String

    let selfId: String
    let selfName: String
    let selfAddr: String
    let selfModel: String
    let selfPlatform: String

    let pairQr: String
    let memberCount: Int
    let connectedCount: Int

    let tokenActive: Bool
    let tokenExpiresS: Int
    let tokenAttemptsLeft: Int
    let tokenHost: String
    let tokenPin: String

    let pairingMode: Bool
    let pairingModeLeftS: Int
    let autoAddedCount: Int
    let devices: [PairingDevice]

    init(_ raw: [String: Any]?) {
        let root = raw ?? [:]
        let stateText = ConfigUtil.evStr(root, "state")
        hasSnapshot = !stateText.isEmpty
        state = PairingState(rawValue: stateText) ?? .unknown
        paired = ConfigUtil.evBool(root, "paired")
        persistenceReady = ConfigUtil.evBool(root, "persistence_ready")
        isFounder = ConfigUtil.evBool(root, "is_founder")
        pskSource = ConfigUtil.evStr(root, "psk_source")
        role = ConfigUtil.evStr(root, "role")

        let me = root["self"] as? [String: Any] ?? [:]
        selfId = ConfigUtil.evStr(me, "id")
        selfName = ConfigUtil.evStr(me, "name")
        selfAddr = ConfigUtil.evStr(me, "addr")
        selfModel = ConfigUtil.evStr(me, "model")
        selfPlatform = ConfigUtil.evStr(me, "platform")

        pairQr = ConfigUtil.evStr(root, "pair_qr")
        let home = root["home"] as? [String: Any] ?? [:]
        memberCount = ConfigUtil.int(home, "member_count", 0)
        connectedCount = ConfigUtil.int(home, "connected_count", 0)

        let token = root["token"] as? [String: Any] ?? [:]
        tokenActive = ConfigUtil.evBool(token, "active")
        tokenExpiresS = ConfigUtil.int(token, "expires_s", 0)
        tokenAttemptsLeft = ConfigUtil.int(token, "attempts_left", 0)
        tokenHost = ConfigUtil.evStr(token, "host")
        tokenPin = ConfigUtil.evStr(token, "pin")

        let pending = root["pending"] as? [String: Any] ?? [:]
        pairingMode = ConfigUtil.evBool(pending, "pairing_mode")
        pairingModeLeftS = ConfigUtil.int(pending, "pairing_mode_left_s", 0)
        autoAddedCount = ConfigUtil.int(pending, "auto_added_count", 0)
        devices = (pending["devices"] as? [[String: Any]] ?? []).map { PairingDevice($0) }
    }

    static func load(_ core: CoreBridge) -> PairingSnapshot {
        return PairingSnapshot(core.pairing())
    }

    /// Identity line for the onboarding header: name, model, address. A device that never
    /// declared a model reports the placeholder "unknown", which is noise on a setup screen.
    func identityLine() -> String {
        var parts: [String] = []
        if !selfName.isEmpty { parts.append(selfName) }
        if PairingCopy.isMeaningful(selfModel) { parts.append(selfModel) }
        if !selfAddr.isEmpty { parts.append(selfAddr) }
        return parts.joined(separator: " · ")
    }
}

/// Localized copy helpers. No user-facing literal ever appears outside i18n/strings.yaml.
enum PairingCopy {

    /// Maps a Core error code onto `pair.err.<code>`, falling back to `pair.err.unknown`.
    static func error(_ texts: Texts, _ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return texts.t("pair.err.unknown") }
        let key = "pair.err." + trimmed
        let message = texts.t(key)
        return message == key ? texts.t("pair.err.unknown") : message
    }

    /// Raw codes are never the primary message; they belong on a small details line.
    static func errorDetail(_ texts: Texts, _ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : texts.t("pair.err_detail", trimmed)
    }

    /// Core fills absent device facts with "unknown"; those are never worth showing.
    static func isMeaningful(_ value: String) -> Bool {
        return !value.isEmpty && value != "unknown" && value != "-"
    }

    static func roleLabel(_ texts: Texts, _ role: String) -> String {
        switch role {
        case "door_station": return texts.t("admin.role_door")
        case "indoor_panel": return texts.t("admin.role_indoor")
        default: return role
        }
    }

    /// Splits a countdown into the {m} and {s} placeholders the catalog uses.
    static func clock(_ seconds: Int) -> (String, String) {
        let total = max(0, seconds)
        return ("\(total / 60)", String(format: "%02d", total % 60))
    }

    static func expiresIn(_ texts: Texts, _ seconds: Int) -> String {
        let parts = clock(seconds)
        return texts.t("pair.code_expires_in", parts.0, parts.1)
    }

    static func addAllOn(_ texts: Texts, leftS: Int, added: Int) -> String {
        let parts = clock(leftS)
        return texts.t("pair.add_all_on", parts.0, parts.1, "\(added)")
    }
}

/// Dark/amber palette shared by every pairing surface, matching the main UI.
enum PairingTheme {
    static let background = UIColor(red: 0.063, green: 0.078, blue: 0.094, alpha: 1)
    static let card = UIColor(white: 1, alpha: 0.08)
    static let foreground = UIColor(white: 0.94, alpha: 1)
    static let dim = UIColor(white: 0.62, alpha: 1)
    static let accent = UIColor(red: 1.0, green: 0.80, blue: 0.25, alpha: 1)
    static let danger = UIColor(red: 0.88, green: 0.36, blue: 0.30, alpha: 1)
    static let ok = UIColor(red: 0.42, green: 0.80, blue: 0.45, alpha: 1)

#if os(tvOS)
    static let titleSize: CGFloat = 54
    static let bodySize: CGFloat = 30
    static let smallSize: CGFloat = 24
    static let buttonSize: CGFloat = 30
    static let codeSize: CGFloat = 64
    static let qrSize: CGFloat = 420
#else
    static let titleSize: CGFloat = 30
    static let bodySize: CGFloat = 19
    static let smallSize: CGFloat = 15
    static let buttonSize: CGFloat = 20
    static let codeSize: CGFloat = 44
    static let qrSize: CGFloat = 260
#endif

    static func label(_ size: CGFloat, _ color: UIColor, bold: Bool = false) -> UILabel {
        let label = UILabel()
        label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    static func button(_ title: String, filled: Bool = false) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: buttonSize, weight: .semibold)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.setTitleColor(filled ? .black : foreground, for: .normal)
        button.setTitleColor(dim, for: .disabled)
        button.backgroundColor = filled ? accent : card
        button.layer.cornerRadius = 12
#if !os(tvOS)
        // tvOS supplies its own focus-aware padding and ignores this on modern releases.
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 22, bottom: 12, right: 22)
#endif
        return button
    }

    static func cardView() -> UIView {
        let view = UIView()
        view.backgroundColor = card
        view.layer.cornerRadius = 14
        return view
    }
}

/// Renders `pair_qr` through the Core encoder. Core owns the payload format, so the shells never
/// build a `doorbell-pair:` string themselves.
enum PairingQR {
    static let payloadPrefix = "doorbell-pair:"

    static func image(core: CoreBridge, text: String, points: CGFloat) -> UIImage? {
        guard !text.isEmpty, points > 0, let encoded = core.qrEncode(text) else { return nil }
        let modules = encoded.size
        guard modules > 0, encoded.bytes.count >= modules * modules else { return nil }
        let quiet = 2
        let side = modules + quiet * 2
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<modules {
            for x in 0..<modules where encoded.bytes[y * modules + x] != 0 {
                let offset = (((y + quiet) * side) + (x + quiet)) * 4
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let bitmap = CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else { return nil }

        let size = CGSize(width: points, height: points)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        defer { UIGraphicsEndImageContext() }
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
        // A QR payload is not vertically symmetric, so undo the UIKit context flip.
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(bitmap, in: rect)
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    /// Splits `doorbell-pair:<addr>|<id>|<pk>`. Returns nil for any other payload.
    static func parse(_ text: String) -> (addr: String, id: String, pk: String)? {
        guard text.hasPrefix(payloadPrefix) else { return nil }
        let body = text.dropFirst(payloadPrefix.count)
        let parts = body.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let addr = String(parts[0])
        let id = String(parts[1])
        let pk = String(parts[2])
        guard !addr.isEmpty, !id.isEmpty, !pk.isEmpty else { return nil }
        return (addr, id, pk)
    }
}

/// The device's own Add QR with its mandatory caption. Shows a placeholder while Core has not
/// published `pair_qr`, so the box is never a blank white square.
final class PairingQrCardView: UIView {
    private let texts: Texts
    private let core: CoreBridge
    private let imageView = UIImageView()
    private let placeholder = UILabel()
    private let caption = UILabel()
    private var renderedPayload = ""

    init(core: CoreBridge, texts: Texts) {
        self.core = core
        self.texts = texts
        super.init(frame: .zero)

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = UIColor(white: 1, alpha: 0.06)
        imageView.layer.cornerRadius = 8
        imageView.clipsToBounds = true
        imageView.accessibilityIdentifier = "pair_own_qr"
        imageView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.text = texts.t("pair.searching")
        placeholder.font = .systemFont(ofSize: PairingTheme.smallSize)
        placeholder.textColor = PairingTheme.dim
        placeholder.textAlignment = .center
        placeholder.numberOfLines = 0
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        caption.text = texts.t("pair.qr_caption")
        caption.font = .systemFont(ofSize: PairingTheme.smallSize)
        caption.textColor = PairingTheme.dim
        caption.textAlignment = .center
        caption.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [imageView, caption])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        imageView.addSubview(placeholder)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.widthAnchor.constraint(equalToConstant: PairingTheme.qrSize),
            imageView.heightAnchor.constraint(equalToConstant: PairingTheme.qrSize),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
            placeholder.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            placeholder.widthAnchor.constraint(equalTo: imageView.widthAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(payload: String) {
        guard payload != renderedPayload else { return }
        renderedPayload = payload
        guard !payload.isEmpty,
              let image = PairingQR.image(core: core, text: payload,
                                          points: PairingTheme.qrSize) else {
            imageView.image = nil
            placeholder.isHidden = false
            return
        }
        imageView.image = image
        placeholder.isHidden = true
    }
}

/// The "Add with a Pairing PIN" card: authoritative address, live PIN, countdown and attempts.
/// It re-renders itself from `pairing.token` so reopening a screen never loses a live code.
final class PairingCodeCardView: UIView {
    var onNewCode: (() -> Void)?

    private let texts: Texts
    private let title = UILabel()
    private let addressLabel = UILabel()
    private let addressValue = UILabel()
    private let addressCopy = UIButton(type: .system)
    private let codeLabel = UILabel()
    private let codeValue = UILabel()
    private let codeCopy = UIButton(type: .system)
    private let countdown = UILabel()
    private let attempts = UILabel()
    private let instructions = UILabel()
    private let expired = UILabel()
    private let newCodeButton: UIButton

    init(texts: Texts) {
        self.texts = texts
        newCodeButton = PairingTheme.button(texts.t("pair.add_with_code"), filled: true)
        super.init(frame: .zero)
        backgroundColor = PairingTheme.card
        layer.cornerRadius = 14

        title.text = texts.t("pair.add_with_code")
        title.font = .boldSystemFont(ofSize: PairingTheme.bodySize)
        title.textColor = PairingTheme.foreground

        addressLabel.text = texts.t("pair.address_label")
        addressLabel.font = .systemFont(ofSize: PairingTheme.smallSize)
        addressLabel.textColor = PairingTheme.dim

        addressValue.font = UIFont.monospacedDigitSystemFont(ofSize: PairingTheme.bodySize,
                                                             weight: .semibold)
        addressValue.textColor = PairingTheme.foreground
        addressValue.numberOfLines = 0
        addressValue.accessibilityIdentifier = "pair_code_address"

        codeLabel.text = texts.t("pair.code_label")
        codeLabel.font = .systemFont(ofSize: PairingTheme.smallSize)
        codeLabel.textColor = PairingTheme.dim

        codeValue.font = UIFont.monospacedDigitSystemFont(ofSize: PairingTheme.codeSize,
                                                          weight: .bold)
        codeValue.textColor = PairingTheme.accent
        codeValue.accessibilityIdentifier = "pair_code_pin"

        countdown.font = UIFont.monospacedDigitSystemFont(ofSize: PairingTheme.bodySize,
                                                          weight: .medium)
        countdown.textColor = PairingTheme.foreground

        attempts.font = .systemFont(ofSize: PairingTheme.smallSize)
        attempts.textColor = PairingTheme.dim

        instructions.text = texts.t("pair.code_instructions")
        instructions.font = .systemFont(ofSize: PairingTheme.smallSize)
        instructions.textColor = PairingTheme.dim
        instructions.numberOfLines = 0

        expired.text = texts.t("pair.code_expired")
        expired.font = .systemFont(ofSize: PairingTheme.bodySize, weight: .semibold)
        expired.textColor = PairingTheme.danger
        expired.numberOfLines = 0
        expired.isHidden = true

        newCodeButton.addTarget(self, action: #selector(newCodeTapped),
                                for: .primaryActionTriggered)

        for (button, identifier) in [(addressCopy, "pair_copy_address"),
                                     (codeCopy, "pair_copy_pin")] {
            button.setTitle(texts.t("pair.copy"), for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: PairingTheme.smallSize)
            button.setTitleColor(PairingTheme.accent, for: .normal)
            button.accessibilityIdentifier = identifier
            button.addTarget(self, action: #selector(copyTapped(_:)),
                             for: .primaryActionTriggered)
#if os(tvOS)
            // tvOS has no pasteboard; the value is read off the screen instead.
            button.isHidden = true
#endif
        }

        let addressRow = UIStackView(arrangedSubviews: [addressValue, addressCopy])
        addressRow.axis = .horizontal
        addressRow.spacing = 12
        addressRow.alignment = .center
        let codeRow = UIStackView(arrangedSubviews: [codeValue, codeCopy])
        codeRow.axis = .horizontal
        codeRow.spacing = 12
        codeRow.alignment = .center
        let countdownRow = UIStackView(arrangedSubviews: [countdown, attempts])
        countdownRow.axis = .horizontal
        countdownRow.spacing = 16
        countdownRow.alignment = .firstBaseline

        let stack = UIStackView(arrangedSubviews: [title, addressLabel, addressRow, codeLabel,
                                                   codeRow, countdownRow, expired,
                                                   newCodeButton, instructions])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
        IOSAvailability.setCustomSpacing(16, after: addressRow, in: stack)
        IOSAvailability.setCustomSpacing(14, after: countdownRow, in: stack)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Renders one snapshot. An inactive token keeps the card visible with the expiry message so
    /// a user who looked away is told what happened instead of finding an empty box.
    func update(_ snapshot: PairingSnapshot) {
        let live = snapshot.tokenActive && snapshot.tokenExpiresS > 0
        addressValue.text = snapshot.tokenHost.isEmpty
            ? texts.t("pair.address_example") : snapshot.tokenHost
        codeValue.text = live && !snapshot.tokenPin.isEmpty ? snapshot.tokenPin : "······"
        countdown.text = live ? PairingCopy.expiresIn(texts, snapshot.tokenExpiresS) : ""
        attempts.text = live ? texts.t("pair.code_attempts_left",
                                       "\(snapshot.tokenAttemptsLeft)") : ""
        countdown.isHidden = !live
        attempts.isHidden = !live
        expired.isHidden = live
        newCodeButton.isHidden = live
        addressCopy.isEnabled = !snapshot.tokenHost.isEmpty
        codeCopy.isEnabled = live
        instructions.isHidden = !live
    }

    @objc private func newCodeTapped() { onNewCode?() }

    @objc private func copyTapped(_ sender: UIButton) {
#if os(iOS)
        let value = sender === codeCopy ? codeValue.text : addressValue.text
        UIPasteboard.general.string = value ?? ""
        sender.setTitle(texts.t("pair.copy"), for: .normal)
#endif
    }
}
