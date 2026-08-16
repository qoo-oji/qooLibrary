import Foundation
import Testing

@testable import QooInfrastructure

/// **ゴミ箱の有無は「尋ねて」判定する** [NV4-01]。
///
/// ボリューム種別で分岐せず実際に尋ねる、という §8.11 の原則の実装。
/// 1-16b の実測では **SMB 3 系統（Samba/QNAP・Apple・Windows）すべてで
/// ゴミ箱が存在せず**、`.trashDirectory` は `NSCocoaErrorDomain 3328` を
/// **0.01 秒**で返した。判定が安いので操作のたびに呼んで構わない。
@Suite(.serialized) struct TrashAvailabilityTests {
    /// ホーム（起動ボリューム）にはゴミ箱がある。
    /// **偽陰性を捕まえるための固定** — ここが `false` になると、
    /// 通常のゴミ箱操作が全部「すぐに削除」の確認へ化ける。
    @Test func theBootVolumeHasATrash() {
        #expect(TrashAvailability.hasTrash(for: FileManager.default.homeDirectoryForCurrentUser))
    }

    /// 判定は 1 項目でも複数でも同じ答えになる（同一ボリューム）。
    @Test func askingForSeveralItemsOnTheSameVolumeAgrees() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let items = [home, home.appendingPathComponent("a"), home.appendingPathComponent("b")]
        #expect(TrashAvailability.hasTrash(forAll: items))
    }

    /// **判定にゴミ箱を作らせない** [NV-86]。`create: false` で尋ねている
    /// ことの固定——こちらの都合でユーザーのボリュームに `.Trashes` を
    /// 作ってしまうと、共有上にアプリ由来のものを置かない方針に反する。
    @Test func askingDoesNotCreateATrashOnTheVolume() throws {
        guard let volume = TinyVolume.make(megabytes: 20) else { return }
        defer { volume.destroy() }

        let before = try FileManager.default.contentsOfDirectory(
            atPath: volume.mountPoint.path
        ).sorted()
        _ = TrashAvailability.hasTrash(for: volume.mountPoint)
        let after = try FileManager.default.contentsOfDirectory(
            atPath: volume.mountPoint.path
        ).sorted()

        #expect(before == after, "判定がボリュームの中身を変えた: \(before) → \(after)")
        #expect(
            !FileManager.default.fileExists(atPath: volume.mountPoint.appendingPathComponent(".Trashes").path),
            "判定が .Trashes を作ってしまった"
        )
    }

    /// 空の一覧を渡しても落ちない（呼び出し側の早期 return と二重に守る）。
    @Test func anEmptyListIsTreatedAsHavingATrash() {
        #expect(TrashAvailability.hasTrash(forAll: []))
    }
}
