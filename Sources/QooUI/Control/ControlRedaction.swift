#if DEBUG
import AppKit
import Foundation
import QooApplication

/// 制御口が返す文字列から、**利用者のデータを既定で伏せる** [MT-33][MT-32]。
///
/// **なぜアプリの側で伏せるのか**: 検証の道具（AX ダンプ）は毎回作り直されて
/// おり、そのたびに許可リストを組み直しては漏らしてきた——登録フォルダ名・
/// 実蔵書のファイル名・ユーザー名を、記録に残っているだけで 6 回。
/// 許可リストの出どころは**アプリ自身が持っている**（自分の文字列カタログと
/// プリセットの語彙）ので、ここで作れば正確なうえ二度と作り直さずに済む。
///
/// **規則は「許可語をすべて取り除いた残りが、記号・数字・空白だけなら通す」**。
/// 「許可語を含むか」の部分一致にしてはならない——プリセットの語（例えば
/// 本の種別）を含むだけで、未知のファイル名が丸ごと素通りする
/// ［過去に実際に起きた事故］。
@MainActor
public enum ControlRedaction {
    /// 既定で有効。`{"redact": false}` を渡した呼び出しでだけ外れる
    /// ——外すのは、その応答に利用者のデータが出ないと分かっているとき。
    public static var isEnabled = true

    /// 呼び出しごとに追加で通す語（使い捨てボリュームへ置いた合成名など）。
    public static var extraAllowed: [String] = []

    public static func apply(_ text: String) -> String {
        guard isEnabled, !text.isEmpty else { return text }
        var remainder = text
        // **組み込みと追加を 1 つの列にしてから長い順に消す。** 2 段に分けて
        // 組み込みを先に消すと、それを部分に含む追加の語がもう一致しなく
        // なる——`allow: ["著者値A"]` を渡しても、組み込みの「著者」が先に
        // 抜けて「値A」だけが残り、伏字のままになる［実測］。このファイルの
        // 「長い語から順に取り除く」という注意は、**両方をまたいで**
        // 成り立たなければ意味を持たない。
        for word in wordsToStrip where !word.isEmpty {
            if remainder.count < word.count { continue }
            remainder = remainder.replacingOccurrences(of: word, with: "")
        }
        let leftover = remainder.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
                && !CharacterSet.decimalDigits.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return leftover.isEmpty ? text : "⟨\(text.count) 文字⟩"
    }

    /// 取り除く語を長い順に 1 列で返す。**追加の語（`allow`）も混ぜる**
    /// ——分けると上の不具合が戻る。
    ///
    /// **作り直すのは `allow` が変わったときだけ。** 語は 3,000 近くあり、
    /// `apply` は木のノードごとに何度も呼ばれる——毎回連結して並べ直すと
    /// `allowedWords` を控えている意味が消える。
    private static var wordsToStrip: [String] {
        if let cached = cachedStrip, cachedStripKey == extraAllowed { return cached }
        let words = (allowedWords + extraAllowed).sorted { $0.count > $1.count }
        cachedStrip = words
        cachedStripKey = extraAllowed
        return words
    }

    private nonisolated(unsafe) static var cachedStrip: [String]?
    private nonisolated(unsafe) static var cachedStripKey: [String]?

    // MARK: - 許可語

    private nonisolated(unsafe) static var cachedWords: [String]?

    /// 長い語から順に取り除く。短い語を先に消すと、長い語の一部だけが
    /// 削れて残りが不自然になる。
    private static var allowedWords: [String] {
        if let cached = cachedWords { return cached }
        var words = Set<String>()
        for bundle in localizationBundles() {
            for localization in ["ja", "en", "Base"] {
                guard let url = bundle.url(
                    forResource: "Localizable", withExtension: "strings",
                    subdirectory: nil, localization: localization) else { continue }
                guard let data = try? Data(contentsOf: url),
                      let table = try? PropertyListSerialization.propertyList(
                          from: data, format: nil) as? [String: String] else { continue }
                for value in table.values {
                    // 書式指定子で割った断片も許可語にする——件数を差し込んだ
                    // 文（「%d 件を試して…」）は値と完全一致しないため。
                    for piece in value.components(separatedBy: formatSpecifier) {
                        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.count >= 1 { words.insert(trimmed) }
                    }
                }
            }
        }
        // プリセットが持つ語彙（テンプレート名・フィールド名）。利用者が
        // 名付けたものではないので通してよい。
        for template in LibraryServices.shared.presetTemplates {
            words.insert(template.displayName)
            for field in template.fields { words.insert(field.name) }
        }
        let sorted = words.sorted { $0.count > $1.count }
        cachedWords = sorted
        return sorted
    }

    /// `%@` `%d` `%1$@` `%.2f` などをまとめて割るための集合。
    private static let formatSpecifier = CharacterSet(charactersIn: "%@ds$.0123456789f")

    private static func localizationBundles() -> [Bundle] {
        var bundles = [Bundle.main]
        if let resources = Bundle.main.resourceURL,
           let contents = try? FileManager.default.contentsOfDirectory(
               at: resources, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension == "bundle" {
                if let bundle = Bundle(url: url) { bundles.append(bundle) }
            }
        }
        return bundles
    }
}
#endif
