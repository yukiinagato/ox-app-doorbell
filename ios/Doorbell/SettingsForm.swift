import UIKit

/// A tiny declarative form used by every native settings screen. It exists so the sections stay
/// readable as data, and so the two runtimes that cannot use the ordinary controls — tvOS has no
/// `UISwitch` and a non-interactive `UISlider` — get equivalent focusable rows without each screen
/// growing its own conditional code.
enum SettingsField {
    case header(String)
    /// Muted explanatory line, used for the "this is edited in the web admin" reasons.
    case note(String)
    case value(title: String, detail: String)
    case action(title: String, detail: String, identifier: String, handler: () -> Void)
    case toggle(title: String, detail: String, value: Bool, identifier: String,
                handler: (Bool) -> Void)
    case level(title: String, detail: String, value: Int, minimum: Int, maximum: Int,
               identifier: String, handler: (Int) -> Void, preview: (() -> Void)?)
    case text(title: String, value: String, placeholder: String, identifier: String,
              handler: (String) -> Void)
    /// A password field: never pre-filled and never echoed.
    case secret(title: String, identifier: String, handler: (String) -> Void)
    case choice(title: String, value: String, options: [(String, String)], identifier: String,
                handler: (String) -> Void)
}

/// Grouped settings list. Rows are rebuilt from `fields`, so a screen only has to re-declare its
/// content after a change.
class SettingsFormViewController: UIViewController {

    let texts: Texts
    var palette = DoorbellPalette.dark
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private let titleLabel = UILabel()
    private var closeButton = UIButton(type: .system)

    var screenTitle: String = "" {
        didSet { titleLabel.text = screenTitle }
    }

    init(texts: Texts) {
        self.texts = texts
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = palette.background

        titleLabel.text = screenTitle
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = palette.ink
        titleLabel.numberOfLines = 0

        closeButton.setTitle(texts.t("settings.close"), for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        closeButton.setTitleColor(palette.ink, for: .normal)
        closeButton.accessibilityIdentifier = "settings_close"
        closeButton.addTarget(self, action: #selector(closeSelf), for: .primaryActionTriggered)

        statusLabel.font = .systemFont(ofSize: 16)
        statusLabel.textColor = palette.inkMuted
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "settings_status"

        let header = UIStackView(arrangedSubviews: [titleLabel, UIView(), closeButton])
        header.axis = .horizontal
        header.spacing = 16
        header.alignment = .center

        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let root = UIStackView(arrangedSubviews: [header, statusLabel, scroll])
        root.axis = .vertical
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: guide.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -18),
            root.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        rebuild()
    }

    /// Overridden by each screen.
    func fields() -> [SettingsField] { return [] }

    func rebuild() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for field in fields() { stack.addArrangedSubview(makeRow(field)) }
    }

    func setStatus(_ message: String) {
        statusLabel.text = message
    }

    @objc func closeSelf() { dismiss(animated: true) }

    // MARK: - Row construction

    private func makeRow(_ field: SettingsField) -> UIView {
        switch field {
        case .header(let title):
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 15, weight: .bold)
            label.textColor = palette.inkMuted
            label.numberOfLines = 0
            let container = UIView()
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            return container

        case .note(let text):
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 15)
            label.textColor = palette.inkMuted
            label.numberOfLines = 0
            return label

        case .value(let title, let detail):
            return card(title: title, detail: detail, trailing: nil, identifier: nil,
                        handler: nil)

        case .action(let title, let detail, let identifier, let handler):
            return card(title: title, detail: detail, trailing: nil, identifier: identifier,
                        handler: handler)

        case .toggle(let title, let detail, let value, let identifier, let handler):
            return toggleRow(title: title, detail: detail, value: value, identifier: identifier,
                             handler: handler)

        case .level(let title, let detail, let value, let minimum, let maximum, let identifier,
                    let handler, let preview):
            return levelRow(title: title, detail: detail, value: value, minimum: minimum,
                            maximum: maximum, identifier: identifier, handler: handler,
                            preview: preview)

        case .text(let title, let value, let placeholder, let identifier, let handler):
            return textRow(title: title, value: value, placeholder: placeholder,
                           identifier: identifier, handler: handler)

        case .secret(let title, let identifier, let handler):
            return textRow(title: title, value: "", placeholder: "", identifier: identifier,
                           secure: true, handler: handler)

