import Foundation
import Testing

@testable import QooInfrastructure

/// **マウント表からボリュームの素性を答える部分** [NV6-02][NV-93]。
///
/// この型が存在する理由は速さではなく、**切断時に固まらないこと**である。
/// `URL.resourceValues([.volumeIsLocalKey])` や `statfs(path)` は対象の
/// ボリュームへ問い合わせるので、相手が応答しないと戻ってこない——
/// SMB で最大 30 秒、NFS の hard マウント（既定）なら無限。
/// 「切断されているか」を知りたい当の場面で判定が固まっては意味が無い。
///
/// 「ブロックしないこと」自体は切断を作れないと確かめられない
/// （`Scripts/network-disconnect-probe.sh` の担当）ので、ここでは
/// **答えの正しさ**を固定する。
@Suite struct MountTableTests {

    // MARK: - パスの照合（合成データ・環境に依存しない）

    /// 起動ボリュームはすべてのパスの接頭辞なので、**最長一致でなければ
    /// 何もかもが起動ボリューム扱いになる。**
    @Test func theDeepestMountWinsNotTheFirstMatch() {
        let table = MountTable(entries: [
            .init(mountPoint: "/", fileSystemType: "apfs", isLocal: true),
            .init(mountPoint: "/Volumes/Share", fileSystemType: "smbfs", isLocal: false),
        ])
        #expect(table.entry(containing: "/Volumes/Share/comics/vol01.cbz")?.mountPoint == "/Volumes/Share")
        #expect(table.isRemote(path: "/Volumes/Share/comics/vol01.cbz"))
        // 逆向きの固定 — 起動ボリューム上のパスがリモート扱いされないこと。
        #expect(!table.isRemote(path: "/Users/someone/Comics"))
    }

    /// マウントは入れ子になる（共有の中にディスクイメージ、等）。
    @Test func nestedMountsResolveToTheInnermost() {
        let table = MountTable(entries: [
            .init(mountPoint: "/", fileSystemType: "apfs", isLocal: true),
            .init(mountPoint: "/Volumes/Share", fileSystemType: "smbfs", isLocal: false),
            .init(mountPoint: "/Volumes/Share/Image", fileSystemType: "apfs", isLocal: true),
        ])
        #expect(table.entry(containing: "/Volumes/Share/Image/x")?.mountPoint == "/Volumes/Share/Image")
        // 内側はローカルなディスクイメージなので、リモートではない。
        #expect(!table.isRemote(path: "/Volumes/Share/Image/x"))
        #expect(table.isRemote(path: "/Volumes/Share/other"))
    }

    /// **素の `hasPrefix` では隣のボリュームに一致してしまう。**
    /// `/Volumes/Private` と `/Volumes/PrivateArchive` は別物。
    @Test func aSiblingWithALongerNameIsNotMatched() {
        let table = MountTable(entries: [
            .init(mountPoint: "/", fileSystemType: "apfs", isLocal: true),
            .init(mountPoint: "/Volumes/Private", fileSystemType: "smbfs", isLocal: false),
        ])
        #expect(table.entry(containing: "/Volumes/PrivateArchive/x")?.mountPoint == "/")
        #expect(!table.isRemote(path: "/Volumes/PrivateArchive/x"))
        // マウント先そのものは一致する。
        #expect(table.isRemote(path: "/Volumes/Private"))
    }

    /// 判定できないときは**ローカル扱いに倒す**。呼び出し側はどちらも
    /// この向きが安全になるよう作ってある。
    /// **2 つの問いで倒す向きが違うのは意図的。** どちらも「呼び出し側に
    /// とって害の小さいほう」で揃えてある——ポーリングは足しそこねても
    /// FSEvents が残るが、退避を誤ると履歴ごと失う。
    @Test func anEmptyTableFallsBackSafelyForEachQuestion() {
        let table = MountTable(entries: [])
        #expect(table.entry(containing: "/anything") == nil)
        // リモート判定は「ローカル扱い」に倒す（余計なポーリングをしない）。
        #expect(!table.isRemote(path: "/Volumes/Share/x"))
        // 未接続判定は「外れている扱い」に倒す（タブを退避させない）。
        #expect(table.isOnAnUnmountedVolume(URL(fileURLWithPath: "/Volumes/Share/x")))
        // 起動ボリューム上のパスは、表が読めなくても外れようが無い。
        #expect(!table.isOnAnUnmountedVolume(URL(fileURLWithPath: "/Users/someone")))
    }

    /// 末尾のスラッシュだけを落とす。**`/private` の特別扱いを持ち込まない** —
    /// `NSString.standardizingPath` / `URL.resolvingSymlinksInPath()` は
    /// 先頭の `/private` を取り除くので、本プロジェクトはそれで一度
    /// `DirectoryChangeHub` の照合を落としている。
    @Test func normalizationOnlyTrimsTrailingSlashes() {
        #expect(MountTable.normalized("/Volumes/Share/") == "/Volumes/Share")
        #expect(MountTable.normalized("/Volumes/Share///") == "/Volumes/Share")
        #expect(MountTable.normalized("/") == "/")
        #expect(MountTable.normalized("/private/var/folders") == "/private/var/folders")
    }

    @Test func mountPointsAreComparedExactly() {
        let table = MountTable(entries: [
            .init(mountPoint: "/Volumes/Share", fileSystemType: "smbfs", isLocal: false)
        ])
        #expect(table.isMounted("/Volumes/Share"))
        #expect(table.isMounted("/Volumes/Share/"))   // 末尾スラッシュは吸収する
        #expect(!table.isMounted("/Volumes/Sha"))
        #expect(!table.isMounted("/Volumes/ShareX"))
    }

