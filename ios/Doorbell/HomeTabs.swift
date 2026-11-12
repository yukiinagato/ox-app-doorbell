import UIKit

/// The Home tab of an indoor panel or a living-room screen: the dashboard under a navigation
/// bar. The household wallpaper belongs to the container behind the tabs and shows through this
/// screen only; the bar is transparent over it and takes Core's automatic ink for its title.
final class HomeViewController: UIViewController {

    let dashboard: DashboardView

    init(dashboard: DashboardView, title: String) {
        self.dashboard = dashboard
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(dashboard)
        // The dashboard starts under the bar and is clipped there, so tiles scroll out of sight
        // rather than under a title that has no material of its own.
        dashboard.clipsToBounds = true
        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        let margins = view.layoutMarginsGuide
        #if os(tvOS)
        dashboard.clipsToBounds = false
        #endif
        NSLayoutConstraint.activate([
            dashboard.topAnchor.constraint(equalTo: guide.topAnchor, constant: Space.xs),
            dashboard.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Space.xs),
            dashboard.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            dashboard.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
    }

    /// Paints the bar for the wallpaper behind it.
    func apply(skin: DoorbellSkin) {
        #if os(iOS)
        guard let bar = navigationController?.navigationBar else { return }
        let ink = skin.ink("status_line")
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.titleTextAttributes = [.foregroundColor: ink]
            appearance.largeTitleTextAttributes = [.foregroundColor: ink]
            navigationItem.standardAppearance = appearance
            navigationItem.scrollEdgeAppearance = appearance
            navigationItem.compactAppearance = appearance
        } else {
            bar.setBackgroundImage(UIImage(), for: .default)
            bar.shadowImage = UIImage()
            bar.titleTextAttributes = [.foregroundColor: ink]
            if #available(iOS 11.0, *) { bar.largeTitleTextAttributes = [.foregroundColor: ink] }
        }
        bar.tintColor = ink
        #endif
    }
}

/// The Settings tab before it is unlocked, and the container for the settings screen after.
/// Settings change the household, so the tab asks for the admin password once per admin window;
/// leaving the tab closes that window again.
final class SettingsGateViewController: UIViewController {

    private let texts: Texts
    var onUnlockRequested: (() -> Void)?
    private(set) var settings: SettingsViewController?
    private let unlockButton: UIButton

    var isUnlocked: Bool { return settings != nil }

    init(texts: Texts) {
        self.texts = texts
        unlockButton = SystemStyle.button(.filled, title: texts.t("settings.unlock"),
                                          large: true)
        super.init(nibName: nil, bundle: nil)
        title = texts.t("nav.settings")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SystemStyle.groupedBackground
        let icon = UIImageView(image: TablerIcon.image("TablerShieldLock"))
        icon.tintColor = SystemStyle.secondaryLabel
        icon.contentMode = .scaleAspectFit
        let heading = SystemStyle.label(.title2, weight: .semibold)
        heading.text = texts.t("nav.settings")
        heading.textAlignment = .center
        let hint = SystemStyle.label(.body, color: SystemStyle.secondaryLabel)
        hint.text = texts.t("settings.locked_hint")
        hint.textAlignment = .center
        unlockButton.accessibilityIdentifier = "settings_unlock"
        unlockButton.addTarget(self, action: #selector(requestUnlock),
                               for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [icon, heading, hint, unlockButton])
        stack.axis = .vertical
        stack.spacing = Space.m
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: margins.trailingAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            unlockButton.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchTarget.minimum),
        ])
    }

    @objc private func requestUnlock() { onUnlockRequested?() }

    /// Shows the settings screen in place of the locked placeholder.
    func unlock(with screen: SettingsViewController) {
        lock(closeAdminWindow: false)
        settings = screen
        screen.isEmbedded = true
        loadViewIfNeeded()
        addChild(screen)
        screen.view.frame = view.bounds
        screen.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen.view)
        screen.didMove(toParent: self)
    }

    /// Removes the settings screen. `closeAdminWindow` also ends Core's admin window.
    func lock(closeAdminWindow: Bool = true) {
        guard let screen = settings else { return }
        settings = nil
        screen.dismiss(animated: false)
        screen.willMove(toParent: nil)
        screen.view.removeFromSuperview()
        screen.removeFromParent()
        if closeAdminWindow { screen.leaveAdminWindow() }
    }
}

/// The destinations of an indoor panel and of the living-room screen: Home, History and
/// Settings. A stock tab bar; each tab owns a navigation controller, with large titles where the
/// OS has them. History carries the unread missed-call count as its badge.
final class PanelTabBarController: UITabBarController, UITabBarControllerDelegate {

    enum Tab: Int {
        case home, history, settings
    }

    let home: HomeViewController
    let history: CallHistoryViewController
    let settingsGate: SettingsGateViewController

    init(home: HomeViewController, history: CallHistoryViewController,
         settingsGate: SettingsGateViewController, texts: Texts) {
        self.home = home
        self.history = history
        self.settingsGate = settingsGate
        super.init(nibName: nil, bundle: nil)
        let homeNav = SystemStyle.navigation(home)
        homeNav.view.backgroundColor = .clear
        let pages: [(UIViewController, String, String, String)] = [
            (homeNav, texts.t("nav.home"), "TablerHome", "tab_home"),
            (history, texts.t("nav.history"), "TablerClock", "tab_history"),
            (settingsGate, texts.t("nav.settings"), "TablerSettings", "tab_settings"),
        ]
        for (index, page) in pages.enumerated() {
            let item = UITabBarItem(title: page.1, image: TablerIcon.image(page.2), tag: index)
            item.accessibilityIdentifier = page.3
            page.0.tabBarItem = item
        }
        viewControllers = pages.map { $0.0 }
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        #if os(iOS)
        // Home has the wallpaper behind it, so the bar keeps its material there instead of going
        // transparent at the scroll edge.
        if #available(iOS 15.0, *) {
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            tabBar.standardAppearance = appearance
            tabBar.scrollEdgeAppearance = appearance
        }
        #endif
    }

    var currentTab: Tab { return Tab(rawValue: selectedIndex) ?? .home }

    func show(_ tab: Tab) {
        guard tab != currentTab else { return }
        if tab == .settings && !settingsGate.isUnlocked {
            settingsGate.onUnlockRequested?()
            return
        }
        leaving(currentTab)
        selectedIndex = tab.rawValue
    }

    /// Back to the dashboard, with the admin window closed: what an unattended panel does.
    func returnHome() {
        leaving(currentTab)
        selectedIndex = Tab.home.rawValue
        settingsGate.lock()
        (viewControllers?.first as? UINavigationController)?.popToRootViewController(animated: false)
    }

    /// Opens the Settings tab on an unlocked settings screen.
    func revealSettings(_ screen: SettingsViewController) {
        settingsGate.unlock(with: screen)
        selectedIndex = Tab.settings.rawValue
    }

    func setUnreadMissed(_ count: Int) {
        history.tabBarItem.badgeValue = count > 0 ? "\(count)" : nil
    }

    private func leaving(_ tab: Tab) {
        if tab == .settings { settingsGate.lock() }
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          shouldSelect viewController: UIViewController) -> Bool {
        if viewController === settingsGate && !settingsGate.isUnlocked {
            settingsGate.onUnlockRequested?()
            return false
        }
        if viewController !== selectedViewController { leaving(currentTab) }
        return true
    }
}
