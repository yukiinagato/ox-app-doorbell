import UIKit

/// Slide-to-trigger SOS. Releasing past 90 % of the track starts a cancellable countdown; only
/// when the countdown reaches zero does the owner call Core. A tap anywhere during the countdown
/// cancels it, and nothing is reported.
///
/// On tvOS there is no touch track, so the same control becomes a focusable button: selecting it
/// starts the identical countdown, and selecting it again cancels.
final class SosSlideControl: UIControl {

    /// Fired once the countdown has elapsed. Nothing else in this control talks to Core.
    var onTriggered: (() -> Void)?
    /// Fired every second while the countdown runs, and with nil when it stops.
    var onCountdown: ((Int?) -> Void)?

    var countdownSeconds = 3 {
        didSet { if !counting { applyIdleLabel() } }
    }

    private let texts: Texts
    private let track = UIView()
    private let thumb = UILabel()
    private let label = UILabel()
    private let countdownLabel = UILabel()
    private let cancelButton = UIButton(type: .system)

    private var thumbLeading: NSLayoutConstraint?
    private var dragging = false
    private var counting = false
    private var remaining = 0
    private var timer: Timer?

    private static let thumbSide: CGFloat = 52
    /// The bar is a bar. Inside a filling stack it has no intrinsic height to defend, so it took
    /// whatever slack was going — a third of an iPad screen on the device. This is the same
    /// compact band the Android shell uses.
    static let barHeight: CGFloat = 78

    init(texts: Texts) {
        self.texts = texts
        super.init(frame: .zero)
        build()
        applyIdleLabel()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { timer?.invalidate() }

    // MARK: - Construction

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "sos_slider"
        isAccessibilityElement = true
        accessibilityTraits = .button

        track.backgroundColor = UIColor(red: 0.55, green: 0.10, blue: 0.09, alpha: 1)
        track.layer.cornerRadius = 14
        // The track and everything drawn on it are decoration: the control itself has to receive
        // the touch, or hit testing would hand the drag to a subview and nothing would track.
        track.isUserInteractionEnabled = false
        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)

        label.numberOfLines = 2
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(label)

        // The double chevron is the vendored Tabler glyph, not the "\u{00BB}" character: a text
        // guillemet is a different shape in every font the fleet's devices ship with, and on the
        // older ones it is not the arrow this control means at all.
        thumb.text = nil
        thumb.textAlignment = .center
        thumb.textColor = UIColor(red: 0.55, green: 0.10, blue: 0.09, alpha: 1)
        thumb.backgroundColor = .white
        if let chevrons = TablerIcon.image("TablerChevronsRight") {
            let mark = UIImageView(image: chevrons)
            mark.tintColor = thumb.textColor
            mark.contentMode = .scaleAspectFit
            mark.translatesAutoresizingMaskIntoConstraints = false
            thumb.addSubview(mark)
            NSLayoutConstraint.activate([
                mark.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
                mark.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
                mark.widthAnchor.constraint(equalToConstant: 28),
                mark.heightAnchor.constraint(equalToConstant: 28),
            ])
        } else {
            thumb.text = "\u{00BB}"
            thumb.font = .systemFont(ofSize: 30, weight: .heavy)
        }
        thumb.layer.cornerRadius = 12
        thumb.clipsToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(thumb)

        countdownLabel.font = .systemFont(ofSize: 22, weight: .bold)
        countdownLabel.textColor = .white
        countdownLabel.textAlignment = .center
        countdownLabel.numberOfLines = 2
        countdownLabel.isHidden = true
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(countdownLabel)

