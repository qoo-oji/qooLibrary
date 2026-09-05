//
//  DB を書き換えるコマンド [11章 §11.1][UD-01]。
//
//  **このファイルが「DB 操作の Undo」の最初の 1 つ**（ロードマップ上は 2-15）。
//  評価だけを先に作ったのは、`RA-06` が「シリーズ全巻への適用は 1 つの Undo
//  単位」と名指しで要求しているため——要件が Undo を前提にしている以上、
//  後から被せる形にはできない。
//
//  ファイル操作のコマンド（`FileCommands`）と違い `OpReceipt` は関わらない。
//  戻すのに要るのは**変更前の値そのもの**なので、コマンドがそれを持つ。
//
import Foundation
import QooKit

/// 評価を書き換える 1 件ぶん。
public struct RatingTarget: Sendable, Hashable {
    public let id: FileID
    /// 診断ログ用の絶対パス [LG2-01][LG2-06]。**`relativePath` ではなく絶対パス**
    /// ——匿名化が拾えるのは絶対パスと `Log.redactable(_:)` の印だけで、
    /// 相対パスを素で書くとファイル名が書き出しバンドルに残る。
    public let url: URL
    /// 変更前の星。`undo()` はこれを 1 件ずつ書き戻す。
    public let previousStars: Int

    public init(id: FileID, url: URL, previousStars: Int) {
        self.id = id
        self.url = url
        self.previousStars = previousStars
    }
}

/// 星を設定・解除する [RA-01][RA-02][RA-04][RA-06]。
///
/// ## 単発も一括も同じ経路を通す
/// 1 件だけの星付けと「シリーズ全巻に適用」[RA-04] は、対象の件数が違うだけで
/// 同じ操作である。別々のコマンドにすると、片方だけ直して取り残す形
/// （1-12 のアプリ関連付けで実際に踏んだ）を新しく作ることになる。
///
/// ## 変更前の値は 1 件ずつ持つ
/// 「全巻に適用」の対象は、もともとの評価がばらばらでありうる。`undo()` で
/// 一律に 0 へ戻すと**元の評価を破壊する**——⌘Z で戻したつもりが、実際には
/// 別の値になっている、という気づきにくい壊れ方になる。
@MainActor
public final class SetRatingCommand: Command {
    private let targets: [RatingTarget]
    private let stars: Int
    private let subjectName: String
    private let seriesName: String?
    private let services: LibraryServices

    /// - Parameters:
    ///   - subjectName: 単発のときに `displayName` へ出す名前（表示のみ）。
    ///   - seriesName: 「全巻に適用」のときのシリーズ名。単発なら `nil`。
    public init(targets: [RatingTarget], stars: Int, subjectName: String,
                seriesName: String? = nil, services: LibraryServices) {
        self.targets = targets
        self.stars = max(0, min(5, stars))
        self.subjectName = subjectName
        self.seriesName = seriesName
        self.services = services
    }

    public var displayName: String {
        let value = stars == 0 ? "評価を解除" : "評価を★\(stars)に設定"
        if let seriesName {
            return "「\(seriesName)」\(targets.count) 冊の\(value)"
        }
        return "「\(subjectName)」の\(value)"
    }

    public var logDescription: String {
        Self.logDescription("setRating(\(stars))", targets.map(\.url))
    }

