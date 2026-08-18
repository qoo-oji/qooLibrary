//
//  フォーマット中のフィールド参照 [MT-12][RW-01〜RW-17]。
//
import Foundation

/// 予約語が指すフィールド。ラベルグループ番号は任意桁を許す [MT-12]。
public enum FieldRef: Sendable, Hashable, Codable {
    case title
    case series
    case author
    case volume
    /// `@labelgroup1` … `@labelgroup12` …。桁数を固定しない [MT-12]。
    case labelGroup(Int)
    case libraryType
    case libraryName
    /// 同一フォーマット内で複数書けるため出現順の連番で区別する [RW-03]。
    case ignore(Int)

    /// 自由文字列として照合するか [9.2.2]。`false` は型付き照合 [TY-01]。
    public var isFreeText: Bool {
        switch self {
        case .title, .series, .author, .labelGroup, .ignore: return true
        case .volume, .libraryType, .libraryName: return false
        }
    }

    /// 抽出値を捨てるフィールド（照合にだけ使う）[RW-02][RW-04]。
    public var discardsValue: Bool {
        switch self {
        case .ignore, .libraryName, .libraryType: return true
        default: return false
        }
    }

    /// フォーマット内での重複を許すか [RW-03]。`@ignore` のみ許す。
    public var allowsDuplicates: Bool {
        if case .ignore = self { return true }
        return false
    }
}

/// セマンティック予約語 [RW-13]。case を足すだけで拡張でき、スキーマ変更を伴わない。
public enum SemanticKeyword: String, Sendable, Codable, CaseIterable, Hashable {
    case series = "@series"
    case author = "@author"
    // 将来: circle / event / genre をここに足すだけでよい [RW-13][RWI-02]

    public var fieldRef: FieldRef {
        switch self {
        case .series: return .series
        case .author: return .author
        }
    }
}

/// 予約語の綴りと `FieldRef` の対応表。
///
/// `@labelgroup#` だけは可変長のため表に載せず、字句解析側で扱う [LX-01][LX-02]。
/// **`@libraryname` を参照する箇所は 3 つ以内に閉じ込める** [RW-05][RWI-01]:
/// この表・`FieldKind` の決定・`postProcess`。
public enum ReservedWordTable {
    public static let labelGroupPrefix = "@labelgroup"

    /// 長い順に並べる（最長一致で読むため）[LX-01]。
    public static let entries: [(word: String, field: FieldRef)] = [
        ("@librarytype", .libraryType),
        ("@libraryname", .libraryName),   // [RW-05] 参照箇所 1 / 3
        ("@series", .series),
        ("@author", .author),
        ("@volume", .volume),
        ("@ignore", .ignore(0)),          // 連番は字句解析側で振り直す [LX-03]
        ("@title", .title),
    ].sorted { $0.word.count > $1.word.count }
}
