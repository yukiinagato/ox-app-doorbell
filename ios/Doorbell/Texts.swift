import Foundation

final class Texts {

    private(set) var lang = "ja"

    private var config: [String: Any]?
    private var overrides: [String: Any]?
    private var bundle: Bundle = .main

    func setConfig(_ cfg: [String: Any]?) {
        config = cfg
        reload()
    }

    func setLang(_ l: String) {
        lang = l.isEmpty ? "ja" : l
        reload()
    }

    private func reload() {
        overrides = ((config?["i18n_overrides"] as? [String: Any])?[lang]) as? [String: Any]
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = .main
        }
    }

    func t(_ key: String, _ args: CVarArg...) -> String {
        if let ov = overrides?[key] as? String, !ov.isEmpty {
            return Texts.fillNamed(ov, args)
        }
        let fmt = bundle.localizedString(forKey: key, value: key, table: nil)
        return args.isEmpty ? fmt : String(format: fmt, arguments: args)
    }

    private static func fillNamed(_ s: String, _ args: [CVarArg]) -> String {
        guard !args.isEmpty,
              let re = try? NSRegularExpression(pattern: "\\{[A-Za-z_][A-Za-z0-9_]*\\}")
        else { return s }
        var out = s
        var i = 0
        while i < args.count,
              let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let r = Range(m.range, in: out) {
            out.replaceSubrange(r, with: "\(args[i])")
            i += 1
        }
        return out
    }

    static func langDisplayName(_ lang: String) -> String {
        switch lang {
        case "ja": return "日本語"
        case "en": return "English"
        case "zh": return "中文"
        default: return lang
        }
    }
}
