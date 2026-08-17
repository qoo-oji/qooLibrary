import Foundation
import Testing

@testable import QooInfrastructure

/// 登録フォルダの縮退状態 [1-17、8章 §8.7.1]。
///
/// ## 分類の検証は純粋関数へ直接ぶつける
/// `.offline` は「ボリュームが外れている」状況でしか起きず、実ストア経由では
/// 作り出せない（テストが使う一時ディレクトリは常にマウントされている）。
/// `RegisteredFolderStore.classify` は I/O を持たない純粋関数にしてあり、
/// `MountTable` は合成できる（`init(entries:)` が公開されている）ので、
/// **実測で確かめた入力の組み合わせをそのまま並べられる**。
///
/// 実測で確定している前提（8章 §8.7.1、1-17 で再確認）:
/// - 完全削除もイジェクトも `NSCocoaErrorDomain code=4`。**エラーからは区別できない。**
/// - ゴミ箱へ移動しても解決は成功する（`isStale = true`）。
@Suite struct RegisteredFolderStatusTests {

    private func folder(lastKnownPath: String?) -> RegisteredFolder {
        RegisteredFolder(
            kind: .library, displayName: "蔵書", bookmarkData: Data("bookmark".utf8),
            lastKnownPath: lastKnownPath
        )
    }

    /// 起動ボリュームと外付け 1 本がマウントされている状態。
    private var mountsWithExternal: MountTable {
        MountTable(entries: [
            .init(mountPoint: "/", fileSystemType: "apfs", isLocal: true),
            .init(mountPoint: "/Volumes/PRO-G40", fileSystemType: "apfs", isLocal: true),
        ])
    }

    /// 外付けが抜かれた状態。
    private var mountsWithoutExternal: MountTable {
        MountTable(entries: [.init(mountPoint: "/", fileSystemType: "apfs", isLocal: true)])
    }

    private func onlineProbe(persistentIDs: Bool? = true) -> RegisteredFolderStore.FolderProbe {
        .init(isDirectory: true, supportsPersistentIDs: persistentIDs, fileSystemName: "APFS")
    }

    // MARK: 解決できなかったとき — オフラインと消失を分ける

