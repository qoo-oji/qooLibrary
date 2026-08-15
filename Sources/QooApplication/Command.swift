import Foundation
import QooInfrastructure

/// Undo/Redo 可能な操作の単位 [11章 §11.1、A-03][UD-01]。
///
/// 仕様書は `Command: Sendable` としているが、実際にコマンドを生成・実行・
/// 保持するのは `CommandStack`（`@MainActor`）とそれを呼ぶ SwiftUI 層のみで、
/// 複数の actor をまたいで受け渡す必要が無い。プロトコル自体に `@MainActor`
/// を付けることで、`Sendable`/`@unchecked Sendable` 対応（可変な捕捉状態を
/// 持つ参照型のため本来は面倒になる）を避けつつ同じ安全性を得られるため、
/// この点は意図的に仕様書と異なる実装にしている [設計判断]。
///
/// 仕様書の `CommandContext`（`fileOps`/`repositories`/`history`/
/// `notifications`/`progress` を束ねる）は、フェーズ1には `fileOps` 以外の
/// 実体が無い（`RepositoryBundle`/`OperationHistoryStore`（本実装）/
/// `NotificationRouter`/`ProgressReporter` はいずれも未実装）ため導入しない。
/// 代わりに、このコードベース全体で既に使われている DI パターン
/// （`ArchiveCompressor(fileOps:stagingRoot:)` 等）に合わせ、各コマンドが
/// 自身の `init` で必要な依存（既定は `.shared`）を直接受け取る。
///
/// `affectedFolderIDs`（`LockManager` 用、LK-10）も未実装。`LockManager`
/// （11章 §11.3）はライブラリ／テンポラリフォルダの一括処理を排他制御する
/// ためのもので、対象になる登録フォルダ自体（SwiftData の
/// `Library`/`TemporaryFolder`）がフェーズ1にまだ無く、ロードマップ上も
/// `LK-*` はどのフェーズ1項目にも割り当てられていない。
@MainActor
public protocol Command: AnyObject {
    /// Undo/Redo メニュー・操作履歴に出す説明。「12 件のファイルを移動」[UD-06]
    var displayName: String { get }

    /// 診断ログ用の説明 [LG2-01][LG2-06]。
    ///
    /// **`displayName` と違い、対象を必ず「絶対パス」で表す。** 理由は 2 つ:
    ///
    /// 1. **匿名化の対象になる**。書き出し時のパス匿名化 [LG2-06] が拾えるのは
    ///    絶対パスと `Log.redactable(_:)` の印だけで、`displayName` のように
    ///    `lastPathComponent` を素で埋め込むとファイル名がそのまま書き出し
    ///    バンドルに残ってしまう（1-15 実装後の実機確認で発覚した取りこぼし）。
    /// 2. **診断に必要な情報が増える**。「どのファイルか」だけでなく
    ///    「どこのファイルか」が分かる。同名ファイルが複数の場所にある
    ///    ライブラリでは、名前だけでは事象を再現できない。
    ///
    /// 既定実装は `displayName` を返す（`CompositeCommand` のように、対象を
    /// 単一の URL で表せないコマンド向け）。**対象の URL を持つコマンドは
    /// 必ずオーバーライドすること。**
    var logDescription: String { get }

    /// `false` の場合は `CommandStack.run` がスタックに積まない
    /// （完全削除等、Undo 不可能な操作用）[UD-10]。
    var isUndoable: Bool { get }

    /// 実行が成功したときに鳴らす UI サウンド。`nil`（既定）なら無音
    /// [ユーザー要望、要件定義書には無い]。
    ///
    /// **Finder と同じ構造にしている**: Finder も操作コントローラの仮想メソッドが
    /// SystemSoundID を返し、進捗ビューが消えるとき（＝操作完了時）に鳴らす。
    /// 既定を「無音」にしているのは、名前の変更・新規フォルダのように一瞬で
    /// 終わり結果が画面上ですぐ分かる操作にまで音を付けないため。
    ///
    /// 鳴らすのは `CommandStack` の 1 箇所だけ（`record` と同じ考え方で、
    /// 経路が増えても鳴らし忘れ・二重再生が構造的に起きないようにする）。
    var completionSound: SystemSoundEffect? { get }

    func execute() async throws -> CommandResult
    func undo() async throws -> UndoResult
    /// 多くのコマンドでは `execute()` の再実行と同じ（`undo()` が完全に元の
    /// 状態へ戻すことを前提にできるため）。個別の実装が異なる挙動を必要と
    /// する場合のみオーバーライドする。
    func redo() async throws -> CommandResult
}

extension Command {
    public func redo() async throws -> CommandResult {
        try await execute()
    }

    public var logDescription: String { displayName }

    public var completionSound: SystemSoundEffect? { nil }

