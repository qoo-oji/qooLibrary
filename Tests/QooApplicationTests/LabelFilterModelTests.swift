import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  ラベルフィルタの状態 [LF-01〜LF-14][PN-01〜PN-06][RT-01〜RT-03][ST-26]。
//
//  **実際に走査してラベルを作ってから確かめる**——グループやラベルを手で
//  差し込む補助コードを置くと、テンプレート由来の並びや意味束縛が落ちた状態を
//  「正しい入力」として固定してしまう（`ScanWorkspace` で実際に踏んだ形）。
//

@Suite("ラベルフィルタ [LF-01〜LF-14][PN-01〜PN-06]", .serialized)
struct LabelFilterModelTests {

    /// 走査まで済ませた作業場と、読み込み済みのモデル。
    @MainActor
    static func prepared(_ files: [String]) async throws -> (ServicesWorkspace, LabelFilterModel) {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for file in files { try w.write(file) }
        let id = try await w.enable()
        _ = try await w.services.scan(libraryID: id)
        let model = LabelFilterModel()
        await model.load(registrationUUID: w.registrationUUID, services: w.services)
        return (w, model)
    }

    /// 同人誌(A) のフォーマットに一致する合成名。
    static func doujin(_ n: Int, circle: Int? = nil) -> String {
        "(同人誌) [サークル値\(circle ?? n) (著者値\(n))] 作品タイトル\(n) (ジャンル値\(n)).cbz"
    }

    // MARK: - 出す条件 [LF-01][LF-02]

