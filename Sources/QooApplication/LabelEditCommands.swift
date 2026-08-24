//
//  ラベルそのものを編集するコマンド [LE-07〜LE-11][LB-05〜LB-07][CO-06]。
//
//  `LibraryCommands.swift` の `SetRatingCommand` / `AssignLabelCommand` に続く
//  「DB 操作の Undo」（ロードマップ上は 2-15）。あちらが**ファイルに付いた値**を
//  書き換えるのに対し、こちらは**ラベルの行そのもの**を書き換える。
//
//  ## 2 つの形がある
//  | 形 | 対象 | 戻し方 |
//  |---|---|---|
//  | 列を書き換えるだけ（改名・色・保管庫・ピン）| 行 ID は変わらない | 変更前の値を持ち、書き戻す |
//  | 行が消える（削除・統合）| 行 ID が消える | `LabelSnapshot` を控え、**同じ ID で**作り直す |
//
//  後者が成り立つのは `label.id` が AUTOINCREMENT で、削除された ID が二度と
//  再利用されないから［実測］。別 ID で作り直すと、ラベルフィルタでチェック中
//  だった選択が黙って外れる。
//
import Foundation
import QooInfrastructure
import QooKit

// MARK: - 列を書き換えるだけのもの

/// 改名 [LB-06][LE-07]。
///
/// 紐づけは行の ID で張られているので、改名しても維持される——「そのラベルを
/// 参照する全ファイルに即座に反映される」[LB-06] は、何もしないことで満たされる。
@MainActor
public final class RenameLabelCommand: Command {
    private let labelID: LabelID
    private let previousName: String
    private let newName: String
    private let services: LibraryServices

    public init(labelID: LabelID, previousName: String, newName: String,
                services: LibraryServices) {
        self.labelID = labelID
        self.previousName = previousName
        self.newName = newName
        self.services = services
    }