        case .choice(let title, let value, let options, let identifier, let handler):
            return choiceRow(title: title, value: value, options: options, identifier: identifier,
                             handler: handler)
        }
    }

    private func card(title: String, detail: String, trailing: UIView?, identifier: String?,
                      handler: (() -> Void)?) -> UIView {
        let container = handler == nil ? SettingsRowView() : SettingsButtonRowView()
        container.backgroundColor = palette.surface
        container.layer.cornerRadius = 10
        container.accessibilityIdentifier = identifier
        if let button = container as? SettingsButtonRowView {
            button.onTap = handler
            button.focusBackground = palette.surfaceStrong
            button.normalBackground = palette.surface
        }

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 18, weight: .medium)
        titleLabel.textColor = palette.ink
        titleLabel.numberOfLines = 0

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .systemFont(ofSize: 15)
        detailLabel.textColor = palette.inkMuted
        detailLabel.numberOfLines = 0
        detailLabel.isHidden = detail.isEmpty

        let column = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        column.axis = .vertical
        column.spacing = 2

        var arranged: [UIView] = [column]
        if let trailing = trailing { arranged.append(trailing) }
        let row = UIStackView(arrangedSubviews: arranged)
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center
        row.isUserInteractionEnabled = trailing != nil
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        return container
    }

    private func toggleRow(title: String, detail: String, value: Bool, identifier: String,
                           handler: @escaping (Bool) -> Void) -> UIView {
        #if os(tvOS)
        // tvOS has no UISwitch; the whole row is the control and select flips it.
        var current = value
        let stateLabel = UILabel()
        stateLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        stateLabel.textColor = palette.ink
        stateLabel.text = current ? texts.t("admin.enabled") : texts.t("admin.disabled")
        let row = card(title: title, detail: detail, trailing: stateLabel,
                       identifier: identifier) {
            current.toggle()
            stateLabel.text = current ? self.texts.t("admin.enabled")
                : self.texts.t("admin.disabled")
            handler(current)
        }
        return row
        #else
        let control = UISwitch()
        control.isOn = value
        control.onTintColor = palette.accent
        control.accessibilityIdentifier = identifier + "_switch"
        let box = SettingsToggleBox(handler: handler)
        control.addTarget(box, action: #selector(SettingsToggleBox.changed(_:)),
                          for: .valueChanged)
        let row = card(title: title, detail: detail, trailing: control, identifier: identifier,
                       handler: nil)
        box.retainer = row
        objc_setAssociatedObject(row, &SettingsToggleBox.key, box,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return row
        #endif
    }

    private func levelRow(title: String, detail: String, value: Int, minimum: Int, maximum: Int,
                          identifier: String, handler: @escaping (Int) -> Void,
                          preview: (() -> Void)?) -> UIView {
        var current = value
        let readout = UILabel()
        readout.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        readout.textColor = palette.ink
        readout.text = "\(current)"
        readout.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        readout.textAlignment = .right

        let controls = UIStackView()
        controls.axis = .horizontal
        controls.spacing = 10
        controls.alignment = .center

        #if !os(tvOS)
        let slider = UISlider()
        slider.minimumValue = Float(minimum)
        slider.maximumValue = Float(maximum)
        slider.value = Float(current)
        slider.minimumTrackTintColor = palette.accent
        slider.accessibilityIdentifier = identifier + "_slider"
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let box = SettingsLevelBox { newValue in
            current = newValue
            readout.text = "\(newValue)"
            handler(newValue)
        }
        slider.addTarget(box, action: #selector(SettingsLevelBox.changed(_:)), for: .valueChanged)
        controls.addArrangedSubview(slider)
        objc_setAssociatedObject(slider, &SettingsLevelBox.key, box,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        #else
        // tvOS sliders are not interactive; two focusable steps replace them.
        for (caption, delta) in [("−", -5), ("＋", 5)] {
            let button = SettingsButtonRowView()
            button.normalBackground = palette.surfaceStrong
            button.focusBackground = palette.accent
            button.backgroundColor = palette.surfaceStrong
            button.layer.cornerRadius = 8
            let label = UILabel()
            label.text = caption
            label.font = .systemFont(ofSize: 24, weight: .bold)
            label.textColor = palette.ink
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 64),
                button.heightAnchor.constraint(equalToConstant: 48),
            ])
            button.onTap = {
                current = max(minimum, min(maximum, current + delta))
                readout.text = "\(current)"
                handler(current)
            }
            controls.addArrangedSubview(button)
        }
        #endif
        controls.addArrangedSubview(readout)

        if let preview = preview {
            let button = SettingsButtonRowView()
            button.normalBackground = palette.surfaceStrong
            button.focusBackground = palette.accent
            button.backgroundColor = palette.surfaceStrong
            button.layer.cornerRadius = 8
            button.accessibilityIdentifier = identifier + "_preview"
            let label = UILabel()
            label.text = texts.t("volume.preview")
            label.font = .systemFont(ofSize: 16, weight: .semibold)
            label.textColor = palette.ink
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                button.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -14),
                button.heightAnchor.constraint(equalToConstant: 44),
            ])
            button.onTap = preview
            controls.addArrangedSubview(button)
        }

        return card(title: title, detail: detail, trailing: controls, identifier: identifier,
                    handler: nil)
    }

    private func textRow(title: String, value: String, placeholder: String, identifier: String,
                         secure: Bool = false,
                         handler: @escaping (String) -> Void) -> UIView {
        let field = UITextField()
        field.isSecureTextEntry = secure
        field.text = value
        field.placeholder = placeholder
        field.textColor = palette.ink
        field.font = .systemFont(ofSize: 18)
        field.borderStyle = .roundedRect
        field.backgroundColor = palette.surfaceStrong
        field.accessibilityIdentifier = identifier + "_field"
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let box = SettingsTextBox(handler: handler)
        field.addTarget(box, action: #selector(SettingsTextBox.changed(_:)),
                        for: .editingDidEnd)
        field.addTarget(box, action: #selector(SettingsTextBox.changed(_:)),
                        for: .editingDidEndOnExit)
        objc_setAssociatedObject(field, &SettingsTextBox.key, box,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return card(title: title, detail: "", trailing: field, identifier: identifier,
                    handler: nil)
    }

    private func choiceRow(title: String, value: String, options: [(String, String)],
                           identifier: String, handler: @escaping (String) -> Void) -> UIView {
        let control = UISegmentedControl(items: options.map { $0.1 })
        control.selectedSegmentIndex = options.firstIndex { $0.0 == value } ?? 0
        control.accessibilityIdentifier = identifier + "_choice"
        let box = SettingsChoiceBox(values: options.map { $0.0 }, handler: handler)
        control.addTarget(box, action: #selector(SettingsChoiceBox.changed(_:)),
                          for: .valueChanged)
        objc_setAssociatedObject(control, &SettingsChoiceBox.key, box,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return card(title: title, detail: "", trailing: control, identifier: identifier,
                    handler: nil)
    }
}

/// Plain container so a non-interactive row still participates in the same layout.
final class SettingsRowView: UIView {}

/// Focusable, tappable row. tvOS drives it with the focus engine; iOS uses a tap recognizer.
final class SettingsButtonRowView: UIControl {
    var onTap: (() -> Void)?
    var normalBackground: UIColor?
    var focusBackground: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // A bare UIControl only receives .primaryActionTriggered on tvOS, where the focus engine
        // sends it; on iOS the row has to listen for the touch itself.
        #if os(tvOS)
        addTarget(self, action: #selector(fire), for: .primaryActionTriggered)
        #else
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { onTap?() }

    #if os(tvOS)
    override var canBecomeFocused: Bool { return true }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ [weak self] in
            guard let self = self else { return }
            self.backgroundColor = focused ? self.focusBackground : self.normalBackground
            self.transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }, completion: nil)
    }
    #endif
}

