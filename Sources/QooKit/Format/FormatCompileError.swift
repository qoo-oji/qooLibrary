//
//  フォーマットの検証エラー [FF-15〜FF-19][TY-05]。
//
import Foundation

/// 検証エラーは**保存を拒否する** [FF-15][VD-01]。編集画面では該当位置に
/// 下線とメッセージを表示する [HP-04]。
public enum FormatCompileError: Error, Equatable, Sendable {
    /// 括弧の対応が取れない。`at` はフォーマット文字列内の文字位置。
    case unbalancedDelimiter(at: Int)
    case duplicateTitle
    case duplicateField(FieldRef)
    // `@labelgroupN` の撤去（v3 ステージ 5）で 3 つの失敗様式が消えた:
    // 番号の重複・範囲外・意味予約語との衝突 [旧 FF-16 の一部][旧 LG-01][旧 RW-15]。
    // フィールドを指す道が意味予約語 1 本になり、同じ軸を 2 通りで書けなくなった。
    case adjacentFreeFields(first: FieldRef, second: FieldRef)  // [FF-18][TY-05]
    case unknownReservedWord(String, at: Int)
    case emptyFormat
    /// 照合しても何も抽出できない（フィールドが 1 つも無い）。
    case noFieldAtAll

    /// エラーが指すフォーマット文字列内の位置（分かる場合）[HP-04]。
    public var sourceOffset: Int? {
        switch self {
        case .unbalancedDelimiter(let at), .unknownReservedWord(_, let at): return at
        default: return nil
        }
    }
}

extension FormatCompileError: UserPresentableError {
    public var whatHappened: String {
        switch self {
        case .unbalancedDelimiter:
            return QooKitStrings.text("format.unbalancedDelimiter.what")
        case .duplicateTitle:
            return QooKitStrings.text("format.duplicateTitle.what")
        case .duplicateField(let f):
            return QooKitStrings.format("format.duplicateField.what", Self.label(f))
        case .adjacentFreeFields(let a, let b):
            return QooKitStrings.format("format.adjacentFreeFields.what",
                                        Self.label(a), Self.label(b))
        case .unknownReservedWord(let w, _):
            return QooKitStrings.format("format.unknownReservedWord.what", w)
        case .emptyFormat:
            return QooKitStrings.text("format.emptyFormat.what")
        case .noFieldAtAll:
            return QooKitStrings.text("format.noFieldAtAll.what")
        }
    }

    public var whyItHappened: String {
        switch self {
        case .unbalancedDelimiter:
            return QooKitStrings.text("format.unbalancedDelimiter.why")
        case .duplicateTitle, .duplicateField:
            return QooKitStrings.text("format.duplicate.why")
        case .adjacentFreeFields:
            return QooKitStrings.text("format.adjacentFreeFields.why")
        case .unknownReservedWord:
            return QooKitStrings.text("format.unknownReservedWord.why")
        case .emptyFormat, .noFieldAtAll:
            return QooKitStrings.text("format.empty.why")
        }
    }

    public var recoveryHint: String? {
        switch self {
        case .unbalancedDelimiter:
            return QooKitStrings.text("format.unbalancedDelimiter.hint")
        case .duplicateTitle, .duplicateField:
            return QooKitStrings.text("format.duplicate.hint")
        case .adjacentFreeFields:
            return QooKitStrings.text("format.adjacentFreeFields.hint")
        case .unknownReservedWord:
            return QooKitStrings.text("format.unknownReservedWord.hint")
        case .emptyFormat, .noFieldAtAll:
            return QooKitStrings.text("format.empty.hint")
        }
    }

    public var recoverySuggestions: [RecoveryAction] { [] }
    public var technicalDetail: String? { nil }
    /// 編集画面のその場に出す [HP-04]。
    public var severity: NotificationSeverity { .inline }

    /// フィールドを予約語の綴りに戻す。
    ///
    /// **綴りは `ReservedWordTable` から引く。** ここに直接書くと、予約語を
    /// 足したときにエラー文言だけが古い綴りのまま残る。
    static func label(_ f: FieldRef) -> String {
        if case .ignore = f { return "@ignore" }   // 連番の違いを吸収する [RW-03]
        return ReservedWordTable.entries.first { $0.field == f }?.word ?? "@?"
    }
}
