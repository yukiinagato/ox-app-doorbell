// Shared pairing presentation layer for the Apple clients.
//
// Core owns the pairing state machine (docs/en/config-schema.md, "Pairing state and events").
// Nothing here infers a state: every screen renders `pairing.state` from the snapshot Core
// returns and reacts to the pairing events delivered through the UI callback. The same types
// back the iOS onboarding gate, the iOS "Add device" panel, and the tvOS display-only variants,
// together with the grouped-table building blocks those screens share.
import UIKit

extension Notification.Name {
    /// Posted whenever Core's pairing snapshot may have changed, so a main screen can repaint
    /// its membership status and its "not set up" banner. Shared by the iOS and tvOS shells.
    static let doorbellPairingChanged = Notification.Name("doorbell.pairingChanged")
    /// Posted by a main screen's banner: reopen the onboarding screen the user deferred.
    static let doorbellOpenPairing = Notification.Name("doorbell.openPairing")
    /// Something that a finger would have woken the panel for. Posted by the screenshot
    /// hook's `wake` request and by anything that ought to put the screen in front of
    /// somebody who is standing at it.
    static let doorbellWakeScreen = Notification.Name("doorbell.wakeScreen")
    /// A `doorbell://pair?…` invitation arrived — from a tapped link or the camera. The
    /// URI travels as the notification object.
    static let doorbellPairInvitation = Notification.Name("doorbell.pairInvitation")
    /// Posted when this device must return to its first-run state: the cluster key, the pairing
    /// fields and its own name, role and door are all discarded.
    static let doorbellResetLocalPairing = Notification.Name("doorbell.resetLocalPairing")
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
    /// The device announced two different pairing keys; it must not be invited until it is
    /// re-pairing from a clean state (security protocol v3).
    let pkConflict: Bool

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
        pkConflict = ConfigUtil.evBool(raw, "pk_conflict")
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
    /// Eight digits an unpaired device shows so the administrator can confirm its key.
    let confirmCode: String
    /// This device was paired under protocol v2 and must join again (security protocol v3 §6).
    let upgradeRejoinRequired: Bool
    let security: PairingSecurity

    let pairQr: String
    let memberCount: Int
    let connectedCount: Int

    let tokenActive: Bool
    let tokenExpiresS: Int
    let tokenAttemptsLeft: Int
    let tokenHost: String
    let tokenPin: String
    /// `doorbell://pair?…`, the scannable form of the same token. Empty on a Core that
    /// predates the field, in which case the card shows the address and PIN alone.
    let tokenUri: String

    let pairingMode: Bool
    let pairingModeLeftS: Int
    let autoAddedCount: Int
    let devices: [PairingDevice]

    /// Everything an observer of `.doorbellPairingChanged` actually redraws from. Compared once
    /// per poll so an unchanged cluster costs nothing downstream.
    var changeFingerprint: String {
        return [state.rawValue, paired ? "1" : "0", persistenceReady ? "1" : "0",
                isFounder ? "1" : "0", pskSource, role, selfId, selfName, selfAddr, pairQr,
                "\(memberCount)", "\(connectedCount)", tokenActive ? "1" : "0",
                "\(tokenExpiresS)", "\(tokenAttemptsLeft)", tokenHost, tokenPin, tokenUri,
                pairingMode ? "1" : "0", "\(pairingModeLeftS)", "\(autoAddedCount)",
                "\(devices.count)", confirmCode, upgradeRejoinRequired ? "1" : "0",
                security.fingerprint,
                devices.filter { $0.pkConflict }.map { $0.id }.joined(separator: ",")]
            .joined(separator: "|")
    }

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
        confirmCode = ConfigUtil.evStr(me, "confirm_code")
        upgradeRejoinRequired = ConfigUtil.evBool(root, "upgrade_rejoin_required")
        security = PairingSecurity(root["security"] as? [String: Any])

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
        tokenUri = ConfigUtil.evStr(token, "uri")

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

/// The cluster-key part of the pairing snapshot (`security`).
struct PairingSecurity {
    let pskId: String
    let previousPskId: String
    let previousPskUntilMs: Int64
    /// Members still speaking protocol v2; they must be upgraded and paired again.
    let legacyPeers: [String]
    /// Members that missed a key rotation past its grace period.
    let rekeyRequired: [String]