    public var displayName: String { "ラベル「\(previousName)」を「\(newName)」に変更" }
    /// **ラベル名は利用者が付けた語なので、そのまま診断ログへ書かない** [LG2-06]
    /// ——絶対パスと違い匿名化の対象にならないため、`Log.redactable(_:)` の印で包む
    /// （包まなければ書き出しバンドルに実名が残る）。
    public var logDescription: String {
        "renameLabel: \(Log.redactable(previousName)) → \(Log.redactable(newName))"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        try await services.renameLabel(labelID, to: newName)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            try await services.renameLabel(labelID, to: previousName)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// ラベル固有色 [LE-10][CO-06]。`nil` はグループ色の継承。
@MainActor
public final class SetLabelColorCommand: Command {
    private let labelID: LabelID
    private let labelName: String
    private let previousHex: String?
    private let newHex: String?
    private let services: LibraryServices

    public init(labelID: LabelID, labelName: String,
                previousHex: String?, newHex: String?, services: LibraryServices) {
        self.labelID = labelID
        self.labelName = labelName
        self.previousHex = previousHex
        self.newHex = newHex
        self.services = services
    }

    public var displayName: String {
        newHex == nil ? "ラベル「\(labelName)」の色を既定に戻す"
                      : "ラベル「\(labelName)」の色を変更"
    }
    public var logDescription: String {
        "setLabelColor(\(newHex ?? "inherit")): \(Log.redactable(labelName))"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        try await services.setLabelColor(labelID, hex: newHex)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            try await services.setLabelColor(labelID, hex: previousHex)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// 保管庫へ移す／戻す [LA-01][LA-08][LE-09]。
///
/// **変更前の状態を 1 件ずつ持つ。** 複数選択でまとめて操作したとき、もともと
/// 保管庫にあったものと無かったものが混ざりうる——一律に戻すと ⌘Z が元と違う
/// 状態を作る（`SetRatingCommand` / `AssignLabelCommand` と同じ判断）。
@MainActor
public final class SetLabelArchivedCommand: Command {
    /// 変更前の状態 1 件ぶん。
    public struct Previous: Sendable, Hashable {
        public let id: LabelID
        public let name: String
        public let isArchived: Bool

        public init(id: LabelID, name: String, isArchived: Bool) {
            self.id = id
            self.name = name
            self.isArchived = isArchived
        }
    }

    private let previous: [Previous]
    private let archived: Bool
    private let services: LibraryServices

    public init(previous: [Previous], archived: Bool, services: LibraryServices) {
        self.previous = previous
        self.archived = archived
        self.services = services
    }

    public var displayName: String {
        let verb = archived ? "保管庫へ移動" : "保管庫から戻す"
        return previous.count == 1
            ? "ラベル「\(previous[0].name)」を\(verb)"
            : "\(previous.count) 件のラベルを\(verb)"
    }
    public var logDescription: String {
        "setLabelArchived(\(archived)): " + previous.map { Log.redactable($0.name) }.joined(separator: ", ")
    }
    public let isUndoable = true

    /// 実際に状態が変わるものだけ。既にその状態のものを含めると、⌘Z で
    /// 「触っていないラベル」まで反転させてしまう。
    private var changing: [Previous] { previous.filter { $0.isArchived != archived } }

    public func execute() async throws -> CommandResult {
        let targets = changing
        guard !targets.isEmpty else { return .success }
        try await services.setLabelArchived(targets.map(\.id), archived)
        return .success
    }

    public func undo() async throws -> UndoResult {
        let targets = changing
        guard !targets.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            try await services.setLabelArchived(targets.map(\.id), !archived)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// ピン留め [LB-03][PN-04]。**ライブラリ単位の永続設定で全ウインドウ共有** [ST-23]。
@MainActor
public final class SetLabelPinnedCommand: Command {
    private let labelID: LabelID
    private let labelName: String
    private let pinned: Bool
    private let services: LibraryServices

    public init(labelID: LabelID, labelName: String, pinned: Bool,
                services: LibraryServices) {
        self.labelID = labelID
        self.labelName = labelName
        self.pinned = pinned
        self.services = services
    }

    public var displayName: String {
        "ラベル「\(labelName)」を\(pinned ? "ピン留め" : "ピン留め解除")"
    }
    public var logDescription: String {
        "setLabelPinned(\(pinned)): \(Log.redactable(labelName))"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        try await services.setLabelPinned(labelID, pinned)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            try await services.setLabelPinned(labelID, !pinned)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

// MARK: - 行が消えるもの

/// 削除 [LE-07][LE-08][LB-05]。
///
/// **写しは `init` ではなく `execute()` の直前に取る。** コマンドを組み立てて
/// から実行するまでの間に他所（スキャン・右ペイン）が紐づけを変えうるので、
/// 作った時点の写しで戻すと ⌘Z が現在と違う状態へ戻す（`RatingEditorModel` で
/// 「書く直前に引き直す」ことにしたのと同じ理由）。
@MainActor
public final class DeleteLabelsCommand: Command {
    private let labelIDs: [LabelID]
    private let labelNames: [String]
    private let services: LibraryServices
    /// `execute()` が控える。`undo()` はこれを戻す。
    private var snapshots: [LabelSnapshot] = []

    public init(labelIDs: [LabelID], labelNames: [String], services: LibraryServices) {
        self.labelIDs = labelIDs
        self.labelNames = labelNames
        self.services = services
    }

    public var displayName: String {
        labelNames.count == 1
            ? "ラベル「\(labelNames[0])」を削除"
            : "\(labelNames.count) 件のラベルを削除"
    }
    public var logDescription: String {
        "deleteLabels: " + labelNames.map { Log.redactable($0) }.joined(separator: ", ")
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        guard !labelIDs.isEmpty else { return .success }
        snapshots = try await services.labelSnapshots(labelIDs)
        try await services.deleteLabels(labelIDs)
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard !snapshots.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            try await services.restoreLabels(snapshots)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// 統合 [LB-07][LE-11]。
///
/// **統合元と統合先の両方を控える。** 統合先は `origin` が書き換わり
/// [LabelOrigin.merging]、統合元にしか無かった紐づけも移ってくるので、
/// 統合元だけ戻しても統合先が統合後のまま残る。
@MainActor
public final class MergeLabelsCommand: Command {
    private let source: LabelID
    private let target: LabelID
    private let sourceName: String
    private let targetName: String
    private let services: LibraryServices
    private var snapshots: [LabelSnapshot] = []

    public init(source: LabelID, sourceName: String,
                target: LabelID, targetName: String, services: LibraryServices) {
        self.source = source
        self.sourceName = sourceName
        self.target = target
        self.targetName = targetName
        self.services = services
    }

    public var displayName: String { "ラベル「\(sourceName)」を「\(targetName)」に統合" }
    public var logDescription: String {
        "mergeLabels: \(Log.redactable(sourceName)) → \(Log.redactable(targetName))"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        snapshots = try await services.labelSnapshots([source, target])
        try await services.mergeLabel(source, into: target)
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard !snapshots.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            // **1 回の `restore` で 2 件とも戻す**——リポジトリが 1 トランザクション
            // で書くので、「統合元は戻ったが統合先は統合後のまま」というどちらでも
            // ない状態が残らない。
            try await services.restoreLabels(snapshots)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}
