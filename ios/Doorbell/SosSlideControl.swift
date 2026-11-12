import UIKit

/// The slide that confirms an SOS, shown on the confirmation surface and nowhere else. Releasing
/// past 90 % of the track starts a cancellable countdown; releasing early springs back; only when
/// the countdown reaches zero does the owner call Core. A tap anywhere during the countdown
/// cancels it, and nothing is reported. There is no press-and-hold.
///
/// On tvOS there is no touch track, so the confirmation there is an alert with a Send button
/// (see `SosTriggerButton`).
final class SosSlideControl: UIControl {

    /// Fired once the countdown has elapsed. Nothing else in this control talks to Core.
    var onTriggered: (() -> Void)?
    /// Fired every second while the countdown runs, and with nil when it stops.
    var onCountdown: ((Int?) -> Void)?
    /// Fired when a finger lands on the control, so its surface can restart its idle timer.
    var onTouch: (() -> Void)?
    /// Replaces the idle label, for the surface that clears an alarm rather than raising one.
    var idleText: String? {
        didSet { if !counting { applyIdleLabel() } }
    }

    var countdownSeconds = 3 {
        didSet { if !counting { applyIdleLabel() } }
    }

    private let texts: Texts
    private let track = UIView()
    private let thumb = UIView()
    private let label = UILabel()
    private let countdownLabel = UILabel()
    private let cancelButton = UIButton(type: .system)

    private var thumbLeading: NSLayoutConstraint?
    private var dragging = false
    private var counting = false
    private var remaining = 0
    private var timer: Timer?
    private weak var accessibleConfirmation: UIAlertController?
    private var confirmationRevision: UInt64 = 0

    private static let thumbSide: CGFloat = 48
    /// The bar is a bar. Inside a filling stack it has no intrinsic height to defend, so it took
    /// whatever slack was going — a third of an iPad screen on the device. This is the same
    /// compact band the Android shell uses.
    static let barHeight: CGFloat = 64

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

        track.backgroundColor = SystemStyle.negative
        track.layer.cornerRadius = SosSlideControl.barHeight / 2
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
        thumb.backgroundColor = .white
        thumb.isUserInteractionEnabled = false
        let mark = UIImageView(image: TablerIcon.image("TablerChevronsRight"))
        mark.tintColor = SystemStyle.negative
        mark.contentMode = .scaleAspectFit
        mark.translatesAutoresizingMaskIntoConstraints = false
        thumb.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 28),
            mark.heightAnchor.constraint(equalToConstant: 28),
        ])
        thumb.layer.cornerRadius = SosSlideControl.thumbSide / 2
        thumb.clipsToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(thumb)

        countdownLabel.font = SystemStyle.font(.headline)
        countdownLabel.textColor = .white
        countdownLabel.textAlignment = .center
        countdownLabel.numberOfLines = 2
        countdownLabel.isHidden = true
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(countdownLabel)

        cancelButton.setTitle(texts.t("sos.cancel_countdown"), for: .normal)
        cancelButton.titleLabel?.font = SystemStyle.font(.headline)
        cancelButton.setTitleColor(SystemStyle.negative, for: .normal)
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
            label.centerXAnchor.constraint(equalTo: track.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: track.leadingAnchor,
                                           constant: SosSlideControl.thumbSide + 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: track.trailingAnchor,
                                            constant: -12),
            leading,
            thumb.centerYAnchor.constraint(equalTo: track.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: SosSlideControl.thumbSide),
            thumb.heightAnchor.constraint(equalToConstant: SosSlideControl.thumbSide),
            countdownLabel.centerYAnchor.constraint(equalTo: track.centerYAnchor),
            countdownLabel.centerXAnchor.constraint(equalTo: track.centerXAnchor),
            countdownLabel.leadingAnchor.constraint(greaterThanOrEqualTo: track.leadingAnchor,
                                                     constant: 14),
            countdownLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor,
                                                      constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: track.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: track.trailingAnchor, constant: -8),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        addTarget(self, action: #selector(onSelect), for: .primaryActionTriggered)
    }

    private func applyIdleLabel() {
        label.attributedText = DoorbellTheme.twoPart(
            idleText ?? texts.t("sos.slide_two_line", "\(countdownSeconds)"),
            primarySize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            color: .white, bold: false)
        accessibilityLabel = texts.t("sos.accessibility_start")
        accessibilityHint = texts.t("sos.accessibility_hint")
        accessibilityValue = nil
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

    #endif

    @objc private func onSelect() {
        guard isEnabled else { return }
#if os(tvOS)
        if counting { cancelCountdown() } else { startCountdown() }
#else
        _ = accessibilityActivate()
#endif
    }

    override func accessibilityActivate() -> Bool {
        guard isAvailableForActivation else { return false }
        if counting { cancelCountdown(); return true }
        if accessibleConfirmation != nil { return true }
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let presenter = responder as? UIViewController,
              presenter.presentedViewController == nil, window != nil else { return false }
        let alert = UIAlertController(title: texts.t("sos.accessibility_confirm"),
                                      message: texts.t("sos.accessibility_hint"), preferredStyle: .alert)
        confirmationRevision &+= 1
        let revision = confirmationRevision
        alert.addAction(UIAlertAction(title: texts.t("admin.cancel"), style: .cancel) { [weak self] _ in
            guard let self = self, self.confirmationRevision == revision else { return }
            self.accessibleConfirmation = nil
        })
        alert.addAction(UIAlertAction(title: texts.t("sos.accessibility_start"), style: .destructive) {
            [weak self] _ in self?.confirmAccessibleStart(revision: revision)
        })
        accessibleConfirmation = alert
        presenter.present(alert, animated: true)
        return true
    }

    private var isAvailableForActivation: Bool {
        guard isEnabled, window != nil else { return false }
        var current: UIView? = self
        while let view = current {
            if view.isHidden || view.alpha <= 0 || !view.isUserInteractionEnabled { return false }
            current = view.superview
        }
        return true
    }

    private func confirmAccessibleStart(revision: UInt64) {
        guard revision == confirmationRevision else { return }
        accessibleConfirmation = nil
        guard isAvailableForActivation else { return }
        startCountdown()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        // Responsive stack rebuilding can reparent this control during the same layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.window == nil else { return }
            self.cancelCountdown()
        }
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled { cancelCountdown() } }
    }

