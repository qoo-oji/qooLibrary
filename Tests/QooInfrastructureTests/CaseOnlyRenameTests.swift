import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **「名前は違って見えるのに同じファイル」を衝突扱いしない** [FM-05]。
///
/// 大文字小文字を区別しないボリューム（APFS/HFS+/exFAT/FAT の既定）では
/// `comic.cbz` → `Comic.cbz` の改名で `fileExists(Comic.cbz)` が **true** に
/// なる。相手は自分自身なのに衝突と判定され、
/// 「『Comic.cbz』がすでに存在するため、処理を続けられませんでした」という
/// ユーザーには意味の分からない文言で弾かれていた（Finder では普通にできる）。
///
/// 同じことが Unicode 正規化の違いでも起きる。しかもそちらは**大文字小文字を
/// 区別するボリュームでも**起きる（実測で APFS 大文字小文字区別版・UDF でも
/// NFC と NFD が同一視されることを確認済み）。
@Suite struct CaseOnlyRenameTests {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-caserename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func renamingOnlyTheCaseSucceeds() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("comic.cbz")
        try Data("x".utf8).write(to: file)

        let service = FileOperationService()
        let receipt = try await service.rename(file, to: "Comic.cbz")

        #expect(receipt.toURL.lastPathComponent == "Comic.cbz")
        let listed = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(listed == ["Comic.cbz"], "実際の名前が変わっていない: \(listed)")
        // 中身が失われていないこと（自分自身を「置き換えて」空にしない）。
        #expect(try Data(contentsOf: receipt.toURL) == Data("x".utf8))
    }

    /// 正規化だけを変える改名。大文字小文字とは別の経路で同じ問題になる。
    @Test func renamingOnlyTheUnicodeNormalizationSucceeds() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let decomposed = "が.cbz".decomposedStringWithCanonicalMapping
        let file = root.appendingPathComponent(decomposed)
        try Data("y".utf8).write(to: file)

        let service = FileOperationService()
        let receipt = try await service.rename(file, to: "が.cbz".precomposedStringWithCanonicalMapping)

        #expect(try Data(contentsOf: receipt.toURL) == Data("y".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    /// **逆方向の固定**（この修正がやり過ぎていないこと）。
    /// 別の実体とぶつかる場合は、これまでどおり衝突として扱わなければならない。
    /// ここが緩むと、健康なファイルを黙って書き潰す経路になる。
    @Test func renamingOntoADifferentExistingItemIsStillAConflict() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.cbz")
        let other = root.appendingPathComponent("Other.cbz")
        try Data("SOURCE".utf8).write(to: source)
        try Data("IMPORTANT".utf8).write(to: other)

        let service = FileOperationService()
        // 衝突解決の手段を渡さない＝ `.ask` のまま解決できない状態にする。
        await #expect(throws: FileOperationError.self) {
            _ = try await service.rename(source, to: "Other.cbz")
        }
        // 既存の中身が守られていること。
        #expect(try Data(contentsOf: other) == Data("IMPORTANT".utf8))
    }

    /// 大文字小文字だけ違う**別の実体**が実在する場合（大文字小文字を区別する
    /// ボリュームでのみ起こり得る）。同一実体ではないので衝突のまま。
    /// 区別しないボリュームではそもそも 2 つ作れないため、作れたときだけ検証する。
    @Test func caseDifferingSiblingsAreStillTreatedAsSeparateItems() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let lower = root.appendingPathComponent("dup.cbz")
        let upper = root.appendingPathComponent("DUP.cbz")
        try Data("lower".utf8).write(to: lower)
        try? Data("upper".utf8).write(to: upper)
        let bothExist = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count == 2
        guard bothExist else { return } // 区別しないボリューム: 検証対象外

        let service = FileOperationService()
        await #expect(throws: FileOperationError.self) {
            _ = try await service.rename(lower, to: "DUP.cbz")
        }
        #expect(try Data(contentsOf: upper) == Data("upper".utf8))
    }
}
