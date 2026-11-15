import UIKit

/// One option of the visitor flow. The icon sits above the label at one size on every option; an
/// option without an icon centres its label. The height follows the wrapped label, never below the
/// visitor touch minimum.
final class FlowOptionButton: UIButton {
    static let iconSize: CGFloat = 30
    var contentHeight: NSLayoutConstraint?
    var minimumHeight: CGFloat = TouchTarget.visitor
    /// Shown while this option waits on Core: in place of the icon, or at the leading edge when
    /// the option has none. The label never moves.
    var activity: UIActivityIndicatorView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let view = activity { addSubview(view) }
            imageView?.alpha = activity == nil ? 1 : 0
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let label = titleLabel, bounds.width > 12 else { return }
        let hasIcon = image(for: .normal) != nil
        defer {
            if let view = activity {
                bringSubviewToFront(view)
                let side = view.bounds.width
                view.center = hasIcon
                    ? CGPoint(x: bounds.midX, y: 16 + FlowOptionButton.iconSize / 2)
                    : CGPoint(x: 12 + side / 2, y: bounds.midY)
            }
        }
        let textHeight = ceil(label.sizeThatFits(
            CGSize(width: bounds.width - 24, height: .greatestFiniteMagnitude)).height)
        let required = max(minimumHeight, textHeight + (hasIcon ? 70 : 32))
        if let height = contentHeight, height.constant != required { height.constant = required }
        if hasIcon {
            let iconSize = FlowOptionButton.iconSize
            imageView?.frame = CGRect(x: (bounds.width - iconSize) / 2, y: 16,
                                      width: iconSize, height: iconSize)
            label.frame = CGRect(x: 12, y: 16 + iconSize + 8, width: bounds.width - 24,
                                 height: max(0, bounds.height - (16 + iconSize + 8) - 12))
        } else {
            label.frame = CGRect(x: 12, y: 0, width: bounds.width - 24, height: bounds.height)
        }
    }
}

/// Renders one page or end step of the visitor flow as one centred block: title, images and body,
/// then the options as equal cards (two columns, three on a wide column; a primary option and a
/// lone last card take the full row). The block scrolls as a whole only when it is taller than the
/// screen; notice, Done and Back stay fixed at the bottom. It holds no flow state; the owner hands
/// it the page to show.
final class VisitorFlowView: UIView {

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
    private let optionStack = UIStackView()
    private let backButton = UIButton(type: .system)
    private let doneButton = FlowOptionButton(type: .custom)
    private let bottomZone = UIStackView()
    private var imageLimits: [NSLayoutConstraint] = []
    private var page: VisitorFlowPage?
    private var columns = 1
    private var skin = DoorbellSkin.plain(.dark)
    private var optionButtons: [(option: VisitorFlowOption, button: FlowOptionButton)] = []
    private var pendingOptionId: String?
    private var pendingStatus: String?
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
        for view in [titleLabel, aboveStack, bodyLabel, belowStack, optionStack] {
            contentStack.addArrangedSubview(view)
        }
        if #available(iOS 11.0, tvOS 11.0, *) { contentStack.setCustomSpacing(24, after: belowStack) }

        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.alwaysBounceVertical = false
        contentHolder.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.addSubview(contentHolder)
        contentHolder.addSubview(contentStack)
        column.addSubview(contentScroll)

        optionStack.axis = .vertical
        optionStack.spacing = 12
        optionStack.alignment = .fill

