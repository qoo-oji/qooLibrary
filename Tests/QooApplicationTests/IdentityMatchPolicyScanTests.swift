import Foundation
import QooKit
import Testing
@testable import QooApplication

//
//  設定 [ID-13] が実際の走査を動かすことを、端から端まで固定する。
//
//  **純粋関数のテスト（`IdentityMatchPolicyRuleTests`）だけでは足りない。**
//  設定は 草案 → JSON → payload → スナップショット → `ScanEngine` と 5 段を
//  渡り歩き、**どの段も既定値付きの引数**なので、繋ぎ忘れてもコンパイルが
//  通り、黙って既定に落ちる——実際に `settingsSnapshot` への 1 行を落として
//  「設定を変えても走査の挙動が変わらない」状態を作った。
//

@Suite("同一性の設定が走査を動かす [ID-13]", .serialized)
struct IdentityMatchPolicyScanTests {

    private static let name = "(同人誌) [サークル値1 (著者値1)] 作品タイトル1 (ジャンル値1).cbz"

    /// 1 件だけ取り込んだライブラリを用意する。
    @MainActor
    private func bench(_ policy: IdentityMatchPolicy)
        async throws -> (ServicesWorkspace, LibraryID)
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        try w.write("旧/\(Self.name)")
        let id = try await w.enable("builtin.doujinshi-a")
        try await w.editSettings(id) { $0.identityMatchPolicy = policy }
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        return (w, id)
    }

    /// **同じ場所での差し替え** [ID-03]③a。スキャン版を電子版へ置き換える等。
    @MainActor
    private func replaceInPlace(_ w: ServicesWorkspace) throws {
        let url = w.libraryRoot.appendingPathComponent("旧/\(Self.name)")
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 0x43, count: 64).write(to: url)   // 大きさを変える
    }

    /// **別の場所へ移しつつ差し替え** [ID-03]③b。
    @MainActor
    private func moveAndReplace(_ w: ServicesWorkspace) throws {
        let from = w.libraryRoot.appendingPathComponent("旧/\(Self.name)")
        let to = w.libraryRoot.appendingPathComponent("新/\(Self.name)")
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 32).write(to: to)
        try FileManager.default.removeItem(at: from)
    }

    @Test("同じ場所での差し替え: alwaysConfirm だけが尋ねる")
    @MainActor
    func replacementInPlace() async throws {
        for policy in IdentityMatchPolicy.allCases {
            let (w, id) = try await bench(policy)
            try replaceInPlace(w)
            let r = try await w.services.scan(libraryID: id, root: w.libraryRoot)
            if policy == .alwaysConfirm {
                #expect(r.candidatesForReview == 1, "\(policy) は確認するはず")
                #expect(r.orphaned == 1)
                #expect(r.reidentified == 0)
            } else {
                #expect(r.reidentified == 1, "\(policy) は黙って引き継ぐはず")
                #expect(r.candidatesForReview == 0)
                #expect(r.orphaned == 0)
                // **走査の途中で拾えていること。** 走査の末尾の後始末（⑤）でも
                // 最終的な状態は同じになるが、そちらは「新しい行を作る →
                // 孤立にする → 引き継いで消す」という往復を通る。`added` が
                // 増えていないことが、`findCandidates` が `.pathOnly` を
                // 返して途中で拾った証拠になる。
                #expect(r.added == 0, "\(policy) は新しい行を作らずに引き継ぐはず")
            }
        }
    }

    /// **`.samePath` の存在意義そのもの。** 「同じ場所なら確認しない」を
    /// 選んだ人にも、場所が変わるものは尋ねなければ設定の意味が無い。
    @Test("別の場所への差し替え: sameName だけが黙って引き継ぐ")
    @MainActor
    func replacementElsewhere() async throws {
        for policy in IdentityMatchPolicy.allCases {
            let (w, id) = try await bench(policy)
            try moveAndReplace(w)
            let r = try await w.services.scan(libraryID: id, root: w.libraryRoot)
            if policy == .sameName {
                #expect(r.reidentified == 1, "\(policy) は黙って引き継ぐはず")
                #expect(r.candidatesForReview == 0)
            } else {
                #expect(r.candidatesForReview == 1, "\(policy) は確認するはず")
                #expect(r.reidentified == 0)
            }
        }
    }

    /// ［ユーザー判断: 次の走査で自動適用］設定を緩めた時点では何もせず、
    /// 次の走査で溜まっていた確認待ちを片付ける。
    ///
    /// **これが無いと「確認しない」に変えても片付かない**——既に新しい行が
    /// `active` として存在するので、次の走査は `findCandidates` の経路を
    /// 通らず、孤立がいつまでも残る。
    @Test("設定を緩めると、溜まっていた確認待ちが次の走査で片付く")
    @MainActor
    func looseningResolvesPendingOnNextScan() async throws {
        let (w, id) = try await bench(.alwaysConfirm)
        try moveAndReplace(w)
        let first = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        #expect(first.candidatesForReview == 1)
        #expect(try await w.services.orphanedFiles(libraryID: id).count == 1)

        try await w.editSettings(id) { $0.identityMatchPolicy = .sameName }
        // 設定を変えただけでは何も起きない（DB は触らない）。
        #expect(try await w.services.orphanedFiles(libraryID: id).count == 1)

        let second = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        #expect(second.reidentified == 1)
        #expect(try await w.services.orphanedFiles(libraryID: id).isEmpty)
    }

    /// **利用者の判断は設定に優先する** [ID-11]。「別のファイルだ」と答えた組は、
    /// あとから設定を緩めても勝手に紐づかない——一度答えたことを設定の変更で
    /// 覆されるなら、却下は意味を持たない。
    @Test("却下した組は、設定を緩めても自動で紐づかない")
    @MainActor
    func rejectionsSurviveLoosening() async throws {
        let (w, id) = try await bench(.alwaysConfirm)
        try moveAndReplace(w)
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)

        let pending = try await w.services.identityMatchesAwaitingDecision(libraryID: id)
        let orphan = try #require(pending.first)
        let candidate = try #require(orphan.candidates.first)
        try await w.services.rejectIdentityMatches(
            [IdentityMatch(orphanID: orphan.id, candidateID: candidate.fileID)])

        try await w.editSettings(id) { $0.identityMatchPolicy = .sameName }
        let after = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        #expect(after.reidentified == 0, "却下した組を設定が上書きしてはならない")
        #expect(try await w.services.orphanedFiles(libraryID: id).count == 1)
    }
}