    init(_ raw: [String: Any]?) {
        pskId = ConfigUtil.evStr(raw ?? [:], "psk_id")
        previousPskId = ConfigUtil.evStr(raw ?? [:], "prev_psk_id")
        previousPskUntilMs = Int64(ConfigUtil.double(raw, "prev_psk_until_ms", 0))
        legacyPeers = (raw?["legacy_peers"] as? [Any])?.compactMap { $0 as? String } ?? []
        rekeyRequired = (raw?["rekey_required"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    var fingerprint: String {
        return [pskId, previousPskId, "\(previousPskUntilMs)", legacyPeers.joined(separator: ","),
                rekeyRequired.joined(separator: ",")].joined(separator: "/")
    }
}

/// Localized copy helpers. No user-facing literal ever appears outside i18n/strings.yaml.
enum PairingCopy {

    /// "12345678" → "1234 5678", the grouping people read aloud.
    static func groupedCode(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return String(code.prefix(4)) + " " + String(code.suffix(4))
    }

    /// Accepts digits with spaces or dashes; nil unless exactly eight digits remain.
    static func normalizedCode(_ raw: String) -> String? {
        let digits = raw.filter { $0.isNumber }
        guard digits.count == 8, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return String(digits)
    }

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

/// Sizes shared by the pairing surfaces. Colours and type come from `SystemStyle`.
enum PairingTheme {
#if os(tvOS)
    static let codeSize: CGFloat = 64
    static let qrSize: CGFloat = 420
    static let codeQrSize: CGFloat = 220
#else
    static let codeSize: CGFloat = 44
    static let qrSize: CGFloat = 260
    static let codeQrSize: CGFloat = 160
#endif
}

/// The pairing invitation a QR carries: `doorbell://pair?host=<ip:port>&pin=<6 digits>
/// &exp=<unix seconds>&cluster=<name>`.
///
/// Core owns this format and reads it for every shell through `db_core_parse_pair_uri_json`,
/// which additionally judges the expiry against corrected cluster time. `parse(_:core:)` asks Core
/// first and only falls back to the local reading below when Core is not running — a code can be
/// scanned before it has started, and an older Core does not export the call at all.
struct PairUri: Equatable {
    let host: String
    let pin: String
    /// Unix seconds. Zero when the invitation carries no expiry.
    let expiresAtS: Int64
    let cluster: String

    /// Why an invitation cannot be acted on. Each is shown to the user in its own words rather
    /// than as one "invalid code".
    enum Failure: String, Error, Equatable {
        case notAPairUri = "bad_scheme"
        case missingHost = "missing_host"
        case missingPin = "missing_pin"
        case expired = "expired"

        /// Core names the refusal in the `err` field; an unknown name from a newer Core is read as
        /// "this code is not one we can act on" rather than crashing or silently accepting it.
        init(coreError: String) {
            self = Failure(rawValue: coreError) ?? .notAPairUri
        }
    }

    static let scheme = "doorbell"
    static let action = "pair"

    /// The reading the shell acts on: Core's when it can give one, the local one otherwise.
    static func parse(_ text: String, core: CoreBridge,
                      nowS: Int64 = Int64(Date().timeIntervalSince1970))
        -> Result<PairUri, Failure> {
        guard let answer = core.parsePairUri(text) else { return parse(text, nowS: nowS) }
        guard ConfigUtil.evBool(answer, "ok") else {
            return .failure(Failure(coreError: ConfigUtil.evStr(answer, "err")))
        }
        let host = ConfigUtil.evStr(answer, "host")
        let pin = ConfigUtil.evStr(answer, "pin")
        guard !host.isEmpty else { return .failure(.missingHost) }
        guard !pin.isEmpty else { return .failure(.missingPin) }
        return .success(PairUri(host: host, pin: pin,
                                expiresAtS: Int64(ConfigUtil.int(answer, "exp", 0)),
                                cluster: ConfigUtil.evStr(answer, "cluster")))
    }

    /// The shell's own reading, used only when Core cannot answer. `nowS` is the wall clock to
    /// judge the expiry against, so the caller decides whose clock counts and a test does not
    /// depend on the machine's.
    static func parse(_ text: String, nowS: Int64) -> Result<PairUri, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == scheme,
              (components.host ?? "").lowercased() == action else {
            return .failure(.notAPairUri)
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where !(item.value ?? "").isEmpty {
            values[item.name.lowercased()] = item.value
        }
        let host = (values["host"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return .failure(.missingHost) }

        // Six digits, and nothing that merely looks like them: a PIN with a stray character is a
        // mis-scan, and sending it would burn one of the token's few attempts.
        let pin = values["pin"] ?? ""
        guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return .failure(.missingPin)
        }

        let expiresAtS = Int64(values["exp"] ?? "") ?? 0
        if expiresAtS > 0 && nowS >= expiresAtS { return .failure(.expired) }

        // URLComponents has already percent-decoded the cluster name.
        return .success(PairUri(host: host, pin: pin, expiresAtS: expiresAtS,
                                cluster: values["cluster"] ?? ""))
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

// MARK: - Grouped table screens

/// The colour role of a row's primary text.
enum PairingTone {
    case primary
    case secondary
    case tint
    case positive
    case negative
    case warning

    var color: UIColor {
        switch self {
        case .primary: return SystemStyle.label
        case .secondary: return SystemStyle.secondaryLabel
        case .tint: return SystemStyle.tint
        case .positive: return SystemStyle.positive
        case .negative: return SystemStyle.negative
        case .warning: return SystemStyle.warning
        }
    }
}

/// One row of a `PairingTableScreen`. The row owns its cell for as long as it lives, so a text
/// field keeps its focus and its text across the once-a-second snapshot refresh.
final class PairingRow {
    let cell: UITableViewCell
    /// Nil for a row that only informs.
    var onSelect: (() -> Void)?
    /// Text a custom cell shows, so the table knows when to measure the row again.
    var note = ""
    /// Nil leaves the labels of a custom cell alone.
    var tone: PairingTone? { didSet { paint() } }
    var isEnabled = true { didSet { enable?(isEnabled) } }
    /// Runs after the stock styling, for whatever the cell adds to it.
    var decorate: (() -> Void)?
    fileprivate var enable: ((Bool) -> Void)?
    fileprivate var retitle: ((String) -> Void)?
    /// Keeps a target object alive for as long as the row.
    fileprivate var keep: AnyObject?

    init(cell: UITableViewCell, tone: PairingTone? = nil) {
        self.cell = cell
        self.tone = tone
        paint()
    }

    func setTitle(_ title: String) { retitle?(title) }

    /// Called again whenever the static palette of a system without semantic colours moves.
    func paint() {
        SystemStyle.style(cell)
        if let tone = tone {
            cell.textLabel?.textColor = tone.color
            cell.detailTextLabel?.textColor = SystemStyle.secondaryLabel
        }
        decorate?()
    }

    fileprivate var signature: String {
        let detail = cell.detailTextLabel?.attributedText?.string ?? ""
        return [cell.textLabel?.text ?? "", detail, note].joined(separator: "\u{1F}")
    }
}

struct PairingSection {
    var header: String?
    var footer: String?
    var rows: [PairingRow]

    init(header: String? = nil, footer: String? = nil, rows: [PairingRow]) {
        self.header = header
        self.footer = footer
        self.rows = rows
    }
}

private final class PairingTapRelay: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// The stock cells the pairing screens are built from.
enum PairingCells {

    /// An informational row in one of the standard cell styles; both labels wrap.
    static func text(style: UITableViewCell.CellStyle = .default, tone: PairingTone = .primary,
                     identifier: String? = nil) -> PairingRow {
        let cell = UITableViewCell(style: style, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.accessibilityIdentifier = identifier
        return PairingRow(cell: cell, tone: tone)
    }

    /// A row that is itself the control: tinted text, or red for a destructive action.
    static func action(title: String, tone: PairingTone = .tint, identifier: String,
                       handler: @escaping () -> Void) -> PairingRow {
        let row = text(tone: tone)
        let cell = row.cell
        cell.textLabel?.text = title
        cell.selectionStyle = .default
        cell.accessibilityIdentifier = identifier
        cell.accessibilityTraits = .button
        row.onSelect = handler
        row.retitle = { [unowned cell] title in cell.textLabel?.text = title }
        row.enable = { [unowned cell] enabled in
            cell.textLabel?.isEnabled = enabled
            cell.selectionStyle = enabled ? .default : .none
        }
        return row
    }

    /// The primary action of a screen. A filled system button on the inset grouped tables of
    /// iOS 13 and later; the centred emphasised row of the grouped style before that and on tvOS,
    /// where the row itself takes the focus.
    static func button(title: String, identifier: String,
                       handler: @escaping () -> Void) -> PairingRow {
        #if os(iOS)
        if #available(iOS 13.0, *) {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.backgroundColor = .clear
            let button = SystemStyle.button(.filled, title: title)
            button.accessibilityIdentifier = identifier
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(button)
            let bottom = button.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)
            bottom.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                button.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
                bottom,
            ])
            let relay = PairingTapRelay(handler)
            button.addTarget(relay, action: #selector(PairingTapRelay.fire),
                             for: .primaryActionTriggered)
            let row = PairingRow(cell: cell)
            row.keep = relay
            var current = title
            row.retitle = { [unowned button] title in
                current = title
                SystemStyle.style(button, kind: .filled, title: title)
            }
            row.enable = { [unowned button] enabled in button.isEnabled = enabled }
            row.decorate = { [unowned button, unowned cell] in
                cell.backgroundColor = .clear
                SystemStyle.style(button, kind: .filled, title: current)
            }
            return row
        }
        #endif
        let row = action(title: title, identifier: identifier, handler: handler)
        let cell = row.cell
        cell.textLabel?.textAlignment = .center
        row.decorate = { [unowned cell] in
            cell.textLabel?.font = SystemStyle.font(.body, weight: .semibold)
        }
        row.paint()
        return row
    }

    /// A row that hosts one view between the cell's layout margins.
    static func custom(_ view: UIView, vertical: CGFloat = 12) -> PairingRow {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(view)
        let margins = cell.contentView.layoutMarginsGuide
        let bottom = view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor,
                                                  constant: -vertical)
        bottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: vertical),
            view.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            bottom,
        ])
        return PairingRow(cell: cell)
    }