    /// **1-17 の中核。** 解決の失敗は 1 種類しか無いので、マウント表だけが
    /// 「待てば戻る」と「戻らない」を分ける。
    @Test func unresolvableOnAnUnmountedVolumeIsOfflineNotMissing() {
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: "/Volumes/PRO-G40/Comics"),
            resolution: .offline(reason: .volumeNotMounted),
            probe: nil,
            mounts: mountsWithoutExternal
        )
        #expect(status == .offline(lastKnownPath: "/Volumes/PRO-G40/Comics"))
        #expect(!status.allowsNavigation) // 展開しても子を読みに行かない [RG3-06]
    }

    /// 同じ失敗でも、ボリュームが繋がっているなら「消えた」と判断してよい。
    @Test func unresolvableOnAMountedVolumeIsMissing() {
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: "/Volumes/PRO-G40/Comics"),
            resolution: .offline(reason: .invalidBookmark),
            probe: nil,
            mounts: mountsWithExternal
        )
        #expect(status == .missing(lastKnownPath: "/Volumes/PRO-G40/Comics"))
    }

    /// 起動ボリューム上のフォルダが解決できないなら、それは消えたということ。
    @Test func unresolvableOnTheBootVolumeIsMissing() {
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: "/Users/someone/Comics"),
            resolution: .offline(reason: .invalidBookmark),
            probe: nil,
            mounts: mountsWithExternal
        )
        #expect(status == .missing(lastKnownPath: "/Users/someone/Comics"))
    }

    /// **応答が無いだけのものを「消えた」と言わない** [レビューで発見]。
    ///
    /// マウントは残っているがサーバが上限時間内に答えない（`.unresponsive`）
    /// 場合、マウント表を見ただけでは `.missing` になってしまう——応答の遅い
    /// NAS 上の**健全な**ライブラリに「見つかりません」と表示し、ユーザーに
    /// 解除を促すことになる。1-17 がまさに無くそうとしている取り違え。
    @Test(arguments: [OfflineReason.unresponsive, .permissionDenied])
    func reasonsThatSayNothingAboutExistenceStayOffline(_ reason: OfflineReason) {
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: "/Volumes/PRO-G40/Comics"),
            resolution: .offline(reason: reason),
            probe: nil,
            mounts: mountsWithExternal // マウントされたまま
        )
        #expect(status == .offline(lastKnownPath: "/Volumes/PRO-G40/Comics"))
    }

    /// 場所が分からない古いレコードは **`.offline` に倒す**。「見つかりません」と
    /// 言って解除を促すより、「接続すれば戻ります」と言うほうが害が小さい。
    @Test func unresolvableWithoutAKnownPathFallsBackToOffline() {
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: nil),
            resolution: .offline(reason: .invalidBookmark),
            probe: nil,
            mounts: mountsWithExternal
        )
        #expect(status == .offline(lastKnownPath: nil))
    }

    // MARK: 解決できたとき

    @Test func resolvedDirectoryIsOnline() {
        let url = URL(fileURLWithPath: "/Volumes/PRO-G40/Comics")
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: url.path),
            resolution: .resolved(url: url, isStale: false),
            probe: onlineProbe(),
            mounts: mountsWithExternal
        )
        #expect(status == .online(url: url))
        #expect(status.allowsNavigation)
        #expect(status.allowsWriting)
        #expect(!status.isDegraded)
    }

    /// ゴミ箱へ移しても解決は成功する（実測）。**二値の設計ではここが
    /// 「正常」に見えていた** — 消える寸前の場所へ書き込みまで通っていた。
    @Test func resolvedInsideTheTrashIsInTrash() {
        let url = URL(fileURLWithPath: "/Volumes/PRO-G40/.Trashes/501/Comics")
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: "/Volumes/PRO-G40/Comics"),
            resolution: .resolved(url: url, isStale: true),
            probe: onlineProbe(),
            mounts: mountsWithExternal
        )
        #expect(status == .inTrash(url: url))
        #expect(!status.allowsWriting)
        #expect(!status.allowsNavigation) // 中へ入れなければ中で書けない［ユーザー判断］
    }

    /// **ゴミ箱判定は実在確認より先。** 順序を逆にすると、ゴミ箱の中でも
    /// 実体はあるので `.online` として通ってしまう。
    @Test func trashIsCheckedBeforeTheDirectoryProbe() {
        let url = URL(fileURLWithPath: "/Users/someone/.Trash/Comics")
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: "/Users/someone/Comics"),
            resolution: .resolved(url: url, isStale: true),
            probe: onlineProbe(), // ディレクトリとして実在する
            mounts: mountsWithExternal
        )
        #expect(status == .inTrash(url: url))
    }

    /// 解決できたのにディレクトリでない（ファイルに置き換えられた等）。
    @Test func resolvedNonDirectoryIsMissing() {
        let url = URL(fileURLWithPath: "/Volumes/PRO-G40/Comics")
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: url.path),
            resolution: .resolved(url: url, isStale: false),
            probe: .init(isDirectory: false, supportsPersistentIDs: true, fileSystemName: "APFS"),
            mounts: mountsWithExternal
        )
        #expect(status == .missing(lastKnownPath: url.path))
    }

    /// [FS-08] 同一性を追跡できなくなったボリューム。オフラインとは区別し、
    /// 閲覧はできるが書き込みは許さない。
    @Test func resolvedOnAVolumeWithoutPersistentIDsIsUnsupported() {
        let url = URL(fileURLWithPath: "/Volumes/PRO-G40/Comics")
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: url.path),
            resolution: .resolved(url: url, isStale: false),
            probe: .init(isDirectory: true, supportsPersistentIDs: false, fileSystemName: "ExFAT"),
            mounts: mountsWithExternal
        )
        #expect(status == .unsupportedFileSystem(url: url, fileSystemName: "ExFAT"))
        #expect(status.allowsNavigation) // 閲覧はできる
        #expect(!status.allowsWriting) // 書き込みは許さない
    }

    /// **不明（`nil`）では縮退させない。** 問い合わせに失敗しただけで
    /// 「対応していない」と決めつけると、応答の遅い共有が読み取り専用になる。
    @Test func unknownPersistentIDSupportStaysOnline() {
        let url = URL(fileURLWithPath: "/Volumes/PRO-G40/Comics")
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: url.path),
            resolution: .resolved(url: url, isStale: false),
            probe: .init(isDirectory: true, supportsPersistentIDs: nil, fileSystemName: nil),
            mounts: mountsWithExternal
        )
        #expect(status == .online(url: url))
    }

    /// **問い合わせが間に合わなくてもゴミ箱判定は効く。**
    ///
    /// ［変異テストで見つけた穴］ゴミ箱判定を「実体の問い合わせ」より後ろへ
    /// 動かす変異を当てたところ、既存のテストが 1 つも落ちなかった。原因は
    /// `probe == nil`（上限超過）の早期 return がその手前にあることで、
    /// **応答の遅い共有にあるゴミ箱の中のフォルダが `.online` として
    /// 書き込み可能になる**経路が空いていた。ゴミ箱判定はパス文字列だけで
    /// 完結し I/O を必要としないので、問い合わせの成否に左右されてはならない。
    @Test func trashIsDetectedEvenWhenTheProbeTimedOut() {
        let url = URL(fileURLWithPath: "/Volumes/PRO-G40/.Trashes/501/Comics")
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: "/Volumes/PRO-G40/Comics"),
            resolution: .resolved(url: url, isStale: true),
            probe: nil,
            mounts: mountsWithExternal
        )
        #expect(status == .inTrash(url: url))
        #expect(!status.allowsWriting)
    }

    /// 実体の問い合わせが上限時間に間に合わなかった場合も `.online` のまま。
    /// 解決自体は成功しているので、ここで縮退させると応答の遅い共有が
    /// 一時的に使えなくなる。
    @Test func timedOutProbeStaysOnline() {
        let url = URL(fileURLWithPath: "/Volumes/PRO-G40/Comics")
        let status = RegisteredFolderStore.classify(
            folder: folder(lastKnownPath: url.path),
            resolution: .resolved(url: url, isStale: false),
            probe: nil,
            mounts: mountsWithExternal
        )
        #expect(status == .online(url: url))
    }

    // MARK: 入れ子の事後検出 [RG3-05]

    @Test func detectsNestingThatAppearedAfterRegistration() {
        let outer = RegisteredFolder(kind: .library, displayName: "外", bookmarkData: Data())
        let inner = RegisteredFolder(kind: .temporary, displayName: "内", bookmarkData: Data())
        let unrelated = RegisteredFolder(kind: .library, displayName: "無関係", bookmarkData: Data())
        let states: [UUID: RegisteredFolderStatus] = [
            outer.id: .online(url: URL(fileURLWithPath: "/Volumes/X/Comics")),
            inner.id: .online(url: URL(fileURLWithPath: "/Volumes/X/Comics/Inbox")),
            unrelated.id: .online(url: URL(fileURLWithPath: "/Volumes/X/Other")),
        ]

        let nested = RegisteredFolderStore.nestedIDs(among: [outer, inner, unrelated], states: states)

        // **両方**を返す。片方だけ警告しても直しようがない。
        #expect(nested == [outer.id, inner.id])
    }

    /// 名前が前方一致するだけの兄弟は入れ子ではない。
    @Test func siblingsWithACommonPrefixAreNotNested() {
        let lhs = RegisteredFolder(kind: .library, displayName: "A", bookmarkData: Data())
        let rhs = RegisteredFolder(kind: .library, displayName: "B", bookmarkData: Data())
        let states: [UUID: RegisteredFolderStatus] = [
            lhs.id: .online(url: URL(fileURLWithPath: "/Volumes/X/Comics")),
            rhs.id: .online(url: URL(fileURLWithPath: "/Volumes/X/ComicsOld")),
        ]

        #expect(RegisteredFolderStore.nestedIDs(among: [lhs, rhs], states: states).isEmpty)
    }

    /// 場所が分からないもの（オフライン・消失）は比較の対象外。
    /// 繋がっていないボリュームの登録に「入れ子です」と警告しても意味が無い。
    @Test func foldersWithoutAResolvedLocationAreNotComparedForNesting() {
        let online = RegisteredFolder(kind: .library, displayName: "生きている", bookmarkData: Data())
        let offline = RegisteredFolder(kind: .library, displayName: "未接続", bookmarkData: Data())
        let states: [UUID: RegisteredFolderStatus] = [
            online.id: .online(url: URL(fileURLWithPath: "/Volumes/X/Comics")),
            offline.id: .offline(lastKnownPath: "/Volumes/X/Comics/Inbox"),
        ]

        #expect(RegisteredFolderStore.nestedIDs(among: [online, offline], states: states).isEmpty)
    }
}