    @Test("ボリューム経由で開いているときは出さない [LF-01]")
    @MainActor
    func volumeRootHasNoFilter() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write(Self.doujin(0))
        let id = try await w.enable()
        _ = try await w.services.scan(libraryID: id)
        let model = LabelFilterModel()
        // 実フォルダは同じでも、**入口がボリュームならライブラリとして扱わない**。
        await model.load(registrationUUID: nil, services: w.services)
        #expect(model.library == nil)
        #expect(model.groups.isEmpty)
    }

    @Test("ラベルが 1 件も無いグループは出さない [LF-02][LG-05]")
    @MainActor
    func emptyGroupsAreHidden() async throws {
        let (w, model) = try await Self.prepared([Self.doujin(0)])
        _ = w
        #expect(!model.groups.isEmpty)
        #expect(model.groups.allSatisfy { $0.labelCount > 0 })
        // 出しているグループには必ずラベルが読み込まれている。
        for group in model.groups {
            #expect(!(model.labels[group.id] ?? []).isEmpty)
        }
    }

    // MARK: - 絞り込み [LF-08〜LF-11]

    @Test("グループ内 OR × グループ間 AND [LF-08〜LF-10]、件数は常時出る [LF-11]")
    @MainActor
    func orWithinGroupAndAcrossGroups() async throws {
        // サークル値0 を 2 件（著者違い）、サークル値1 を 1 件。
        let (w, model) = try await Self.prepared([
            Self.doujin(0, circle: 0), Self.doujin(1, circle: 0), Self.doujin(2, circle: 2),
        ])
        #expect(model.totalCount == 3)

        let circle = try #require(model.groups.first { !(model.labels[$0.id] ?? []).isEmpty
            && (model.labels[$0.id] ?? []).contains { $0.name.hasPrefix("サークル値") } })
        let circleLabels = try #require(model.labels[circle.id])
        let circle0 = try #require(circleLabels.first { $0.name == "サークル値0" })
        let circle2 = try #require(circleLabels.first { $0.name == "サークル値2" })

        model.toggle(circle0)
        await model.refreshResults(folderRelativePath: "", services: w.services)
        #expect(model.matchedCount == 2)                      // グループ内 OR の片側

        model.toggle(circle2)
        await model.refreshResults(folderRelativePath: "", services: w.services)
        #expect(model.matchedCount == 3)                      // [LF-08] OR

        // 著者で AND を掛けると、片方だけに絞られる [LF-09][LF-10]。
        let author = try #require(model.groups.first { group in
            (model.labels[group.id] ?? []).contains { $0.name.hasPrefix("著者値") }
        })
        let author0 = try #require(model.labels[author.id]?.first { $0.name == "著者値0" })
        model.toggle(author0)
        await model.refreshResults(folderRelativePath: "", services: w.services)
        #expect(model.matchedCount == 1)
    }

    @Test("該当ファイルと、それを配下に持つフォルダだけが残る [VM-02]")
    @MainActor
    func allowedChildNamesKeepsAncestors() async throws {
        let (w, model) = try await Self.prepared([
            "上位/" + Self.doujin(0),
            "別の場所/" + Self.doujin(1),
        ])
        let circle = try #require(model.groups.first { group in
            (model.labels[group.id] ?? []).contains { $0.name == "サークル値0" }
        })
        let target = try #require(model.labels[circle.id]?.first { $0.name == "サークル値0" })
        model.toggle(target)
        await model.refreshResults(folderRelativePath: "", services: w.services)
        // ライブラリ直下から見ると、**該当を含むフォルダ名**が残る。
        #expect(model.allowedChildNames == ["上位"])

        // そのフォルダの中まで降りるとファイル名で返る。
        await model.refreshResults(folderRelativePath: "上位", services: w.services)
        #expect(model.allowedChildNames == [Self.doujin(0)])
    }

    @Test("フィルタが全 OFF なら絞らない [VM-01][LF-06]")
    @MainActor
    func inactiveFilterDoesNotRestrict() async throws {
        let (w, model) = try await Self.prepared([Self.doujin(0)])
        #expect(!model.isActive)
        await model.refreshResults(folderRelativePath: "", services: w.services)
        // **`nil` は「絞らない」**。空集合（＝何も残さない）と取り違えると
        // 一覧が黙って空になる。
        #expect(model.allowedChildNames == nil)
    }

    // MARK: - ピン留め [PN-02][PN-03][PN-06]

    @Test("ピン留めが無ければ名前順で上位 10 件 [PN-03]")
    @MainActor
    func collapsedShowsTopTen() async throws {
        let (w, model) = try await Self.prepared((0..<12).map { Self.doujin($0, circle: $0) })
        _ = w
        let circle = try #require(model.groups.first { group in
            (model.labels[group.id] ?? []).count >= 12
        })
        #expect(model.visibleLabels(in: circle).count == AppLimits.LabelFilter.collapsedLabelCount)
        #expect(model.hasMoreLabels(in: circle))
        // 「もっと見る」で全件 [PN-05]。
        model.revealedGroups.insert(circle.id)
        #expect(model.visibleLabels(in: circle).count == 12)
        #expect(!model.hasMoreLabels(in: circle))
    }

    @Test("ピン留めがあればピン留めだけ [PN-02]")
    @MainActor
    func pinnedLabelsWin() async throws {
        let (w, model) = try await Self.prepared((0..<12).map { Self.doujin($0, circle: $0) })
        let circle = try #require(model.groups.first { ($0.labelCount) >= 12 })
        let pinned = try #require(model.labels[circle.id]?.first)
        await model.setPinned(pinned, true, services: w.services)
        #expect(model.visibleLabels(in: circle).map(\.name) == [pinned.name])
    }

    @Test("チェック中のラベルはピン対象外でも必ず出る [PN-06]")
    @MainActor
    func checkedLabelsAlwaysVisible() async throws {
        let (w, model) = try await Self.prepared((0..<12).map { Self.doujin($0, circle: $0) })
        let circle = try #require(model.groups.first { ($0.labelCount) >= 12 })
        let all = try #require(model.labels[circle.id])
        let hidden = try #require(all.last)                   // 上位 10 件の外
        #expect(!model.visibleLabels(in: circle).contains { $0.id == hidden.id })
        model.toggle(hidden)
        #expect(model.visibleLabels(in: circle).contains { $0.id == hidden.id })
        _ = w
    }

    @Test("展開中はインクリメンタル検索で絞れる [PN-05]")
    @MainActor
    func revealedGroupSupportsSearch() async throws {
        let (w, model) = try await Self.prepared((0..<12).map { Self.doujin($0, circle: $0) })
        _ = w
        let circle = try #require(model.groups.first { ($0.labelCount) >= 12 })
        model.revealedGroups.insert(circle.id)
        model.searchText[circle.id] = "値11"
        #expect(model.visibleLabels(in: circle).map(\.name) == ["サークル値11"])
    }

    // MARK: - 解除とリセット [LF-07][ST-26]

    @Test("一括 OFF はラベルも評価も落とす [LF-07]")
    @MainActor
    func clearAllDropsRatingToo() async throws {
        let (w, model) = try await Self.prepared([Self.doujin(0)])
        _ = w
        let group = try #require(model.groups.first)
        let label = try #require(model.labels[group.id]?.first)
        model.toggle(label)
        model.ratingFilter = .init(stars: 3)
        #expect(model.isActive)
        model.clearAll()
        #expect(!model.isActive)
        #expect(model.ratingFilter == nil)
        #expect(model.selection.isEmpty)
    }

    @Test("ライブラリの外へ出たら選択をリセットする [ST-26]")
    @MainActor
    func switchingLibraryResetsSelection() async throws {
        let (w, model) = try await Self.prepared([Self.doujin(0)])
        let group = try #require(model.groups.first)
        let label = try #require(model.labels[group.id]?.first)
        model.toggle(label)
        #expect(model.isActive)
        await model.load(registrationUUID: nil, services: w.services)
        #expect(!model.isActive)
        #expect(model.allowedChildNames == nil)
    }

    @Test("選択が変わるたびに再計算の合図が出る")
    @MainActor
    func revisionAdvancesOnChange() async throws {
        let (w, model) = try await Self.prepared([Self.doujin(0)])
        _ = w
        let group = try #require(model.groups.first)
        let label = try #require(model.labels[group.id]?.first)
        let before = model.revision
        model.toggle(label)
        #expect(model.revision > before)
        let afterToggle = model.revision
        model.ratingFilter = .init(stars: 2)
        #expect(model.revision > afterToggle)
    }
}
