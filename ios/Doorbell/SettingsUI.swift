import UIKit

// Native settings, laid out like the system Settings app: a grouped drill-down on iPhone and a
// master–detail split on iPad and Apple TV. Every screen renders a page from `SettingsCatalog` and
// sends committed values back to the host, which writes them through Core's config batch path
// (with the native admin window handled by `ConfigWriter`) and refreshes every open page.

/// What every settings screen needs from the container.
protocol SettingsHosting: AnyObject {
    var palette: DoorbellPalette { get }
    var texts: Texts { get }
    var usesSplit: Bool { get }
    func catalog() -> SettingsCatalog
    func commit(_ item: SettingItem, _ value: SettingValue, from: UIViewController)
    func perform(_ effect: SettingEffect, item: SettingItem?, value: SettingValue?,
                 from: UIViewController, completion: ((Bool) -> Void)?)
    func openShell(_ id: String, title: String, from: UIViewController)
    func openWeb(title: String, reason: String, from: UIViewController)
    func register(_ screen: SettingsRefreshable)
    func show(_ controller: UIViewController, from: UIViewController)
}

protocol SettingsRefreshable: AnyObject {
    func refreshFromHost()
}

// MARK: - Styling shared by every settings screen

enum SettingsStyle {
    static func tableStyle() -> UITableView.Style {
        #if os(iOS)
        if #available(iOS 13.0, *) { return .insetGrouped }
        #endif
        return .grouped
    }

    static func apply(_ palette: DoorbellPalette, to table: UITableView) {
        table.backgroundColor = palette.background
        table.backgroundView = nil
        #if os(iOS)
        table.separatorColor = palette.separator
        #endif
        table.tintColor = palette.accent
        table.estimatedRowHeight = 52
        table.rowHeight = UITableView.automaticDimension
        if #available(iOS 9.0, tvOS 9.0, *) { table.cellLayoutMarginsFollowReadableWidth = true }
    }

    static func apply(_ palette: DoorbellPalette, to cell: UITableViewCell) {
        cell.backgroundColor = palette.surfaceSolid
        cell.textLabel?.textColor = palette.ink
        cell.detailTextLabel?.textColor = palette.inkMuted
        cell.tintColor = palette.accent
        let selected = UIView()
        selected.backgroundColor = palette.surfaceStrongSolid
        cell.selectedBackgroundView = selected
    }

    static func apply(_ palette: DoorbellPalette, to bar: UINavigationBar) {
        bar.barTintColor = palette.background
        bar.tintColor = palette.accent
        bar.isTranslucent = false
        bar.titleTextAttributes = [.foregroundColor: palette.ink]
        #if os(iOS)
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = palette.background
            appearance.titleTextAttributes = [.foregroundColor: palette.ink]
            appearance.largeTitleTextAttributes = [.foregroundColor: palette.ink]
            bar.standardAppearance = appearance
            bar.scrollEdgeAppearance = appearance
            bar.compactAppearance = appearance
        }
        #endif
    }

    static func header(_ palette: DoorbellPalette, _ view: UIView) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.textColor = palette.inkMuted
    }

    private static var iconCache: [String: UIImage] = [:]

    /// The coloured rounded tile beside a category, drawn once per glyph.
    static func icon(_ icon: SettingIcon) -> UIImage? {
        let key = "\(icon.glyph)#\(icon.tint)"
        if let cached = iconCache[key] { return cached }
        let size = CGSize(width: 30, height: 30)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }
        let color = UIColor(red: CGFloat((icon.tint >> 16) & 0xFF) / 255,
                            green: CGFloat((icon.tint >> 8) & 0xFF) / 255,
                            blue: CGFloat(icon.tint & 0xFF) / 255, alpha: 1)
        color.setFill()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7).fill()
        let glyph = icon.glyph as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18)]
        let measured = glyph.size(withAttributes: attributes)
        glyph.draw(at: CGPoint(x: (size.width - measured.width) / 2,
                               y: (size.height - measured.height) / 2), withAttributes: attributes)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        if let image = image { iconCache[key] = image }
        return image
    }

    /// The options a tvOS list offers for a numeric control (tvOS has no slider or stepper).
    static func steps(minimum: Int, maximum: Int, step: Int, unit: String) -> [SettingOption] {
        var stride = max(1, step)
        while (maximum - minimum) / stride > 60 { stride *= 2 }
        var values = Array(Swift.stride(from: minimum, through: maximum, by: stride))
        if values.last != maximum { values.append(maximum) }
        return values.map { SettingOption(value: "\($0)", title: unit.isEmpty ? "\($0)" : "\($0) \(unit)") }
    }

    static func clockSteps() -> [SettingOption] {
        return Swift.stride(from: 0, to: 24 * 60, by: 15).map {
            let value = String(format: "%02d:%02d", $0 / 60, $0 % 60)
            return SettingOption(value: value, title: value)
        }
    }

    static var isTV: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Category list (the left column, or the iPhone root)

