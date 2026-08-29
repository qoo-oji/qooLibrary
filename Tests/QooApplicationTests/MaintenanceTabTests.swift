import Testing
import Foundation
import QooKit
@testable import QooApplication

//
//  メンテナンスウインドウのタブ [19章 §19.6、ステージ 4]。
//
//  **タブによってオフラインの扱いが逆**なのがこの型の存在理由。統合の都合で
//  揃えると、片方が守っているものが消える——孤立は「実体が見つからない」と
//  いう実体についての判断なので、見えない状態で確定させてはならない
//  [OR2-06]。保管庫は DB だけで答えられるので一覧は出し、操作だけ止める
//  [SB-05]。
//

@Suite("メンテナンスのタブ [19章 §19.6]")
struct MaintenanceTabTests {

    private func library(_ id: Int64, online: Bool) -> LibrarySummary {
        LibrarySummary(id: LibraryID(rawValue: id), uuid: UUID(), displayName: "L\(id)",
                       resolvedPath: "/Volumes/L\(id)", volumeUUID: "VOL\(id)",
                       libraryTypeID: LibraryTypeID(rawValue: 1), libraryTypeName: "同人誌",
                       isOnline: online, isReadOnlyDueToFS: false, fileCount: 0,
                       settingsRevision: 0)
    }

    @Test("タブの並びは片付ける頻度の順（見つからない → 保管庫）")
    func orderIsStable() {
        #expect(MaintenanceTab.allCases == [.orphans, .vault])
    }

    @Test("題は旧ウインドウの語をそのまま使う（語彙を割らない）")
    func titlesReuseTheExistingVocabulary() {
        #expect(MaintenanceTab.orphans.titleKey == "orphanCleanup.windowTitle")
        #expect(MaintenanceTab.vault.titleKey == "fileVault.windowTitle")
    }

    @Test("オンラインなら、どちらのタブも件数を出す")
    func onlineShowsCounts() {
        let lib = library(1, online: true)
        let counts = [lib.id: 3]
        for tab in MaintenanceTab.allCases {
            let status = tab.status(for: lib, counts: counts)
            #expect(status.showsCount)
            #expect(status.count == 3)
            #expect(!status.showsOfflineNote)
            #expect(!status.isDimmed)
        }
    }

    @Test("見つからないファイルは、オフラインでは件数を出さない [OR2-06]")
    func orphansHideCountWhenOffline() {
        let lib = library(1, online: false)
        let status = MaintenanceTab.orphans.status(for: lib, counts: [lib.id: 5])
        // **0 件と紛らわしくしない**——「無い」のか「見られない」のかは別のこと。
        #expect(!status.showsCount)
        #expect(status.showsOfflineNote)
        #expect(status.isDimmed)
    }

    @Test("保管庫はオフラインでも件数を出す [SB-05]")
    func vaultKeepsCountWhenOffline() {
        let lib = library(1, online: false)
        let status = MaintenanceTab.vault.status(for: lib, counts: [lib.id: 5])
        // 何がしまってあるかは DB だけで答えられる。止めるのは操作だけ。
        #expect(status.showsCount)
        #expect(status.count == 5)
        #expect(status.showsOfflineNote)
        #expect(!status.isDimmed)
    }

    @Test("片付けるものが無い行は淡く描く（0 件はキーごと現れない）")
    func emptyLibrariesAreDimmed() {
        let lib = library(1, online: true)
        for tab in MaintenanceTab.allCases {
            let status = tab.status(for: lib, counts: [:])
            #expect(status.count == 0)
            #expect(status.isDimmed)
        }
    }

    @Test("孤立タブの一覧の可否は `OrphanCleanupModel` の判定と一致する")
    func orphanStatusFollowsTheModel() {
        // **2 箇所に書くと「一覧は出ないのに件数だけ出る」形でずれる。**
        for online in [true, false] {
            let lib = library(1, online: online)
            #expect(MaintenanceTab.orphans.status(for: lib, counts: [lib.id: 1]).showsCount
                    == OrphanCleanupModel.canListOrphans(of: lib))
        }
    }
}