    /// `logDescription` を組み立てる共通ヘルパー。
    /// 例: `move: /Volumes/Ext/A.cbz, /Volumes/Ext/B.cbz → /Volumes/Ext/Sub`
    ///
    /// 件数が多いときに 1 行が際限なく伸びないよう、先頭数件で打ち切る
    /// （全件は `FileOperationService` 側が項目ごとに `debug` で残す）。
    static func logDescription(_ operation: String, _ urls: [URL], to destination: URL? = nil) -> String {
        let limit = 5
        var listed = urls.prefix(limit).map { Log.path($0) }.joined(separator: ", ")
        if urls.count > limit {
            listed += " ほか \(urls.count - limit) 件"
        }
        let target = destination.map { " → \(Log.path($0))" } ?? ""
        return "\(operation): \(listed)\(target)"
    }
}

public enum CommandResult: Sendable {
    case success
    case partial(succeeded: Int, failed: [FailedItem])
}

extension PartialTransferFailure {
    /// 途中で止まった一括処理を `CommandResult` に翻訳する [ER-13][ER-14]。
    ///
    /// **例外として投げ直さないことが肝心**。`CommandStack.run` は
    /// `execute()` が投げると Undo スタックへ積まないため、投げ直すと
    /// **実際に動いたファイルを取り消す手段が無くなる**。部分的な成功として
    /// 返せば、スタックにも操作履歴にも載り、`CommandStack` が理由を
    /// ユーザーへ提示する。
    public func commandResult(total: Int) -> CommandResult {
        let remaining = max(total - receipts.count, 1)
        var failed = [FailedItem(item: failedItem.lastPathComponent, reason: underlying.localizedDescription)]
        // 止まった時点で手つかずのまま残った項目があることも伝える
        // （「30 件成功・1 件失敗」だけだと残り 69 件の行方が分からない）。
        if remaining > 1 {
            failed.append(FailedItem(
                item: "ほか \(remaining - 1) 件",
                reason: "先の失敗により処理していません"
            ))
        }
        return .partial(succeeded: receipts.count, failed: failed)
    }
}

public enum UndoResult: Sendable {
    case complete
    case partial(succeeded: Int, failed: [FailedItem])
    case impossible(reason: String)
}

public struct FailedItem: Sendable, Equatable {
    public let item: String
    public let reason: String

    public init(item: String, reason: String) {
        self.item = item
        self.reason = reason
    }
}

/// 複数の `Command` をまとめて 1 つの Undo 単位にする [UD-04]。
public final class CompositeCommand: Command {
    public let children: [any Command]
    private let name: String

    public init(displayName: String, children: [any Command]) {
        self.name = displayName
        self.children = children
    }

    public var displayName: String { name }

    /// 子の `logDescription` を並べる。**`name`（＝`displayName`）は使わない** —
    /// `displayName` はユーザー向けの文言で、`lastPathComponent` を素で
    /// 埋め込んでいることがあり、書き出し時に匿名化されないため [LG2-06]。
    public var logDescription: String {
        "composite[\(children.map(\.logDescription).joined(separator: " | "))]"
    }

    public var isUndoable: Bool { children.allSatisfy(\.isUndoable) }

    /// 子のうち最初に音を持つものを 1 つだけ採用する。複数アーカイブの一括展開
    /// のように子が N 個あっても**鳴るのは 1 回**（Finder も操作 1 回につき
    /// 1 回しか鳴らさない）。子がどれも音を持たなければ無音。
    public var completionSound: SystemSoundEffect? {
        children.lazy.compactMap(\.completionSound).first
    }

    public func execute() async throws -> CommandResult {
        var executed: [any Command] = []
        for child in children {
            do {
                _ = try await child.execute()
            } catch {
                // **中断されたら、すでに実行した子を巻き戻す**［実機検証で発見］。
                // 「〈名前〉に展開」は「フォルダを作る」＋「展開する」の 2 つ。
                // 展開を止めたのに空のフォルダだけが残っていた（しかも
                // `execute()` が投げるので Undo スタックにも積まれず、
                // ユーザーには片付ける手立てが無い）。
                //
                // **巻き戻すのは中断のときだけ。** 失敗（容量不足など）では
                // 巻き戻さない — 5 個中 3 個目で失敗したときに、成功した 2 個
                // まで消えるのは驚きが大きく、部分的な成功をどう見せるかは
                // 別の設計課題（`BatchNotificationSession`、フェーズ2）。
                if CommandStack.isCancellation(error) {
                    for done in executed.reversed() { _ = try? await done.undo() }
                }
                throw error
            }
            executed.append(child)
        }
        return .success
    }

    /// [UD-07] children を逆順に実行する。失敗した子は部分取り消しとして記録する。
    public func undo() async throws -> UndoResult {
        var failedItems: [FailedItem] = []
        var succeededCount = 0
        for child in children.reversed() {
            do {
                switch try await child.undo() {
                case .complete:
                    succeededCount += 1
                case .partial(let succeeded, let failed):
                    succeededCount += succeeded
                    failedItems.append(contentsOf: failed)
                case .impossible(let reason):
                    failedItems.append(FailedItem(item: child.displayName, reason: reason))
                }
            } catch {
                failedItems.append(FailedItem(item: child.displayName, reason: error.localizedDescription))
            }
        }
        return failedItems.isEmpty ? .complete : .partial(succeeded: succeededCount, failed: failedItems)
    }
}
