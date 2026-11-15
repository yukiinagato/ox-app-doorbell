import UIKit

/// One option of the visitor flow. A purpose icon sits above the label; an option without an icon
/// centres its label. The height follows the wrapped label, never below the visitor touch minimum.
final class FlowOptionButton: UIButton {
    var contentHeight: NSLayoutConstraint?
    var minimumHeight: CGFloat = TouchTarget.visitor

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let label = titleLabel, bounds.width > 12 else { return }
        let hasIcon = image(for: .normal) != nil
        let textHeight = ceil(label.sizeThatFits(
            CGSize(width: bounds.width - 24, height: .greatestFiniteMagnitude)).height)
        let required = max(minimumHeight, textHeight + (hasIcon ? 64 : 32))
        if let height = contentHeight, height.constant != required { height.constant = required }
        if hasIcon {
            let iconSize: CGFloat = 26
            imageView?.frame = CGRect(x: (bounds.width - iconSize) / 2, y: 14,
                                      width: iconSize, height: iconSize)
            label.frame = CGRect(x: 12, y: 46, width: bounds.width - 24,
                                 height: max(0, bounds.height - 52))
        } else {
            label.frame = CGRect(x: 12, y: 0, width: bounds.width - 24, height: bounds.height)
        }
    }
}

/// Renders one page or end step of the visitor flow: a content zone (title, images, body) that
/// scrolls, and an option zone fixed to the bottom that scrolls internally only when it would
/// exceed half the viewport. It holds no flow state; the owner hands it the page to show.
final class VisitorFlowView: UIView, UIScrollViewDelegate {

    static let maxColumnWidth: CGFloat = 760

    var onOption: ((String) -> Void)?
    var onBack: (() -> Void)?
    var onDone: (() -> Void)?
    var viewportHeight: CGFloat = 0 {
        didSet {
            guard oldValue != viewportHeight else { return }
            for constraint in imageLimits { constraint.constant = imageLimit }
            setNeedsLayout()
        }
    }

    private let texts: Texts
    private let column = UIView()
    private let contentScroll = UIScrollView()
    private let contentHolder = UIView()
    private let contentStack = UIStackView()
    private let aboveStack = UIStackView()
    private let belowStack = UIStackView()
    private let titleLabel = HaloLabel()
    private let bodyLabel = HaloLabel()
    private let noticeLabel = HaloLabel()
    private let optionScroll = UIScrollView()
    private let optionStack = UIStackView()
    private let backButton = UIButton(type: .system)
    private let doneButton = FlowOptionButton(type: .custom)
    private let bottomZone = UIStackView()
    private var optionHeight: NSLayoutConstraint!
    private var imageLimits: [NSLayoutConstraint] = []
    private var page: VisitorFlowPage?
    private var columns = 1
    private var skin = DoorbellSkin.plain(.dark)
    private var optionButtons: [(option: VisitorFlowOption, button: FlowOptionButton)] = []
    private static var imageCache: [String: UIImage] = [:]

