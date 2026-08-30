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
    /// 本の種別（一般コミック／同人誌…）。**ライブラリ単位の設定**で、
    /// ファイル名の中の印（`(同人誌)`）と照合する [TY-01]。
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
    public var discardsValue: Bool {
        switch self {
        case .ignore, .bookType: return true
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
/// 既定 5 種（著者・サークル・ジャンル・イベント・キーワード）は**この列挙が
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

    public var fieldRef: FieldRef {
        switch self {
        case .series: return .series
        case .author: return .author
        case .circle: return .circle
        case .event: return .event
        case .genre: return .genre
        case .keyword: return .keyword
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
        case .circle, .event, .genre, .keyword: return false
        }
    }

    /// 既定フィールドとして全ライブラリに保証する 5 種 [§19.2]。**並び順が
    /// そのまま設定画面の既定の並びと配色の割り当て順になる。**
    /// `@series` を含まないのは、シリーズが構造化列であってフィールドでは
    /// ないため——束縛はできるが、既定では置かない。
    public static let defaultFields: [SemanticKeyword] = [
        .author, .circle, .genre, .event, .keyword,
    ]
}

/// 予約語の綴りと `FieldRef` の対応表。
///
/// ## 予約語はここに並ぶものがすべて [v3 ステージ 5]
/// **`@labelgroupN` と `@libraryname` は撤去した。**
/// - `@labelgroupN`: 番号はフィールドの身元ではない（並べ替え・改名で指す先が
///   変わる）。既定フィールド 5 種は意味予約語で参照でき、それ以外のフィールドは
///   手で付けるためのもの——ファイル名から自動抽出する軸は既定の 5 種に閉じる。
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
            ("@booktype", .bookType),
            ("@volume", .volume),
            ("@ignore", .ignore(0)),          // 連番は字句解析側で振り直す [LX-03]
            ("@title", .title),
        ]
        return (semantic + others).sorted { $0.word.count > $1.word.count }
    }()
}
