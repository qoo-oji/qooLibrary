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