    static func spinner() -> UIActivityIndicatorView {
        let spinner = IOSAvailability.activityIndicator(large: false)
        spinner.color = SystemStyle.secondaryLabel
        spinner.hidesWhenStopped = true
        spinner.sizeToFit()
        return spinner
    }

    /// Shows or removes the progress indicator in a row's accessory position.
    static func setBusy(_ busy: Bool, _ row: PairingRow, spinner: UIActivityIndicatorView) {
        if busy {
            spinner.color = SystemStyle.secondaryLabel
            if row.cell.accessoryView !== spinner { row.cell.accessoryView = spinner }
            spinner.startAnimating()
        } else if row.cell.accessoryView === spinner {
            spinner.stopAnimating()
            row.cell.accessoryView = nil
        }
    }
}

/// One line of text entry in a table row. iOS edits in place with a `UITextField`; tvOS has no
/// inline keyboard, so the row shows the value and edits it through the system text alert.
final class PairingFieldRow: NSObject, UITextFieldDelegate {
    private(set) var row: PairingRow!
    var onReturn: (() -> Void)?
    var onChange: (() -> Void)?

#if os(iOS)
    let field = UITextField()
    var text: String {
        get { return field.text ?? "" }
        set { field.text = newValue }
    }
#else
    weak var presenter: UIViewController?
    var confirmTitle = ""
    var cancelTitle = ""
    var keyboardType = UIKeyboardType.default
    private let label: String
    private let placeholder: String
    private let identifier: String
    var text = "" { didSet { show() } }
#endif