    /// 既定実装は `logDescription` の先頭 5 件しか拾えない [OH-01]。
    /// シリーズ全巻への適用 [RA-04] は 1 回で何十冊も動く。
    public var logTargets: [String] { targets.map(\.url.path) }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        guard !targets.isEmpty else { return .success }
        try await services.setRating(stars, ids: targets.map(\.id))
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard !targets.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        // 変更前の値でまとめて書き戻す。星は 0〜5 の 6 通りしか無いので、
        // 何件あっても書き込みは最大 6 回で済む。
        let grouped = Dictionary(grouping: targets, by: \.previousStars)
        var restored = 0
        for (previous, group) in grouped {
            do {
                try await services.setRating(previous, ids: group.map(\.id))
                restored += group.count
            } catch {
                // **1 つのトランザクションではない**ので、途中で失敗したら
                // どこまで戻せたかを伝える [ER-13]。`.impossible` と答えると
                // 「1 件も戻っていない」と読まれる。
                return restored == 0
                    ? .impossible(reason: error.localizedDescription)
                    : .partial(succeeded: restored,
                               failed: [FailedItem(item: "\(group.count) 件",
                                                   reason: error.localizedDescription)])
            }
        }
        return .complete
    }
}

/// ラベルの付与・除去 [RL-01][RL-03][RL-07][RP-02]。
///
/// ## `SetRatingCommand` と同じ形にしてある
/// 単一選択の付け外しと複数選択の一括 [RP-02] は、対象の件数が違うだけの同じ
/// 操作である。別々のコマンドにすると、片方だけ直して取り残す形を新しく作る。
///
/// ## 付け外しは、そのフィールドの保護を同時に立てる [PR-03]
/// 手で触ったフィールドは以後の自動更新から守られる。**紐づけと保護は同じ
/// トランザクションで書く**（`applyAssignments` が両方を受け取る）——別々に
/// 呼ぶと「ラベルは変わったが保護が付いていない」状態があり得て、次の走査で
/// 手で付けたラベルが黙って消える。
///
/// ## 変更前の状態は 1 件ずつ持つ
/// 付いていたか／いなかったか、どのスコープが保護されていたかはファイルごとに
/// 違う。`undo()` で一律に戻すと**元の状態を破壊する**（評価で同じ判断を
/// している [RA-06]）。
@MainActor
public final class AssignLabelCommand: Command {
    /// 変更前の状態 1 件ぶん。
    public struct Previous: Sendable, Hashable {
        public let fileID: FileID
        public let url: URL
        /// そのラベルが付いていたか。
        public let wasAssigned: Bool
        /// 変更前の保護スコープ [PR-03]。**⌘Z はここへちょうど戻す**——
        /// 一律に「保護なし」へ戻すと、元から保護されていた他のフィールドまで
        /// 落ちる。
        public let protectedScopes: Set<ProtectionScope>

        public init(fileID: FileID, url: URL, wasAssigned: Bool,
                    protectedScopes: Set<ProtectionScope>) {
            self.fileID = fileID
            self.url = url
            self.wasAssigned = wasAssigned
            self.protectedScopes = protectedScopes
        }
    }

    private let labelID: LabelID
    /// そのラベルが属するフィールド [PR-02]。保護の単位。
    private let fieldID: FieldID
    private let previous: [Previous]
    private let assigning: Bool
    private let labelName: String
    private let subjectName: String
    private let services: LibraryServices

    /// - Parameters:
    ///   - assigning: 付けるなら `true`、外すなら `false`。
    ///   - subjectName: 表示に使う対象の呼び名（単一ならファイル名、複数なら「N 項目」）。
    public init(labelID: LabelID, fieldID: FieldID, labelName: String,
                previous: [Previous], assigning: Bool, subjectName: String,
                services: LibraryServices) {
        self.labelID = labelID
        self.fieldID = fieldID
        self.labelName = labelName
        self.previous = previous
        self.assigning = assigning
        self.subjectName = subjectName
        self.services = services
    }

    public var displayName: String {
        "「\(subjectName)」のラベル「\(labelName)」\(assigning ? "を付与" : "を除去")"
    }

    public var logDescription: String {
        Self.logDescription("\(assigning ? "assignLabel" : "unassignLabel")",
                            previous.map(\.url))
    }

