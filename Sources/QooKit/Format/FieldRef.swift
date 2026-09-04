//
//  フォーマット中のフィールド参照 [MT-12][RW-01〜RW-17]。
//
import Foundation

/// 予約語が指すフィールド。ラベルグループ番号は任意桁を許す [MT-12]。
public enum FieldRef: Sendable, Hashable, Codable {
    case title
    case series
    case author
    /// サークル・イベント・ジャンル・キーワード [RWI-02]。
    /// **構造化列を持たず、束縛先のフィールドへラベルとしてだけ流れる**
    /// ——`@author` が `managedFile.authorName` を持つのとはそこが違う。
    case circle
    case event
    case genre
    case keyword
    case volume
    /// 本の種別（一般コミック／同人誌…）。ファイル名の中の印（`(同人誌)`）と
    /// **語彙で照合し** [TY-01]、一致した値は**ラベルとして残る**。
    ///
    /// ## なぜ自由文字列にしないか [実測]
    /// 型条件を外して自由文字列にすると、プリセットの
    /// `(@booktype) [@circle (@author)] @title …` が
    /// `(@event) [@circle (@author)] @title …` と**先頭以外まったく同じ形**に
    /// なり、優先順位が上の前者が `(C99)` のようなイベント名まで吸う。
    /// public ゴールデン 352 件のうち **48 件でイベントが取れなくなる**ことを
    /// 実際に測って確かめた。フォーマットの順序では解けない（2 本が同型のため）。
    case bookType
    /// 同一フォーマット内で複数書けるため出現順の連番で区別する [RW-03]。
    case ignore(Int)

    /// 自由文字列として照合するか [9.2.2]。`false` は型付き照合 [TY-01]。
    public var isFreeText: Bool {
        switch self {
        case .title, .series, .author, .circle, .event, .genre, .keyword, .ignore:
            return true
        case .volume, .bookType:
            return false
        }
    }

    /// 抽出値を捨てるフィールド（照合にだけ使う）[RW-02][RW-04]。
    ///
    /// **`@booktype` はここに含めない** [TY-01、2026-09-04]。
    ///
    /// ここが効くのは `FormatCompiler` の「1 つも抽出しないフォーマットを
    /// 拒む」検査 [FF-13] だけ——`(@booktype)` の 1 本だけでも意味のある
    /// フォーマットになった、というのがこの変更の意味である。
    /// **値がラベルへ流れるのはここではなく `SemanticKeyword.bookType` の
    /// 束縛による**ので、取り違えないこと（この 2 つは独立している）。
    public var discardsValue: Bool {
        switch self {
        case .ignore: return true
        default: return false
        }
    }

    /// フォーマット内での重複を許すか [RW-03]。`@ignore` のみ許す。
    public var allowsDuplicates: Bool {
        if case .ignore = self { return true }
        return false
    }
}

/// セマンティック予約語 [RW-13][RWI-02]。
///
/// **case を足すだけで拡張でき、スキーマ変更を伴わない**——束縛は
/// `settingsJSON.semanticBindings`（`[String: Int]`）に載るだけで、
/// 知らない綴りは読み飛ばされる。
///
/// ## 既定フィールドとの関係 [§19.2]
/// 既定 6 種（著者・サークル・ジャンル・イベント・キーワード・本の種別）は**この列挙が
/// そのまま身元になる**——表示名はライブラリごとに変えられるので、表示名を
/// 識別子にすると改名した瞬間にフォーマットと束縛が壊れる。`@series` だけは
/// 既定フィールドではなく、シリーズ名（構造化列）をラベルにも流したいときの
/// 任意の束縛として残る。
public enum SemanticKeyword: String, Sendable, Codable, CaseIterable, Hashable {
    case series = "@series"
    case author = "@author"
    case circle = "@circle"
    case event = "@event"
    case genre = "@genre"
    case keyword = "@keyword"
    case bookType = "@booktype"

    public var fieldRef: FieldRef {
        switch self {
        case .series: return .series
        case .author: return .author
        case .circle: return .circle
        case .event: return .event
        case .genre: return .genre
        case .keyword: return .keyword
        case .bookType: return .bookType
        }
    }

    /// 束縛が無くても値が残るか [RW-16]。
    ///
    /// `@series` は `seriesName`、`@author` は `authorName` という**構造化列**を
    /// 持つので、どのフィールドにも束縛されていなくても書く意味がある。
    /// 残る 4 種は列を持たないため、束縛が無ければ切り出した値は**捨てられる**
    /// ——照合には成功するのに何も残らない、という気づきにくい状態になる。
    public var hasStructuredColumn: Bool {
        switch self {
        case .series, .author: return true
        case .circle, .event, .genre, .keyword, .bookType: return false
        }
    }

    /// 既定フィールドとして全ライブラリに保証する 6 種 [§19.2]。**並び順が
    /// そのまま設定画面の既定の並びと配色の割り当て順になる。**
    /// `@series` を含まないのは、シリーズが構造化列であってフィールドでは
    /// ないため——束縛はできるが、既定では置かない。
    ///
    /// **`@booktype` は末尾に足す。** 既定 1〜5 の番号を動かさないため
    /// ——番号はフィールドの身元ではないが、既存の設定・テストが番号で
    /// 引いている箇所があり、動かす利点が無い。
    public static let defaultFields: [SemanticKeyword] = [
        .author, .circle, .genre, .event, .keyword, .bookType,
    ]
}

/// 予約語の綴りと `FieldRef` の対応表。
///
/// ## 予約語はここに並ぶものがすべて [v3 ステージ 5]
/// **`@labelgroupN` と `@libraryname` は撤去した。**
/// - `@labelgroupN`: 番号はフィールドの身元ではない（並べ替え・改名で指す先が
///   変わる）。既定フィールド 6 種は意味予約語で参照でき、それ以外のフィールドは
///   手で付けるためのもの——ファイル名から自動抽出する軸は既定の 6 種に閉じる。
/// - `@libraryname`: 用途が定まらないまま置かれていた [旧 RW-05] うえ、
///   表示名がフォルダ名へ自動追随するようになった [RG3-31] ので、**利用者が
///   Finder でフォルダを改名した瞬間に照合値が変わる**——黙って一致しなくなる。
public enum ReservedWordTable {
    /// 長い順に並べる（最長一致で読むため）[LX-01]。
    ///
    /// **セマンティック予約語はここに直接書かず `SemanticKeyword` から導く。**
    /// 2 箇所に書くと、case を足したのに字句解析が読めない（＝綴りを書いても
    /// 「不明な予約語」になる）という、気づきにくい食い違いが起きる。
    public static let entries: [(word: String, field: FieldRef)] = {
        let semantic = SemanticKeyword.allCases.map { (word: $0.rawValue, field: $0.fieldRef) }
        let others: [(word: String, field: FieldRef)] = [
            ("@volume", .volume),
            ("@ignore", .ignore(0)),          // 連番は字句解析側で振り直す [LX-03]
            ("@title", .title),
        ]
        return (semantic + others).sorted { $0.word.count > $1.word.count }
    }()
}