    init(label: String, placeholder: String, identifier: String) {
#if os(tvOS)
        self.label = label
        self.placeholder = placeholder
        self.identifier = identifier
#endif
        super.init()
#if os(iOS)
        let title = SystemStyle.label(.body)
        title.text = label
        title.isHidden = label.isEmpty
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        field.font = SystemStyle.font(.body)
        if #available(iOS 10.0, *) { field.adjustsFontForContentSizeCategory = true }
        field.placeholder = placeholder
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.accessibilityIdentifier = identifier
        field.delegate = self
        field.addTarget(self, action: #selector(edited), for: .editingChanged)
        let stack = UIStackView(arrangedSubviews: [title, field])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        row = PairingCells.custom(stack, vertical: 0)
        row.decorate = { [unowned self] in
            title.textColor = SystemStyle.label
            self.field.textColor = SystemStyle.label
        }
        row.paint()
        row.onSelect = { [unowned self] in self.field.becomeFirstResponder() }
#else
        row = PairingCells.text(style: .value1)
        row.cell.selectionStyle = .default
        row.cell.accessibilityIdentifier = identifier
        row.onSelect = { [unowned self] in self.edit() }
        show()
#endif
    }

    func focus() {
#if os(iOS)
        field.becomeFirstResponder()
#endif
    }

#if os(iOS)
    @objc private func edited() { onChange?() }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn?()
        return true
    }
#else
    private func show() {
        row.cell.textLabel?.text = label
        row.cell.detailTextLabel?.text = text.isEmpty ? placeholder : text
    }