        backButton.setTitle(texts.t("flow.back"), for: .normal)
        backButton.titleLabel?.font = IOSAvailability.visitorFont(size: 20, weight: .semibold,
                                                                  traits: traitCollection)
        backButton.accessibilityIdentifier = "flow_back"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        doneButton.setTitle(texts.t("flow.done"), for: .normal)
        doneButton.titleLabel?.numberOfLines = 0
        doneButton.titleLabel?.font = IOSAvailability.visitorFont(size: 28, weight: .semibold,
                                                                  traits: traitCollection)
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
        for view in [noticeLabel, doneButton, backButton] {
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
        ])
        // The block is as tall as its content, centred in the zone; taller than the zone, it scrolls.
        contentHolder.heightAnchor.constraint(greaterThanOrEqualTo: contentStack.heightAnchor).isActive = true
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
        optionStack.isHidden = page.options.isEmpty
        rebuildImages(page.images)
        rebuildOptions(page.options)
        applyColors()
        applyPending(announce: false)
        if previous?.id != page.id {
            contentScroll.setContentOffset(.zero, animated: false)
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

    /// Two columns, three once the column is wide. A page of one option uses the full row.
    private func columnCount(for options: [VisitorFlowOption]) -> Int {
        let width = min(bounds.width, VisitorFlowView.maxColumnWidth)
        let wanted = width >= 640 ? 3 : 2
        return max(1, min(wanted, options.filter { !$0.isPrimary }.count))
    }

    private func rebuildOptions(_ options: [VisitorFlowOption]) {
        for view in optionStack.arrangedSubviews {
            optionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        optionButtons = []
        columns = columnCount(for: options)
        let showIcons = options.contains { !$0.isPrimary && (!$0.purpose.isEmpty || !$0.icon.isEmpty) }
        var row: UIStackView?
        for option in options {
            let button = makeButton(option, withIcon: showIcons && !option.isPrimary)
            optionButtons.append((option, button))
            if option.isPrimary || columns == 1 {
                row = nil
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
    }

    private func makeRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually
        return row
    }

    private func makeButton(_ option: VisitorFlowOption, withIcon: Bool) -> FlowOptionButton {
        let button = FlowOptionButton(type: .custom)
        let glyph = withIcon
            ? AppIcon.image(AppIcon.flowGlyph(purpose: option.purpose, icon: option.icon)) : nil
        button.setTitle(option.label, for: .normal)
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

    /// While an option waits on Core: that option shows an activity indicator and stays selected,
    /// every other option and Back are dimmed and ignore touches, and `status` is the one-line
    /// progress text under the options. `nil` restores everything. Applied again after each
    /// `render`, which rebuilds the buttons.
    func setPending(optionId: String?, status: String? = nil) {
        let began = optionId != nil && optionId != pendingOptionId
        pendingOptionId = optionId
        let previousStatus = pendingStatus
        pendingStatus = optionId == nil ? nil : status
        applyPending(announce: began)
        if let text = pendingStatus, !text.isEmpty, text != previousStatus {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    private func applyPending(announce: Bool) {
        let pending = pendingOptionId
        for (option, button) in optionButtons {
            let busy = option.id == pending
            button.isUserInteractionEnabled = pending == nil
            button.alpha = pending == nil || busy ? 1 : 0.45
            button.accessibilityValue = busy ? texts.t("flow.busy") : nil
            var traits = button.accessibilityTraits
            if pending != nil, !busy { traits.insert(.notEnabled) } else { traits.remove(.notEnabled) }
            button.accessibilityTraits = traits
            if busy {
                if button.activity == nil { button.activity = makeActivityIndicator(for: button) }
            } else if button.activity != nil {
                button.activity = nil
            }
        }
        for control in [backButton, doneButton] {
            control.isUserInteractionEnabled = pending == nil
            control.alpha = pending == nil ? 1 : 0.45
            var traits = control.accessibilityTraits
            if pending != nil { traits.insert(.notEnabled) } else { traits.remove(.notEnabled) }
            control.accessibilityTraits = traits
        }
        if let text = pendingStatus, !text.isEmpty {
            noticeLabel.text = text
            noticeLabel.isHidden = false
        }
        if announce, let busy = optionButtons.first(where: { $0.option.id == pending })?.button {
            UIAccessibility.post(notification: .layoutChanged, argument: busy)
        }
    }

    private func makeActivityIndicator(for button: FlowOptionButton) -> UIActivityIndicatorView {
        let style: UIActivityIndicatorView.Style
        if #available(iOS 13.0, tvOS 13.0, *) { style = .medium } else { style = .white }
        let view = UIActivityIndicatorView(style: style)
        view.hidesWhenStopped = false
        view.color = button.titleColor(for: .normal)
        view.isAccessibilityElement = false
        view.sizeToFit()
        // A static indicator under reduced motion: the busy state is still visible and announced.
        if UIAccessibility.isReduceMotionEnabled { view.stopAnimating() } else { view.startAnimating() }
        return view
    }

    @objc private func optionTapped(_ sender: UIButton) {
        guard pendingOptionId == nil else { return }
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
        for (_, button) in optionButtons { button.activity?.color = button.titleColor(for: .normal) }
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

    #if DEBUG
    var contentZoneForTesting: UIScrollView { return contentScroll }
    var optionGridForTesting: UIView { return optionStack }
    var titleForTesting: UIView { return titleLabel }
    var optionButtonsForTesting: [UIButton] { return optionButtons.map { $0.button } }
    var noticeForTesting: UILabel { return noticeLabel }
    var backButtonForTesting: UIButton { return backButton }
    func activityVisible(on index: Int) -> Bool { return optionButtons[index].button.activity != nil }
    var columnsForTesting: Int { return columns }
    #endif

    // MARK: - Layout

    override func layoutSubviews() {
        if let page = page, bounds.width > 0, columnCount(for: page.options) != columns {
            rebuildOptions(page.options)
            applyColors()
        }
        super.layoutSubviews()
    }
}
