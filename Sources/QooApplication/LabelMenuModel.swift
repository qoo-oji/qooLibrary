//
//  中央ペインのコンテキストメニューでのラベル付け外し [RL3-01〜RL3-03]。
//
//  メニューは遅延構築され、**構築後の非同期更新は反映されない**（`OpenWithMenu`
//  で実測済みの制約）。そのためメニューが必要とするもの——フィールドとラベルの
//  一覧・表示中のファイルの紐づけ——を**事前に**読み込み、メニュー構築時は
//  同期の問い合わせだけで組み立てられるようにする。フォルダ表示モードの
//  対応付けは `BookFolderIndex` と同じ「名前で DB を引く」形。
//
//  `qooLibraryApp` ではなく `QooApplication` に置く（`LabelEditorModel` と同じ
//  理由——三状態の畳み込み・アーカイブ済みの出し分け・対象の解決を自動テストで
//  固定するため）。SwiftUI には依存しない。
//
import Foundation
import Observation
import QooKit

/// 中央ペインのラベルメニューが 1 ウインドウにつき 1 つ持つ事前読み込み。
@MainActor
@Observable
public final class LabelMenuModel {
    /// メニューの対象 1 件。`url` は診断ログの匿名化 [LG2-06] と表示名にだけ使う。
    public struct Target: Sendable, Equatable {
        public let id: FileID
        public let url: URL

        public init(id: FileID, url: URL) {
            self.id = id
            self.url = url
        }
    }

    /// 全フィールド（表示順）。空のフィールドを出すかどうかは
    /// `menuLabels(in:for:)` の結果が決める——アーカイブ済みラベルの出し分けが
    /// 対象に依存するので、ここでは絞れない。
    public private(set) var groups: [LabelGroupSummary] = []
    private var labelsByGroup: [LabelGroupID: [LabelSummary]] = [:]
    /// フォルダ表示モード用: 現在フォルダ直下の「ファイル名 → 行 ID」[RL3-01]。
    private var fileIDsByName: [String: FileID] = [:]
    /// 表示中の行の紐づけ。チェック状態の出どころで、トグル直後は
    /// ここを先に書き換えて画面へ即座に反映する（`.task` の読み直しは後から届く）。
    private var assignmentsByFile: [FileID: [LabelID: LabelOrigin]] = [:]
    private var services: LibraryServices?
    /// 古い結果を捨てるための世代（`BookFolderIndex` と同じ形）。
    private var generation = 0

    private let commands: CommandStack

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 読み込み

    /// 読み込む。
    ///
    /// - Parameters:
    ///   - library: `nil`（ボリューム経由・ライブラリ機能が無効・DB 未準備）なら
    ///     空にする [LF-01 と同じ判断]。
    ///   - relativePath: フォルダ表示モードでの現在フォルダ。
    ///   - libraryRows: ライブラリ表示モードで読み込み済みの行。**非空なら
    ///     こちらを対象にし、名前の対応表は作らない**——あちらの行は
    ///     `FolderEntry.libraryRow` から直接引ける。
    public func load(library: LibrarySummary?, relativePath: String?,
                     libraryRows: [FileRow], services: LibraryServices) async {
        generation &+= 1
        let mine = generation
        self.services = services
        guard let library, services.isReady else {
            clearContent()
            return
        }
        do {
            let loadedGroups = try await services.labelGroups(libraryID: library.id)
            var loadedLabels: [LabelGroupID: [LabelSummary]] = [:]
            for group in loadedGroups {
                // アーカイブ済みも読む——付与済みなら出す必要がある [RL-05] ので、
                // 読んでから対象ごとに出し分ける（`LabelEditorModel` と同じ）。
                loadedLabels[group.id] = try await services.labels(groupID: group.id,
                                                                   includeArchived: true)
            }
            var byName: [String: FileID] = [:]
            let ids: [FileID]
            if libraryRows.isEmpty {
                guard let relativePath else {
                    clearContent()
                    return
                }
                byName = try await services.fileIDsByChildName(libraryID: library.id,
                                                               relativePath: relativePath)
                ids = Array(byName.values)
            } else {
                ids = libraryRows.map(\.id)
            }
            let assignments = try await services.labelAssignments(fileIDs: ids)
            guard mine == generation else { return }
            groups = loadedGroups
            labelsByGroup = loadedLabels
            fileIDsByName = byName
            assignmentsByFile = assignments
        } catch {
            guard mine == generation else { return }
            // **取り消しは失敗ではない**（他のモデルと同じ扱い）。
            guard !CommandStack.isCancellation(error) else { return }
            // 引けなかったときはメニューを出さない。**出さないのが安全側**——
            // 古い紐づけでチェック印を出すと、トグルの向きが逆になりうる。
            clearContent()
        }
    }

    public func clear() {
        generation &+= 1
        clearContent()
    }

    private func clearContent() {
        groups = []
        labelsByGroup = [:]
        fileIDsByName = [:]
        assignmentsByFile = [:]
    }

    // MARK: - 問い合わせ（メニュー構築時。すべて同期）

    /// フォルダ表示モードで、直下の項目名から行 ID を引く [RL3-01]。
    ///
    /// 通常フォルダ・対象拡張子外・検索で出た深い階層の項目（対応表に無い）は
    /// `nil`——それらはラベルの対象にならない。
    public func fileID(forChildName name: String) -> FileID? {
        fileIDsByName[name]
    }

    /// そのラベルの、対象に対する三状態 [RP-02]。
    public func checkState(of label: LabelSummary, for ids: [FileID]) -> LabelEditorModel.CheckState {
        var assigned = 0
        for id in ids {
            guard let origin = assignmentsByFile[id]?[label.id],
                  origin != .manuallyRemoved else { continue }
            assigned += 1
        }
        if assigned == 0 || ids.isEmpty { return .none }
        return assigned == ids.count ? .all : .some
    }

    /// そのフィールドでメニューに並べるラベル [LA-03][RL-05]。
    ///
    /// 出し分けの規則は `LabelEditorModel.candidates`（アーカイブ済みは
    /// 付与済みのときだけ）と共有する。並びは `labels(groupID:)` が返す
    /// ピン留め優先・名前順のまま**全件**——メニューは「もっと見る」を
    /// 持てないので畳まない。
    public func menuLabels(in group: LabelGroupSummary, for ids: [FileID]) -> [LabelSummary] {
        LabelEditorModel.candidates(from: labelsByGroup[group.id] ?? []) { label in
            checkState(of: label, for: ids) != .none
        }
    }

    // MARK: - 操作

    /// メニューの項目を押す [RL3-01][RL3-03]。
    ///
    /// トグルの向きは `LabelEditorModel.toggle` と同一——`.some`（一部に
    /// 付いている）を押したら全部に付ける。
    public func toggle(_ label: LabelSummary, targets: [Target]) async throws {
        guard let services, !targets.isEmpty else { return }
        let assigning = checkState(of: label, for: targets.map(\.id)) != .all
        guard let command = AssignLabelCommand.toggling(
            labelID: label.id, labelName: label.name,
            files: targets.map { (id: $0.id, url: $0.url) },
            assignments: assignmentsByFile, assigning: assigning,
            subjectName: LabelEditorModel.displayName(for: targets.map(\.url)),
            services: services) else { return }
        _ = try await commands.run(command)
        // 画面をすぐ合わせる。`.task` の読み直しは後から届く。
        let origin: LabelOrigin = assigning ? .manual : .manuallyRemoved
        for target in targets {
            assignmentsByFile[target.id, default: [:]][label.id] = origin
        }
    }
}
