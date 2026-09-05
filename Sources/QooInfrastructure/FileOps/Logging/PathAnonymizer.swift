import CryptoKit
import Foundation
import QooKit

/// 診断ログ書き出し時のパス匿名化 [LG2-06][CB-23]。
///
/// ## 対象の広さ（仕様書 §2.6 CB-23 からの拡張）
///
/// 元の記述は「ホームディレクトリ以下を `~/…/<sha256 先頭 8 桁>` に置換する」
/// だったが、**サンドボックスアプリである qooLibrary が実際に扱うパスの大半は
/// ホーム外**（外部ボリューム上のライブラリ／テンポラリフォルダ、`/Volumes/…`）
/// であり、ホーム配下だけを対象にすると匿名化の目的をほとんど果たさない。
/// そのため、
///
/// 1. **すべての絶対パス**を対象にする。
/// 2. パス全体を 1 つのトークンに畳まず、**成分ごとに**置換する。
///    階層の深さと最終成分の拡張子は残す。
///
/// ```
/// 元:   /Volumes/PRO-G40/Comics/(成年コミック) [サークル] 作品名.cbz
/// 匿名: /Volumes/3f2a9c11/8b41d0e7/c9a7f215.cbz
/// ```
///
/// 成分ごとに置換することで「同じフォルダにある別のファイル」「移動元と
/// 移動先が同じ親を持つ」といった関係がログ上で追えるままになり、診断の
/// 役に立つ。`Volumes`/`Library`/`Documents` のような、個人情報を含まない
/// 標準的な成分（`preservedComponents`）はそのまま残す。
///
/// **トークンは「その成分までのパス接頭辞」から導出する**（成分名単体では
/// ない）。同じ絶対パスは常に同じトークンになり [CB-23]、別の場所にある
/// 同名フォルダが同じトークンになって誤った関連付けを生むことも防げる。
/// **ソルト**（`DiagnosticLogPreferences.anonymizationSalt`）を混ぜる。
/// ソルトはこの Mac にだけ保存され、書き出したバンドルには含めない。
///
/// ## 「どこがパスか」の決め方（重要）
///
/// **ログ本文からパスを推測しない。書く側が範囲を明示する。**
///
/// macOS のファイル名には **`/` と NUL 以外のあらゆる文字**が入る——空白も、
/// 括弧も、引用符も、矢印も、タブすら合法である。したがって「この文字が
/// 来たらパスの終わり」という区切り文字は原理的に存在しない。実際、当初の
/// 推測方式では実機のログで 2 度続けて取りこぼした:
///
/// - 空白で打ち切っていたため `/Volumes/<hash>/My Sample/作品名.cbz` と、
///   途中までしか匿名化されなかった。
/// - 区切りに括弧を加えたところ、`(成年コミック) [98765架空社] …` という
///   この分野ではもっとも普通のファイル名がまるごと素通しになった。
///
/// どちらも取りこぼしより質が悪い（匿名化したつもりで漏れている）。そこで
/// **`Log.path(_:)` が書き込み時にパスを `⟪…⟫` で囲み**、ここではその範囲を
/// そのまま信じて置換する。ファイル名に `⟪`/`⟫` 自体が含まれていても、
/// 書き込み時に二重化してエスケープされるので曖昧さは残らない。
///
/// 推測に頼るのは、**こちらが書式を決められないテキスト**——`Foundation` の
/// `localizedDescription` が埋め込むパスなど——に限る（`heuristicPathRun`）。
/// そこでは「余分に伏せる」側へ倒す。
///
/// ## 計装側の約束事
///
/// 1. パスは **`Log.path(url)`** で囲む。素の `url.path` を書かない。
/// 2. 絶対パスが手元に無いユーザー由来の名前（解決できない登録フォルダの
///    表示名、アーカイブ内のエントリ名）は **`Log.redactable(_:)`**（`⟨…⟩`）。
/// 3. 引用符・鉤括弧の中身も伏せる（安全網、`CB-27`）。自由文のエラー向けで、
///    伏せる範囲を選べないため**新しい計装がこれに頼ってはならない**。
public struct PathAnonymizer: Sendable {
    private let salt: String

    public init(salt: String) {
        self.salt = salt
    }

    /// `Log.path(_:)` が付けるパスの範囲印。ファイル名に現れることが事実上
    /// 無い文字を選んでいる（U+27EA / U+27EB）。万一含まれていても
    /// 書き込み時に二重化される。
    static let pathOpen: Character = "⟪"
    static let pathClose: Character = "⟫"