    private func edit() {
        let alert = UIAlertController(title: label, message: nil, preferredStyle: .alert)
        alert.addTextField { [placeholder, text, keyboardType, identifier] field in
            field.placeholder = placeholder
            field.text = text
            field.keyboardType = keyboardType
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.accessibilityIdentifier = identifier
        }
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel))
        alert.addAction(UIAlertAction(title: confirmTitle, style: .default) {
            [weak self, weak alert] _ in
            guard let self = self else { return }
            self.text = alert?.textFields?.first?.text ?? ""
            self.onChange?()
            self.onReturn?()
        })
        presenter?.present(alert, animated: true)
    }
#endif
}

/// A modal screen that is presented as itself and still shows the stock navigation bar: it
/// hosts its own navigation controller around one grouped table. Subclasses describe the table
/// as sections of `PairingRow` and hand a new description to `setSections` whenever state moves.
class PairingTableScreen: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let list = UITableViewController(style: SystemStyle.tableStyle())
    private(set) var bar: UINavigationController?
    private var sections: [PairingSection] = []
    private var measured = ""
    private var header: UIView?

    var table: UITableView { return list.tableView }
    /// Title and bar buttons of the hosted navigation bar.
    var barItem: UINavigationItem { return list.navigationItem }
    var prefersLargeTitle: Bool { return true }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SystemStyle.groupedBackground
        let nav = SystemStyle.navigation(list, largeTitles: prefersLargeTitle)
        bar = nav
        addChild(nav)
        nav.view.frame = view.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(nav.view)
        nav.didMove(toParent: self)
        table.dataSource = self
        table.delegate = self
        SystemStyle.style(table)
#if os(iOS)
        table.keyboardDismissMode = .interactive