#if os(iOS)
    override var canBecomeFirstResponder: Bool { return true }
    override var keyCommands: [UIKeyCommand]? {
        return [UIKeyCommand(input: " ", modifierFlags: [], action: #selector(onSelect)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(onSelect)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                             action: #selector(cancelCountdown))]
    }
#endif

    // MARK: - Touch tracking

    #if os(iOS)
    /// A drag that starts on the track belongs to the slide. Without this the sheet the control
    /// sits in takes the pan for its own dismissal and cancels the slide half way.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return !(gestureRecognizer is UIPanGestureRecognizer)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if counting {
            cancelCountdown()
            return false
        }
        onTouch?()
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
        confirmationRevision &+= 1
        accessibleConfirmation?.dismiss(animated: false)
        accessibleConfirmation = nil
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
        accessibilityValue = countdownLabel.text
        accessibilityHint = texts.t("sos.cancel_countdown")
    }

    var isCountingDown: Bool { return counting }
}

/// The SOS trigger: a compact outlined button, an icon and "SOS", that never competes with a
/// screen's primary action. Tapping it only opens the confirmation surface. The alert itself
/// needs a second, different gesture there (a slide end to end), so a resting palm, a stray tap
/// or a long press cannot raise it. After the slide the cancellable countdown runs, and
/// `onTriggered` fires only when it reaches zero.
final class SosTriggerButton: UIButton {

    /// Fired once the countdown has elapsed. Nothing in this file talks to Core.
    var onTriggered: (() -> Void)?
    var countdownSeconds = 3

    private let texts: Texts
    private weak var surface: UIViewController?
    private var countdownTimer: Timer?

