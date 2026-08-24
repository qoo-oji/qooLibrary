//
//  ラベル編集ウインドウが使うリポジトリ API [LE-07〜LE-11][LB-05〜LB-07][CO-06]。
//
//  削除・統合は `label` の行を物理的に消すので、Undo は「行を作り直す」形になる。
//  **元の ID へ戻せることがこの一連の要**なので、そこを重点的に固定する。
//
import Testing
import Foundation
import GRDB
import QooKit
@testable import QooPersistence

@Suite("ラベルの編集 [LE-07〜LE-11]")
struct LabelEditingTests {

    /// グループ 1 つと、そこに属するファイル数件を用意する。
    struct Setup {
        let f: Fixture
        let group: LabelGroupSummary
        var fileIDs: [FileID] = []

        static func make(files: Int = 3) async throws -> Setup {
            let f = try await Fixture.make()
            let group = try #require(try await f.labels.group(libraryID: f.libraryID, index: 2))
            var s = Setup(f: f, group: group)
            for i in 0..<files {
                s.fileIDs.append(try await f.files.upsert(
                    f.snapshot(inode: UInt64(i + 1), path: "本\(i).cbz")))
            }
            return s
        }
    }

    // MARK: - 削除 [LE-07][LE-08][LB-05]

    @Test("削除すると紐づけも消える [LE-08][LB-05]")
    func deleteRemovesAssignments() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "消す")
        let keep = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "残す")
        for file in s.fileIDs {
            try await s.f.labels.assign(fileID: file, labelID: id, origin: .auto)
            try await s.f.labels.assign(fileID: file, labelID: keep, origin: .manual)
        }

        try await s.f.labels.deleteLabels([id])

        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .map(\.id) == [keep])
        // 紐づけは外部キーの cascade で消える。残っているのは keep だけ。
        for file in s.fileIDs {
            #expect(try await s.f.labels.labelIDs(fileID: file).map(\.labelID) == [keep])
        }
    }

    @Test("削除は 0 件でも空リストでも落ちない")
    func deleteToleratesEmptyInput() async throws {
        let s = try await Setup.make(files: 0)
        try await s.f.labels.deleteLabels([])
        try await s.f.labels.deleteLabels([LabelID(rawValue: 9999)])
    }

    // MARK: - 写しと復元（Undo の土台）

    @Test("削除した写しを復元すると、同じ ID で紐づけごと戻る")
    func restoreBringsBackTheSameRowID() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        try await s.f.labels.setPinned(id, true)
        try await s.f.labels.setColor(id, hex: "#ABCDEF")
        try await s.f.labels.assign(fileID: s.fileIDs[0], labelID: id, origin: .manual)
        try await s.f.labels.assign(fileID: s.fileIDs[1], labelID: id, origin: .auto)
        // 「外した」印も写しに含まれること [RC-04]
        try await s.f.labels.unassign(fileID: s.fileIDs[2], labelID: id,
                                      markManuallyRemoved: true)

        let snapshots = try await s.f.labels.snapshot(labelIDs: [id])
        #expect(snapshots.count == 1)
        #expect(snapshots[0].assignments.count == 3)

        try await s.f.labels.deleteLabels([id])
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true).isEmpty)

        try await s.f.labels.restore(snapshots)

        let restored = try #require(try await s.f.labels
            .labels(groupID: s.group.id, includeArchived: true).first)
        // **同じ ID で戻る。** ここが崩れると、ラベルフィルタでチェック中だった
        // 選択やウインドウ状態復元が黙って外れる。
        #expect(restored.id == id)
        #expect(restored.name == "サークル値A")
        #expect(restored.isPinned)
        #expect(restored.colorHex == "#ABCDEF")
        // origin も 1 件ずつ戻る
        let byFile = try await s.f.labels.assignments(fileIDs: s.fileIDs)
        #expect(byFile[s.fileIDs[0]]?[id] == .manual)
        #expect(byFile[s.fileIDs[1]]?[id] == .auto)
        #expect(byFile[s.fileIDs[2]]?[id] == .manuallyRemoved)
        // `manuallyRemoved` は数えない
        #expect(restored.fileCount == 2)
    }

    @Test("削除と復元の間に別のラベルを作っても ID が食い合わない")
    func restoreDoesNotCollideWithLabelsCreatedMeanwhile() async throws {
        let s = try await Setup.make(files: 1)
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "先")
        let snapshots = try await s.f.labels.snapshot(labelIDs: [id])
        try await s.f.labels.deleteLabels([id])

        // AUTOINCREMENT なので、この新規ラベルは消した ID を再利用しない
        let other = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "後")
        #expect(other != id)

        try await s.f.labels.restore(snapshots)
        let all = try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
        #expect(Set(all.map(\.id)) == Set([id, other]))
        #expect(all.first { $0.id == id }?.name == "先")
        #expect(all.first { $0.id == other }?.name == "後")
    }

    @Test("復元は写しに無い紐づけを消す（ちょうどその状態に揃える）")
    func restoreIsExactNotAdditive() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "L")
        try await s.f.labels.assign(fileID: s.fileIDs[0], labelID: id, origin: .auto)

        let snapshots = try await s.f.labels.snapshot(labelIDs: [id])
        // 写しを取ったあとで増やす
        try await s.f.labels.assign(fileID: s.fileIDs[1], labelID: id, origin: .manual)

        try await s.f.labels.restore(snapshots)
        let byFile = try await s.f.labels.assignments(fileIDs: s.fileIDs)
        #expect(byFile[s.fileIDs[0]]?[id] == .auto)
        #expect(byFile[s.fileIDs[1]]?[id] == nil)   // 写しに無いので消える
    }

    @Test("相手のファイルが消えていても、残りの紐づけは戻る")
    func restoreSkipsAssignmentsWhoseFileIsGone() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "L")
        for file in s.fileIDs { try await s.f.labels.assign(fileID: file, labelID: id, origin: .auto) }
        let snapshots = try await s.f.labels.snapshot(labelIDs: [id])
        try await s.f.labels.deleteLabels([id])

        // ファイルを 1 件、DB から消す（外部キー違反を誘う）
        try await s.f.database.writer.write { db in
            try db.execute(sql: "DELETE FROM managedFile WHERE id = ?",
                           arguments: [s.fileIDs[1].rawValue])
        }

        try await s.f.labels.restore(snapshots)
        let restored = try #require(try await s.f.labels
            .labels(groupID: s.group.id, includeArchived: true).first)
        #expect(restored.fileCount == 2)   // 消えた 1 件を除いて戻る
    }

    // MARK: - 件数の 2 つの意味 [LE-03][LE-05][FA-05]

    /// **要件が意図的に食い違う 1 点。** ファイル保管庫へ移したファイルは
    /// ラベルフィルタの結果から外れる [FA-05] が、ラベル編集ウインドウの
    /// バッジには影響しない [LE-05]——紐づけは維持されているので、保管庫へ
    /// 入れただけでラベルが「0 件」＝赤字＝消してよさそう [LE-04] に見えるのは誤り。
    ///
    /// ファイル保管庫そのものは 2-11 で未実装なので、ここでは `isArchived` を
    /// 直接書いて**その状況を作ってから**確かめる（主張が成り立ちうる前提を
    /// 先に用意する）。
    @Test("保管庫へ移したファイルは、フィルタの件数からは外れるがバッジには残る [LE-05][FA-05]")
    func archivedFilesLeaveTheFilterCountButKeepTheBadgeCount() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        for file in s.fileIDs { try await s.f.labels.assign(fileID: file, labelID: id, origin: .auto) }
        try await s.f.labels.recountAll(libraryID: s.f.libraryID)

        var label = try #require(try await s.f.labels
            .labels(groupID: s.group.id, includeArchived: true).first)
        #expect(label.fileCount == 3)
        #expect(label.fileCountIncludingArchived == 3, "保管庫が空なら 2 つは一致する")

        // 1 件をファイル保管庫へ入れる [FA-05]
        try await s.f.database.writer.write { db in
            try db.execute(sql: "UPDATE managedFile SET isArchived = 1 WHERE id = ?",
                           arguments: [s.fileIDs[0].rawValue])
        }
        try await s.f.labels.recountAll(libraryID: s.f.libraryID)

        label = try #require(try await s.f.labels
            .labels(groupID: s.group.id, includeArchived: true).first)
        #expect(label.fileCount == 2, "フィルタからは外れる [FA-05]")
        #expect(label.fileCountIncludingArchived == 3, "バッジには影響しない [LE-05]")
    }

    @Test("孤立・ゴミ箱のファイルはどちらの件数にも入らない [ID-06][TR-01]")
    func orphanedFilesCountForNeither() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "L")
        for file in s.fileIDs { try await s.f.labels.assign(fileID: file, labelID: id, origin: .auto) }
        try await s.f.database.writer.write { db in
            try db.execute(sql: "UPDATE managedFile SET state = 'orphaned' WHERE id = ?",
                           arguments: [s.fileIDs[0].rawValue])
        }
        try await s.f.labels.recountAll(libraryID: s.f.libraryID)
        let label = try #require(try await s.f.labels
            .labels(groupID: s.group.id, includeArchived: true).first)
        #expect(label.fileCount == 2)
        #expect(label.fileCountIncludingArchived == 2)
    }

    // MARK: - 統合 [LB-07][LE-11]

    @Test("統合で手動付与が消えない [LB-07]", arguments: [
        (LabelOrigin.manual, LabelOrigin.manuallyRemoved, LabelOrigin.manual),
        (LabelOrigin.manuallyRemoved, LabelOrigin.manual, LabelOrigin.manual),
        (LabelOrigin.manual, LabelOrigin.auto, LabelOrigin.manual),
        (LabelOrigin.auto, LabelOrigin.manual, LabelOrigin.manual),
        (LabelOrigin.auto, LabelOrigin.manuallyRemoved, LabelOrigin.auto),
        (LabelOrigin.manuallyRemoved, LabelOrigin.manuallyRemoved, LabelOrigin.manuallyRemoved),
        (LabelOrigin.auto, LabelOrigin.auto, LabelOrigin.auto),
    ])
    func mergeResolvesOriginByPriority(
        sourceOrigin: LabelOrigin, targetOrigin: LabelOrigin, expected: LabelOrigin
    ) async throws {
        let s = try await Setup.make(files: 1)
        let file = s.fileIDs[0]
        let source = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "旧表記")
        let target = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "新表記")
        try await Self.put(s.f, file: file, label: source, origin: sourceOrigin)
        try await Self.put(s.f, file: file, label: target, origin: targetOrigin)

        try await s.f.labels.merge(source, into: target)

        let byFile = try await s.f.labels.assignments(fileIDs: [file])
        #expect(byFile[file]?[target] == expected)
        #expect(byFile[file]?[source] == nil)
    }

    /// `assign` は `manuallyRemoved` を書けないので、印を立てる経路を使い分ける。
    static func put(_ f: Fixture, file: FileID, label: LabelID, origin: LabelOrigin) async throws {
        switch origin {
        case .manuallyRemoved:
            try await f.labels.assign(fileID: file, labelID: label, origin: .auto)
            try await f.labels.unassign(fileID: file, labelID: label, markManuallyRemoved: true)
        case .auto, .manual:
            try await f.labels.assign(fileID: file, labelID: label, origin: origin)
        }
    }

    @Test("統合は片方にしか付いていないファイルもまとめる")
    func mergeMovesNonOverlappingAssignments() async throws {
        let s = try await Setup.make()
        let source = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "旧")
        let target = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "新")
        try await s.f.labels.assign(fileID: s.fileIDs[0], labelID: source, origin: .manual)
        try await s.f.labels.assign(fileID: s.fileIDs[1], labelID: target, origin: .auto)

        try await s.f.labels.merge(source, into: target)

        let byFile = try await s.f.labels.assignments(fileIDs: s.fileIDs)
        #expect(byFile[s.fileIDs[0]]?[target] == .manual)
        #expect(byFile[s.fileIDs[1]]?[target] == .auto)
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .first?.fileCount == 2)
    }

    @Test("グループをまたぐ統合は断る [LB-07]")
    func mergeAcrossGroupsIsRefused() async throws {
        let s = try await Setup.make(files: 0)
        let other = try #require(try await s.f.labels.group(libraryID: s.f.libraryID, index: 3))
        let a = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "A")
        let b = try await s.f.labels.ensureLabel(groupID: other.id, name: "B")
        await #expect(throws: LabelEditError.crossGroupMerge) {
            try await s.f.labels.merge(a, into: b)
        }
    }

    @Test("統合を写しから戻すと、2 つのラベルが元どおりに分かれる")
    func mergeIsUndoableFromSnapshots() async throws {
        let s = try await Setup.make()
        let source = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "旧")
        let target = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "新")
        try await s.f.labels.assign(fileID: s.fileIDs[0], labelID: source, origin: .manual)
        try await s.f.labels.assign(fileID: s.fileIDs[0], labelID: target, origin: .auto)
        try await s.f.labels.assign(fileID: s.fileIDs[1], labelID: source, origin: .auto)

        // **統合元と統合先の両方を控える**——統合先は origin が書き換わり、
        // 統合元にしか無かった紐づけも移ってくるため。
        let before = try await s.f.labels.snapshot(labelIDs: [source, target])
        try await s.f.labels.merge(source, into: target)
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .map(\.id) == [target])

        try await s.f.labels.restore(before)

        let all = try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
        #expect(Set(all.map(\.id)) == Set([source, target]))
        let byFile = try await s.f.labels.assignments(fileIDs: s.fileIDs)
        #expect(byFile[s.fileIDs[0]]?[source] == .manual)
        #expect(byFile[s.fileIDs[0]]?[target] == .auto)   // 上書きが戻っている
        #expect(byFile[s.fileIDs[1]]?[source] == .auto)
        #expect(byFile[s.fileIDs[1]]?[target] == nil)
    }

    // MARK: - 改名 [LB-06][LE-11]

    @Test("同じグループの既存名へ改名すると、衝突相手を添えて断る [LE-11]")
    func renameToExistingNameReportsTheCollision() async throws {
        let s = try await Setup.make(files: 0)
        let a = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        let b = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値B")
        await #expect(throws: LabelEditError.nameAlreadyExists(existing: a, name: "サークル値A")) {
            try await s.f.labels.rename(b, to: "サークル値A")
        }
        // 名前は変わっていない
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .first { $0.id == b }?.name == "サークル値B")
    }

    /// **標本は「正規化しても同じ文字列になる」形でなければ意味が無い。**
    /// 最初は半角カナ `ｻｰｸﾙ` → `サークル` で書いたが、`TextNormalizer` は
    /// 半角カナを全角へ畳まない［実測。NM-01 が `CFStringTransform` を使わないため］
    /// ので正規化名が変わってしまい、**この経路を一度も通っていなかった**
    /// （変異検証で発覚）。畳まれるのは大小文字と全角英数記号のほう。
    @Test("表記だけを整える改名は通る（自分自身は衝突ではない）", arguments: [
        ("studio abc", "STUDIO ABC"),   // 大小文字だけ
        ("ＳＴＵＤＩＯ", "STUDIO"),      // 全角英数 → 半角
    ])
    func renameThatOnlyChangesTheSurfaceFormIsAllowed(from: String, to: String) async throws {
        let s = try await Setup.make(files: 0)
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: from)
        let before = try #require(try await s.f.labels
            .labels(groupID: s.group.id, includeArchived: true).first)
        try await s.f.labels.rename(id, to: to)
        let after = try #require(try await s.f.labels
            .labels(groupID: s.group.id, includeArchived: true).first)
        // 前提の確認: 正規化名が変わらない改名であること（変わっていたら
        // 「自分自身は衝突ではない」の経路を通らず、この検査は空振りする）
        #expect(before.normalizedName == after.normalizedName)
        #expect(after.name == to)
    }

    @Test("別グループに同じ名前があっても改名は通る [LB-01]")
    func renameIgnoresCollisionsInOtherGroups() async throws {
        let s = try await Setup.make(files: 0)
        let other = try #require(try await s.f.labels.group(libraryID: s.f.libraryID, index: 3))
        _ = try await s.f.labels.ensureLabel(groupID: other.id, name: "同じ名前")
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "元の名前")
        try await s.f.labels.rename(id, to: "同じ名前")
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .first?.name == "同じ名前")
    }

    // MARK: - 色 [LE-10][CO-06]

    @Test("ラベル固有色は設定と解除ができる [CO-06]")
    func labelColorCanBeSetAndCleared() async throws {
        let s = try await Setup.make(files: 0)
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "L")
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .first?.colorHex == nil)   // 既定はグループ色の継承
        try await s.f.labels.setColor(id, hex: "#123456")
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .first?.colorHex == "#123456")
        try await s.f.labels.setColor(id, hex: nil)
        #expect(try await s.f.labels.labels(groupID: s.group.id, includeArchived: true)
            .first?.colorHex == nil)
    }
}

@Suite("統合したときの origin [LB-07]")
struct LabelOriginMergingTests {
    @Test("manual > auto > manuallyRemoved で、順序を入れ替えても同じ")
    func priorityIsSymmetric() {
        let all = LabelOrigin.allCases
        for a in all {
            for b in all {
                #expect(LabelOrigin.merging(a, b) == LabelOrigin.merging(b, a))
            }
        }
        #expect(LabelOrigin.merging(.manual, .manuallyRemoved) == .manual)
        #expect(LabelOrigin.merging(.auto, .manuallyRemoved) == .auto)
        #expect(LabelOrigin.merging(.manual, .auto) == .manual)
        #expect(LabelOrigin.merging(.manuallyRemoved, .manuallyRemoved) == .manuallyRemoved)
    }
}
