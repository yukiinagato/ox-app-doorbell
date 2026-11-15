import UIKit

/// The editor's "try it": the visitor-flow walker over the document Core publishes for the
/// current configuration. A call or a notify never reaches Core; the session reports which action
/// would have run and carries on as if it had succeeded (a notify shows its end page, a press stays
/// where it is).
final class FlowPreviewSession {

    let walker: VisitorFlowWalker
    private let texts: Texts
    private let editor: VisitorFlowEditor
    private let lang: String
    private let purposeLabel: (String) -> String
    /// What the last tap would have done, empty before the first call or notify.
    private(set) var banner = ""

    init(document: [String: Any], editor: VisitorFlowEditor, texts: Texts, lang: String,
         purposeLabel: @escaping (String) -> String) {
        self.walker = VisitorFlowWalker(flow: document, lang: lang)
        self.editor = editor
        self.texts = texts
        self.lang = lang
        self.purposeLabel = purposeLabel
    }

    var isUsable: Bool { return walker.isEnabled }

    func tap(_ optionId: String) {
        banner = ""
        var intent = walker.tap(optionId)
        while case .call(let call) = intent {
            switch call {
            case .press(let purpose):
                banner = purpose.isEmpty
                    ? texts.t("flow_editor.preview_call")
                    : texts.t("flow_editor.preview_call_purpose", purposeLabel(purpose))
                walker.pressFinished(success: false)
                intent = .none
            case .notify(let step):
                let message = VisitorFlowText.text(editor.steps[step]?["message"], lang: lang) ?? ""
                banner = texts.t("flow_editor.preview_notify", message)
                intent = walker.notifyFinished(ok: true)
            }
        }
    }

    func back() {
        banner = ""
        walker.back()
    }

    func done() {
        banner = ""
        walker.done()
    }
}

/// Hosts the visitor-flow renderer for a preview session, with a banner saying nothing is sent.
final class FlowPreviewViewController: UIViewController {

    private let session: FlowPreviewSession
    private let texts: Texts
    private let skin: DoorbellSkin
    private let flowView: VisitorFlowView
    private let banner = HaloLabel()
    private let result = HaloLabel()

    init(session: FlowPreviewSession, texts: Texts, palette: DoorbellPalette) {
        self.session = session
        self.texts = texts
        self.skin = DoorbellSkin.plain(palette)
        self.flowView = VisitorFlowView(texts: texts)
        super.init(nibName: nil, bundle: nil)
        title = texts.t("flow_editor.preview")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = skin.background
        view.accessibilityIdentifier = "flow_preview_screen"
        for label in [banner, result] {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }
        banner.font = .systemFont(ofSize: 14, weight: .medium)
        banner.text = texts.t("flow_editor.preview_banner")
        banner.accessibilityIdentifier = "flow_preview_banner"
        result.font = .systemFont(ofSize: 17, weight: .semibold)
        result.accessibilityIdentifier = "flow_preview_result"
        flowView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(flowView)
        let guide = IOSAvailability.safeAreaLayoutGuide(for: view)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            flowView.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8),
            flowView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            flowView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            flowView.bottomAnchor.constraint(equalTo: result.topAnchor, constant: -8),
            result.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            result.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            result.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
        ])
        flowView.apply(skin: skin)
        skin.apply("hint", to: banner)
        skin.apply("notice", to: result)
        flowView.onOption = { [weak self] id in
            self?.session.tap(id)
            self?.render()
        }
        flowView.onBack = { [weak self] in
            self?.session.back()
            self?.render()
        }
        flowView.onDone = { [weak self] in
            self?.session.done()
            self?.render()
        }
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        flowView.viewportHeight = flowView.bounds.height
    }

    private func render() {
        guard session.isUsable, let page = session.walker.page else {
            result.text = texts.t("flow_editor.preview_off")
            return
        }
        result.text = session.banner
        flowView.render(page, notice: nil)
    }
}