    init(texts: Texts) {
        self.texts = texts
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "sos_trigger"
        #if os(tvOS)
        // A remote lands on it by focus: a roomier target, and the focus state drawn by hand
        // because this is not a system-styled button.
        titleLabel?.font = SystemStyle.font(.headline)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 66).isActive = true
        #else
        setImage(TablerIcon.image("TablerAlertTriangle"), for: .normal)
        titleLabel?.font = SystemStyle.font(.subheadline, weight: .semibold)
        #endif
        SystemStyle.followContentSize(titleLabel)
        layer.cornerRadius = 10
        layer.borderWidth = 1.5
        #if !os(tvOS)
        contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 14)
        titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: -6)
        #endif
        heightAnchor.constraint(greaterThanOrEqualToConstant: TouchTarget.minimum).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        addTarget(self, action: #selector(open), for: .primaryActionTriggered)
        refreshStrings()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { countdownTimer?.invalidate() }

    func refreshStrings() {
        setTitle(texts.t("sos.title"), for: .normal)
        accessibilityLabel = texts.t("sos.title")
        accessibilityHint = texts.t("sos.accessibility_hint")
        // An outline in the negative role and no fill: present, but quieter than any primary.
        setTitleColor(SystemStyle.negative, for: .normal)
        tintColor = SystemStyle.negative
        layer.borderColor = SystemStyle.negative.cgColor
    }

    #if os(tvOS)
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ [weak self] in
            guard let self = self else { return }
            self.transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
            self.backgroundColor = focused ? SystemStyle.negative : .clear
            self.setTitleColor(focused ? .white : SystemStyle.negative, for: .normal)
        }, completion: nil)
    }
    #endif

    var isConfirming: Bool { return surface != nil }

    /// Closes the confirmation surface and stops any countdown on it.
    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        #if os(iOS)
        (surface as? SosConfirmViewController)?.abandon()
        #endif
        surface?.dismiss(animated: false)
        surface = nil
    }

    private func presenter() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) { responder = current.next }
        var top = responder as? UIViewController
        while let parent = top?.parent { top = parent }
        guard top?.presentedViewController == nil else { return nil }
        return top
    }

    @objc private func open() {
        guard isEnabled, !isHidden, window != nil, surface == nil,
              let presenter = presenter() else { return }
        #if os(tvOS)
        openAlert(from: presenter)
        #else
        let confirm = SosConfirmViewController(texts: texts,
                                               purpose: .send(countdown: countdownSeconds)) {
            [weak self] in self?.onTriggered?()
        }
        surface = confirm
        presenter.present(confirm, animated: !Motion.reduced)
        #endif
    }

    #if os(tvOS)
    /// A remote has no drag, so the confirmation is an alert whose Send button is not the
    /// default focus; the countdown that follows is the same cancellable one.
    private func openAlert(from presenter: UIViewController) {
        let alert = SosConfirmation.alert(texts: texts, title: texts.t("sos.confirm_title"),
                                          message: texts.t("sos.hint"),
                                          confirm: texts.t("sos.send")) { [weak self] in
            self?.runCountdown(from: presenter)
        }
        surface = alert
        presenter.present(alert, animated: true)
    }

    private func runCountdown(from presenter: UIViewController) {
        var remaining = max(0, countdownSeconds)
        guard remaining > 0 else { onTriggered?(); return }
        let alert = UIAlertController(title: texts.t("sos.countdown", "\(remaining)"),
                                      message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: texts.t("sos.cancel_countdown"), style: .cancel) {
            [weak self] _ in self?.cancelCountdown()
        })
        surface = alert
        presenter.present(alert, animated: true)
        countdownTimer = IOSAvailability.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self, weak alert] _ in
            guard let self = self else { return }
            remaining -= 1
            if remaining > 0 {
                alert?.title = self.texts.t("sos.countdown", "\(remaining)")
                return
            }
            self.countdownTimer?.invalidate()
            self.countdownTimer = nil
            self.surface = nil
            alert?.dismiss(animated: true) { [weak self] in self?.onTriggered?() }
        }
    }
    #endif
}

/// The alert form of the SOS confirmation, for input without a drag: Cancel is the preferred
/// action and takes the default focus, the confirming action is the destructive one, and the
/// alert closes by itself after ten seconds without input.
enum SosConfirmation {
    static let idleTimeout: TimeInterval = 10

    static func alert(texts: Texts, title: String, message: String, confirm: String,
                      onConfirm: @escaping () -> Void) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let cancel = UIAlertAction(title: texts.t("admin.cancel"), style: .cancel)
        alert.addAction(cancel)
        alert.addAction(UIAlertAction(title: confirm, style: .destructive) { _ in onConfirm() })
        alert.preferredAction = cancel
        alert.view.accessibilityIdentifier = "sos_confirm"
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout) { [weak alert] in
            guard let alert = alert, alert.presentingViewController != nil else { return }
            alert.dismiss(animated: true)
        }
        return alert
    }
}

#if os(iOS)
/// The SOS confirmation surface: a sheet that says what will happen and who is alerted, with the
/// slide that confirms it and a plain Cancel. It closes by itself after ten seconds without
/// input. The same surface, worded for it, confirms clearing an active alarm.
final class SosConfirmViewController: UIViewController {

