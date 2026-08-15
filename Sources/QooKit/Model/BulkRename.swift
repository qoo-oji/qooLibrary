import Foundation

/// Finder の「名前を変更…」（複数選択時）相当の一括リネーム。
///
/// **フェーズ3の一括リネーム（BR-01〜11）とは別物**［ユーザー判断］。あちらは
/// 「連番を振る順番をユーザーが決める」ことが主眼のライブラリ整備機能で、
/// こちらは日常のファイル操作。ただし土台は共通で、プレビュー [BR-08]・
/// 衝突検出 [BR-09]・2 パス方式 [BR-10]・1 Undo 単位 [BR-11] はここで作った
/// ものをフェーズ3が使える。
///
/// この型は**名前を計算するだけ**で、ファイルには一切触らない [A-01]。
public enum BulkRename {
    /// Finder と同じ 3 モード。
    public enum Mode: Sendable, Equatable {
        /// テキストを置き換える。
        case replaceText(find: String, replaceWith: String)
        /// テキストを追加する。
        case addText(String, placement: Placement)
        /// フォーマット（名前＋連番／カウンタ／日付）。
        /// - Parameter customText: **`nil` は「元の名前をそのまま使う」**、
        ///   非 `nil` は「元の名前を捨ててこの文字列にする」［ユーザー要望:
        ///   置き換えるかどうかをチェックで明示したい］。空文字列も有効で、
        ///   その場合は区切り文字と番号だけになる。以前は「空なら元の名前」と
        ///   していたが、空欄の意味が 2 通りに読めて分かりにくかった。
        case format(
            style: FormatStyle, customText: String?, placement: Placement,
            startNumber: Int, digits: Int = BulkRename.defaultDigits,
            separator: Separator = BulkRename.defaultSeparator
        )
    }

    public enum Placement: String, Sendable, CaseIterable {
        /// 名前の前。
        case before
        /// 名前の後。**拡張子より前**に入れる — 拡張子の後ろに足すと
        /// ファイルの種類が変わってしまい、開けなくなる。
        case after
    }

    public enum FormatStyle: String, Sendable, CaseIterable {
        /// **番号だけ**（元の名前もカスタム文字列も使わない）［ユーザー要望］。
        /// 「001.jpg」「002.jpg」のように連番へ振り直す。
        /// **既定**［ユーザー要望: 一番上に置き、既定にする］。
        case numberOnly
        /// 名前と番号（1, 2, 3 … / 桁数を指定すれば 001, 002 …）。
        ///
        /// Finder は「インデックス」と「カウンタ」（5 桁ゼロ詰め固定）を
        /// 別の形式として持つが、**桁数を指定できるようにした**［ユーザー要望］
        /// 以上、カウンタは「番号 ＋ 5 桁」と同じものになるため 1 つにまとめた
        /// ［設計判断］。選択肢が 2 つある方が、どちらを選べばよいか迷わせる。
        case nameAndIndex
        /// 名前と日付。
        case nameAndDate
    }

    /// 連番の桁数（ゼロ詰め）。1 は詰めない。
    public static let digitRange = 1...6
    public static let defaultDigits = 1

    /// 名前と番号のあいだに入れる文字［ユーザー要望: スペースは行儀が良くない］。
    ///
    /// **既定はアンダースコア。** Finder はスペースを使うが、ファイル名の
    /// 空白はシェルや URL で毎回エスケープが要る。Finder 準拠より実用を採った
    /// ［設計判断］。スペースが好みなら選べる。
    public enum Separator: String, Sendable, CaseIterable {
        case underscore = "_"
        case hyphen = "-"
        case space = " "
        case none = ""
    }

    public static let defaultSeparator = Separator.underscore
    public static let defaultFormatStyle = FormatStyle.numberOnly

    /// 変更前後の 1 組。プレビュー表示 [BR-08] にそのまま使う。
    public struct Change: Sendable, Equatable, Identifiable {
        public var id: String { originalName }
        public let originalName: String
        public let newName: String
        /// この行が衝突しているか [BR-09]。実行前に赤字で示し、1 件でもあれば
        /// 実行させない。
        public var conflicts: Bool

        public init(originalName: String, newName: String, conflicts: Bool = false) {
            self.originalName = originalName
            self.newName = newName
            self.conflicts = conflicts
        }

        /// 名前が実際に変わるか（変わらない行はリネームしない）。
        public var isChanged: Bool { originalName != newName }
    }

    /// 変更後の名前を計算する。
    ///
    /// - Parameters:
    ///   - names: 変更対象の**現在の**名前（表示順）。連番はこの順に振る。
    ///   - existingNames: 同じフォルダにある**対象外**の項目の名前。衝突判定に使う。
    ///   - date: 日付フォーマット用（テスト から固定値を渡せるようにしている）。
    public static func plan(
        names: [String],
        mode: Mode,
        existingNames: Set<String> = [],
        date: Date = Date(),
        locale: Locale = .current
    ) -> [Change] {
        var changes: [Change] = []
        for (offset, name) in names.enumerated() {
            changes.append(Change(originalName: name, newName: newName(
                for: name, at: offset, mode: mode, date: date, locale: locale
            )))
        }
        return markingConflicts(changes, existingNames: existingNames)
    }