    /// 既定実装は先頭 5 件しか拾えない [OH-01]。複数選択の一括付与 [RP-02] は
    /// 1 回で何十件も動く。
    public var logTargets: [String] { previous.map(\.url.path) }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        guard !previous.isEmpty else { return .success }
        var scopes: [FileID: Set<ProtectionScope>] = [:]
        for item in previous {
            scopes[item.fileID] = item.protectedScopes.union([.field(fieldID)])
        }
        try await services.applyLabelAssignments(
            labelID: labelID,
            previous.map { LabelAssignmentChange(fileID: $0.fileID, isAssigned: assigning) },
            protectedScopes: scopes)
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard !previous.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            // **1 トランザクションで書き戻す**ので、途中まで戻った状態は残らない
            // ——`SetRatingCommand` が `.partial` を返しうるのは、星の値ごとに
            // 分けて書くため。こちらは 1 回の呼び出しで済む。
            var scopes: [FileID: Set<ProtectionScope>] = [:]
            for item in previous { scopes[item.fileID] = item.protectedScopes }
            try await services.applyLabelAssignments(
                labelID: labelID,
                previous.map { LabelAssignmentChange(fileID: $0.fileID,
                                                     isAssigned: $0.wasAssigned) },
                protectedScopes: scopes)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }

    /// トグル 1 回ぶんのコマンドを組み立てる [RL3-03]。
    ///
    /// インスペクタ（`LabelEditorModel`）と中央ペインのメニュー（`LabelMenuModel`）の
    /// **両方がここを通る**——変更前の拾い方・no-op の判定を 2 箇所に書くと、
    /// 片方だけ直して取り残す（このリポジトリで繰り返し起きている形）。
    ///
    /// **「既にその状態」でも、保護が付いていなければ変化がある** [PR-03]。
    /// 付いているラベルをもう一度付ける操作は、そのフィールドを守る意思表示
    /// として意味を持つ。
    ///
    /// - Returns: 何も変わらないなら `nil`（Undo スタックを汚さない）。
    public static func toggling(
        labelID: LabelID, fieldID: FieldID, labelName: String,
        files: [(id: FileID, url: URL)],
        assignments: [FileID: Set<LabelID>],
        protectedScopes: [FileID: Set<ProtectionScope>],
        assigning: Bool, subjectName: String, services: LibraryServices
    ) -> AssignLabelCommand? {
        let previous = files.map { file in
            Previous(fileID: file.id, url: file.url,
                     wasAssigned: assignments[file.id]?.contains(labelID) ?? false,
                     protectedScopes: protectedScopes[file.id] ?? [])
        }
        guard previous.contains(where: {
            $0.wasAssigned != assigning || !$0.protectedScopes.contains(.field(fieldID))
        }) else { return nil }
        return AssignLabelCommand(labelID: labelID, fieldID: fieldID, labelName: labelName,
                                  previous: previous, assigning: assigning,
                                  subjectName: subjectName, services: services)
    }
}

/// タイトル・シリーズ名・巻数・著者を書き換える [RP-10][RP-11][RP-12]。
///
/// ## 手動編集と「ファイル名から再取得」を 1 つのコマンドで扱う
/// 前者は基本情報のどれか 1 つ、後者は 4 つとも——**書き換える列の数が違う
/// だけの同じ操作**である。`SetRatingCommand` を単発と「全巻に適用」で
/// 共有しているのと同じ理由で、別々のコマンドにすると片方だけ直して取り残す
/// 形を新しく作ることになる。
///
/// ## 編集は基本情報スコープを保護し、再取得は解除する [PR-03][PR-04]
/// **値と保護は同じトランザクションで書く**（`setFields` が両方を受け取る）
/// ——別々に呼ぶと「値は変わったが保護が付いていない」状態があり得て、
/// 次の走査で手で直した値が黙って自動値へ戻る。
///
/// ## 変更前は「値一式 ＋ 保護」で持つ
/// `undo()` は前の値と前の保護をそのまま書き戻す。保護を戻し忘れると、
/// **次の再スキャンで手動編集が消える**——しかも取り消した直後には正しく
/// 見えるので気づけない。
@MainActor
public final class SetFileFieldsCommand: Command {
    public enum Kind: Sendable {
        /// 右ペインで基本情報を打ち替えた [RP-10][RP-13][RP-14]。
        /// **どれを打ったかは表示にしか使わない**——保護の単位は基本情報
        /// ひとまとめ [PR-02] なので、3 つとも同じスコープを立てる。
        case editTitle, editSeriesName, editVolume
        /// 「ファイル名から再取得」[RP-12] ＝ 保護の解除 [PR-04]。
        case rederive
    }