    enum Purpose {
        /// Raise an SOS after the cancellable countdown.
        case send(countdown: Int)
        /// Clear the alarm that is active now.
        case clear
    }

    private let texts: Texts
    private let purpose: Purpose
    private var onConfirmed: (() -> Void)?
    let slide: SosSlideControl
    private var idleTimer: Timer?

    init(texts: Texts, purpose: Purpose, onConfirmed: @escaping () -> Void) {
        self.texts = texts
        self.purpose = purpose
        self.onConfirmed = onConfirmed
        self.slide = SosSlideControl(texts: texts)
        super.init(nibName: nil, bundle: nil)
        if #available(iOS 15.0, *) {
            modalPresentationStyle = .pageSheet
            sheetPresentationController?.detents = [.medium(), .large()]
            sheetPresentationController?.prefersGrabberVisible = true
        } else {
            modalPresentationStyle = .formSheet
        }
        preferredContentSize = CGSize(width: 480, height: 420)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { idleTimer?.invalidate() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SystemStyle.background
        view.accessibilityIdentifier = "sos_confirm"
        let icon = UIImageView(image: TablerIcon.image("TablerAlertTriangle"))
        icon.tintColor = SystemStyle.negative
        icon.contentMode = .scaleAspectFit
        let heading = SystemStyle.label(.title2, weight: .bold)
        heading.textAlignment = .center
        heading.accessibilityTraits = .header
        let body = SystemStyle.label(.body, color: SystemStyle.secondaryLabel)
        body.textAlignment = .center
        let send = SystemStyle.button(.destructive, large: true)
        send.accessibilityIdentifier = "sos_send"
        send.addTarget(self, action: #selector(sendWithoutSlide), for: .touchUpInside)
        // A drag is not available to everyone: with VoiceOver or Switch Control running, the
        // confirming step is a button, placed after Cancel so it is not the first thing reached.
        send.isHidden = !(UIAccessibility.isVoiceOverRunning
            || UIAccessibility.isSwitchControlRunning)
        let cancel = SystemStyle.button(.gray, title: texts.t("admin.cancel"), large: true)
        cancel.accessibilityIdentifier = "sos_confirm_cancel"
        cancel.addTarget(self, action: #selector(close), for: .touchUpInside)

        switch purpose {
        case .send(let countdown):
            heading.text = texts.t("sos.confirm_title")
            body.text = texts.t("sos.hint")
            slide.countdownSeconds = countdown
            SystemStyle.style(send, kind: .destructive, title: texts.t("sos.send"), large: true)
        case .clear:
            heading.text = texts.t("emergency.cancel")
            body.text = texts.t("emergency.clear_confirm")
            slide.countdownSeconds = 0
            slide.idleText = texts.t("sos.slide_to_clear")
            slide.accessibilityLabel = texts.t("emergency.cancel")
            SystemStyle.style(send, kind: .destructive, title: texts.t("emergency.cancel"),
                              large: true)
        }
        slide.isAccessibilityElement = send.isHidden
        slide.onTouch = { [weak self] in self?.restartIdleTimer() }
        slide.onCountdown = { [weak self] remaining in
            // The countdown is its own deadline; the idle timer starts again if it is cancelled.
            if remaining == nil { self?.restartIdleTimer() } else { self?.idleTimer?.invalidate() }
        }
        slide.onTriggered = { [weak self] in self?.confirmed() }

        let stack = UIStackView(arrangedSubviews: [icon, heading, body, slide, cancel, send])
        stack.axis = .vertical
        stack.spacing = Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let margins = view.layoutMarginsGuide
        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 40),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: Space.xl),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor,
                                          constant: -Space.m),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchTarget.minimum),
            send.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchTarget.minimum),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restartIdleTimer()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        abandon()
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = IOSAvailability.scheduledTimer(
            withTimeInterval: SosConfirmation.idleTimeout, repeats: false
        ) { [weak self] _ in self?.close() }
    }

    /// Drops the pending confirmation: nothing fires after this.
    func abandon() {
        idleTimer?.invalidate()
        idleTimer = nil
        onConfirmed = nil
        slide.cancelCountdown()
    }

    @objc private func close() {
        abandon()
        dismiss(animated: !Motion.reduced)
    }

    @objc private func sendWithoutSlide() {
        restartIdleTimer()
        slide.startCountdown()
    }

    private func confirmed() {
        idleTimer?.invalidate()
        let action = onConfirmed
        onConfirmed = nil
        dismiss(animated: !Motion.reduced) { action?() }
    }
}
#endif
