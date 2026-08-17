import Foundation
import Testing

@testable import QooInfrastructure

/// ゴミ箱判定 [RG3-03][BM-2]。
///
/// **標本は実測したパスの形をそのまま使う。** 1-15 の匿名化テストで
/// 「きれいな例だけを標本にすると、その分野で最も普通の入力を取りこぼす」
/// という教訓を得ているため、ここでも実際にゴミ箱へ移して観測した
/// 2 つの形（起動ボリューム・外部ボリューム）を基準にしている。
@Suite struct TrashLocationTests {

    // MARK: ゴミ箱の中と判定すべきもの [実測した形]

    @Test(arguments: [
        // 起動ボリューム: `~/.Trash/<名前>`
        "/Users/someone/.Trash/作品タイトル",
        "/Users/someone/.Trash/作品タイトル/第01巻.cbz",
        // 外部ボリューム: `/Volumes/<名前>/.Trashes/<uid>/<名前>`
        "/Volumes/PRO-G40/.Trashes/501/Comics",
        "/Volumes/PRO-G40/.Trashes/501/Comics/(成年コミック) [98765架空社] 作品.cbz",
        // 起動ボリュームのルート直下の `.Trashes`（所有者以外のユーザー向け）
        "/.Trashes/501/something",
    ])
    func recognizesTrashPaths(_ path: String) {
        #expect(TrashLocation.isInTrash(path: path))
        #expect(TrashLocation.isInTrash(URL(fileURLWithPath: path)))
    }

    // MARK: ゴミ箱ではないもの

    @Test(arguments: [
        "/Volumes/PRO-G40/Comics/作品タイトル",
        "/Users/someone/Documents/蔵書",
        "/",
        "/Volumes/PRO-G40",
        // **成分の一部が一致するだけのもの。** 素の文字列包含で実装すると
        // ここを取り違える。
        "/Users/someone/Documents/.Trashy",
        "/Users/someone/Documents/Trash Talk/第01巻.cbz",
        "/Volumes/X/MyTrashes/photos",
        "/Volumes/X/.TrashesOld/photos",
    ])
    func rejectsNonTrashPaths(_ path: String) {
        #expect(!TrashLocation.isInTrash(path: path))
        #expect(!TrashLocation.isInTrash(URL(fileURLWithPath: path)))
    }

    /// 末尾スラッシュ・重複スラッシュ・`.` を含む表現でも同じ答えになる。
    /// 解決済みの URL がどういう表現で来るかは経路によって揺れる
    /// [`SessionState.cutURLs` で実際に踏んだ問題]。
    @Test func normalizesBeforeMatching() {
        #expect(TrashLocation.isInTrash(URL(fileURLWithPath: "/Users/someone/.Trash/x/")))
        #expect(TrashLocation.isInTrash(URL(fileURLWithPath: "/Users/someone/.Trash/./x")))
        #expect(TrashLocation.isInTrash(path: "/Users/someone/.Trash/x/"))
    }

    /// **決して失敗しない**のがこの実装を選んだ理由の 1 つ
    /// （Apple 推奨の `getRelationship` は存在しないパスで `NSCocoaErrorDomain
    /// 3328` を投げる、実測）。存在しないパスでも素直に答える。
    @Test func answersForPathsThatDoNotExist() {
        #expect(TrashLocation.isInTrash(path: "/no/such/place/.Trash/gone"))
        #expect(!TrashLocation.isInTrash(path: "/no/such/place/at/all"))
    }
}
