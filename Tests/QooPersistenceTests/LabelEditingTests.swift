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
            try await s.f.labels.assign(fileID: file, labelID: id)
            try await s.f.labels.assign(fileID: file, labelID: keep)
        }

        try await s.f.labels.deleteLabels([id])

        #expect(try await s.f.labels.labels(groupID: s.group.id)
            .map(\.id) == [keep])
        // 紐づけは外部キーの cascade で消える。残っているのは keep だけ。
        for file in s.fileIDs {
            #expect(try await s.f.labels.labelIDs(fileID: file) == [keep])
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
        try await s.f.labels.assign(fileID: s.fileIDs[0], labelID: id)
        try await s.f.labels.assign(fileID: s.fileIDs[1], labelID: id)
        try await s.f.labels.assign(fileID: s.fileIDs[2], labelID: id)

        let snapshots = try await s.f.labels.snapshot(labelIDs: [id])
        #expect(snapshots.count == 1)
        #expect(snapshots[0].assignments.count == 3)

        try await s.f.labels.deleteLabels([id])
        #expect(try await s.f.labels.labels(groupID: s.group.id).isEmpty)

        try await s.f.labels.restore(snapshots)

        let restored = try #require(try await s.f.labels
            .labels(groupID: s.group.id).first)
        // **同じ ID で戻る。** ここが崩れると、ラベルフィルタでチェック中だった
        // 選択やウインドウ状態復元が黙って外れる。
        #expect(restored.id == id)
        #expect(restored.name == "サークル値A")
        #expect(restored.isPinned)
        #expect(restored.colorHex == "#ABCDEF")
        // 紐づけも 1 件ずつ戻る
        let byFile = try await s.f.labels.assignments(fileIDs: s.fileIDs)
        for file in s.fileIDs { #expect(byFile[file] == [id]) }
        #expect(restored.fileCount == 3)
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
        let all = try await s.f.labels.labels(groupID: s.group.id)
        #expect(Set(all.map(\.id)) == Set([id, other]))
        #expect(all.first { $0.id == id }?.name == "先")
        #expect(all.first { $0.id == other }?.name == "後")
    }

    @Test("復元は写しに無い紐づけを消す（ちょうどその状態に揃える）")
    func restoreIsExactNotAdditive() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "L")
        try await s.f.labels.assign(fileID: s.fileIDs[0], labelID: id)

        let snapshots = try await s.f.labels.snapshot(labelIDs: [id])
        // 写しを取ったあとで増やす
        try await s.f.labels.assign(fileID: s.fileIDs[1], labelID: id)

        try await s.f.labels.restore(snapshots)
        let byFile = try await s.f.labels.assignments(fileIDs: s.fileIDs)
        #expect(byFile[s.fileIDs[0]] == [id])
        #expect(byFile[s.fileIDs[1]]?.isEmpty != false, "写しに無いので消える")
    }

    @Test("相手のファイルが消えていても、残りの紐づけは戻る")
    func restoreSkipsAssignmentsWhoseFileIsGone() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "L")
        for file in s.fileIDs { try await s.f.labels.assign(fileID: file, labelID: id) }
        let snapshots = try await s.f.labels.snapshot(labelIDs: [id])
        try await s.f.labels.deleteLabels([id])

        // ファイルを 1 件、DB から消す（外部キー違反を誘う）
        try await s.f.database.writer.write { db in
            try db.execute(sql: "DELETE FROM managedFile WHERE id = ?",
                           arguments: [s.fileIDs[1].rawValue])
        }

        try await s.f.labels.restore(snapshots)
        let restored = try #require(try await s.f.labels
            .labels(groupID: s.group.id).first)
        #expect(restored.fileCount == 2)   // 消えた 1 件を除いて戻る
    }

    // MARK: - 件数の 2 つの意味 [LE-03][LE-05][FA-05]

    /// **要件が意図的に食い違う 1 点。** ファイル保管庫へ移したファイルは
    /// **件数は 1 つだけになった** [§19.13 #1]。ファイル保管庫へ入れたファイルは
    /// フィルタの結果から外れる [FA-05] ので、件数からも外れる——0 になれば
    /// LA3-01 により自動的に非表示になり、**画面に出る数字と一覧の見え方が
    /// 必ず一致する**。以前はここだけ保管庫のファイルも数えていた [LE-05] が、
    /// 0 件ラベルの赤字 [LE-04] が撤回された [LA3-04] ことで存在理由が消えた。
    @Test("保管庫へ移したファイルは件数から外れる [FA-05][LE-05 撤回]")
    func archivedFilesLeaveTheCount() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        for file in s.fileIDs { try await s.f.labels.assign(fileID: file, labelID: id) }

        var label = try #require(try await s.f.labels
            .labels(groupID: s.group.id).first)
        #expect(label.fileCount == 3)
        #expect(label.isVisible, "実体があり手動でも隠していないので見える [LA3-01]")

        // 1 件をファイル保管庫へ入れる [FA-05]
        try await s.f.database.writer.write { db in
            try db.execute(sql: "UPDATE managedFile SET isArchived = 1 WHERE id = ?",
                           arguments: [s.fileIDs[0].rawValue])
        }

        label = try #require(try await s.f.labels
            .labels(groupID: s.group.id).first)
        #expect(label.fileCount == 2, "**数え直しを呼んでいない**——件数は毎回数える")
    }

    /// **全件が保管庫か孤立になれば自動的に非表示** [LA3-01]。移動イベントも
    /// 印も持たない——実体が戻れば件数が 1 以上になり、そのまま表示へ戻る。
    @Test("生きている実体が 0 件になると自動的に非表示になる [LA3-01]")
    func labelWithoutLiveFilesBecomesHidden() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "サークル値A")
        for file in s.fileIDs { try await s.f.labels.assign(fileID: file, labelID: id) }
        try await s.f.database.writer.write { db in
            try db.execute(sql: "UPDATE managedFile SET state = 'orphaned'")
        }
        var label = try #require(try await s.f.labels.labels(groupID: s.group.id).first)
        #expect(label.fileCount == 0)
        #expect(!label.isVisible, "手動の印は無いが、実体が無いので隠れる")
        #expect(!label.isHidden, "**状態ではなく導出**——手動の印は立っていない")

        // 実体が戻れば、何もしなくても表示へ戻る。
        try await s.f.database.writer.write { db in
            try db.execute(sql: "UPDATE managedFile SET state = 'active'")
        }
        label = try #require(try await s.f.labels.labels(groupID: s.group.id).first)
        #expect(label.isVisible)
    }

    /// **手動の印は実体があっても効き続ける** [LA3-02]。うるさい自動ラベルを
    /// フィルタから消す唯一の手段（削除しても次の走査で復活する）。
    @Test("手動で非表示にしたラベルは実体があっても隠れたまま [LA3-02]")
    func manuallyHiddenStaysHidden() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "L")
        for file in s.fileIDs { try await s.f.labels.assign(fileID: file, labelID: id) }
        try await s.f.labels.setHidden([id], true)
        let label = try #require(try await s.f.labels.labels(groupID: s.group.id).first)
        #expect(label.fileCount == 3)
        #expect(label.isHidden)
        #expect(!label.isVisible, "実体が何件あっても隠れたまま")
    }

    @Test("孤立・ゴミ箱のファイルは件数に入らない [ID-06][TR-01]")
    func orphanedFilesDoNotCount() async throws {
        let s = try await Setup.make()
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "L")
        for file in s.fileIDs { try await s.f.labels.assign(fileID: file, labelID: id) }
        try await s.f.database.writer.write { db in
            try db.execute(sql: "UPDATE managedFile SET state = 'orphaned' WHERE id = ?",
                           arguments: [s.fileIDs[0].rawValue])
        }
        let label = try #require(try await s.f.labels
            .labels(groupID: s.group.id).first)
        #expect(label.fileCount == 2)
    }

    // MARK: - 統合 [LB-07][LE-11]

    /// **どちらを残すかの規則は要らなくなった** [PR-08]。紐づけは付いている／
    /// いないの 2 値で、保護は紐づけではなくフィールドに付く [PR-02]。統合は
    /// 「同じものに 2 つの名前が付いていた」を是正する操作なので、両方に
    /// 付いていたら 1 行へ畳めばよい。
    @Test("両方に付いていたら 1 行へ畳む [LB-07]")
    func mergeFoldsOverlappingAssignments() async throws {
        let s = try await Setup.make(files: 1)
        let file = s.fileIDs[0]
        let source = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "旧表記")
        let target = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "新表記")
        try await s.f.labels.assign(fileID: file, labelID: source)
        try await s.f.labels.assign(fileID: file, labelID: target)

        try await s.f.labels.merge(source, into: target)

        let byFile = try await s.f.labels.assignments(fileIDs: [file])
        #expect(byFile[file] == [target])
        #expect(try await s.f.labels.labels(groupID: s.group.id)
            .first?.fileCount == 1, "1 ファイルを二重に数えない")
    }

    @Test("統合は片方にしか付いていないファイルもまとめる")
    func mergeMovesNonOverlappingAssignments() async throws {
        let s = try await Setup.make()
        let source = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "旧")
        let target = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "新")
        try await s.f.labels.assign(fileID: s.fileIDs[0], labelID: source)
        try await s.f.labels.assign(fileID: s.fileIDs[1], labelID: target)

        try await s.f.labels.merge(source, into: target)

        let byFile = try await s.f.labels.assignments(fileIDs: s.fileIDs)
        #expect(byFile[s.fileIDs[0]] == [target])
        #expect(byFile[s.fileIDs[1]] == [target])
        #expect(try await s.f.labels.labels(groupID: s.group.id)
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
        try await s.f.labels.assign(fileID: s.fileIDs[0], labelID: source)
        try await s.f.labels.assign(fileID: s.fileIDs[0], labelID: target)
        try await s.f.labels.assign(fileID: s.fileIDs[1], labelID: source)

        // **統合元と統合先の両方を控える**——統合元にしか無かった紐づけが
        // 統合先へ移ってくるため。
        let before = try await s.f.labels.snapshot(labelIDs: [source, target])
        try await s.f.labels.merge(source, into: target)
        #expect(try await s.f.labels.labels(groupID: s.group.id)
            .map(\.id) == [target])

        try await s.f.labels.restore(before)

        let all = try await s.f.labels.labels(groupID: s.group.id)
        #expect(Set(all.map(\.id)) == Set([source, target]))
        let byFile = try await s.f.labels.assignments(fileIDs: s.fileIDs)
        #expect(byFile[s.fileIDs[0]] == [source, target])
        #expect(byFile[s.fileIDs[1]] == [source], "統合先へ移った紐づけが戻っている")
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
        #expect(try await s.f.labels.labels(groupID: s.group.id)
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
            .labels(groupID: s.group.id).first)
        try await s.f.labels.rename(id, to: to)
        let after = try #require(try await s.f.labels
            .labels(groupID: s.group.id).first)
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
        #expect(try await s.f.labels.labels(groupID: s.group.id)
            .first?.name == "同じ名前")
    }

    // MARK: - 色 [LE-10][CO-06]

    @Test("ラベル固有色は設定と解除ができる [CO-06]")
    func labelColorCanBeSetAndCleared() async throws {
        let s = try await Setup.make(files: 0)
        let id = try await s.f.labels.ensureLabel(groupID: s.group.id, name: "L")
        #expect(try await s.f.labels.labels(groupID: s.group.id)
            .first?.colorHex == nil)   // 既定はグループ色の継承
        try await s.f.labels.setColor(id, hex: "#123456")
        #expect(try await s.f.labels.labels(groupID: s.group.id)
            .first?.colorHex == "#123456")
        try await s.f.labels.setColor(id, hex: nil)
        #expect(try await s.f.labels.labels(groupID: s.group.id)
            .first?.colorHex == nil)
    }
}
