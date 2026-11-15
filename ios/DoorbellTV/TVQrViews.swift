import UIKit

/// The admin QR as a small card in the corner. It takes the system focus effect and opens the
/// full-size sheet on Select.
final class TVQrThumbnail: UIControl {

    let caption = UILabel()
    let detail = UILabel()
    private let card = UIView()
    private let picture = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = .white
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.isUserInteractionEnabled = false
        card.translatesAutoresizingMaskIntoConstraints = false
        picture.contentMode = .scaleAspectFit
        picture.layer.magnificationFilter = .nearest
        picture.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(picture)
        caption.font = SystemStyle.font(.callout, weight: .semibold)
        detail.font = SystemStyle.font(.callout)
        caption.textColor = .white
        detail.textColor = UIColor(white: 1, alpha: 0.85)
        detail.numberOfLines = 1
        let column = UIStackView(arrangedSubviews: [caption, detail])
        column.axis = .vertical
        column.spacing = 4
        column.isUserInteractionEnabled = false
        let row = UIStackView(arrangedSubviews: [card, column])
        row.axis = .horizontal
        row.spacing = 24
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 112),
            card.heightAnchor.constraint(equalToConstant: 112),
            picture.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            picture.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            picture.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            picture.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setImage(_ image: UIImage?) { picture.image = image }

    override var canBecomeFocused: Bool { return true }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        layer.cornerRadius = 24
        coordinator.addCoordinatedAnimations({
            self.transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
            self.layer.shadowColor = UIColor.black.cgColor
            self.layer.shadowOpacity = focused ? 0.5 : 0
            self.layer.shadowRadius = 24
            self.layer.shadowOffset = CGSize(width: 0, height: 12)
            self.backgroundColor = focused ? UIColor(white: 1, alpha: 0.16) : .clear
        }, completion: nil)
    }
}

/// Full-screen QR: a dimmed backdrop, the code large on a white card, the address host and a hint.
/// Menu or Select closes it.
final class TVQrSheetViewController: UIViewController {

    var onClose: (() -> Void)?
    private let core: CoreBridge
    private let texts: Texts
    private let address: String
    private let card = UIView()

    init(core: CoreBridge, texts: Texts, address: String) {
        self.core = core
        self.texts = texts
        self.address = address
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blur)
        let dim = UIView()
        dim.backgroundColor = UIColor(white: 0, alpha: 0.45)
        dim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dim)

        let title = SystemStyle.label(.title2, weight: .semibold, color: .white)
        title.text = texts.t("tv.qr_title")
        title.textAlignment = .center
        let host = SystemStyle.label(.callout, color: UIColor(white: 1, alpha: 0.75))
        host.text = URLComponents(string: address)?.host ?? ""
        host.textAlignment = .center
        let hint = SystemStyle.label(.callout, color: UIColor(white: 1, alpha: 0.75))
        hint.text = texts.t("tv.qr_hint")
        hint.textAlignment = .center

        card.backgroundColor = .white
        card.layer.cornerRadius = 36
        card.layer.cornerCurve = .continuous
        let picture = UIImageView()
        picture.contentMode = .scaleAspectFit
        picture.layer.magnificationFilter = .nearest
        picture.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(picture)
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [title, card, host, hint])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: view.topAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dim.topAnchor.constraint(equalTo: view.topAnchor),
            dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.widthAnchor.constraint(equalToConstant: 560),
            card.heightAnchor.constraint(equalToConstant: 560),
            picture.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            picture.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
            picture.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            picture.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        // Rendered at twice the card so each module is a whole number of device pixels.
        let core = self.core
        let url = address
        DispatchQueue.global(qos: .userInitiated).async {
            let image = PairingQR.image(core: core, text: url, points: 1008)
            DispatchQueue.main.async { picture.image = image }
        }
        if !UIAccessibility.isReduceMotionEnabled {
            card.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            card.alpha = 0
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0, options: []) {
            self.card.transform = .identity
            self.card.alpha = 1
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu || $0.type == .select }) {
            let callback = onClose
            dismiss(animated: true) { callback?() }
            return
        }
        super.pressesEnded(presses, with: event)
    }
}