final class SettingsCategoryListController: UITableViewController, SettingsRefreshable {

    private weak var host: SettingsHosting?
    private var allCategories: [SettingsCategory] = []
    private var categories: [SettingsCategory] = []
    private var selectedId: String?
    private var query = ""
    var onClose: (() -> Void)?
    #if os(iOS)
    private let search = UISearchBar()
    #endif

    init(host: SettingsHosting) {
        self.host = host
        super.init(style: SettingsStyle.tableStyle())
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let host = host else { return }
        title = host.texts.t("settings.title")
        SettingsStyle.apply(host.palette, to: tableView)
        tableView.accessibilityIdentifier = "settings_categories"
        #if os(iOS)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: host.texts.t("settings.close"),
                                                           style: .done, target: self,
                                                           action: #selector(close))
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "settings_close"
        #endif
        #if os(iOS)
        search.placeholder = host.texts.t("prefs.search")
        search.delegate = self
        search.autocapitalizationType = .none
        search.barTintColor = host.palette.background
        search.sizeToFit()
        tableView.tableHeaderView = search
        #endif
        host.register(self)
        refreshFromHost()
    }

    /// A category matches when its title, its summary or any item title on its page does.
    private func applyFilter() {
        let needle = query.lowercased()
        guard !needle.isEmpty else {
            categories = allCategories
            return
        }
        categories = allCategories.filter { category in
            if category.title.lowercased().contains(needle) ||
                category.summary.lowercased().contains(needle) { return true }
            return category.page().sections.contains { section in
                section.header.lowercased().contains(needle) ||
                    section.items.contains { $0.title.lowercased().contains(needle) }
            }
        }
    }

    func select(_ id: String) {
        selectedId = id
        if let row = categories.firstIndex(where: { $0.id == id }) {
            tableView.selectRow(at: IndexPath(row: row, section: 0), animated: false,
                                scrollPosition: .none)
        }
    }

    func refreshFromHost() {
        guard let host = host else { return }
        allCategories = host.catalog().categories()
        applyFilter()
        tableView.reloadData()
        if host.usesSplit, let id = selectedId { select(id) }
    }

    @objc private func close() { onClose?() }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return SettingsStyle.isTV ? 2 : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? categories.count : 1
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        if let palette = host?.palette { SettingsStyle.apply(palette, to: cell) }
        guard indexPath.section == 0 else {
            cell.textLabel?.text = host?.texts.t("settings.close")
            cell.textLabel?.textAlignment = .center
            cell.accessibilityIdentifier = "settings_close"
            return cell
        }
        let category = categories[indexPath.row]
        cell.textLabel?.text = category.title
        cell.detailTextLabel?.text = host?.usesSplit == true ? "" : category.summary
        cell.imageView?.image = SettingsStyle.icon(category.icon)
        cell.accessoryType = host?.usesSplit == true ? .none : .disclosureIndicator
        cell.accessibilityIdentifier = "settings_\(category.id)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let host = host else { return }
        guard indexPath.section == 0 else { close(); return }
        let category = categories[indexPath.row]
        selectedId = category.id
        let page = SettingsPageController(host: host, path: [category.id])
        if host.usesSplit {
            let nav = UINavigationController(rootViewController: page)
            SettingsStyle.apply(host.palette, to: nav.navigationBar)
            splitViewController?.showDetailViewController(nav, sender: self)
        } else {
            tableView.deselectRow(at: indexPath, animated: true)
            navigationController?.pushViewController(page, animated: true)
        }
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView,
                            forSection section: Int) {
        if let palette = host?.palette { SettingsStyle.header(palette, view) }
    }
}

#if os(iOS)
extension SettingsCategoryListController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText
        applyFilter()
        tableView.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
}
#endif

// MARK: - One settings page

final class SettingsPageController: UITableViewController, SettingsRefreshable {

    private weak var host: SettingsHosting?
    let path: [String]
    private var page = SettingsPage(id: "", title: "", sections: [])
    private var pendingStepper: DispatchWorkItem?

    init(host: SettingsHosting, path: [String]) {
        self.host = host
        self.path = path
        super.init(style: SettingsStyle.tableStyle())
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let host = host else { return }
        SettingsStyle.apply(host.palette, to: tableView)
        tableView.accessibilityIdentifier = "settings_page_\(path.last ?? "")"
        host.register(self)
        refreshFromHost()
    }

