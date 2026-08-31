//
//  メタデータの保護の付け外し [PR-04][PR-05]。
//
import Foundation
import QooKit

/// 保護スコープを付ける・外す [PR-05]。
///
/// ## 解除は「手動編集の破棄」である [PR-04]
/// 外したスコープはその場で自動値へ戻る。**⌘Z は値も戻す**——保護だけ戻して
/// 値を戻さないと、取り消した直後は正しく見えるのに手で直した内容が消えた
/// ままになる（`SetFileFieldsCommand` の「変更前は値一式で持つ」と同じ理由）。
///
/// ## 変更前は 1 件ずつ持つ
/// ファイルごとに保護の集合も手動値も違う。一律に戻すと元の状態を壊す
/// [RA-06 と同じ判断]。
@MainActor
public final class SetProtectionCommand: Command {
    /// 変更前の状態 1 件ぶん。
    public struct Previous: Sendable {
        public let fileID: FileID
        public let url: URL
        public let scopes: Set<ProtectionScope>
        /// 解除で失われる基本情報。⌘Z がここへ戻す。
        public let fields: FileFieldEdit
        /// 解除で失われるラベル。同上。
        public let labels: Set<LabelID>

        public init(fileID: FileID, url: URL, scopes: Set<ProtectionScope>,
                    fields: FileFieldEdit, labels: Set<LabelID>) {
            self.fileID = fileID
            self.url = url
            self.scopes = scopes
            self.fields = fields
            self.labels = labels
        }
    }

    public enum Mode: Sendable {
        /// ファイル全体 [PR-02][PR-05]。**フィールドの一覧を渡す**——
        /// 「全体」は別の値ではなく「基本情報 ＋ そのライブラリの全フィールド」
        /// が揃った状態なので、一覧なしには表現できない。
        case all(fields: [LabelGroupID], protected: Bool)
        /// 1 つのスコープ。
        case scope(ProtectionScope, protected: Bool)

        var isProtecting: Bool {
            switch self {
            case .all(_, let protected), .scope(_, let protected): protected
            }
        }
    }

    private let targets: [Previous]
    private let mode: Mode
    private let libraryID: LibraryID
    private let subjectName: String
    private let services: LibraryServices

    public init(targets: [Previous], mode: Mode, libraryID: LibraryID,
                subjectName: String, services: LibraryServices) {
        self.targets = targets
        self.mode = mode
        self.libraryID = libraryID
        self.subjectName = subjectName
        self.services = services
    }

    private func nextScopes(for current: Set<ProtectionScope>) -> Set<ProtectionScope> {
        switch mode {
        case .all(let fields, let protected):
            protected ? Set<ProtectionScope>.everything(fields: fields) : []
        case .scope(let scope, let protected):
            protected ? current.union([scope]) : current.subtracting([scope])
        }
    }

    public var displayName: String {
        "「\(subjectName)」のメタデータ\(mode.isProtecting ? "を保護" : "の保護を解除")"
    }

    public var logDescription: String {
        Self.logDescription(mode.isProtecting ? "protectMetadata" : "unprotectMetadata",
                            targets.map(\.url))
    }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        guard !targets.isEmpty else { return .success }
        var scopes: [FileID: Set<ProtectionScope>] = [:]
        var released: [FileID] = []
        for item in targets {
            let next = nextScopes(for: item.scopes)
            scopes[item.fileID] = next
            // **解除されたスコープがあるものだけ**導き直す。付けただけの
            // ファイルまで走らせると、無関係な行に書き込みが発生する。
            if !item.scopes.subtracting(next).isEmpty { released.append(item.fileID) }
        }
        try await services.setProtectedScopes(scopes)
        if !released.isEmpty {
            try await services.reapplyAutomaticMetadata(ids: released, libraryID: libraryID)
        }
        return .success
    }

    public func undo() async throws -> UndoResult {
        guard !targets.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        do {
            for item in targets {
                // **保護と値を一緒に書き戻す**（`setFields` が両方を受ける）。
                try await services.setFileFields(item.fields, id: item.fileID,
                                                 protectedScopes: item.scopes)
                try await services.setFileLabels(fileID: item.fileID, labelIDs: item.labels)
            }
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }

    /// 変化があるときだけコマンドを作る（Undo スタックを汚さない）。
    public static func making(targets: [Previous], mode: Mode, libraryID: LibraryID,
                              subjectName: String,
                              services: LibraryServices) -> SetProtectionCommand? {
        let command = SetProtectionCommand(targets: targets, mode: mode, libraryID: libraryID,
                                           subjectName: subjectName, services: services)
        guard targets.contains(where: { command.nextScopes(for: $0.scopes) != $0.scopes })
        else { return nil }
        return command
    }

    /// ファイル全体の保護を切り替える 1 回ぶんを組み立てる [PR-05]。
    ///
    /// **インスペクタ（`ProtectionEditorModel`）と中央ペインのメニュー
    /// （`LabelMenuModel`）の両方がここを通る**——控えの取り方を 2 箇所に
    /// 書くと、片方だけ直して取り残す（`AssignLabelCommand.toggling` と
    /// 同じ理由 [RL3-03]）。
    ///
    /// **解除するときは、戻すための値とラベルを先に控える** [PR-04]。保護を
    /// 外すとその場で自動値へ導き直されるので、控えないと ⌘Z が手で直した
    /// 内容を戻せない。逆に付けるときは何も失われないので読み直さない
    /// ——複数選択のたびに 2 本の問い合わせが増えるのは高い。
    public static func togglingAll(
        files: [(id: FileID, url: URL)],
        scopes: [FileID: Set<ProtectionScope>],
        fields: [LabelGroupID],
        libraryID: LibraryID, subjectName: String,
        services: LibraryServices
    ) async throws -> SetProtectionCommand? {
        let protecting = !files.allSatisfy {
            (scopes[$0.id] ?? []).coversEverything(fields: fields)
        }
        var targets: [Previous] = []
        for file in files {
            let current = scopes[file.id] ?? []
            if protecting {
                targets.append(Previous(fileID: file.id, url: file.url, scopes: current,
                                        fields: FileFieldEdit(title: nil, seriesName: nil,
                                                              volume: .none, authorName: nil),
                                        labels: []))
            } else {
                let row = try await services.fileRow(id: file.id)
                let labels = try await services.fileLabelIDs(fileID: file.id)
                targets.append(Previous(
                    fileID: file.id, url: file.url, scopes: current,
                    fields: row.map(FileFieldEdit.init)
                        ?? FileFieldEdit(title: nil, seriesName: nil,
                                         volume: .none, authorName: nil),
                    labels: Set(labels)))
            }
        }
        return making(targets: targets,
                      mode: .all(fields: fields, protected: protecting),
                      libraryID: libraryID, subjectName: subjectName, services: services)
    }
}
