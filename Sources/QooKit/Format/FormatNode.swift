//
//  フォーマットの構文木 [4.4]。
//
//  **正規表現の連結では実装しない** [FF-12]。字句解析 → 構文木 →
//  バックトラッキング照合の 3 段構成にする。
//
import Foundation

/// フィールドの照合方法。**コンパイル時にライブラリ設定から決まる** [TY-06]。
public enum FieldKind: Sendable, Equatable, Hashable {
    /// 自由文字列。非貪欲に伸ばす [FF-13]。
    case free
    /// 数字表記または登録済み巻数フォーマット [TY-01][SE-24]。
    case volume
    /// 列挙された候補のいずれか [TY-01]。`@librarytype` / `@libraryname`。
    case enumerated([String])
}

public indirect enum FormatNode: Sendable, Equatable {
    case literal(String)
    /// 弾力的空白。**0 個以上**の空白にマッチする [WS-01]。
    case whitespace
    case separator(SeparatorDelimiter)
    case field(FieldRef, kind: FieldKind)
    /// ペア型区切り。ネストできる [FF-11]。
    case group(PairDelimiter, children: [FormatNode])
}

extension FormatNode {
    /// この節が「境界」になるか（自由文字列フィールドの終端を決められるか）。
    /// 弾力的空白は**境界にならない** [VD-02] ——0 個でもよいので終端が決まらない。
    var isBoundary: Bool {
        switch self {
        case .literal(let s): return !s.isEmpty
        case .separator, .group: return true
        case .whitespace: return false
        case .field(_, let kind):
            switch kind {
            case .free: return false
            case .volume, .enumerated: return true   // 型条件で終端が決まる [VD-03]
            }
        }
    }

    var freeFieldRef: FieldRef? {
        if case .field(let ref, .free) = self { return ref }
        return nil
    }

    /// 自身と子孫のフィールドを出現順に返す。
    func fieldsInOrder() -> [FieldRef] {
        switch self {
        case .field(let ref, _): return [ref]
        case .group(_, let children): return children.flatMap { $0.fieldsInOrder() }
        default: return []
        }
    }
}

/// 検証を通ったフォーマット。`LibrarySettingsSnapshot` の revision に紐づく [TY-06]。
public struct CompiledFormat: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// 正規化済みのフォーマット文字列 [WS-03]。
    public let source: String
    public let nodes: [FormatNode]
    public let isEnabled: Bool          // [FF-05]
    public let priority: Int            // [FF-03][FF-04]
    public let usedFields: Set<FieldRef>
    /// 出現順に並べたフィールド。変換リネームのフィールド分解表示に使う [CW-16]。
    public let fieldOrder: [FieldRef]

    public init(id: UUID = UUID(), source: String, nodes: [FormatNode],
                isEnabled: Bool = true, priority: Int = 0,
                usedFields: Set<FieldRef>, fieldOrder: [FieldRef]) {
        self.id = id
        self.source = source
        self.nodes = nodes
        self.isEnabled = isEnabled
        self.priority = priority
        self.usedFields = usedFields
        self.fieldOrder = fieldOrder
    }
}