    private let fileID: FileID
    private let url: URL
    private let previous: FileFieldEdit
    private let next: FileFieldEdit
    private let previousScopes: Set<ProtectionScope>
    private let subjectName: String
    private let kind: Kind
    private let services: LibraryServices

    public init(fileID: FileID, url: URL, previous: FileFieldEdit, next: FileFieldEdit,
                previousScopes: Set<ProtectionScope>,
                subjectName: String, kind: Kind, services: LibraryServices) {
        self.fileID = fileID
        self.url = url
        self.previous = previous
        self.next = next
        self.previousScopes = previousScopes
        self.subjectName = subjectName
        self.kind = kind
        self.services = services
    }

    /// 書き込んだ後の保護スコープ [PR-03][PR-04]。
    private var nextScopes: Set<ProtectionScope> {
        switch kind {
        case .editTitle, .editSeriesName, .editVolume: previousScopes.union([.basic])
        case .rederive: previousScopes.subtracting([.basic])
        }
    }

    public var displayName: String {
        switch kind {
        case .editTitle: "「\(subjectName)」のタイトルを変更"
        case .editSeriesName: "「\(subjectName)」のシリーズ名を変更"
        case .editVolume: "「\(subjectName)」の巻数を変更"
        case .rederive: "「\(subjectName)」をファイル名から再取得"
        }
    }

    public var logDescription: String {
        Self.logDescription(kind == .rederive ? "rederiveFields" : "setFields", [url])
    }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        try await services.setFileFields(next, id: fileID, protectedScopes: nextScopes)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            try await services.setFileFields(previous, id: fileID,
                                             protectedScopes: previousScopes)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// カバー画像の割り当てを書き換える [CV-02][CV-07]。
///
/// **複製そのものは消さない。** 差し替えも「既定に戻す」も ⌘Z で戻せる以上、
/// その場で複製を消すと**取り消した先に実体が無い**状態を作る。参照されなく
/// なった複製は起動時に掃除される（`LibraryServices.purgeUnreferencedUserCovers`）。
@MainActor
public final class SetCoverCommand: Command {
    public enum Kind: Sendable {
        /// 好きな画像に差し替えた [CV-02][CV-03][CV-04][CV-05]。
        case replace
        /// 自動抽出へ戻した [CV-07]。
        case revert
    }

    private let fileID: FileID
    private let url: URL
    private let previous: CoverAssignment
    private let next: CoverAssignment
    private let subjectName: String
    private let kind: Kind
    private let services: LibraryServices

    public init(fileID: FileID, url: URL, previous: CoverAssignment, next: CoverAssignment,
                subjectName: String, kind: Kind, services: LibraryServices) {
        self.fileID = fileID
        self.url = url
        self.previous = previous
        self.next = next
        self.subjectName = subjectName
        self.kind = kind
        self.services = services
    }

    public var displayName: String {
        switch kind {
        case .replace: "「\(subjectName)」のカバー画像を変更"
        case .revert: "「\(subjectName)」のカバー画像を既定に戻す"
        }
    }

    public var logDescription: String {
        Self.logDescription(kind == .replace ? "setCover" : "revertCover", [url])
    }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        try await services.setCover(next, id: fileID)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            try await services.setCover(previous, id: fileID)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}