    init(texts: Texts) {
        self.texts = texts
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var imageLimit: CGFloat {
        let height = viewportHeight > 0 ? viewportHeight : max(bounds.height, 400)
        return floor(height * 0.4)
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let preferred = column.widthAnchor.constraint(equalTo: widthAnchor)
        preferred.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: VisitorFlowView.maxColumnWidth),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            preferred,
        ])

        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "flow_title"
        titleLabel.accessibilityTraits = .header
        bodyLabel.numberOfLines = 0
        bodyLabel.textAlignment = .center
        bodyLabel.accessibilityIdentifier = "flow_text"
        noticeLabel.numberOfLines = 0
        noticeLabel.textAlignment = .center
        noticeLabel.accessibilityIdentifier = "flow_notice"
        noticeLabel.isHidden = true
        for stack in [aboveStack, belowStack] {
            stack.axis = .vertical
            stack.spacing = 12
            stack.alignment = .fill
        }
        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleLabel, aboveStack, bodyLabel, belowStack] {
            contentStack.addArrangedSubview(view)
        }

        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.alwaysBounceVertical = false
        contentHolder.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.addSubview(contentHolder)
        contentHolder.addSubview(contentStack)
        column.addSubview(contentScroll)

        optionStack.axis = .vertical
        optionStack.spacing = 12
        optionStack.alignment = .fill
        optionStack.translatesAutoresizingMaskIntoConstraints = false
        optionScroll.translatesAutoresizingMaskIntoConstraints = false
        optionScroll.alwaysBounceVertical = false
        optionScroll.delegate = self
        optionScroll.addSubview(optionStack)
        optionHeight = optionScroll.heightAnchor.constraint(equalToConstant: TouchTarget.visitor)

        backButton.setTitle(texts.t("flow.back"), for: .normal)
        backButton.titleLabel?.font = IOSAvailability.visitorFont(size: 20, weight: .semibold,
                                                                  traits: traitCollection)
        backButton.accessibilityIdentifier = "flow_back"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        doneButton.setTitle(texts.t("flow.done"), for: .normal)
        doneButton.titleLabel?.numberOfLines = 0
        doneButton.titleLabel?.textAlignment = .center
        doneButton.accessibilityIdentifier = "flow_done"
        doneButton.layer.cornerRadius = 18
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        let doneHeight = doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 88)
        doneHeight.isActive = true
        doneButton.contentHeight = doneHeight
        doneButton.minimumHeight = 88

        bottomZone.axis = .vertical
        bottomZone.spacing = 10
        bottomZone.alignment = .fill
        bottomZone.translatesAutoresizingMaskIntoConstraints = false
        for view in [noticeLabel, optionScroll, doneButton, backButton] {
            bottomZone.addArrangedSubview(view)
        }
        column.addSubview(bottomZone)

        let holderHeight = contentHolder.heightAnchor.constraint(
            greaterThanOrEqualTo: contentScroll.heightAnchor)
        holderHeight.priority = UILayoutPriority(999)
        let centred = contentStack.centerYAnchor.constraint(equalTo: contentHolder.centerYAnchor)
        centred.priority = UILayoutPriority(500)
        NSLayoutConstraint.activate([
            contentScroll.topAnchor.constraint(equalTo: column.topAnchor),
            contentScroll.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            contentScroll.bottomAnchor.constraint(equalTo: bottomZone.topAnchor, constant: -12),
            contentHolder.topAnchor.constraint(equalTo: contentScroll.topAnchor),
            contentHolder.bottomAnchor.constraint(equalTo: contentScroll.bottomAnchor),
            contentHolder.leadingAnchor.constraint(equalTo: contentScroll.leadingAnchor),
            contentHolder.trailingAnchor.constraint(equalTo: contentScroll.trailingAnchor),
            contentHolder.widthAnchor.constraint(equalTo: contentScroll.widthAnchor),
            holderHeight,
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: contentHolder.topAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentHolder.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentHolder.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentHolder.trailingAnchor),
            centred,
            bottomZone.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            bottomZone.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            bottomZone.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            optionStack.topAnchor.constraint(equalTo: optionScroll.topAnchor),
            optionStack.bottomAnchor.constraint(equalTo: optionScroll.bottomAnchor),
            optionStack.leadingAnchor.constraint(equalTo: optionScroll.leadingAnchor),
            optionStack.trailingAnchor.constraint(equalTo: optionScroll.trailingAnchor),
            optionStack.widthAnchor.constraint(equalTo: optionScroll.widthAnchor),
            optionHeight,
        ])
        // The text may be taller than the zone: it then scrolls rather than push the options out.
        let stackHeight = contentStack.heightAnchor.constraint(
            equalTo: contentHolder.heightAnchor)
        stackHeight.priority = UILayoutPriority(1)
        stackHeight.isActive = true
    }

    // MARK: - Content

    func render(_ page: VisitorFlowPage, notice: String?) {
        let previous = self.page
        self.page = page
        let wide = bounds.width >= 600
        titleLabel.font = IOSAvailability.visitorFont(size: wide ? 40 : 30, weight: .bold,
                                                      style: .title1, traits: traitCollection)
        bodyLabel.font = IOSAvailability.visitorFont(size: wide ? 24 : 19, traits: traitCollection)
        noticeLabel.font = IOSAvailability.visitorFont(size: wide ? 22 : 18, weight: .semibold,
                                                       traits: traitCollection)
        titleLabel.text = page.title
        titleLabel.isHidden = page.title.isEmpty
        bodyLabel.text = page.body
        bodyLabel.isHidden = page.body.isEmpty
        noticeLabel.text = notice
        noticeLabel.isHidden = (notice ?? "").isEmpty
        backButton.setTitle(texts.t("flow.back"), for: .normal)
        doneButton.setTitle(texts.t("flow.done"), for: .normal)
        backButton.isHidden = !page.canGoBack
        doneButton.isHidden = !page.showsDone
        optionScroll.isHidden = page.options.isEmpty
        rebuildImages(page.images)
        rebuildOptions(page.options)
        applyColors()
        if previous?.id != page.id {
            contentScroll.setContentOffset(.zero, animated: false)
            optionScroll.setContentOffset(.zero, animated: false)
            UIAccessibility.post(notification: .screenChanged,
                                 argument: titleLabel.isHidden ? nil : titleLabel)
        }
        setNeedsLayout()
    }

    private func rebuildImages(_ images: [VisitorFlowImage]) {
        for stack in [aboveStack, belowStack] {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        imageLimits = []
        for image in images {
            let view = makeImageView(image)
            (image.place == "below" ? belowStack : aboveStack).addArrangedSubview(view)
        }
        aboveStack.isHidden = aboveStack.arrangedSubviews.isEmpty
        belowStack.isHidden = belowStack.arrangedSubviews.isEmpty
    }

    private func makeImageView(_ image: VisitorFlowImage) -> UIView {
        if let path = image.path, !path.isEmpty, let picture = VisitorFlowView.picture(at: path),
           picture.size.width > 0 {
            let view = UIImageView(image: picture)
            view.contentMode = .scaleAspectFit
            view.isAccessibilityElement = true
            view.accessibilityLabel = image.alt
            view.accessibilityTraits = .image
            view.translatesAutoresizingMaskIntoConstraints = false
            let ratio = picture.size.height / picture.size.width
            let natural = view.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: ratio)
            natural.priority = UILayoutPriority(750)
            let limit = view.heightAnchor.constraint(lessThanOrEqualToConstant: imageLimit)
            imageLimits.append(limit)
            NSLayoutConstraint.activate([natural, limit])
            return view
        }
        // The file has not arrived: the description stands in until a visitor_flow_changed follows.
        let label = HaloLabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = image.alt
        label.font = IOSAvailability.visitorFont(size: 17, traits: traitCollection)
        label.accessibilityLabel = image.alt
        return label
    }

    private static func picture(at path: String) -> UIImage? {
        if let cached = imageCache[path] { return cached }
        guard let loaded = UIImage(contentsOfFile: path) else { return nil }
        if imageCache.count > 16 { imageCache.removeAll() }
        imageCache[path] = loaded
        return loaded
    }

    private func rebuildOptions(_ options: [VisitorFlowOption]) {
        for view in optionStack.arrangedSubviews {
            optionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        optionButtons = []
        columns = bounds.width >= 600 ? 2 : 1
        var row: UIStackView?
        func closeRow() {
            if let open = row, open.arrangedSubviews.count < columns {
                for _ in open.arrangedSubviews.count..<columns { open.addArrangedSubview(UIView()) }
            }
            row = nil
        }
        for option in options {
            let button = makeButton(option)
            optionButtons.append((option, button))
            if option.isPrimary || columns == 1 {
                closeRow()
                let single = makeRow()
                single.addArrangedSubview(button)
                optionStack.addArrangedSubview(single)
                continue
            }
            if row == nil {
                row = makeRow()
                optionStack.addArrangedSubview(row!)
            }
            row!.addArrangedSubview(button)
            if row!.arrangedSubviews.count == columns { row = nil }
        }
        closeRow()
    }

    private func makeRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually
        return row
    }

    private func makeButton(_ option: VisitorFlowOption) -> FlowOptionButton {
        let button = FlowOptionButton(type: .custom)
        let glyph = option.isPrimary ? nil : AppIcon.purpose(option.purpose)
        var title = option.label
        if glyph == nil, !option.icon.isEmpty, !option.isPrimary { title = option.icon + " " + title }
        button.setTitle(title, for: .normal)
        button.setImage(glyph, for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.titleLabel?.font = option.isPrimary
            ? IOSAvailability.visitorFont(size: bounds.width >= 600 ? 34 : 28, weight: .semibold,
                                          traits: traitCollection)
            : IOSAvailability.visitorFont(size: bounds.width >= 600 ? 22 : 18, weight: .medium,
                                          traits: traitCollection)
        button.layer.cornerRadius = option.isPrimary ? 18 : 14
        button.minimumHeight = option.isPrimary ? 88 : TouchTarget.visitor
        let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: button.minimumHeight)
        height.isActive = true
        button.contentHeight = height
        button.accessibilityIdentifier = option.isPrimary ? "call_primary"
            : (option.purpose.isEmpty ? "flow_option_\(option.id)" : "purpose_\(option.purpose)")
        button.accessibilityLabel = option.label
        button.addTarget(self, action: #selector(optionTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func optionTapped(_ sender: UIButton) {
        guard let match = optionButtons.first(where: { $0.button === sender }) else { return }
        onOption?(match.option.id)
    }

    @objc private func backTapped() { onBack?() }
    @objc private func doneTapped() { onDone?() }

    // MARK: - Appearance

    func apply(skin: DoorbellSkin) {
        self.skin = skin
        applyColors()
    }

    private func applyColors() {
        skin.apply("clock", to: titleLabel)
        skin.apply("hint", to: bodyLabel)
        skin.apply("notice", to: noticeLabel)
        for stack in [aboveStack, belowStack] {
            for case let label as UILabel in stack.arrangedSubviews { skin.apply("hint", to: label) }
        }
        let call = DoorbellTheme.callButtonColors(display: skin.display, background: skin.background)
        for (option, button) in optionButtons {
            if option.isPrimary {
                button.backgroundColor = call.fill
                button.setTitleColor(call.ink, for: .normal)
            } else {
                button.backgroundColor = skin.surface
                button.setTitleColor(skin.cardInk("tile_label"), for: .normal)
                button.tintColor = skin.cardInk("tile_label")
            }
        }
        doneButton.backgroundColor = call.fill
        doneButton.setTitleColor(call.ink, for: .normal)
        backButton.setTitleColor(skin.cardInk("tile_label"), for: .normal)
        backButton.tintColor = skin.cardInk("tile_label")
        backButton.backgroundColor = skin.surface
        backButton.layer.cornerRadius = 12
    }

    /// Hands every option button, the Back and the Done control to the semantic-style applier.
    func forEachControl(_ body: (_ semanticId: String, _ view: UIView) -> Void) {
        for (option, button) in optionButtons { body(option.semanticId, button) }
        body("flow.back", backButton)
        body("flow.done", doneButton)
        body("flow.text", bodyLabel)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        let wanted = bounds.width >= 600 ? 2 : 1
        if let page = page, wanted != columns, bounds.width > 0 {
            columns = wanted
            rebuildOptions(page.options)
            applyColors()
        }
        super.layoutSubviews()
        updateOptionZone()
    }

    private func updateOptionZone() {
        guard !optionScroll.isHidden, optionScroll.bounds.width > 0 else { return }
        let fit = optionStack.systemLayoutSizeFitting(
            CGSize(width: optionScroll.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        let viewport = viewportHeight > 0 ? viewportHeight : bounds.height
        let cap = max(TouchTarget.visitor * 2, floor(viewport * 0.5))
        let height = min(fit, cap)
        if abs(optionHeight.constant - height) > 0.5 {
            optionHeight.constant = height
            setNeedsLayout()
        }
        optionScroll.isScrollEnabled = fit > cap + 0.5
        updateFade()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === optionScroll { updateFade() }
    }

    /// A scrollable option zone fades out at the bottom edge while more options lie below.
    private func updateFade() {
        let scrollable = optionScroll.contentSize.height > optionScroll.bounds.height + 1
        let atEnd = optionScroll.contentOffset.y + optionScroll.bounds.height >=
            optionScroll.contentSize.height - 2
        guard scrollable, !atEnd, optionScroll.bounds.height > 0 else {
            optionScroll.layer.mask = nil
            return
        }
        let mask = (optionScroll.layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.frame = optionScroll.bounds
        mask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        let fade = min(0.3, 40 / optionScroll.bounds.height)
        mask.locations = [0, NSNumber(value: Double(1 - fade)), 1]
        optionScroll.layer.mask = mask
    }
}
