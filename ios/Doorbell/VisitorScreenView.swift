import UIKit

final class VisitorScreenView: UIView {

    private let texts: Texts
    private let clockLabel = HaloLabel()
    private let dateLabel = HaloLabel()
    private let noticeLabel = HaloLabel()
    private let noticeExpand = UIButton(type: .system)
    private let hintLabel = HaloLabel()
    private let footerLabel = HaloLabel()
    /// Shown only when the camera has actually been refused. A door station whose camera is off
    /// disappears from every indoor panel's tile list, so the reason belongs on its own screen
    /// where somebody standing at the door can read it.
    private let cameraWarning = PaddedLabel()

    private let callButton: UIButton
    private let langBar: UIView
    private let purposeSection: UIView
    private let sosControl: SosSlideControl

    private let root = UIStackView()
    private let noticeColumn = UIStackView()
    private let actionColumn = UIStackView()

    private var noticeExpanded = false
    private var noticeText = ""
    private var isLandscape = false
    private var layoutStyle = "standard"
    private var lastLayoutSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.height > 0, bounds.size != lastLayoutSize {
            applyLayout(for: bounds.size)
        }
    }

    func setLayoutStyle(_ value: String) {
        let next = ["standard", "left", "right", "edges"].contains(value) ? value : "standard"
        guard next != layoutStyle else { return }
        layoutStyle = next
        applyLayout(for: bounds.size)
    }
    /// Whether this device's role offers the SOS slider. Remembered because `applyLayout` takes
    /// the whole stack apart and puts it back.
    private var sosVisible = true
    private var columnWidth: NSLayoutConstraint?
    private var callWidth: NSLayoutConstraint?
    /// The call button may not hug its label: the verb is two characters in Japanese, and a
    /// button barely wider than a finger is not what a visitor should have to hunt for.
    private static let callButtonMinimumColumnShare: CGFloat = 0.8
    private var skin = DoorbellSkin.plain(.dark)

    init(texts: Texts, callButton: UIButton, langBar: UIView, purposeSection: UIView,
         sosControl: SosSlideControl) {
        self.texts = texts
        self.callButton = callButton
        self.langBar = langBar
        self.purposeSection = purposeSection
        self.sosControl = sosControl
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        clockLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 96, weight: .light)
        clockLabel.textAlignment = .center
        clockLabel.adjustsFontSizeToFitWidth = true
        clockLabel.minimumScaleFactor = 0.4
        clockLabel.accessibilityIdentifier = "visitor_clock"

        dateLabel.font = .systemFont(ofSize: 24, weight: .medium)
        dateLabel.textAlignment = .center
        clockLabel.inkCompanion = dateLabel
        dateLabel.inkCompanion = clockLabel

        // A visitor is shown the message and nothing else: no author, no expiry.
        noticeLabel.font = .systemFont(ofSize: 22)
        noticeLabel.numberOfLines = 2
        noticeLabel.textAlignment = .center
        noticeLabel.accessibilityIdentifier = "visitor_notice"
        cameraWarning.font = .systemFont(ofSize: 17, weight: .semibold)
        cameraWarning.numberOfLines = 2
        cameraWarning.textAlignment = .center
        cameraWarning.accessibilityIdentifier = "visitor_camera_warning"
        cameraWarning.isHidden = true
        noticeExpand.setTitle("▾", for: .normal)
        noticeExpand.titleLabel?.font = .systemFont(ofSize: 22, weight: .bold)
        noticeExpand.accessibilityIdentifier = "visitor_notice_expand"
        noticeExpand.addTarget(self, action: #selector(toggleNotice), for: .primaryActionTriggered)
        noticeExpand.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        hintLabel.font = .systemFont(ofSize: 20)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.accessibilityIdentifier = "visitor_hint"

        footerLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        footerLabel.textAlignment = .center
        footerLabel.numberOfLines = 0
        footerLabel.accessibilityIdentifier = "app_version"

        let noticeRow = UIStackView(arrangedSubviews: [noticeLabel, noticeExpand])
        noticeRow.axis = .horizontal
        noticeRow.spacing = 8
        noticeRow.alignment = .center

        noticeColumn.axis = .vertical
        noticeColumn.spacing = 8
        noticeColumn.addArrangedSubview(noticeRow)
        noticeColumn.addArrangedSubview(cameraWarning)

        actionColumn.axis = .vertical
        actionColumn.spacing = 18
        // Children take the column's width: that is what bounds the purpose grid to the column it
        // sits in, and what gives the three language chips one row of equal widths in landscape
        // as well as portrait. Only the call button is centred at its own size.
        actionColumn.alignment = .fill

        // The bar keeps its own height; the spacer above it is what absorbs the slack.
        sosControl.setContentHuggingPriority(.required, for: .vertical)
        sosControl.setContentCompressionResistancePriority(.required, for: .vertical)

        root.axis = .vertical
        root.spacing = 18
        root.alignment = .fill
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyLayout(for: CGSize(width: 768, height: 1024))
    }

    func applyLayout(for size: CGSize) {
        lastLayoutSize = size
        let landscape = size.width > size.height
        let wide = min(size.width, size.height) >= 768
        isLandscape = landscape
        columnWidth?.isActive = false

        for view in root.arrangedSubviews.reversed() {
            root.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in [noticeColumn, actionColumn] {
            for child in view.arrangedSubviews {
                view.removeArrangedSubview(child)
                child.removeFromSuperview()
            }
        }

        let clockColumn = UIStackView(arrangedSubviews: [clockLabel, dateLabel])
        clockColumn.axis = .vertical
        clockColumn.spacing = 8

        let noticeRow = UIStackView(arrangedSubviews: [noticeLabel, noticeExpand])
        noticeRow.axis = .horizontal
        noticeRow.spacing = 8
        noticeRow.alignment = .center
        noticeColumn.addArrangedSubview(noticeRow)

        clockLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: wide ? 104 : (landscape ? 80 : 84), weight: .regular)
        hintLabel.font = .systemFont(ofSize: wide ? 18 : 16, weight: .regular)
        callButton.titleLabel?.font = .systemFont(ofSize: wide ? 44 : 38, weight: .semibold)
        #if !os(tvOS)
        let vertical: CGFloat = wide ? 34 : 24
        callButton.contentEdgeInsets = UIEdgeInsets(top: vertical, left: 60, bottom: vertical,
                                                    right: 60)
        #endif

        if layoutStyle == "left" || layoutStyle == "right" {
            clockLabel.font = .monospacedDigitSystemFont(ofSize: wide ? 80 : 68, weight: .regular)
            #if !os(tvOS)
            callButton.contentEdgeInsets = UIEdgeInsets(top: 30, left: 28, bottom: 30, right: 28)
            #endif
            actionColumn.addArrangedSubview(clockColumn)
            actionColumn.addArrangedSubview(noticeColumn)
            actionColumn.addArrangedSubview(callButtonRow())
            actionColumn.addArrangedSubview(hintLabel)
            actionColumn.addArrangedSubview(purposeSection)
            actionColumn.addArrangedSubview(langBar)
            let space = UIView()
            let columns = UIStackView(arrangedSubviews: layoutStyle == "left"
                ? [actionColumn, space] : [space, actionColumn])
            columns.axis = .horizontal
            columns.spacing = 24
            columns.alignment = .center
            columnWidth = actionColumn.widthAnchor.constraint(equalTo: columns.widthAnchor,
                multiplier: landscape ? 0.46 : 0.70)
            columnWidth?.isActive = true
            root.addArrangedSubview(columns)
            root.addArrangedSubview(footerLabel)
            if sosVisible { root.addArrangedSubview(sosControl) }
            return
        }
        if layoutStyle == "edges" {
            clockLabel.font = .monospacedDigitSystemFont(ofSize: wide ? 80 : 68, weight: .regular)
            root.addArrangedSubview(clockColumn)
            root.addArrangedSubview(noticeColumn)
            root.addArrangedSubview(UIView())
            root.addArrangedSubview(callButtonRow())
            root.addArrangedSubview(hintLabel)
            root.addArrangedSubview(purposeSection)
            root.addArrangedSubview(langBar)
            root.addArrangedSubview(footerLabel)
            if sosVisible { root.addArrangedSubview(sosControl) }
            return
        }
        if landscape {
            actionColumn.addArrangedSubview(callButtonRow())
            actionColumn.addArrangedSubview(hintLabel)
            actionColumn.addArrangedSubview(purposeSection)
            actionColumn.addArrangedSubview(langBar)
            let columns = UIStackView(arrangedSubviews: [
                stackVertically([clockColumn, noticeColumn, UIView()]), actionColumn])
            columns.axis = .horizontal
            columns.spacing = 28
            columns.distribution = .fillEqually
            columns.alignment = .center
            root.addArrangedSubview(columns)
            root.addArrangedSubview(footerLabel)
            if sosVisible { root.addArrangedSubview(sosControl) }
            return
        }

        root.addArrangedSubview(clockColumn)
        root.addArrangedSubview(noticeColumn)
        actionColumn.addArrangedSubview(callButtonRow())
        actionColumn.addArrangedSubview(hintLabel)
        actionColumn.addArrangedSubview(purposeSection)
        actionColumn.addArrangedSubview(langBar)
        root.addArrangedSubview(actionColumn)
        root.addArrangedSubview(UIView())
        root.addArrangedSubview(footerLabel)
        if sosVisible { root.addArrangedSubview(sosControl) }
    }

    /// The call button, centred in a full-width row and never narrower than its share of it.
    private func callButtonRow() -> UIView {
        let row = centred(callButton)
        callWidth?.isActive = false
        let width = callButton.widthAnchor.constraint(
            greaterThanOrEqualTo: row.widthAnchor,
            multiplier: VisitorScreenView.callButtonMinimumColumnShare)
        width.priority = UILayoutPriority(999)
        width.isActive = true
        callWidth = width
        return row
    }

    /// Wraps a control that must keep its own size inside a full-width row.
    private func centred(_ view: UIView) -> UIView {
        let row = UIStackView(arrangedSubviews: [UIView(), view, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .fill
        if let first = row.arrangedSubviews.first, let last = row.arrangedSubviews.last {
            first.widthAnchor.constraint(equalTo: last.widthAnchor).isActive = true
        }
        return row
    }

    private func stackVertically(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 16
        return stack
    }

    // MARK: - Content

    func setCallFlow(_ mode: String, hasPurposes: Bool) {
        let chooseOnHome = mode != "ring_then_purpose" && hasPurposes
        purposeSection.isHidden = !chooseOnHome
        callButton.setTitle(texts.t(chooseOnHome ? "door.call_direct" : "idle.call_button_verb"),
                            for: .normal)
        updateHint(texts.t(chooseOnHome ? "door.hint_purpose_first" : "door.hint_call"))
    }

    func updateClock(_ reading: DoorbellClock.Reading, lang: String) {
        clockLabel.text = reading.hhmmss
        dateLabel.text = DoorbellClock.longDate(reading, lang: lang)
    }

    func updateNotice(_ notice: DoorbellNotice?) {
        noticeText = notice?.text ?? ""
        let hasNotice = !noticeText.isEmpty
        noticeColumn.isHidden = !hasNotice
        noticeLabel.text = noticeText
        noticeExpand.isHidden = !hasNotice || noticeText.count < 40
        applyNoticeLines()
    }

    private func applyNoticeLines() {
        noticeLabel.numberOfLines = noticeExpanded ? 0 : 2
        noticeExpand.setTitle(noticeExpanded ? "▴" : "▾", for: .normal)
    }

    @objc private func toggleNotice() {
        noticeExpanded.toggle()
        applyNoticeLines()
    }

    func updateHint(_ text: String) {
        hintLabel.text = text
    }

    func updateFooter(_ text: String) {
        footerLabel.text = text
    }

    /// `nil` hides the banner. Nothing is said while a prompt is merely unanswered.
    func updateCameraWarning(_ text: String?) {
        cameraWarning.text = text
        cameraWarning.isHidden = (text == nil)
        applyCameraWarningSkin()
    }

    private func applyCameraWarningSkin() {
        DoorbellTheme.pill(cameraWarning, background: skin.palette.danger,
                           ink: DoorbellTheme.readableInk(on: skin.palette.danger), fontSize: 17)
    }

    /// A screen whose role offers no SOS slider does not merely hide one: it never puts one in
    /// the hierarchy. Hiding was not enough, because a safety control's semantic style forces it
    /// visible again on every layout pass.
    func setSosVisible(_ visible: Bool) {
        guard visible != sosVisible else { return }
        sosVisible = visible
        sosControl.isHidden = !visible
        if bounds.width > 0 && bounds.height > 0 { applyLayout(for: bounds.size) }
    }

    /// Applies the skin and the computed call-button colour. Every label here is drawn straight
    /// on the theme background, so each takes its own region's automatic ink. The button colour
    /// comes from Core's `auto_accent` when it is published, from the administrator's override
    /// when there is one, and from the local complement computation otherwise.
    func apply(skin: DoorbellSkin) {
        self.skin = skin
        let regions: [(String, UILabel)] = [("clock", clockLabel), ("date", dateLabel),
                                            ("hint", hintLabel), ("footer", footerLabel),
                                            ("notice", noticeLabel)]
        for (region, label) in regions {
            skin.apply(region, to: label, quiet: region == "footer")
        }
        noticeExpand.setTitleColor(noticeLabel.textColor, for: .normal)
        applyCameraWarningSkin()

        let colors = DoorbellTheme.callButtonColors(display: skin.display,
                                                    background: skin.background)
        callButton.backgroundColor = colors.fill
        // The call button keeps a plain title: it is one phrase, it already centres over as many
        // lines as it needs, and `applyLayout` resizes its font per screen size — which an
        // attributed title would freeze.
        callButton.setTitleColor(colors.ink, for: .normal)
    }
}