        cancelButton.setTitle(texts.t("sos.cancel_countdown"), for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        cancelButton.setTitleColor(UIColor(red: 0.55, green: 0.10, blue: 0.09, alpha: 1),
                                   for: .normal)
        cancelButton.backgroundColor = .white
        cancelButton.layer.cornerRadius = 12
        cancelButton.accessibilityIdentifier = "sos_cancel_countdown"
        cancelButton.isHidden = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelCountdown),
                               for: .touchUpInside)
        // The cancel control stays outside the decoration so it can still be pressed.
        addSubview(cancelButton)

        let leading = thumb.leadingAnchor.constraint(equalTo: track.leadingAnchor, constant: 5)
        thumbLeading = leading
        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.heightAnchor.constraint(equalToConstant: SosSlideControl.barHeight),
            label.centerYAnchor.constraint(equalTo: track.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: track.leadingAnchor,
                                           constant: SosSlideControl.thumbSide + 16),
            label.trailingAnchor.constraint(equalTo: track.trailingAnchor, constant: -12),
            leading,
            thumb.centerYAnchor.constraint(equalTo: track.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: SosSlideControl.thumbSide),
            thumb.heightAnchor.constraint(equalToConstant: SosSlideControl.thumbSide),
            countdownLabel.centerYAnchor.constraint(equalTo: track.centerYAnchor),
            countdownLabel.leadingAnchor.constraint(equalTo: track.leadingAnchor, constant: 14),
            countdownLabel.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor,
                                                     constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: track.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: track.trailingAnchor, constant: -8),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        #if os(tvOS)
        // No touch tracking on tvOS: the control is focusable and the select button arms it.
        addTarget(self, action: #selector(onSelect), for: .primaryActionTriggered)
        #endif
    }

    private func applyIdleLabel() {
        label.attributedText = DoorbellTheme.twoPart(
            texts.t("sos.slide_two_line", "\(countdownSeconds)"), primarySize: 22, color: .white)
        accessibilityLabel = texts.t("sos.slide_two_line", "\(countdownSeconds)")
            .replacingOccurrences(of: "\n", with: " ")
    }

    func refreshStrings() {
        cancelButton.setTitle(texts.t("sos.cancel_countdown"), for: .normal)
        if !counting { applyIdleLabel() }
    }

    // MARK: - tvOS focus

    #if os(tvOS)
    override var canBecomeFocused: Bool { return true }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ [weak self] in
            self?.transform = focused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
            self?.track.layer.borderWidth = focused ? 3 : 0
            self?.track.layer.borderColor = UIColor.white.cgColor
        }, completion: nil)
    }

    @objc private func onSelect() {
        if counting { cancelCountdown() } else { startCountdown() }
    }
    #endif

    // MARK: - Touch tracking

    #if os(iOS)
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if counting {
            cancelCountdown()
            return false
        }
        dragging = true
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard dragging else { return false }
        move(to: touch.location(in: track).x)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        dragging = false
        // The final touch position decides, not the accumulated one: a quick flick delivers few
        // intermediate moves, and the gesture must still count as "slid to the end".
        if let touch = touch { move(to: touch.location(in: track).x) }
        let travel = maximumTravel()
        let value = travel > 0 ? (thumbLeading?.constant ?? 5) / travel : 0
        if value >= 0.9 {
            startCountdown()
        }
        resetThumb(animated: true)
    }

    override func cancelTracking(with event: UIEvent?) {
        dragging = false
        resetThumb(animated: true)
    }

    private func maximumTravel() -> CGFloat {
        return max(0, track.bounds.width - SosSlideControl.thumbSide - 10)
    }

    private func move(to x: CGFloat) {
        let travel = maximumTravel()
        guard travel > 0 else { return }
        let offset = max(5, min(travel, x - SosSlideControl.thumbSide / 2))
        thumbLeading?.constant = offset
        label.alpha = max(0, 1 - (offset / travel) * 1.4)
    }

    private func resetThumb(animated: Bool) {
        thumbLeading?.constant = 5
        label.alpha = 1
        guard animated else { return }
        UIView.animate(withDuration: 0.18) { self.layoutIfNeeded() }
    }
    #endif

    // MARK: - Countdown

    /// Public so the owner can arm the countdown from another surface with identical semantics.
    func startCountdown() {
        guard !counting else { return }
        counting = true
        remaining = max(0, countdownSeconds)
        label.isHidden = true
        thumb.isHidden = true
        countdownLabel.isHidden = false
        cancelButton.isHidden = false
        renderCountdown()
        if remaining == 0 {
            fire()
            return
        }
        timer?.invalidate()
        timer = IOSAvailability.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in self?.tick()
        }
    }

    @objc func cancelCountdown() {
        guard counting else { return }
        stopCountdown()
        onCountdown?(nil)
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            fire()
            return
        }
        renderCountdown()
        onCountdown?(remaining)
    }

    private func fire() {
        stopCountdown()
        onCountdown?(0)
        onTriggered?()
    }

    private func stopCountdown() {
        timer?.invalidate()
        timer = nil
        counting = false
        countdownLabel.isHidden = true
        cancelButton.isHidden = true
        label.isHidden = false
        thumb.isHidden = false
        #if os(iOS)
        resetThumb(animated: false)
        #endif
        applyIdleLabel()
    }

    private func renderCountdown() {
        countdownLabel.text = texts.t("sos.countdown", "\(max(remaining, 0))")
    }

    var isCountingDown: Bool { return counting }
}