#endif
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged),
                                               name: SystemStyle.changed, object: nil)
    }

#if os(iOS)
    override var childForStatusBarStyle: UIViewController? { return bar }
#endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = header else { return }
        bar?.view.layoutIfNeeded()
        let width = table.bounds.width
        guard width > 0 else { return }
        let fitted = header.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        guard abs(header.frame.height - fitted.height) > 0.5 ||
                abs(header.frame.width - width) > 0.5 else { return }
        header.frame = CGRect(x: 0, y: 0, width: width, height: fitted.height)
        table.tableHeaderView = header
    }

    /// A view above the first section. It is measured again after `headerChanged()`.
    func setHeader(_ view: UIView) {
        header = view
        table.tableHeaderView = view
        headerChanged()
    }

    func headerChanged() {
        if isViewLoaded { view.setNeedsLayout() }
    }

    /// Replaces the table's content. Rows are compared by identity: the table reloads only when
    /// rows or section texts were added, removed or moved, and otherwise just measures again.
    func setSections(_ next: [PairingSection]) {
        let reshaped = !PairingTableScreen.sameShape(next, sections)
        sections = next
        guard isViewLoaded else { return }
        let text = next.flatMap { $0.rows }.map { $0.signature }.joined(separator: "\u{1E}")
        if reshaped {
            measured = text
            // A row that was off screen missed any palette or accent change in the meantime.
            for row in next.flatMap({ $0.rows }) { row.paint() }
            // A reload detaches the cells for a moment, which would drop the keyboard from
            // under somebody typing; the field takes it back.
            let editing = PairingTableScreen.firstResponder(in: table)
            table.reloadData()
            if let editing = editing, !editing.isFirstResponder {
                table.layoutIfNeeded()
                if editing.window != nil { editing.becomeFirstResponder() }
            }
            return
        }
        guard text != measured else { return }
        measured = text
        UIView.performWithoutAnimation {
            table.beginUpdates()
            table.endUpdates()
        }
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let found = firstResponder(in: child) { return found }
        }
        return nil
    }

    private static func sameShape(_ first: [PairingSection], _ second: [PairingSection]) -> Bool {
        guard first.count == second.count else { return false }
        for (a, b) in zip(first, second) {
            guard (a.header ?? "") == (b.header ?? ""), (a.footer ?? "") == (b.footer ?? ""),
                  a.rows.count == b.rows.count,
                  !zip(a.rows, b.rows).contains(where: { $0 !== $1 }) else { return false }
        }
        return true
    }

    /// Anchors an action sheet to the row it belongs to, as a popover needs on iPad.
    func anchor(_ alert: UIAlertController, to row: PairingRow) {
        alert.popoverPresentationController?.sourceView = row.cell
        alert.popoverPresentationController?.sourceRect = row.cell.bounds
    }

    @objc private func styleChanged() {
        view.backgroundColor = SystemStyle.groupedBackground
        SystemStyle.style(table)
        if let bar = bar { SystemStyle.style(bar, largeTitles: prefersLargeTitle) }
        for row in sections.flatMap({ $0.rows }) { row.paint() }
        styleDidChange()
        table.reloadData()
    }

    /// For whatever a subclass painted outside its rows.
    func styleDidChange() {}

    func numberOfSections(in tableView: UITableView) -> Int { return sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        return row.cell
    }

    /// Focus lands only on rows that do something. An informational row under the focus platter
    /// would have its own text washed out, and the remote has nothing to do there.
    func tableView(_ tableView: UITableView, canFocusRowAt indexPath: IndexPath) -> Bool {
        let row = sections[indexPath.section].rows[indexPath.row]
        return row.onSelect != nil && row.isEnabled
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].header
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return sections[section].footer
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView,
                   forSection section: Int) {
        SystemStyle.style(headerFooter: view)
    }

    func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView,
                   forSection section: Int) {
        SystemStyle.style(headerFooter: view)
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
#if os(tvOS)
        // Focus is how a remote scrolls, so informational rows stay focusable.
        return true
#else
        let row = sections[indexPath.section].rows[indexPath.row]
        return row.onSelect != nil && row.isEnabled
#endif
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        guard row.isEnabled else { return }
        row.onSelect?()
    }
}