    func refreshFromHost() {
        guard let host = host, let fresh = host.catalog().page(path: path) else { return }
        page = fresh
        title = fresh.title
        tableView.reloadData()
    }

    private func item(at indexPath: IndexPath) -> SettingItem {
        return page.sections[indexPath.section].items[indexPath.row]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { return page.sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return page.sections[section].items.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let header = page.sections[section].header
        return header.isEmpty ? nil : header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let footer = page.sections[section].footer
        return footer.isEmpty ? nil : footer
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView,
                            forSection section: Int) {
        if let palette = host?.palette { SettingsStyle.header(palette, view) }
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView,
                            forSection section: Int) {
        if let palette = host?.palette { SettingsStyle.header(palette, view) }
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let host = host else { return UITableViewCell() }
        let item = self.item(at: indexPath)
        let palette = host.palette
        let cell: UITableViewCell
        switch item.control {
        #if os(iOS)
        case .slider(let value, let minimum, let maximum, let step):
            let slider = SettingsSliderCell(palette: palette)
            slider.configure(title: item.title, detail: item.detail, value: value, minimum: minimum,
                             maximum: maximum, step: step) { [weak self] newValue in
                guard let self = self else { return }
                self.host?.commit(item, .int(newValue), from: self)
            }
            cell = slider
        case .segmented(let value, let options):
            let segmented = SettingsSegmentCell(palette: palette)
            segmented.configure(title: item.title, value: value, options: options) {
                [weak self] newValue in
                guard let self = self else { return }
                self.host?.commit(item, .string(newValue), from: self)
            }
            cell = segmented
        case .secret:
            let secret = SettingsSecretCell(palette: palette)
            secret.configure(title: item.title) { [weak self] text in
                guard let self = self else { return }
                self.host?.commit(item, .string(text), from: self)
            }
            cell = secret
        #endif
        default:
            cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            SettingsStyle.apply(palette, to: cell)
            configure(cell, item: item, palette: palette)
        }
        cell.accessibilityIdentifier = item.id
        return cell
    }

    private func configure(_ cell: UITableViewCell, item: SettingItem, palette: DoorbellPalette) {
        guard let host = host else { return }
        cell.textLabel?.text = item.title
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        cell.selectionStyle = .default
        switch item.control {
        case .toggle(let on):
            #if os(iOS)
            let toggle = UISwitch()
            toggle.isOn = on
            toggle.onTintColor = palette.accent
            toggle.accessibilityIdentifier = item.id + "_switch"
            toggle.addTarget(self, action: #selector(toggled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
            #else
            cell.detailTextLabel?.text = host.texts.t(on ? "settings.on" : "settings.off")
            #endif
        case .stepper(let value, let minimum, let maximum, let step, let unit):
            cell.detailTextLabel?.text = unit.isEmpty ? "\(value)" : "\(value) \(unit)"
            #if os(iOS)
            let stepper = UIStepper()
            stepper.minimumValue = Double(minimum)
            stepper.maximumValue = Double(maximum)
            stepper.stepValue = Double(step)
            stepper.value = Double(value)
            stepper.tintColor = palette.accent
            stepper.accessibilityIdentifier = item.id + "_stepper"
            stepper.addTarget(self, action: #selector(stepped(_:)), for: .valueChanged)
            cell.accessoryView = stepper
            cell.selectionStyle = .none
            #else
            cell.accessoryType = .disclosureIndicator
            #endif
        case .slider(let value, _, _, _):
            cell.detailTextLabel?.text = "\(value)"
            cell.accessoryType = .disclosureIndicator
        case .segmented(let value, let options), .choice(let value, let options, _):
            cell.detailTextLabel?.text = options.first { $0.value == value }?.title ?? value
            cell.accessoryType = .disclosureIndicator
        case .multiChoice(let values, let options, _, _):
            cell.detailTextLabel?.text = item.detail.isEmpty
                ? values.compactMap { value in options.first { $0.value == value }?.title }
                    .joined(separator: ", ") : item.detail
            cell.accessoryType = .disclosureIndicator
        case .time(let value):
            cell.detailTextLabel?.text = value
            cell.accessoryType = .disclosureIndicator
        case .text(let value, _, _):
            cell.detailTextLabel?.text = item.detail.isEmpty ? value : item.detail
            cell.accessoryType = .disclosureIndicator
        case .secret:
            cell.detailTextLabel?.text = "••••"
            cell.accessoryType = .disclosureIndicator
        case .info(let value):
            cell.detailTextLabel?.text = value
            cell.selectionStyle = .none
        case .action(let destructive):
            cell.textLabel?.textColor = destructive ? palette.danger : palette.accent
            cell.textLabel?.textAlignment = .center
        case .page, .list, .shell:
            cell.detailTextLabel?.text = item.detail
            cell.accessoryType = .disclosureIndicator
        }
    }

    // MARK: Inline controls (iOS)

    private func itemForControl(_ control: UIView) -> SettingItem? {
        var view: UIView? = control
        while let current = view, !(current is UITableViewCell) { view = current.superview }
        guard let cell = view as? UITableViewCell, let indexPath = tableView.indexPath(for: cell)
        else { return nil }
        return item(at: indexPath)
    }

    #if os(iOS)
    @objc private func toggled(_ sender: UISwitch) {
        guard let item = itemForControl(sender) else { return }
        host?.commit(item, .bool(sender.isOn), from: self)
    }

    /// A stepper writes once the presses stop, so holding it is one write, not twenty.
    @objc private func stepped(_ sender: UIStepper) {
        guard let item = itemForControl(sender),
              case .stepper(_, _, _, _, let unit) = item.control else { return }
        let value = Int(sender.value)
        if let cell = sender.superview as? UITableViewCell {
            cell.detailTextLabel?.text = unit.isEmpty ? "\(value)" : "\(value) \(unit)"
        }
        pendingStepper?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.host?.commit(item, .int(value), from: self)
        }
        pendingStepper = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    #endif

    // MARK: Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let host = host else { return }
        let item = self.item(at: indexPath)
        switch item.control {
        case .toggle(let on):
            if SettingsStyle.isTV { host.commit(item, .bool(!on), from: self) }
        case .slider(let value, let minimum, let maximum, let step):
            guard SettingsStyle.isTV else { return }
            push(SettingsChoiceController(host: host, item: item, value: "\(value)",
                                          options: SettingsStyle.steps(minimum: minimum, maximum: maximum,
                                                                       step: step, unit: ""),
                                          searchable: false, asInt: true))
        case .stepper(let value, let minimum, let maximum, let step, let unit):
            guard SettingsStyle.isTV else { return }
            push(SettingsChoiceController(host: host, item: item, value: "\(value)",
                                          options: SettingsStyle.steps(minimum: minimum, maximum: maximum,
                                                                       step: step, unit: unit),
                                          searchable: false, asInt: true))
        case .segmented(let value, let options):
            guard SettingsStyle.isTV else { return }
            push(SettingsChoiceController(host: host, item: item, value: value, options: options,
                                          searchable: false, asInt: false))
        case .choice(let value, let options, let searchable):
            push(SettingsChoiceController(host: host, item: item, value: value, options: options,
                                          searchable: searchable, asInt: false))
        case .multiChoice(let values, let options, let ordered, let minimumCount):
            push(SettingsMultiChoiceController(host: host, item: item, values: values,
                                               options: options, ordered: ordered,
                                               minimumCount: minimumCount))
        case .time(let value):
            push(SettingsTimeController(host: host, item: item, value: value))
        case .text(let value, let placeholder, let numeric):
            push(SettingsTextController(host: host, item: item, value: value,
                                        placeholder: placeholder, numeric: numeric, secure: false))
        case .secret:
            guard SettingsStyle.isTV else { return }
            push(SettingsTextController(host: host, item: item, value: "", placeholder: "",
                                        numeric: false, secure: true))
        case .info:
            break
        case .action:
            host.commit(item, .bool(true), from: self)
        case .page:
            push(SettingsPageController(host: host, path: path + [item.id]))
        case .list:
            push(SettingsListController(host: host, path: path + [item.id]))
        case .shell(let id):
            host.openShell(id, title: item.title, from: self)
        }
    }

    private func push(_ controller: UIViewController) {
        host?.show(controller, from: self)
    }
}

// MARK: - Inline cells (iOS)

#if os(iOS)
final class SettingsSliderCell: UITableViewCell {
    private let title = UILabel()
    private let valueLabel = UILabel()
    private let detail = UILabel()
    private let slider = UISlider()
    private var step = 1
    private var minimum = 0
    private var onCommit: ((Int) -> Void)?

    init(palette: DoorbellPalette) {
        super.init(style: .default, reuseIdentifier: nil)
        SettingsStyle.apply(palette, to: self)
        selectionStyle = .none
        title.textColor = palette.ink
        valueLabel.textColor = palette.inkMuted
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
        detail.textColor = palette.inkMuted
        detail.font = .systemFont(ofSize: 13)
        detail.numberOfLines = 0
        slider.minimumTrackTintColor = palette.accent
        let top = UIStackView(arrangedSubviews: [title, UIView(), valueLabel])
        top.axis = .horizontal
        let stack = UIStackView(arrangedSubviews: [top, slider, detail])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)
        slider.addTarget(self, action: #selector(released),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(title text: String, detail note: String, value: Int, minimum: Int,
                   maximum: Int, step: Int, onCommit: @escaping (Int) -> Void) {
        title.text = text
        detail.text = note
        detail.isHidden = note.isEmpty
        self.step = step
        self.minimum = minimum
        slider.minimumValue = Float(minimum)
        slider.maximumValue = Float(maximum)
        slider.value = Float(value)
        slider.accessibilityLabel = text
        valueLabel.text = "\(value)"
        self.onCommit = onCommit
    }

    private var snapped: Int {
        return SettingValidation.snap(Int(slider.value.rounded()), minimum: minimum,
                                      maximum: Int(slider.maximumValue), step: step)
    }

    @objc private func changed() { valueLabel.text = "\(snapped)" }

    /// Written once, when the finger lifts.
    @objc private func released() {
        slider.value = Float(snapped)
        onCommit?(snapped)
    }
}

final class SettingsSegmentCell: UITableViewCell {
    private let title = UILabel()
    private let control = UISegmentedControl(items: [])
    private var options: [SettingOption] = []
    private var onCommit: ((String) -> Void)?

    init(palette: DoorbellPalette) {
        super.init(style: .default, reuseIdentifier: nil)
        SettingsStyle.apply(palette, to: self)
        selectionStyle = .none
        title.textColor = palette.ink
        title.numberOfLines = 0
        control.tintColor = palette.accent
        let stack = UIStackView(arrangedSubviews: [title, control])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
        control.addTarget(self, action: #selector(changed), for: .valueChanged)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(title text: String, value: String, options: [SettingOption],
                   onCommit: @escaping (String) -> Void) {
        title.text = text
        self.options = options
        control.removeAllSegments()
        for (index, option) in options.enumerated() {
            control.insertSegment(withTitle: option.title, at: index, animated: false)
        }
        control.selectedSegmentIndex = options.firstIndex { $0.value == value } ?? UISegmentedControl.noSegment
        control.accessibilityLabel = text
        self.onCommit = onCommit
    }

    @objc private func changed() {
        let index = control.selectedSegmentIndex
        guard index >= 0, index < options.count else { return }
        onCommit?(options[index].value)
    }
}

final class SettingsSecretCell: UITableViewCell, UITextFieldDelegate {
    private let field = UITextField()
    private var onCommit: ((String) -> Void)?

    init(palette: DoorbellPalette) {
        super.init(style: .default, reuseIdentifier: nil)
        SettingsStyle.apply(palette, to: self)
        selectionStyle = .none
        field.isSecureTextEntry = true
        field.textColor = palette.ink
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(field)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: margins.topAnchor),
            field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        field.addTarget(self, action: #selector(ended), for: .editingDidEnd)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(title: String, onCommit: @escaping (String) -> Void) {
        field.placeholder = title
        field.accessibilityLabel = title
        self.onCommit = onCommit
    }

    @objc private func ended() { onCommit?(field.text ?? "") }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
#endif

// MARK: - Choice list (checkmarks)

final class SettingsChoiceController: UITableViewController {
    private weak var host: SettingsHosting?
    private let item: SettingItem
    private var value: String
    private let options: [SettingOption]
    private var visible: [SettingOption]
    private let asInt: Bool
    #if os(iOS)
    private let search = UISearchBar()
    #endif

    init(host: SettingsHosting, item: SettingItem, value: String, options: [SettingOption],
         searchable: Bool, asInt: Bool) {
        self.host = host
        self.item = item
        self.value = value
        self.options = options
        self.visible = options
        self.asInt = asInt
        super.init(style: SettingsStyle.tableStyle())
        title = item.title
        isSearchable = searchable
        #if os(iOS)
        if searchable {
            search.delegate = self
            search.autocapitalizationType = .none
            search.sizeToFit()
        }
        #endif
    }

    private var isSearchable = false

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let host = host else { return }
        SettingsStyle.apply(host.palette, to: tableView)
        #if os(iOS)
        if isSearchable {
            search.barTintColor = host.palette.background
            tableView.tableHeaderView = search
        }
        #endif
        if let index = visible.firstIndex(where: { $0.value == value }) {
            tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: false)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return visible.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if let palette = host?.palette { SettingsStyle.apply(palette, to: cell) }
        let option = visible[indexPath.row]
        cell.textLabel?.text = option.title
        cell.accessoryType = option.value == value ? .checkmark : .none
        cell.accessibilityIdentifier = item.id + "_option_" + option.value
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let option = visible[indexPath.row]
        value = option.value
        tableView.reloadData()
        let committed: SettingValue = asInt ? .int(Int(option.value) ?? 0) : .string(option.value)
        host?.commit(item, committed, from: self)
        navigationController?.popViewController(animated: true)
    }
}

#if os(iOS)
extension SettingsChoiceController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let needle = searchText.lowercased()
        visible = needle.isEmpty ? options : options.filter {
            $0.title.lowercased().contains(needle) || $0.value.lowercased().contains(needle)
        }
        tableView.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
}
#endif

// MARK: - Multiple choice with optional order

final class SettingsMultiChoiceController: UITableViewController {
    private weak var host: SettingsHosting?
    private let item: SettingItem
    private var selected: [String]
    private let options: [SettingOption]
    private let ordered: Bool
    private let minimumCount: Int

    init(host: SettingsHosting, item: SettingItem, values: [String], options: [SettingOption],
         ordered: Bool, minimumCount: Int) {
        self.host = host
        self.item = item
        self.selected = values
        self.options = options
        self.ordered = ordered
        self.minimumCount = minimumCount
        super.init(style: SettingsStyle.tableStyle())
        title = item.title
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let host = host else { return }
        SettingsStyle.apply(host.palette, to: tableView)
        #if os(iOS)
        if ordered {
            tableView.isEditing = true
            tableView.allowsSelectionDuringEditing = true
        }
        #endif
    }

    private var unselected: [SettingOption] {
        return options.filter { !selected.contains($0.value) }
    }

    private func title(_ value: String) -> String {
        return options.first { $0.value == value }?.title ?? value
    }

    override func numberOfSections(in tableView: UITableView) -> Int { return 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? selected.count : unselected.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let texts = host?.texts else { return nil }
        return section == 0 ? texts.t("prefs.selected") : texts.t("prefs.available")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return section == 0 && ordered ? host?.texts.t("prefs.order_footer") : nil
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if let palette = host?.palette { SettingsStyle.apply(palette, to: cell) }
        if indexPath.section == 0 {
            cell.textLabel?.text = title(selected[indexPath.row])
            cell.accessoryType = .checkmark
        } else {
            cell.textLabel?.text = unselected[indexPath.row].title
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            guard selected.count > minimumCount else { return }
            selected.remove(at: indexPath.row)
        } else {
            selected.append(unselected[indexPath.row].value)
        }
        tableView.reloadData()
        commit()
    }

    private func commit() {
        host?.commit(item, .strings(selected), from: self)
    }

    override func tableView(_ tableView: UITableView,
                            editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return .none
    }

    override func tableView(_ tableView: UITableView,
                            shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { return false }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return ordered && indexPath.section == 0
    }

    override func tableView(_ tableView: UITableView,
                            targetIndexPathForMoveFromRowAt source: IndexPath,
                            toProposedIndexPath proposed: IndexPath) -> IndexPath {
        if proposed.section == 0 { return proposed }
        return IndexPath(row: max(0, selected.count - 1), section: 0)
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath,
                            to destination: IndexPath) {
        let moved = selected.remove(at: source.row)
        selected.insert(moved, at: destination.row)
        commit()
    }
}

// MARK: - Text entry

final class SettingsTextController: UITableViewController, UITextFieldDelegate {
    private weak var host: SettingsHosting?
    private let item: SettingItem?
    private let field = UITextField()
    private let initial: String
    private let placeholder: String
    private let numeric: Bool
    private let secure: Bool
    private var message = ""
    /// For list "Add" prompts, which commit through a closure rather than an item.
    var onSubmit: ((String) -> SettingEffect)?

    init(host: SettingsHosting, item: SettingItem?, value: String, placeholder: String,
         numeric: Bool, secure: Bool, title: String = "") {
        self.host = host
        self.item = item
        self.initial = value
        self.placeholder = placeholder
        self.numeric = numeric
        self.secure = secure
        super.init(style: SettingsStyle.tableStyle())
        self.title = item?.title ?? title
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let host = host else { return }
        SettingsStyle.apply(host.palette, to: tableView)
        field.text = initial
        field.placeholder = placeholder
        field.textColor = host.palette.ink
        field.isSecureTextEntry = secure
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.delegate = self
        field.accessibilityIdentifier = (item?.id ?? "settings_add") + "_field"
        #if os(iOS)
        field.clearButtonMode = .whileEditing
        if numeric { field.keyboardType = .numbersAndPunctuation }
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: host.texts.t("prefs.save"),
                                                            style: .done, target: self,
                                                            action: #selector(save))
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return 1 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return message.isEmpty ? nil : message
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if let palette = host?.palette { SettingsStyle.apply(palette, to: cell) }
        cell.selectionStyle = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: margins.topAnchor),
            field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        return cell
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        save()
        return false
    }

    @objc private func save() {
        guard let host = host else { return }
        let text = field.text ?? ""
        let effect: SettingEffect
        if let item = item, let commit = item.commit {
            effect = commit(.string(text))
        } else if let submit = onSubmit {
            effect = submit(text)
        } else {
            return
        }
        if case .invalid(let key) = effect {
            message = host.texts.t(key)
            tableView.reloadData()
            return
        }
        field.resignFirstResponder()
        host.perform(effect, item: item, value: .string(text), from: self) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.navigationController?.popViewController(animated: true)
            } else {
                self.message = host.texts.t("settings.save_failed")
                self.tableView.reloadData()
            }
        }
    }
}

