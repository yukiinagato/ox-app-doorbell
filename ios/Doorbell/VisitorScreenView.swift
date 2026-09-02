import UIKit

/// Door-station visitor screen. It hosts the controls `MainViewController` already owns — the call
/// button, the language row and the purpose buttons — and adds the layout the owner approved:
/// a large `HH:MM:SS` clock with the date, a text-only announcement, the language row in the
/// middle in portrait and directly above the call button in landscape, a single-sentence hint, and
/// a footer with the door name, both versions and the battery. There is no way into settings from
/// here; the hidden corner plus the admin password remains the only route.
final class VisitorScreenView: UIView {

    private let texts: Texts
    private let clockLabel = HaloLabel()
    private let dateLabel = HaloLabel()
    private let noticeLabel = HaloLabel()
    private let noticeExpand = UIButton(type: .system)
    private let hintLabel = HaloLabel()
    private let footerLabel = HaloLabel()

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
    /// Whether this device's role offers the SOS slider. Remembered because `applyLayout` takes
    /// the whole stack apart and puts it back.
    private var sosVisible = true
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

        dateLabel.font = .systemFont(ofSize: 24)
        dateLabel.textAlignment = .center

        // A visitor is shown the message and nothing else: no author, no expiry.
        noticeLabel.font = .systemFont(ofSize: 22)
        noticeLabel.numberOfLines = 2
        noticeLabel.textAlignment = .center
        noticeLabel.accessibilityIdentifier = "visitor_notice"
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

    /// Both orientations are computed from the current size, never fixed. Portrait stacks
    /// clock → notice → language → call → hint → footer; landscape splits the notice into the left
    /// column and keeps the language row immediately above the call button on the right.
    func applyLayout(for size: CGSize) {
        let landscape = size.width > size.height
        let wide = min(size.width, size.height) >= 768
        isLandscape = landscape

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
        clockColumn.spacing = 4

        let noticeRow = UIStackView(arrangedSubviews: [noticeLabel, noticeExpand])
        noticeRow.axis = .horizontal
        noticeRow.spacing = 8
        noticeRow.alignment = .center
        noticeColumn.addArrangedSubview(noticeRow)

        clockLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: wide ? 108 : (landscape ? 72 : 76), weight: .light)
        hintLabel.font = .systemFont(ofSize: wide ? 22 : 18)
        callButton.titleLabel?.font = .systemFont(ofSize: wide ? 40 : 30, weight: .bold)
        #if !os(tvOS)
        let vertical: CGFloat = wide ? 34 : 24
        callButton.contentEdgeInsets = UIEdgeInsets(top: vertical, left: 60, bottom: vertical,
                                                    right: 60)
        #endif

        if landscape {
            // With a notice on screen, the language row belongs directly above the call button.
            actionColumn.addArrangedSubview(langBar)
            actionColumn.addArrangedSubview(centred(callButton))
            actionColumn.addArrangedSubview(hintLabel)
            actionColumn.addArrangedSubview(purposeSection)
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
        root.addArrangedSubview(langBar)
        actionColumn.addArrangedSubview(centred(callButton))
        actionColumn.addArrangedSubview(hintLabel)
        actionColumn.addArrangedSubview(purposeSection)
        root.addArrangedSubview(actionColumn)
        root.addArrangedSubview(UIView())
        root.addArrangedSubview(footerLabel)
        if sosVisible { root.addArrangedSubview(sosControl) }
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
            skin.apply(region, to: label, quiet: region == "footer" || region == "date")
        }
        noticeExpand.setTitleColor(noticeLabel.textColor, for: .normal)

        let colors = DoorbellTheme.callButtonColors(display: skin.display,
                                                    background: skin.background)
        callButton.backgroundColor = colors.fill
        // The call button keeps a plain title: it is one phrase, it already centres over as many
        // lines as it needs, and `applyLayout` resizes its font per screen size — which an
        // attributed title would freeze.
        callButton.setTitleColor(colors.ink, for: .normal)
    }
}
