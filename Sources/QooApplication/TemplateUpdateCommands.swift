//
//  プリセット改訂の差分を適用するコマンド [LT-14][LT-16]。
//
//  **適用は 1 つの Undo 単位** [LT-16]。設定の書き換えは `updateSettings` が
//  付随テーブルごと入れ替えるので、取り消しは**適用前の草案をそのまま
//  書き戻す**だけで済む——`LabelEditCommands` の表でいう「列を書き換える
//  だけ」の形にあたる。
//
//  ## base も一緒に動かす
//  適用したら「この改訂は判断済み」として base を最新へ進める [LT-16]。
//  進めないと同じ差分を毎回見せることになり、LT-12 の通知が永久に消えない。
//  取り消しでは base も戻す——**片方だけ戻すと、次に開いたときに
//  「適用したはずの項目がまた差分に出る」か「戻したのに出ない」のどちらかに
//  なる**（どちらの向きでも利用者には理由が読めない）。
//
//  ## フィールドの削除は差分に載らない
//  載せられない理由は `TemplateDiff` の型コメント——`updateSettings` が
//  ラベルごと連鎖削除し、書き戻しても新しい行 ID の空フィールドが復活する
//  だけなので、**このコマンドの「1 つの Undo 単位」を満たせない**。
//
import Foundation
import QooInfrastructure
import QooKit

/// 選んだ差分項目を適用する [LT-14][LT-16]。
@MainActor
public final class ApplyTemplateDiffCommand: Command {
    private let libraryID: LibraryID
    private let libraryName: String
    private let items: [TemplateDiff.Item]
    private let advancedBase: LibraryTypeTemplate
    private let services: LibraryServices

    /// 適用前の状態。**執行時に読む**——組み立て時に読むと、ダイアログを
    /// 開いている間に設定が変わった場合に古い草案へ戻してしまう
    /// （`RatingEditorModel` で実際に踏んだ形）。
    private var previousDraft: LibrarySettingsDraft?
    private var previousBase: LibraryTypeTemplate?

    public init(libraryID: LibraryID, libraryName: String,
                items: [TemplateDiff.Item], advancedBase: LibraryTypeTemplate,
                services: LibraryServices)
    {
        self.libraryID = libraryID
        self.libraryName = libraryName
        self.items = items
        self.advancedBase = advancedBase
        self.services = services
    }

    public var displayName: String {
        items.isEmpty
            ? "「\(libraryName)」のテンプレート改訂を確認済みにする"
            : "「\(libraryName)」にテンプレートの変更 \(items.count) 件を適用"
    }

    public var logDescription: String {
        "applyTemplateDiff: \(Log.redactable(libraryName)) 件数=\(items.count) "
        + "→ v\(advancedBase.version)"
    }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        let before = try await services.settingsDraft(libraryID: libraryID)
        guard let before else {
            throw TemplateUpdateError.settingsUnavailable
        }
        if previousDraft == nil { previousDraft = before }
        if previousBase == nil {
            previousBase = try await services.registeredTemplate(libraryID: libraryID)
        }
        let applied = TemplateDiff.applying(items, to: before)
        if applied != before {
            try await services.updateSettings(applied, libraryID: libraryID)
        }
        try await services.setRegisteredTemplate(advancedBase, libraryID: libraryID)
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard let previousDraft else { return .impossible(reason: "適用前の設定が分からない") }
        do {
            if let current = try await services.settingsDraft(libraryID: libraryID),
               current != previousDraft {
                try await services.updateSettings(previousDraft, libraryID: libraryID)
            }
            try await services.setRegisteredTemplate(previousBase, libraryID: libraryID)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}

/// **文言は日本語のリテラル。** `QooApplication` には文字列カタログが無く
/// （`Command.displayName` も同じ扱い）、ここだけ英語にすると 1 行だけ
/// 英語になってかえって読めない。ローカライズは既存の負債として、
/// `displayName` と一緒に片付けること。
public enum TemplateUpdateError: Error, LocalizedError, Equatable {
    case settingsUnavailable

    public var errorDescription: String? {
        switch self {
        case .settingsUnavailable: "ライブラリの設定を読み取れませんでした。"
        }
    }
}