// MARK: - Shared pairing rows

/// The device's own Add QR. Shows a placeholder while Core has not published `pair_qr`, so the
/// row is never an empty box.
final class PairingQrRow {
    let row: PairingRow
    private let core: CoreBridge
    private let imageView = UIImageView()
    private let placeholder = SystemStyle.label(.footnote, color: SystemStyle.secondaryLabel)
    private var renderedPayload = ""

    init(core: CoreBridge, texts: Texts) {
        self.core = core
        let box = UIView()
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = 8
        imageView.clipsToBounds = true
        imageView.accessibilityIdentifier = "pair_own_qr"
        imageView.isAccessibilityElement = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = texts.t("pair.searching")
        placeholder.textAlignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(imageView)
        imageView.addSubview(placeholder)
        let side = imageView.widthAnchor.constraint(equalToConstant: PairingTheme.qrSize)
        side.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            side,
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor),
            imageView.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: box.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            placeholder.widthAnchor.constraint(equalTo: imageView.widthAnchor, constant: -24),
        ])
        row = PairingCells.custom(box)
        row.decorate = { [unowned self] in
            self.placeholder.textColor = SystemStyle.secondaryLabel
            self.imageView.backgroundColor = self.imageView.image == nil
                ? SystemStyle.fill : .white
        }
        row.paint()
    }

    func update(payload: String) {
        guard payload != renderedPayload else { return }
        renderedPayload = payload
        imageView.image = payload.isEmpty ? nil
            : PairingQR.image(core: core, text: payload, points: PairingTheme.qrSize)
        placeholder.isHidden = imageView.image != nil
        row.paint()
    }
}

/// The "Add with a Pairing PIN" section: authoritative address, live PIN, countdown, attempts
/// and the invitation QR. It renders `pairing.token`, so reopening a screen never loses a live
/// code, and an expired token keeps the section on screen with the way to a new one.
final class PairingCodeRows {
    var onNewCode: (() -> Void)?
    /// The invitation QR finished rendering, so the section gained or lost a row.
    var onChange: (() -> Void)?

    private let texts: Texts
    private let core: CoreBridge?
    private let addressRow = PairingCells.text(style: .value1)
    private let pinLabel = UILabel()
    private let pinRow: PairingRow
    private let timerRow = PairingCells.text(style: .subtitle)
    private let expiredRow = PairingCells.text(tone: .negative)
    private let qrView = UIImageView()
    private let qrRow: PairingRow
    private var newCodeRow: PairingRow!
    private var live = false
    private var renderedUri = ""
    private var address = ""
    private var pin = ""

