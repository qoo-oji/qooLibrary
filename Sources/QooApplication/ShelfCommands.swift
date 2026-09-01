//
//  シェルフを編集するコマンド [SH-01〜SH-04][SH-11]。
//
//  `LabelEditCommands.swift` と同じ形の「DB 操作の Undo」。あちらの表の
//  2 つの形がそのまま当てはまる:
//
//  | 形 | 対象 | 戻し方 |
//  |---|---|---|
//  | 列を書き換えるだけ（改名・上書き保存）| 行 ID は変わらない | 変更前の値を持ち、書き戻す |
//  | 行が増える／消える（作成・削除）| 行 ID が動く | 写しを控え、**同じ ID で**作り直す |
//
//  **並び順 [SH-10] はコマンドにしない**——フィールドの並び順 [LF-03] と
//  登録フォルダの並び順 [RG3-33] のどちらも Undo の対象外で、そこへ揃える。
//
//  シェルフ名は利用者が付けた語なので、診断ログへ素で書かない [LG2-06]
//  ——`Log.redactable(_:)` の印で包む（`RenameLabelCommand` と同じ）。
//
import Foundation
import QooInfrastructure
import QooKit

/// 現在の絞り込みを保存する [SH-01]。
@MainActor
public final class CreateShelfCommand: Command {
    private let libraryID: LibraryID
    private let name: String
    private let condition: ShelfCondition
    private let services: LibraryServices
    /// 実行して初めて決まる。`undo()` で消し、`redo()` で**同じ ID へ**戻す。
    private var created: ShelfSummary?

    public init(libraryID: LibraryID, name: String, condition: ShelfCondition,
                services: LibraryServices) {
        self.libraryID = libraryID
        self.name = name
        self.condition = condition
        self.services = services
    }

    public var displayName: String { "シェルフ「\(name)」を保存" }
    public var logDescription: String { "createShelf: \(Log.redactable(name))" }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        if let created {
            // **やり直しは同じ行 ID で作り直す** [SH-11]。別 ID にすると、
            // 取り消しの前後でシェルフの同一性が切れる。
            try await services.restoreShelves([created])
        } else {
            let id = try await services.createShelf(libraryID: libraryID, name: name,
                                                    condition: condition)
            created = try await services.shelfSnapshots([id]).first
        }
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard let created else { return .impossible(reason: "作成した行が分からない") }
        do {
            try await services.deleteShelves([created.id])
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// 改名 [SH-03]。
@MainActor
public final class RenameShelfCommand: Command {
    private let shelfID: ShelfID
    private let previousName: String
    private let newName: String
    private let services: LibraryServices

    public init(shelfID: ShelfID, previousName: String, newName: String,
                services: LibraryServices) {
        self.shelfID = shelfID
        self.previousName = previousName
        self.newName = newName
        self.services = services
    }

    public var displayName: String { "シェルフ「\(previousName)」を「\(newName)」に変更" }
    public var logDescription: String {
        "renameShelf: \(Log.redactable(previousName)) → \(Log.redactable(newName))"
    }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        try await services.renameShelf(shelfID, to: newName)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            try await services.renameShelf(shelfID, to: previousName)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// 上書き保存 [SH-04]。いまの絞り込みで条件だけを差し替える。
@MainActor
public final class UpdateShelfCommand: Command {
    private let shelfID: ShelfID
    private let shelfName: String
    private let previousCondition: ShelfCondition
    private let newCondition: ShelfCondition
    private let services: LibraryServices

    public init(shelfID: ShelfID, shelfName: String,
                previousCondition: ShelfCondition, newCondition: ShelfCondition,
                services: LibraryServices) {
        self.shelfID = shelfID
        self.shelfName = shelfName
        self.previousCondition = previousCondition
        self.newCondition = newCondition
        self.services = services
    }

    public var displayName: String { "シェルフ「\(shelfName)」を現在の絞り込みで更新" }
    public var logDescription: String { "updateShelf: \(Log.redactable(shelfName))" }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        try await services.updateShelfCondition(shelfID, newCondition)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            try await services.updateShelfCondition(shelfID, previousCondition)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// 削除 [SH-02]。**写しを控えて同じ行 ID で戻す** [SH-11]。
@MainActor
public final class DeleteShelfCommand: Command {
    private let shelfID: ShelfID
    private let shelfName: String
    private let services: LibraryServices
    private var snapshot: ShelfSummary?

    public init(shelfID: ShelfID, shelfName: String, services: LibraryServices) {
        self.shelfID = shelfID
        self.shelfName = shelfName
        self.services = services
    }

    public var displayName: String { "シェルフ「\(shelfName)」を削除" }
    public var logDescription: String { "deleteShelf: \(Log.redactable(shelfName))" }
    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        // **写しは実行のたびに取り直す**——やり直しの直前に名前や条件が
        // 変わっていることがある（`SetRatingCommand` が書く直前に引き直すのと
        // 同じ理由）。
        snapshot = try await services.shelfSnapshots([shelfID]).first
        try await services.deleteShelves([shelfID])
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard let snapshot else { return .impossible(reason: "削除前の写しが無い") }
        do {
            try await services.restoreShelves([snapshot])
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}