// MARK: - Time of day

final class SettingsTimeController: UIViewController {
    private weak var host: SettingsHosting?
    private let item: SettingItem
    private let value: String
    #if os(iOS)
    private let picker = UIDatePicker()
    #endif

    init(host: SettingsHosting, item: SettingItem, value: String) {
        self.host = host
        self.item = item
        self.value = value
        super.init(nibName: nil, bundle: nil)
        title = item.title
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let host = host else { return }
        view.backgroundColor = host.palette.background
        #if os(iOS)
        picker.datePickerMode = .time
        // 24-hour wheels in every UI language; the stored value is always HH:mm.
        picker.locale = Locale(identifier: "en_GB")
        picker.timeZone = TimeZone(secondsFromGMT: 0)
        if #available(iOS 13.4, *) { picker.preferredDatePickerStyle = .wheels }
        if #available(iOS 13.0, *) {
            picker.overrideUserInterfaceStyle = host.palette.appearance == .dark ? .dark : .light
        } else {
            picker.setValue(host.palette.ink, forKey: "textColor")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let minutes = SettingValidation.minutes(ofClock: value) ?? 0
        picker.date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1,
                                                         hour: minutes / 60, minute: minutes % 60))
            ?? Date()
        picker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            picker.topAnchor.constraint(equalTo: IOSAvailability.safeAreaLayoutGuide(for: view).topAnchor,
                                        constant: 24),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: host.texts.t("prefs.save"),
                                                            style: .done, target: self,
                                                            action: #selector(save))
        #else
        let list = SettingsChoiceController(host: host, item: item, value: value,
                                            options: SettingsStyle.clockSteps(),
                                            searchable: false, asInt: false)
        addChild(list)
        list.view.frame = view.bounds
        list.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(list.view)
        list.didMove(toParent: self)
        #endif
    }

    #if os(iOS)
    @objc private func save() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.hour, .minute], from: picker.date)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        host?.commit(item, .string(clock), from: self)
        navigationController?.popViewController(animated: true)
    }
    #endif
}

