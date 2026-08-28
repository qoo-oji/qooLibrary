//
//  文字列正規化 [N-01〜N-04][WS-05][DB-03][SR-06]。
//
//  **正規化は 1 箇所にしか実装しない。**ラベルの重複と検索の取りこぼしはすべて
//  ここで潰す。`normalize` は純粋関数で、単体テストのカバレッジ 100% を必須と
//  する [NM-04]。
//
import Foundation

public enum TextNormalizer {

    // MARK: - 公開 API

    /// 表示用。原文を保持する（正規化しない）[N-02][N-03]。
    ///
    /// 何もしない関数だが、「ここは表示用だから正規化していない」という意図を
    /// 呼び出し側のコードに残すために存在する。
    @inlinable
    public static func display(_ s: String) -> String { s }

    /// 照合用。①NFC ②全角→半角 ③空白の畳み込み ④小文字化。
    ///
    /// 大文字・小文字は**常に同一視する**［N-04 撤回、§19.8］——以前は
    /// ライブラリ設定で切り替えられたが、この設定が制御していたのは語彙の
    /// 同一視ルールであってファイルシステムの性質ではなく、名前が誤解を
    /// 招いていた。
    ///
    /// 冪等（`normalize(normalize(x)) == normalize(x)`）であることを単体テストで
    /// 固定している。DB の `normalizedName` はこの結果を保存したもの [NM-05]。
    public static func normalize(_ s: String) -> String {
        // 全角畳み込みとケース変換は NFC/NFD のどちらでも同じ結果になる
        // （U+FF01〜FF5E と U+3000 は正準分解を持たない）ため、順序は自由。
        // NFC は最後に 1 回だけ通す——ケース変換が非 NFC を作りうるため。
        var t = WidthFolding.fold(s).lowercased()
        t = collapseWhitespace(t)
        return t.precomposedStringWithCanonicalMapping
    }

    /// ①②のみ。フィールド値の内部空白を保持したいときに使う [WS-05]。
    public static func canonicalWidth(_ s: String) -> String {
        WidthFolding.fold(s).precomposedStringWithCanonicalMapping
    }

    /// 先頭・末尾の空白（半角・全角・タブ・NBSP）を除去する [FF-14][WS-05]。
    /// 内部の空白は原文のまま残す。
    public static func trimWhitespace(_ s: String) -> String {
        var start = s.startIndex
        var end = s.endIndex
        while start < end, Whitespace.isWhitespace(s[start]) { start = s.index(after: start) }
        while end > start {
            let prev = s.index(before: end)
            guard Whitespace.isWhitespace(s[prev]) else { break }
            end = prev
        }
        return String(s[start..<end])
    }

    /// 検索用。`normalize` の結果をさらにカナ統一（ひらがな→カタカナ）した文字列
    /// [DB-03][SR-06]。
    ///
    /// 半角カナ（U+FF61〜U+FF9F）の全角化は行わない [設計判断]。実コーパス
    /// 2,953 件のうち半角カナを含むファイル名は 1 件（0.03%）で、濁点の合成
    /// （`ｶ` + `ﾞ` → `ガ`）は 2 文字 → 1 文字の写像になり `normalize` の
    /// 「長さを変えない」性質も崩す。必要になったらここへ足す。
    public static func searchKey(_ s: String) -> String {
        let normalized = normalize(s)
        guard normalized.unicodeScalars.contains(where: isHiragana) else { return normalized }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(normalized.unicodeScalars.count)
        for scalar in normalized.unicodeScalars {
            out.append(katakana(for: scalar))
        }
        return String(out)
    }

