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
/// ## 変更前の状態は 1 件ずつ持つ
/// 同じラベルでも、あるファイルでは `auto`、別のファイルでは `manual`、
/// また別では `manuallyRemoved` の印が付いている——という状態がふつうにある。
/// `undo()` で一律に消すと**元の状態を破壊する**（評価で同じ判断をしている
/// [RA-06]）。`nil`（行が無かった）も 3 種目の状態として区別する。
///
/// ## 外すときは常に `manuallyRemoved` を立てる［ユーザー判断］
/// `RC-04` は自動ラベルについて定めているが、**利用者から見れば origin の違いは
/// 画面上の小さな印だけ**で、「外したのに再スキャンで戻ってくる」の驚きは
/// どちらでも変わらない。外す操作を「このファイルにこのラベルは不要」という
/// 意思表示として扱い、付け直せば印は消える（`assign` が origin を上書きする）。
@MainActor
public final class AssignLabelCommand: Command {
    /// 変更前の状態 1 件ぶん。`origin` が `nil` は「紐づけの行が無かった」。
    public struct Previous: Sendable, Hashable {
        public let fileID: FileID
        public let url: URL
        public let origin: LabelOrigin?

        public init(fileID: FileID, url: URL, origin: LabelOrigin?) {
            self.fileID = fileID
            self.url = url
            self.origin = origin
        }
    }

    private let labelID: LabelID
    private let previous: [Previous]
    /// 付けるなら `.manual`、外すなら `.manuallyRemoved`［ユーザー判断］。
    private let newOrigin: LabelOrigin
    private let labelName: String
    private let subjectName: String
    private let services: LibraryServices

    /// - Parameters:
    ///   - assigning: 付けるなら `true`、外すなら `false`。
    ///   - subjectName: 表示に使う対象の呼び名（単一ならファイル名、複数なら「N 項目」）。
    public init(labelID: LabelID, labelName: String, previous: [Previous],
                assigning: Bool, subjectName: String, services: LibraryServices) {
        self.labelID = labelID
        self.labelName = labelName
        self.previous = previous
        self.newOrigin = assigning ? .manual : .manuallyRemoved
        self.subjectName = subjectName
        self.services = services
    }

    public var displayName: String {
        let verb = newOrigin == .manual ? "を付与" : "を除去"
        return "「\(subjectName)」のラベル「\(labelName)」\(verb)"
    }

    public var logDescription: String {
        Self.logDescription("\(newOrigin == .manual ? "assignLabel" : "unassignLabel")",
                            previous.map(\.url))
    }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        guard !previous.isEmpty else { return .success }
        try await services.applyLabelAssignments(labelID: labelID, previous.map {
            LabelAssignmentChange(fileID: $0.fileID, origin: newOrigin)
        })
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard !previous.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            // **1 トランザクションで書き戻す**ので、途中まで戻った状態は残らない
            // ——`SetRatingCommand` が `.partial` を返しうるのは、星の値ごとに
            // 分けて書くため。こちらは 1 回の呼び出しで済む。
            try await services.applyLabelAssignments(labelID: labelID, previous.map {
                LabelAssignmentChange(fileID: $0.fileID, origin: $0.origin)
            })
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// タイトル・シリーズ名・巻数・著者を書き換える [RP-10][RP-11][RP-12]。
///
/// ## 手動編集と「ファイル名から再取得」を 1 つのコマンドで扱う
/// 前者は `title`/`titleOrigin` だけ、後者はそこにシリーズ名・巻数・著者が
/// 加わる——**書き換える列の数が違うだけの同じ操作**である。`SetRatingCommand`
/// を単発と「全巻に適用」で共有しているのと同じ理由で、別々のコマンドにすると
/// 片方だけ直して取り残す形を新しく作ることになる。
///
/// ## 変更前は「値一式」で持つ
/// 再取得は `titleOrigin` を `.manual` から `.auto` へ落とすので、`undo()` で
/// 値だけ戻して origin を戻し忘れると、**次の再スキャンで手動編集が消える**
/// ——しかも取り消した直後には正しく見えるので気づけない。前後を同じ型
/// （`FileFieldEdit`）で持てば、書き戻しは「前の値をそのまま書く」で済む。
@MainActor
public final class SetFileFieldsCommand: Command {
    public enum Kind: Sendable {
        /// 右ペインでタイトルを打ち替えた [RP-10]。
        case editTitle
        /// 「ファイル名から再取得」[RP-12]。
        case rederive
    }

    private let fileID: FileID
    private let url: URL
    private let previous: FileFieldEdit
    private let next: FileFieldEdit
    private let subjectName: String
    private let kind: Kind
    private let services: LibraryServices

    public init(fileID: FileID, url: URL, previous: FileFieldEdit, next: FileFieldEdit,
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
        case .editTitle: "「\(subjectName)」のタイトルを変更"
        case .rederive: "「\(subjectName)」をファイル名から再取得"
        }
    }

    public var logDescription: String {
        Self.logDescription(kind == .editTitle ? "setTitle" : "rederiveFields", [url])
    }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        try await services.setFileFields(next, id: fileID)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            try await services.setFileFields(previous, id: fileID)
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