/// Small target objects: UIKit control targets are unowned, so each one is kept alive by an
/// associated object on the control it serves.
final class SettingsToggleBox: NSObject {
    static var key: UInt8 = 0
    private let handler: (Bool) -> Void
    var retainer: UIView?

    init(handler: @escaping (Bool) -> Void) { self.handler = handler }

    @objc func changed(_ sender: Any) {
        #if !os(tvOS)
        guard let control = sender as? UISwitch else { return }
        handler(control.isOn)
        #endif
    }
}

final class SettingsLevelBox: NSObject {
    static var key: UInt8 = 0
    private let handler: (Int) -> Void

    init(handler: @escaping (Int) -> Void) { self.handler = handler }

    @objc func changed(_ sender: Any) {
        #if !os(tvOS)
        guard let control = sender as? UISlider else { return }
        handler(Int(control.value.rounded()))
        #endif
    }
}

final class SettingsTextBox: NSObject {
    static var key: UInt8 = 0
    private let handler: (String) -> Void

    init(handler: @escaping (String) -> Void) { self.handler = handler }

    @objc func changed(_ sender: Any) {
        guard let field = sender as? UITextField else { return }
        handler(field.text ?? "")
    }
}

final class SettingsChoiceBox: NSObject {
    static var key: UInt8 = 0
    private let values: [String]
    private let handler: (String) -> Void

    init(values: [String], handler: @escaping (String) -> Void) {
        self.values = values
        self.handler = handler
    }

    @objc func changed(_ sender: Any) {
        guard let control = sender as? UISegmentedControl,
              control.selectedSegmentIndex >= 0,
              control.selectedSegmentIndex < values.count else { return }
        handler(values[control.selectedSegmentIndex])
    }
}
