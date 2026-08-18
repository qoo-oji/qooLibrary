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
    case duplicateLabelGroup(index: Int)                        // [FF-16]
    case labelGroupOutOfRange(index: Int, max: Int)             // [LG-01][MT-11]
    case semanticConflict(keyword: SemanticKeyword, labelGroup: Int)  // [RW-15]
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
        case .unbalancedDelimiter: return "フォーマットの括弧の対応が取れていません。"
        case .duplicateTitle: return "@title が複数あります。"
        case .duplicateField(let f): return "\(Self.label(f)) が複数あります。"
        case .duplicateLabelGroup(let i): return "@labelgroup\(i) が複数あります。"
        case .labelGroupOutOfRange(let i, _): return "@labelgroup\(i) は存在しないラベルグループです。"
        case .semanticConflict(let kw, let g):
            return "\(kw.rawValue) と @labelgroup\(g) が同じラベルグループを指しています。"
        case .adjacentFreeFields(let a, let b):
            return "\(Self.label(a)) と \(Self.label(b)) が隣り合っています。"
        case .unknownReservedWord(let w, _): return "「\(w)」は予約語ではありません。"
        case .emptyFormat: return "フォーマットが空です。"
        case .noFieldAtAll: return "フォーマットに予約語が 1 つもありません。"
        }
    }

    public var whyItHappened: String {
        switch self {
        case .unbalancedDelimiter:
            return "開き括弧と閉じ括弧の数が合っていないか、対応する相手がありません。"
        case .duplicateTitle, .duplicateField, .duplicateLabelGroup:
            return "同じ予約語を 1 つのフォーマットに 2 回以上書くと、どちらへ割り当てるかを決められません。"
        case .labelGroupOutOfRange(_, let max):
            return "設定できるラベルグループは 1 〜 \(max) です。"
        case .semanticConflict:
            return "1 つのラベルグループに 2 通りの意味を割り当てることはできません。"
        case .adjacentFreeFields:
            return "どちらも自由文字列のため、境目が決まりません。"
        case .unknownReservedWord:
            return "綴りが違うか、この版では使えない予約語です。"
        case .emptyFormat, .noFieldAtAll:
            return "照合しても取り出せる情報がありません。"
        }
    }

    public var recoveryHint: String? {
        switch self {
        case .unbalancedDelimiter: return "括弧を追加するか、余分な括弧を削除してください。"
        case .duplicateTitle, .duplicateField, .duplicateLabelGroup:
            return "片方を削除するか、別の予約語に置き換えてください。"
        case .labelGroupOutOfRange:
            return "ライブラリ設定でラベルグループを追加するか、既存の番号を指定してください。"
        case .semanticConflict:
            return "ライブラリ設定でセマンティック予約語の割り当てを外すか、別のラベルグループを指定してください。"
        case .adjacentFreeFields:
            return "間に区切り文字やリテラル文字を挟んでください（空白だけでは境目になりません）。"
        case .unknownReservedWord:
            return "予約語パレットから選び直してください。"
        case .emptyFormat, .noFieldAtAll:
            return "@title などの予約語を 1 つ以上書いてください。"
        }
    }

    public var recoverySuggestions: [RecoveryAction] { [] }
    public var technicalDetail: String? { nil }
    /// 編集画面のその場に出す [HP-04]。
    public var severity: NotificationSeverity { .inline }

    static func label(_ f: FieldRef) -> String {
        switch f {
        case .title: return "@title"
        case .series: return "@series"
        case .author: return "@author"
        case .volume: return "@volume"
        case .libraryType: return "@librarytype"
        case .libraryName: return "@libraryname"
        case .labelGroup(let i): return "@labelgroup\(i)"
        case .ignore: return "@ignore"
        }
    }
}
