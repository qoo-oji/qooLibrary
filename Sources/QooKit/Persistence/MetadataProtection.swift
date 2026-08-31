//
//  メタデータの保護 [PR-01〜PR-09]。
//
//  本のメタデータ（ラベル・タイトル・シリーズ・巻・著者）は**既定で自動更新の
//  対象**で [PR-01]、走査は保護されていないものを毎回まるごと再導出してよい。
//  保護されたスコープにだけ触れない——この 1 つの規則が、旧来の
//  `fileLabel.origin` 3 状態 [RC-04] と `titleOrigin` [RP-11] という
//  2 つの暗黙の保護機構を置き換える（v3 ステージ 6）。
//
import Foundation

/// 保護の単位 [PR-02]。
///
/// 単位は 2 つだけ: **基本情報**と**フィールド**。「ファイル全体の保護」は
/// 別の値ではなく「基本情報 ＋ そのライブラリの全フィールド」が揃った状態を
/// 指す（`coversEverything(fields:)`）——別の値として持つと、フィールドを
/// 1 つ増やしただけで「全体を保護したはずのファイル」の意味が静かに変わる。
public enum ProtectionScope: Sendable, Hashable {
    /// タイトル・シリーズ名・巻数・著者名 [PR-02]。**4 つで 1 かたまり**——
    /// 利用者から見て「この本の基本情報」は 1 つで、タイトルだけ守って
    /// シリーズは上書きする、という状態は説明できない。旧 `titleOrigin` は
    /// 実際にそうなっており、手で直したシリーズ名が次の走査で黙って
    /// 自動値へ戻っていた。
    case basic
    /// ラベルの軸 1 つぶん [PR-02]。保護されたフィールドのラベルは、
    /// 付いているものも付いていないものも走査が動かさない。
    case field(LabelGroupID)
}

extension ProtectionScope {
    /// 永続化とバックアップで使う綴り。**この文字列は DB と JSON の両方に
    /// 出る**ので、変えると移行が要る。
    public var storageKey: String {
        switch self {
        case .basic: "basic"
        case .field(let id): "field:\(id.rawValue)"
        }
    }

    public init?(storageKey: String) {
        if storageKey == Self.basicKey {
            self = .basic
            return
        }
        guard storageKey.hasPrefix(Self.fieldPrefix),
              let raw = Int64(storageKey.dropFirst(Self.fieldPrefix.count))
        else { return nil }
        self = .field(LabelGroupID(rawValue: raw))
    }

    /// 綴りの部品。**JSON バックアップは同じ形式を使うが、`field:` に続く
    /// 数字の意味が違う**——DB は行 ID、JSON はライブラリ内のフィールド番号
    /// [JS-04]。取り違えると別のフィールドを保護するので、翻訳は
    /// `SQLiteBackupRepository` の `exportScopes` / `importScopes` に閉じてある。
    public static let basicKey = "basic"
    public static let fieldPrefix = "field:"

    /// フィールド番号での綴りを組み立てる（JSON 用）。
    public static func portableFieldKey(index: Int) -> String { "\(fieldPrefix)\(index)" }

    /// フィールド番号での綴りを読む（JSON 用）。`basic` は `nil` を返す。
    public static func portableFieldIndex(from key: String) -> Int? {
        guard key.hasPrefix(fieldPrefix) else { return nil }
        return Int(key.dropFirst(fieldPrefix.count))
    }
}

extension Set where Element == ProtectionScope {
    /// 保護されているフィールドの ID。
    public var protectedFields: Set<LabelGroupID> {
        var result: Set<LabelGroupID> = []
        for scope in self {
            if case .field(let id) = scope { result.insert(id) }
        }
        return result
    }

    /// 全体が保護されているか [PR-02][PR-05]。**そのライブラリのフィールド
    /// 一覧を渡す必要がある**——フィールドは増減するので、集合だけを見て
    /// 「全体」は判定できない。
    public func coversEverything(fields: [LabelGroupID]) -> Bool {
        guard contains(.basic) else { return false }
        return fields.allSatisfy { contains(.field($0)) }
    }

    /// ファイル全体の保護 [PR-05]（ワンクリックで付ける側の値）。
    public static func everything(fields: [LabelGroupID]) -> Set<ProtectionScope> {
        var result: Set<ProtectionScope> = [.basic]
        for id in fields { result.insert(.field(id)) }
        return result
    }
}

/// 保護スコープ集合の永続化 [PR-09]。
///
/// DB は `managedFile.protectedScopes` の TEXT 列 1 本に JSON 配列で持つ。
/// **別テーブルにしていない**のは、判定が常にファイル単位だから——
/// `applyParsedFields` も `replaceAutoLabels` も 1 ファイルを扱う関数で、
/// 集合を丸ごと読めば足りる。列 1 本なら `RegenerabilityDeclaring` の
/// 網羅性検査 [MG-23] にも素直に乗る。
public enum ProtectionScopeCoding {
    /// 空集合は空文字ではなく `"[]"`。**列を NOT NULL DEFAULT '[]' にする**
    /// ので、既定値と書き出した値の形が揃う。
    public static let empty = "[]"

    /// **並びは決定的**（綴りの昇順）。同じ集合が毎回同じ文字列になれば、
    /// 意味の無い UPDATE と JSON バックアップの差分が出ない。
    public static func encode(_ scopes: Set<ProtectionScope>) -> String {
        let keys = scopes.map(\.storageKey).sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: keys),
              let text = String(data: data, encoding: .utf8)
        else { return empty }
        return text
    }

    /// 解釈できない要素は**その要素だけ**捨てる。行ごと捨てないのが要点——
    /// 将来スコープの種類が増えた版で書かれた行を古い版が読んでも、分かる
    /// ぶんの保護は効いたままになる（全部失うより害が小さい）。
    public static func decode(_ text: String?) -> Set<ProtectionScope> {
        guard let text, let data = text.data(using: .utf8),
              let keys = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return Set(keys.compactMap(ProtectionScope.init(storageKey:)))
    }
}