    /// 検索キーの部品どうしを隔てる印 [SR-03]。
    ///
    /// **空白で繋いではならない。** `normalize` は空白を 1 つに畳むので、
    /// 部品を空白で連結すると `作品A` と `巻` が `"作品A 巻"` になり、
    /// **語をまたいだ誤一致**（`"A 巻"` で当たる）が起きる。ここで使う
    /// U+001F は ①`WidthFolding` の写像域（U+FF01〜FF5E・U+3000）の外
    /// ②`lowercased()` で変わらない ③`Whitespace.isWhitespace` が偽 —— の
    /// 3 つを満たすので `normalize` を素通りする。**利用者が検索欄へ打つ
    /// 手段が無い**ので、問い合わせ側の検索キーには決して現れず、
    /// `LIKE '%…%'` は必ず 1 つの部品の内側でしか当たらない。
    public static let searchKeyPartSeparator: Character = "\u{1F}"

    /// 複数の値をまとめた検索用キー [SR-03][SR-06][DB-03]。
    ///
    /// ライブラリ表示モードの検索はファイル名だけでなくタイトル・シリーズ名も
    /// 対象にする [SR-03] ので、`managedFile.searchKey` はそれらを繋いだものに
    /// なる。**部品ごとに正規化してから繋ぐ**——先に繋ぐと区切りが空白畳み込みの
    /// 影響を受ける。
    ///
    /// `nil`・空・**既に入っている部品と同一のもの**は落とす。ファイル名の
    /// stem がタイトルと一致する（自動抽出ではごく普通）ときに同じ文字列を
    /// 2 回持つと、索引 `mf_search` が理由もなく倍の大きさになる。
    public static func searchKey(joining parts: [String?]) -> String {
        var out: [String] = []
        out.reserveCapacity(parts.count)
        for part in parts {
            guard let part else { continue }
            let key = searchKey(part)
            guard !key.isEmpty, !out.contains(key) else { continue }
            out.append(key)
        }
        return out.joined(separator: String(searchKeyPartSeparator))
    }

    // MARK: - 内部

    /// ひらがな U+3041〜U+3096（`ぁ`〜`ゖ`）と反復記号 U+309D〜U+309E。
    /// U+3099〜U+309C（結合濁点・半濁点）はカタカナと共通なので変換しない。
    @usableFromInline
    static func isHiragana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041...0x3096).contains(scalar.value) || (0x309D...0x309E).contains(scalar.value)
    }

    @usableFromInline
    static let hiraganaToKatakanaOffset: UInt32 = 0x60

    /// ひらがな → カタカナ。**失敗しうる初期化子を使わない**ため、対象範囲の
    /// 対応表を先に作っておく（到達不能な分岐はカバレッジの穴になるだけ）[NM-04]。
    /// ひらがな U+3041〜U+309E に 0x60 を足した U+30A1〜U+30FE の対応表。
    /// `compactMap` を使うことで、このファイルの中に到達不能な分岐（`??` や `!`）を
    /// 作らずに済む。落ちた要素があれば `katakanaTableIsComplete` テストが検出する。
    @usableFromInline
    static let katakanaTable: [Unicode.Scalar] =
        (UInt32(0x3041) + hiraganaToKatakanaOffset ... UInt32(0x309E) + hiraganaToKatakanaOffset)
            .compactMap(Unicode.Scalar.init(_:))

    /// 対応表が期待する長さであること（テストから参照する）。
    @usableFromInline
    static let katakanaTableExpectedCount = Int(0x309E - 0x3041) + 1

    @usableFromInline
    static func katakana(for scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard isHiragana(scalar) else { return scalar }
        return katakanaTable[Int(scalar.value - 0x3041)]
    }

    /// 連続する空白を半角 1 個に畳み、前後をトリムする [WS-06][FF-14][NM-03]。
    static func collapseWhitespace(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        var pendingSpace = false
        var wroteAny = false
        for c in s {
            if Whitespace.isWhitespace(c) {
                pendingSpace = wroteAny        // 先頭の空白は落とす
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(c)
                wroteAny = true
            }
        }
        // 末尾に残った pendingSpace は書かない＝末尾トリム
        return out
    }
}