    // MARK: - 実際のマウント表

    /// 起動ボリュームは必ず載っていて、ローカルである。
    @Test func theRealTableContainsTheBootVolume() {
        let table = MountTable.current()
        #expect(!table.entries.isEmpty)
        let root = table.entries.first { $0.mountPoint == "/" }
        #expect(root != nil)
        #expect(root?.isLocal == true)
        #expect(!table.isRemote(path: "/usr/bin"))
    }

    /// **`MNT_LOCAL` の答えが `URLResourceKey.volumeIsLocalKey` と一致すること。**
    ///
    /// 本プロジェクトは能力フラグに繰り返し裏切られている
    /// （`volumeIsEjectable`／`supportsPersistentIDs`／`supportsExclusiveRenaming`）
    /// ので、ここでも名前を信じずに突き合わせる。**この機に実在する
    /// ボリュームすべてが対象**なので、SMB が刺さっていれば SMB も含まれる。
    @Test func mntLocalAgreesWithTheResourceKeyForEveryMountedVolume() {
        let table = MountTable.current()
        for entry in table.entries {
            // スナップショット類は数が多いだけで情報が無く、`/System/Volumes/`
            // 配下は firmlink の都合で意味が薄いので対象外にする。
            guard !entry.mountPoint.hasPrefix("/System/Volumes/"),
                  !entry.mountPoint.contains(".timemachine")
            else { continue }
            let viaResourceKey = (try? URL(fileURLWithPath: entry.mountPoint)
                .resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
            guard let viaResourceKey else { continue } // 読めない場所は判定しない
            #expect(
                viaResourceKey == entry.isLocal,
                "\(entry.mountPoint) (\(entry.fileSystemType)): MNT_LOCAL=\(entry.isLocal) だが volumeIsLocal=\(viaResourceKey)"
            )
        }
    }

    /// **実在するボリュームは 1 つも「外れている」と判定されないこと。**
    ///
    /// Time Machine のスナップショットのように**入口が `/Volumes/<名前>`
    /// より深い**マウントも対象に含める（`/Volumes/.timemachine/<UUID>/…`）。
    /// 素朴に `/Volumes/<名前>` だけで判定すると、ここが軒並み
    /// 「未接続」に倒れる。
    @Test func noMountedVolumeIsReportedAsUnmounted() {
        let table = MountTable.current()
        #expect(!table.isOnAnUnmountedVolume(URL(fileURLWithPath: "/usr/bin")))
        for entry in table.entries where entry.mountPoint.hasPrefix("/Volumes/") {
            let reported = table.isOnAnUnmountedVolume(URL(fileURLWithPath: entry.mountPoint))
            #expect(!reported, "マウントされている \(entry.mountPoint) を未接続と判定した")
        }
    }

    /// **外したボリュームを「外れている」と答えること** [NV-93]。
    ///
    /// ここが逆に倒れると、切断のたびにタブが祖先へ退避され、
    /// しかも履歴から実在しない項目が取り除かれて**挿し直しても
    /// 元の場所へ戻れなくなる**（[SB-05] に正面から反する）。
    @Test func aDetachedVolumeIsReportedAsUnmounted() throws {
        guard let volume = TinyVolume.make(megabytes: 20) else { return }
        defer { volume.destroy() }

        let inside = volume.mountPoint.appendingPathComponent("comics")
        // **`#expect` にテーブルそのものを渡さない** — 落ちたときに
        // マウント 97 件が丸ごと出力され、肝心の一行が読めなくなる。
        let whileAttached = MountTable.current().isOnAnUnmountedVolume(inside)
        #expect(!whileAttached, "付いている間は未接続ではない")

        guard volume.detachKeepingImage() else { return }
        let whileDetached = MountTable.current().isOnAnUnmountedVolume(inside)
        volume.reattach()
        #expect(whileDetached, "外したのに未接続と判定できていない")
    }

    /// ボリュームの入口を取り出す部分。**外れた瞬間に答えが `/` へ後退する**
    /// という罠（最初の実装がここで落ちた）を、合成データで直接固定する。
    @Test func theVolumeRootIsExtractedFromThePath() {
        #expect(MountTable.volumeRoot(of: "/Volumes/Share/a/b") == "/Volumes/Share")
        #expect(MountTable.volumeRoot(of: "/Volumes/Share") == "/Volumes/Share")
        // 起動ボリューム上のパスにはボリュームの入口が無い。
        #expect(MountTable.volumeRoot(of: "/Users/someone/Comics") == nil)
        #expect(MountTable.volumeRoot(of: "/Volumes") == nil)
        #expect(MountTable.volumeRoot(of: "/Volumes/") == nil)
    }

    /// 外れたボリュームの配下は、**最長一致が `/` まで後退しても**
    /// 未接続と答えること。合成データなので環境に依存しない。
    @Test func aPathUnderAMissingVolumeIsUnmountedEvenThoughRootMatches() {
        let table = MountTable(entries: [
            .init(mountPoint: "/", fileSystemType: "apfs", isLocal: true)
        ])
        #expect(table.isOnAnUnmountedVolume(URL(fileURLWithPath: "/Volumes/Gone/comics")))
        // 起動ボリューム上のパスは外れようが無い。
        #expect(!table.isOnAnUnmountedVolume(URL(fileURLWithPath: "/Users/someone")))
    }
}