    /// [BR-09] そのまま実行できない行に印を付ける。
    ///
    /// 3 種類ある: ①変更後の名前どうしがぶつかる ②対象外の既存項目とぶつかる
    /// ③そもそも名前として使えない。
    /// **大文字小文字だけが違う名前もぶつかる扱いにする** — macOS の既定の
    /// ファイルシステムは大文字小文字を区別しないため、区別する前提で通すと
    /// 実行時に初めて失敗する。
    ///
    /// ③を加えたのは監査での指摘による。置換文字列に `/` を含めると、
    /// リネームのつもりが**別フォルダへの移動**になる（実測で再現）。
    /// 一括リネームは 1 件ずつ順に実行するため、途中で弾かれると
    /// 「半分だけ名前が変わった」状態が残る。**プレビューの時点で印を付け、
    /// 実行させない**のがいちばん安全 [`FileNameValidation`]。
    static func markingConflicts(_ changes: [Change], existingNames: Set<String>) -> [Change] {
        let foldedExisting = Set(existingNames.map { $0.lowercased() })
        var counts: [String: Int] = [:]
        for change in changes {
            counts[change.newName.lowercased(), default: 0] += 1
        }
        return changes.map { change in
            var marked = change
            let folded = change.newName.lowercased()
            marked.conflicts = change.newName.isEmpty
                || counts[folded, default: 0] > 1
                || foldedExisting.contains(folded)
                || !FileNameValidation.isAcceptable(change.newName)
            return marked
        }
    }

    private static func newName(
        for name: String, at index: Int, mode: Mode, date: Date, locale: Locale
    ) -> String {
        switch mode {
        case .replaceText(let find, let replaceWith):
            // **拡張子も含めた名前全体**が対象（Finder と同じ）。
            guard !find.isEmpty else { return name }
            return name.replacingOccurrences(of: find, with: replaceWith)

        case .addText(let text, let placement):
            guard !text.isEmpty else { return name }
            switch placement {
            case .before: return text + name
            case .after: return insertBeforeExtension(text, into: name)
            }

        case .format(let style, let customText, let placement, let startNumber, let digits, let separator):
            let suffix: String
            switch style {
            case .nameAndIndex, .numberOnly:
                // 桁数はゼロ詰めの**下限**。9 桁の番号を 3 桁指定で切り詰めたり
                // しない（`%03d` は 1234 をそのまま 1234 と出す）。
                let width = min(max(digits, digitRange.lowerBound), digitRange.upperBound)
                suffix = String(format: "%0\(width)d", index + startNumber)
            case .nameAndDate:
                let formatter = DateFormatter()
                formatter.locale = locale
                // ファイル名に使える形（`/` と `:` を含まない）。
                formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                suffix = formatter.string(from: date)
            }
            // 番号のみは名前を一切使わない（位置も区切り文字も意味を持たない）。
            if style == .numberOnly {
                return applyExtension(of: name, to: suffix)
            }
            let base = customText ?? stem(of: name)
            let joiner = separator.rawValue
            let composed = placement == .before ? "\(suffix)\(joiner)\(base)" : "\(base)\(joiner)\(suffix)"
            return applyExtension(of: name, to: composed)
        }
    }

    /// 拡張子を除いた部分。`.tar.gz` のような複合拡張子は扱わない
    /// （Finder も最後の `.` だけを見る）。
    static func stem(of name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    static func fileExtension(of name: String) -> String {
        (name as NSString).pathExtension
    }

    private static func applyExtension(of original: String, to newStem: String) -> String {
        let ext = fileExtension(of: original)
        return ext.isEmpty ? newStem : "\(newStem).\(ext)"
    }

    private static func insertBeforeExtension(_ text: String, into name: String) -> String {
        let ext = fileExtension(of: name)
        guard !ext.isEmpty else { return name + text }
        return "\(stem(of: name))\(text).\(ext)"
    }

    /// [BR-10] 循環（A→B, B→A）を含む並べ替えでも安全に実行できるよう、
    /// 一時名を経由する 2 パスが必要かを判定する。
    ///
    /// 変更後の名前が、**この操作で名前が変わるいずれかの項目の変更前の名前**と
    /// ぶつかる場合に必要。ぶつからなければ 1 パスで足りる（余計なリネームを
    /// 増やさない）。
    public static func requiresTwoPass(_ changes: [Change]) -> Bool {
        let changed = changes.filter(\.isChanged)
        guard !changed.isEmpty else { return false }
        let originals = Set(changed.map { $0.originalName.lowercased() })
        return changed.contains { originals.contains($0.newName.lowercased()) }
    }
}