    /// `Log.redactable(_:)` が付ける、絶対パスを持たない名前の印
    /// （U+27E8 / U+27E9）。同じく二重化でエスケープする。
    static let redactionOpen: Character = "⟨"
    static let redactionClose: Character = "⟩"

    /// 引用符の組（安全網 [CB-27]）。閉じが現れない場合は何もしない
    /// （壊れた行で残りを丸ごと失わないため）。
    private static let quotePairs: [(open: Character, close: Character)] = [
        ("「", "」"),
        ("『", "』"),
        ("\u{201C}", "\u{201D}"), // “ ”（Foundation のエラー文言が使う）
        ("\u{2018}", "\u{2019}"), // ‘ ’
    ]

    /// 個人情報を含まない、そのまま残してよい標準的なパス成分。
    ///
    /// ボリューム名（`/Volumes/<name>`）とユーザー名（`/Users/<name>`）は
    /// 個人を特定し得るため、あえて含めていない（置換対象）。
    private static let preservedComponents: Set<String> = [
        "Volumes", "Users", "Applications", "System", "Network",
        "Library", "Application Support", "Caches", "Preferences", "Containers",
        "private", "tmp", "var", "etc", "usr", "bin", "opt", "dev",
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
        ".Trash", ".Trashes", "Data", "Shared",
        // qooLibrary 自身が作るアプリ内部の領域
        "com.qoolibrary.app", "qooLibrary", "Logs", "covers", "staging", "quicklook", "store", "backups",
    ]

    // MARK: - 公開 API

    /// テキスト中のパス・名前を匿名化する。それ以外の部分は変更しない。
    ///
    /// 1 回の左から右への走査で、印付きパス `⟪…⟫`・印付き名前 `⟨…⟩`・
    /// 引用符の中身・（印の無い）素の絶対パス をまとめて処理する。
    /// **段階を分けて複数回走査する形にはしない** — 先の段階が出力した
    /// トークン（`/Volumes/3f2a9c11/…`）を後の段階が再びパスとみなして
    /// 二重にハッシュしてしまい、「同じパスは同じトークン」[CB-23] が
    /// 壊れるため。
    public func anonymize(_ text: String) -> String {
        transform(text, anonymizing: true)
    }

    /// 匿名化せずに印だけを取り除く（書き出し時に匿名化しない場合）。
    /// 印はログを機械的に処理するための目印であって、読む人には不要。
    public static func strippingMarkers(_ text: String) -> String {
        PathAnonymizer(salt: "").transform(text, anonymizing: false)
    }

    /// 絶対パス 1 本を匿名化する。相対パス・空文字はそのまま返す。
    public func anonymizePath(_ path: String) -> String {
        var cache: [String: String] = [:]
        return anonymizePath(path, cache: &cache)
    }

    // MARK: - 走査

    private func transform(_ text: String, anonymizing: Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pathCache: [String: String] = [:]
        var nameCache: [String: String] = [:]
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            // ① 印付きパス `⟪…⟫`（書き込み側が範囲を明示したもの）
            if character == Self.pathOpen,
               let marked = scanMarked(text, from: index, open: Self.pathOpen, close: Self.pathClose) {
                if anonymizing {
                    // **絶対パスでない中身は丸ごと伏せる**［フェーズ1完了時の
                    // 監査で発見]。`anonymizePath` は絶対パス以外を素通しする
                    // ため、相対パスや素の名前が `Log.path(_:)` に渡された場合、
                    // **書き込み側が明示的に「ユーザーデータ」と印を付けた
                    // 範囲がそのまま平文で書き出されていた**（印の経路は
                    // 引用符の安全網も通らないので、印が無いより悪い）。
                    result += marked.content.hasPrefix("/")
                        ? anonymizePath(marked.content, cache: &pathCache)
                        : token(for: marked.content, cache: &nameCache)
                } else {
                    result += marked.content
                }
                index = marked.next
                continue
            }

            // ② 印付きの名前 `⟨…⟩`（絶対パスを持たないユーザー由来の名前）
            if character == Self.redactionOpen,
               let marked = scanMarked(text, from: index, open: Self.redactionOpen, close: Self.redactionClose) {
                result += anonymizing ? token(for: marked.content, cache: &nameCache) : marked.content
                index = marked.next
                continue
            }

            // ③ 引用符の中身（安全網 [CB-27]）。印を外すだけのときは触らない。
            if anonymizing, let pair = Self.quotePairs.first(where: { $0.open == character }),
               let quoted = scanQuoted(text, from: index, close: pair.close) {
                result.append(pair.open)
                result += quoted.content.isEmpty ? "" : token(for: quoted.content, cache: &nameCache)
                result.append(pair.close)
                index = quoted.next
                continue
            }

            // ④ 印の無い素の絶対パス（`localizedDescription` など、書式を
            //    こちらで決められないテキスト向けの推測）。
            if anonymizing, character == "/",
               isPathStart(text, at: index),
               let run = heuristicPathRun(text, from: index) {
                result += anonymizePath(run.content, cache: &pathCache)
                index = run.next
                continue
            }

            result.append(character)
            index = text.index(after: index)
        }