    init(texts: Texts, core: CoreBridge?) {
        self.texts = texts
        self.core = core

        pinLabel.font = SystemStyle.digits(size: PairingTheme.codeSize, weight: .semibold)
        pinLabel.textAlignment = .center
        pinLabel.adjustsFontSizeToFitWidth = true
        pinLabel.minimumScaleFactor = 0.5
        pinLabel.accessibilityIdentifier = "pair_code_pin"
        pinRow = PairingCells.custom(pinLabel)

        let qrBox = UIView()
        qrView.contentMode = .scaleAspectFit
        qrView.accessibilityIdentifier = "pair_code_qr"
        qrView.isAccessibilityElement = true
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrBox.addSubview(qrView)
        NSLayoutConstraint.activate([
            qrView.widthAnchor.constraint(equalToConstant: PairingTheme.codeQrSize),
            qrView.heightAnchor.constraint(equalToConstant: PairingTheme.codeQrSize),
            qrView.centerXAnchor.constraint(equalTo: qrBox.centerXAnchor),
            qrView.topAnchor.constraint(equalTo: qrBox.topAnchor),
            qrView.bottomAnchor.constraint(equalTo: qrBox.bottomAnchor),
        ])
        qrRow = PairingCells.custom(qrBox)

        addressRow.cell.textLabel?.text = texts.t("pair.address_label")
        addressRow.cell.detailTextLabel?.accessibilityIdentifier = "pair_code_address"
        expiredRow.cell.textLabel?.text = texts.t("pair.code_expired")
        pinRow.decorate = { [unowned self] in self.pinLabel.textColor = SystemStyle.label }
        pinRow.paint()
        newCodeRow = PairingCells.button(title: texts.t("pair.new_code"),
                                         identifier: "pair_new_code") { [weak self] in
            self?.onNewCode?()
        }
#if os(iOS)
        // tvOS has no pasteboard; the values are read off the screen there.
        addressRow.cell.accessoryView = copyButton("pair_copy_address", #selector(copyAddress))
        pinRow.cell.accessoryView = copyButton("pair_copy_pin", #selector(copyPin))
#endif
    }

    func update(_ snapshot: PairingSnapshot) {
        live = snapshot.tokenActive && snapshot.tokenExpiresS > 0
        updateInvitationQr(live ? snapshot.tokenUri : "")
        address = snapshot.tokenHost
        pin = live ? snapshot.tokenPin : ""
        addressRow.cell.detailTextLabel?.text = address.isEmpty
            ? texts.t("pair.address_example") : address
        pinLabel.text = pin
        pinRow.note = pin
        timerRow.cell.textLabel?.text = live
            ? PairingCopy.expiresIn(texts, snapshot.tokenExpiresS) : ""
        timerRow.cell.detailTextLabel?.text = live
            ? texts.t("pair.code_attempts_left", "\(snapshot.tokenAttemptsLeft)") : ""
        (addressRow.cell.accessoryView as? UIButton)?.isEnabled = !address.isEmpty
    }

    /// The sections for the snapshot last given to `update`: the invitation itself, and the
    /// way to a new one once it has expired.
    func sections() -> [PairingSection] {
        var rows = [addressRow]
        if live {
            if !pin.isEmpty { rows.append(pinRow) }
            rows.append(timerRow)
            if qrView.image != nil { rows.append(qrRow) }
        } else {
            rows.append(expiredRow)
        }
        let invitation = PairingSection(header: texts.t("pair.add_with_code"),
                                        footer: live ? texts.t("pair.code_instructions") : nil,
                                        rows: rows)
        return live ? [invitation] : [invitation, PairingSection(rows: [newCodeRow])]
    }

    /// Core owns the payload; the shell only draws it. Encoding is a nested module loop and a
    /// bitmap context, so it runs off the main thread and only when the invitation changed.
    private func updateInvitationQr(_ uri: String) {
        guard uri != renderedUri else { return }
        renderedUri = uri
        guard !uri.isEmpty, let core = core else {
            qrView.image = nil
            return
        }
        let points = PairingTheme.codeQrSize
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = PairingQR.image(core: core, text: uri, points: points)
            DispatchQueue.main.async {
                guard let self = self, self.renderedUri == uri else { return }
                self.qrView.image = image
                self.onChange?()
            }
        }
    }

#if os(iOS)
    private func copyButton(_ identifier: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        if let icon = TablerIcon.image("TablerCopy") {
            button.setImage(icon, for: .normal)
        } else {
            button.setTitle(texts.t("pair.copy"), for: .normal)
        }
        button.accessibilityLabel = texts.t("pair.copy")
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .primaryActionTriggered)
        button.sizeToFit()
        button.frame.size = CGSize(width: max(44, button.frame.width), height: 44)
        return button
    }

    @objc private func copyAddress() {
        UIPasteboard.general.string = address
    }

    @objc private func copyPin() {
        UIPasteboard.general.string = pin
    }
#endif
}
