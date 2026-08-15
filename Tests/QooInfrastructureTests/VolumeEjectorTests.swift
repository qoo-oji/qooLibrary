import Foundation
import Testing

@testable import QooInfrastructure

/// [1-16] 取り出し可能かどうかの判定。
///
/// **実際のイジェクトはテストしない** — 実マシンのボリュームをアンマウント
/// することになるため（`FileOperationService` の `trash` を自動テストの対象外に
/// しているのと同じ理由）。判定ロジックだけを、マシンによらず必ず成り立つ
/// 性質に絞って検証する。実際の取り出しは使い捨てのディスクイメージを
/// 使った手動検証で確認済み（CLAUDE.md 参照）。
struct VolumeEjectorTests {
    /// 起動ボリュームは絶対に取り出せない。**この判定を誤ると、ユーザーが
    /// 自分の起動ディスクを取り出そうとできてしまう**ため、環境に依存せず
    /// 必ず成り立つこの 1 点は自動テストで固定しておく。
    @Test func rootFileSystemIsNeverEjectable() {
        #expect(VolumeEjector.isEjectable(URL(fileURLWithPath: "/", isDirectory: true)) == false)
    }

    /// 取り出し可能な一覧に起動ボリュームが混ざらない（「すべてを取り出す」が
    /// 起動ディスクへ手を伸ばさない）。
    @Test func ejectableVolumesNeverIncludeTheBootVolume() {
        let root = URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL.path
        #expect(!VolumeEjector.ejectableVolumes().contains { $0.standardizedFileURL.path == root })
    }

    /// 存在しないパスでも例外を投げず `false` を返す（メニューの出し分けが
    /// 落ちない）。
    @Test func nonexistentPathIsNotEjectable() {
        #expect(VolumeEjector.isEjectable(URL(fileURLWithPath: "/no/such/volume/here")) == false)
    }
}
