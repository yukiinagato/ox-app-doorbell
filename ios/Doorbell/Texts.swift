// 文言解決の前段 (Localizable.strings の手前): config i18n_overrides.<lang>.<key> があれば
// それを使い、無ければ言語別 .lproj バンドルの組込文言へ回落する (Android の Texts と同役)。
// 訪客言語 (門口機の言語バー) の現在値もここが持つ。
// 上書き文言のプレースホルダは i18n/strings.yaml と同じ名前付き ({unit} 等) で出現順に埋める。
// 組込文言は gen_i18n.py が {name} → %@ (出現順) に変換済み — String(format:) で埋める。
import Foundation

final class Texts {

    /// 現在の表示言語 (門口機は訪客言語、室内機/TV は boot.ui_lang)。
    private(set) var lang = "ja"

    private var config: [String: Any]?
    private var overrides: [String: Any]?
    private var bundle: Bundle = .main

    /// 設定ツリーの差し替え (起動時 / config_changed)。
    func setConfig(_ cfg: [String: Any]?) {
        config = cfg
        reload()
    }

    /// 表示言語の切替 (組込文言の .lproj バンドルもここで差し替える)。
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

    /// key = i18n/strings.yaml のドットキー。上書き → 組込 Localizable.strings の順で解決。
    func t(_ key: String, _ args: CVarArg...) -> String {
        if let ov = overrides?[key] as? String, !ov.isEmpty {
            return Texts.fillNamed(ov, args)
        }
        let fmt = bundle.localizedString(forKey: key, value: key, table: nil)
        return args.isEmpty ? fmt : String(format: fmt, arguments: args)
    }

    /// 名前付きプレースホルダ {name} を出現順に args で埋める (gen_i18n.py と同じ順序規約)。
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

    /// 言語の自言語表記 (訪客が自分の言語を見つけられるように)。
    static func langDisplayName(_ lang: String) -> String {
        switch lang {
        case "ja": return "日本語"
        case "en": return "English"
        case "zh": return "中文"
        default: return lang
        }
    }
}