// MARK: - List editor

final class SettingsListController: UITableViewController, SettingsRefreshable {
    private weak var host: SettingsHosting?
    private let path: [String]
    private var model = SettingsListModel(id: "", title: "", rows: [])
    private var filter = ""
    #if os(iOS)
    private let search = UISearchBar()
    #endif

    /// The rows shown: all of them, or those matching the search text.
    private var rows: [SettingsListRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.rows }
        return model.rows.filter {
            $0.title.lowercased().contains(needle) || $0.detail.lowercased().contains(needle)
        }
    }

    init(host: SettingsHosting, path: [String]) {
        self.host = host
        self.path = path
        super.init(style: SettingsStyle.tableStyle())
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let host = host else { return }
        SettingsStyle.apply(host.palette, to: tableView)
        tableView.allowsSelectionDuringEditing = false
        host.register(self)
        refreshFromHost()
        #if os(iOS)
        if model.reorder != nil || model.delete != nil {
            navigationItem.rightBarButtonItem = editButtonItem
        }
        if model.searchable {
            search.delegate = self
            search.autocapitalizationType = .none
            search.autocorrectionType = .no
            search.barTintColor = host.palette.background
            search.sizeToFit()
            tableView.tableHeaderView = search
        }
        #endif
    }

    func refreshFromHost() {
        guard let host = host, let fresh = host.catalog().list(path: path) else { return }
        model = fresh
        title = fresh.title
        tableView.reloadData()
    }

    private var hasAdd: Bool { return model.add != nil || model.addWithText != nil }

    override func numberOfSections(in tableView: UITableView) -> Int { return hasAdd ? 2 : 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? rows.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return section == numberOfSections(in: tableView) - 1 && !model.footer.isEmpty
            ? model.footer : nil
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        guard let host = host else { return cell }
        SettingsStyle.apply(host.palette, to: cell)
        guard indexPath.section == 0 else {
            cell.textLabel?.text = model.addTitle
            cell.textLabel?.textColor = host.palette.accent
            cell.accessibilityIdentifier = model.id + "_add"
            return cell
        }
        let row = rows[indexPath.row]
        cell.textLabel?.text = row.title
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = row.detail
        cell.accessibilityIdentifier = model.id + "_" + row.id
        #if os(iOS)
        if let enabled = row.enabled, row.toggle != nil {
            let toggle = UISwitch()
            toggle.isOn = enabled
            toggle.onTintColor = host.palette.accent
            toggle.tag = indexPath.row
            toggle.addTarget(self, action: #selector(rowToggled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.editingAccessoryType = row.edit == nil ? .none : .disclosureIndicator
            return cell
        }
        #else
        if let enabled = row.enabled { cell.detailTextLabel?.text = host.texts.t(enabled ? "settings.on" : "settings.off") }
        #endif
        cell.accessoryType = row.edit == nil ? .none : .disclosureIndicator
        if row.edit == nil { cell.selectionStyle = .none }
        return cell
    }

    #if os(iOS)
    @objc private func rowToggled(_ sender: UISwitch) {
        let shown = rows
        guard sender.tag < shown.count, let toggle = shown[sender.tag].toggle else { return }
        host?.perform(toggle(sender.isOn), item: nil, value: nil, from: self, completion: nil)
    }
    #endif

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let host = host else { return }
        if indexPath.section == 1 {
            if let add = model.add {
                host.perform(add(), item: nil, value: nil, from: self, completion: nil)
            } else if let addWithText = model.addWithText {
                let prompt = SettingsTextController(host: host, item: nil, value: "",
                                                    placeholder: model.addPrompt, numeric: false,
                                                    secure: false, title: model.addTitle)
                prompt.onSubmit = addWithText
                host.show(prompt, from: self)
            }
            return
        }
        let row = rows[indexPath.row]
        guard row.edit != nil else { return }
        host.show(SettingsPageController(host: host, path: path + [row.id]), from: self)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 0 && (model.delete != nil || model.reorder != nil)
    }

    override func tableView(_ tableView: UITableView,
                            editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return indexPath.section == 0 && model.delete != nil ? .delete : .none
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, let delete = model.delete else { return }
        host?.perform(delete(rows[indexPath.row].id), item: nil, value: nil, from: self,
                      completion: nil)
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 0 && model.reorder != nil && !SettingsStyle.isTV && filter.isEmpty
    }

    override func tableView(_ tableView: UITableView,
                            targetIndexPathForMoveFromRowAt source: IndexPath,
                            toProposedIndexPath proposed: IndexPath) -> IndexPath {
        return proposed.section == 0 ? proposed
            : IndexPath(row: max(0, model.rows.count - 1), section: 0)
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath,
                            to destination: IndexPath) {
        var ids = model.rows.map { $0.id }
        let moved = ids.remove(at: source.row)
        ids.insert(moved, at: destination.row)
        guard let reorder = model.reorder else { return }
        host?.perform(reorder(ids), item: nil, value: nil, from: self, completion: nil)
    }
}

#if os(iOS)
extension SettingsListController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        filter = searchText
        tableView.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
}
#endif

// MARK: - Web admin address (About)

/// The web admin's address as a QR code and URL, with the reason this item is edited there.
final class SettingsWebAdminController: UIViewController {
    private let core: CoreBridge
    private let boot: BootConfig
    private let texts: Texts
    private let palette: DoorbellPalette
    private let reason: String

    init(core: CoreBridge, boot: BootConfig, texts: Texts, palette: DoorbellPalette,
         title: String, reason: String) {
        self.core = core
        self.boot = boot
        self.texts = texts
        self.palette = palette
        self.reason = reason
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = palette.background
        let note = UILabel()
        note.text = reason.isEmpty ? texts.t("web_admin.scan_hint")
            : reason + "\n\n" + texts.t("web_admin.scan_hint")
        note.textColor = palette.inkMuted
        note.numberOfLines = 0
        note.textAlignment = .center
        let card = AdminQrView(core: core, boot: boot, texts: texts, compact: false)
        card.skin = DoorbellSkin.plain(palette)
        card.reload()
        let stack = UIStackView(arrangedSubviews: [note, card])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -24),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }
}