        return result
    }

    /// `open` から始まる印付き範囲を読む。**二重化された印は中身の 1 文字**
    /// として扱う（ファイル名に印そのものが含まれていた場合の逃げ道）。
    /// 閉じが見つからなければ `nil`（印ではなかったものとして扱う）。
    private func scanMarked(
        _ text: String, from start: String.Index, open: Character, close: Character
    ) -> (content: String, next: String.Index)? {
        Self.scanMarked(text, from: start, open: open, close: close)
    }

    /// 印付きパスの取り出し [OH-01]。`Log.path(_:)` の逆で、**書き込み側が
    /// 明示した範囲だけ**を返す（`⟨…⟩` の名前と、印の無い素のパスは含めない
    /// ——前者は絶対パスではなく、後者は推測になる）。
    ///
    /// **自由文からパスを推測しない**という PathAnonymizer 自身の教訓が
    /// そのまま効く場所。macOS のファイル名には `/` と NUL 以外のあらゆる
    /// 文字が入るので、印が無ければ範囲は決められない。
    static func markedPaths(in text: String) -> [String] {
        var found: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == pathOpen,
               let marked = scanMarked(text, from: index, open: pathOpen, close: pathClose) {
                // **絶対パスだけを対象とみなす。** 相対パスや素の名前が
                // `Log.path(_:)` に渡されることがあり（匿名化側も同じ判定で
                // 分岐している）、それを「対象のフルパス」として一覧に出すと
                // 嘘になる。
                if marked.content.hasPrefix("/") { found.append(marked.content) }
                index = marked.next
                continue
            }
            index = text.index(after: index)
        }
        return found
    }

    private static func scanMarked(
        _ text: String, from start: String.Index, open: Character, close: Character
    ) -> (content: String, next: String.Index)? {
        var content = ""
        var index = text.index(after: start)

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if character == close {
                if next < text.endIndex, text[next] == close {
                    content.append(close) // 二重化 → 中身の 1 文字
                    index = text.index(after: next)
                    continue
                }
                return (content, next) // ここで閉じる
            }
            if character == open, next < text.endIndex, text[next] == open {
                content.append(open) // 二重化 → 中身の 1 文字
                index = text.index(after: next)
                continue
            }
            content.append(character)
            index = next
        }
        return nil // 閉じが無い
    }

    private func scanQuoted(
        _ text: String, from start: String.Index, close: Character
    ) -> (content: String, next: String.Index)? {
        let contentStart = text.index(after: start)
        guard let closeIndex = text[contentStart...].firstIndex(of: close) else { return nil }
        return (String(text[contentStart..<closeIndex]), text.index(after: closeIndex))
    }

    /// パスの始まりらしいスラッシュか。`比率 3/4` のようなスラッシュを
    /// 誤って拾わないための最小限の防御。
    private func isPathStart(_ text: String, at index: String.Index) -> Bool {
        if index > text.startIndex {
            let previous = text[text.index(before: index)]
            guard Self.isLeadingBoundary(previous) else { return false }
        }
        // `削除 1 件 / 失敗 1 件` のような箇条の区切り（スラッシュの直後が空白）。
        let after = text.index(after: index)
        guard after < text.endIndex, !text[after].isWhitespace else { return false }
        return true
    }

    private static func isLeadingBoundary(_ character: Character) -> Bool {
        switch character {
        case " ", "\t", "\n", "\r", "\"", "'", "`", "(", "[", "{", "=", ":", ",", "/",
             "\u{3000}", "「", "『", "（", "→", "…", "＝",
             // 日本語の文中に埋め込まれたパスの直前に現れる句読点・記号
             // [フェーズ1完了時の監査で発見: `…できませんでした。/Volumes/…` の
             // ような Foundation 由来の文で、`。` が境界と見なされず素のパスが
             // 匿名化をすり抜けていた。範囲を広げる方向の変更なので、
             // 「余分に伏せる側へ倒す」方針 [CB-27] と整合する]。
             "。", "、", "：", "；", "」", "』", "）", "！", "？", "!", "?", ";": true
        default: false
        }
    }

    /// 印の無い素のパスの範囲を推測する。**こちらが書式を決められない
    /// テキスト専用**（`Foundation` の `localizedDescription` など）。
    ///
    /// ファイル名にはあらゆる文字が入り得るため、ここでの区切りは
    /// 「絶対に正しい」ものにはなり得ない。**余分に伏せる側へ倒す**方針で、
    /// 打ち切るのは、パスの一部としてはまず現れない
    /// 「空白＋区切り記号」の並び（`, ` / ` → ` / ` — ` / `/ `）と
    /// 制御文字だけにする。読みにくくなることはあっても、漏れるよりよい。
    private func heuristicPathRun(_ text: String, from start: String.Index) -> (content: String, next: String.Index)? {
        var index = start
        var end = text.endIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "\t" || character == "\n" || character == "\r" {
                end = index
                break
            }
            // `, ` `/ `（列挙・箇条の区切り）
            let next = text.index(after: index)
            if character == "," || character == "/" {
                if next < text.endIndex, text[next].isWhitespace {
                    end = index
                    break
                }
            }
            // ` → ` ` — `（このコードベースが使うパスの区切り）
            if character == "→" || character == "—" {
                end = index
                break
            }
            index = next
        }

        // 末尾の空白は範囲外（`…/dir → …` の空白）。
        var contentEnd = end
        while contentEnd > start, text[text.index(before: contentEnd)].isWhitespace {
            contentEnd = text.index(before: contentEnd)
        }

        let content = String(text[start..<contentEnd])
        guard !content.allSatisfy({ $0 == "/" }) else { return nil }
        return (content, contentEnd)
    }

    // MARK: - 置換

    private func anonymizePath(_ path: String, cache: inout [String: String]) -> String {
        guard path.hasPrefix("/") else { return path }

        // `file:///Volumes/…` のように先頭スラッシュが複数ある場合、
        // 見た目を保つためスラッシュはそのまま残し、成分だけを置換する。
        let leadingSlashCount = path.prefix(while: { $0 == "/" }).count
        let body = String(path.dropFirst(leadingSlashCount))
        guard !body.isEmpty else { return path }

        let components = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var transformed: [String] = []
        transformed.reserveCapacity(components.count)
        var prefix = ""

        for (offset, component) in components.enumerated() {
            guard !component.isEmpty else {
                transformed.append(component) // 末尾スラッシュ・連続スラッシュを保つ
                continue
            }
            prefix += "/" + component
            transformed.append(
                transform(
                    component: component,
                    prefix: prefix,
                    isLast: offset == components.count - 1,
                    cache: &cache
                )
            )
        }

        return String(repeating: "/", count: leadingSlashCount) + transformed.joined(separator: "/")
    }

    private func transform(
        component: String, prefix: String, isLast: Bool, cache: inout [String: String]
    ) -> String {
        if Self.preservedComponents.contains(component) { return component }

        let token = token(for: prefix, cache: &cache)
        // 最終成分の拡張子だけは残す。`.cbz` なのか `.mkv` なのかは、
        // 個人情報にならない一方で診断上きわめて有用なため。
        if isLast {
            let ext = (component as NSString).pathExtension
            if !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return "\(token).\(ext)"
            }
        }
        return token
    }

    /// 同じ入力には同じトークン [CB-23]。ログには同じフォルダが何千行にも
    /// 現れるため、1 回の走査の中で使い回す。
    private func token(for input: String, cache: inout [String: String]) -> String {
        if let cached = cache[input] { return cached }
        let generated = token(for: input)
        cache[input] = generated
        return generated
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    private func token(for input: String) -> String {
        let digest = SHA256.hash(data: Data("\(salt)\u{0}\(input)".utf8))
        // `String(format: "%02x", …)` はここでは使わない。1 回の書き出しで
        // 数十万回呼ばれ得るうえ、`String(format:)` は内部でロケール解決を
        // 伴い桁違いに遅い（実測で 3 倍以上の差）。
        var hex = ""
        hex.reserveCapacity(AppLimits.Logging.anonymizationTokenLength)
        for byte in digest.prefix((AppLimits.Logging.anonymizationTokenLength + 1) / 2) {
            hex.append(Self.hexDigits[Int(byte >> 4)])
            hex.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return String(hex.prefix(AppLimits.Logging.anonymizationTokenLength))
    }
}
