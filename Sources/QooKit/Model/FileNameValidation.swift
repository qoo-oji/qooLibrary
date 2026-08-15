import Foundation

/// ユーザーが入力した名前を、実際にファイルシステムへ渡す前に検査する
/// ただ 1 つの窓口。リネーム・新規フォルダ・一括リネームが共通で使う。
///
/// ## なぜ要るのか（実測で確認した実害）
/// 名前に `/` を含めたままリネームすると、`appendingPathComponent` が
/// **パス区切りとして解釈し、別フォルダへの移動になる**。ユーザーから見ると
/// 「名前を変えたはずのファイルが一覧から消える」。新規フォルダでも
/// `withIntermediateDirectories: true` と組み合わさって入れ子のフォルダが
/// 2 つできる。どちらも実測で再現した。
///
/// ## 何を禁止するかは実測で決めた
/// macOS が実際にマウントし得る形式すべて（APFS / APFS 大文字小文字区別 /
/// HFS+ / HFS+ 大文字小文字区別 / exFAT / FAT12・16・32 / UDF /
/// SMB〈実 NAS〉）で同じ名前を作って確かめたところ、**どの形式でも拒否
/// されたのは `/` と `.` と `..` だけ**だった。
///
/// Windows で禁止されている `\ : * ? " < > |` も、改行・タブ・制御文字も、
/// 末尾の空白・ドットも、先頭ドットも、**すべての形式が受け付けた**
/// （SMB 経由でも同じ）。したがってこれらを本アプリ側で禁止すると、
/// 実際には作れる名前を理由なく拒むことになるため禁止しない
/// ［CLAUDE.md 冒頭「機械が人間に合わせる」］。
///
/// ## `/` は黙って置き換えず、拒否して理由を伝える［ユーザー判断］
/// Finder は `/` の入力を受け付け、POSIX 上は `:` として保存する
/// （HFS+ 時代のパス区切りが `:` だった名残）。同じ変換をする案もあったが、
/// **入力した名前と実際に保存される名前が食い違う**ため採らない。
/// 「その文字は使えない」と実行前に伝えるほうが、黙って別の名前にするより
/// ユーザーの意図に忠実だと判断した。
public enum FileNameValidation {
    public enum Failure: Error, Sendable, Equatable {
        /// 空、または空白だけ。
        case empty
        /// パス区切り（`/`）や NUL を含む。
        case forbiddenCharacter(String)
        /// `.` / `..`（ファイルシステムが予約している）。
        case reservedDotName
        /// 上限を超えている。
        case tooLong(units: Int)
    }

    /// 名前 1 つの長さの上限。**単位は「NFD 正規化後の UTF-16 単位」**。
    ///
    /// 実測でファイルシステムごとに単位が違うことが分かっている:
    ///
    /// | 形式 | `あ` の最大個数 | `が`(NFC) の最大個数 | 実質の単位 |
    /// |---|---|---|---|
    /// | APFS / HFS+ | 255 | 127 | NFD 後の UTF-16 単位 255 |
    /// | exFAT / FAT | 255 | 165 | （駆動側の正規化に依存） |
    /// | SMB（実 NAS）| 85 | 85 | UTF-8 バイト 255 |
    /// | UDF | 78 | 39 | さらに短い |
    ///
    /// **単一の規則では正確に予測できない**ため、ここでは最も緩い
    /// APFS/HFS+ の規則を採る。これより短い上限を持つ形式（SMB・UDF）で
    /// 実際に弾かれた場合は、書き込み時の `ENAMETOOLONG` を
    /// `PosixFailure` が「名前またはパスが長すぎます」と説明する。
    ///
    /// 緩い側に倒すのは、**誤って拒否すると正当な操作ができなくなる**のに
    /// 対し、通してしまっても失敗は理由付きで伝わるという害の非対称による
    /// [`VolumeCapacity` と同じ判断]。
    public static let maxNameUnits = 255

    /// 名前として使えない文字。実測に基づき `/`（POSIX のパス区切り）と
    /// NUL（C 文字列の終端）だけ。
    public static let forbiddenCharacters: CharacterSet = CharacterSet(charactersIn: "/\0")

    /// 入力を整えて返す。使えない名前なら `Failure` を投げる。
    ///
    /// 整えるのは前後の空白を落とすことだけ（Finder も落とす）。
    /// **文字の置き換えはしない** — 型のコメント参照。
    public static func sanitized(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        if trimmed.contains("/") { throw Failure.forbiddenCharacter("/") }
        if trimmed.rangeOfCharacter(from: forbiddenCharacters) != nil {
            throw Failure.forbiddenCharacter("\\0")
        }
        guard trimmed != ".", trimmed != ".." else { throw Failure.reservedDotName }
        let units = trimmed.decomposedStringWithCanonicalMapping.utf16.count
        guard units <= maxNameUnits else { throw Failure.tooLong(units: units) }
        return trimmed
    }

    /// 投げずに判定だけしたい呼び出し側（入力欄の「決定」ボタンの有効・無効など）用。
    public static func isAcceptable(_ raw: String) -> Bool {
        (try? sanitized(raw)) != nil
    }
}

/// 文言は日本語のリテラル。この層は文字列カタログを参照できないため
/// ［既知の限界、`FileOperationError`/`ExtractError` と同じ］。
extension FileNameValidation.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty:
            return "名前を入力してください。"
        case let .forbiddenCharacter(character):
            return "名前に「\(character)」は使えません。"
                + "この文字はフォルダの区切りとして予約されています。別の文字に置き換えてください。"
        case .reservedDotName:
            return "「.」と「..」はファイルシステムが使う名前のため、項目の名前には使えません。"
        case let .tooLong(units):
            return "名前が長すぎます（\(units) 文字ぶん、上限 \(FileNameValidation.maxNameUnits) 文字ぶん）。"
                + "短い名前を入力してください。"
        }
    }
}
