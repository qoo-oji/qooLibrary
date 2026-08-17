import Foundation
import QooInfrastructure

/// フォルダツリーの 1 ノード [14章 §14.2]。
public struct FolderTreeNode: Identifiable, Sendable, Hashable {
    public let id: String // 正規化パス
    public let url: URL
    public let displayName: String // 登録フォルダは displayName [LP-03]
    public let kind: Kind
    public var isOnline: Bool = true // オフラインはグレーアウト [LP-04]
    public var isSymlink: Bool = false // バッジ表示 [SL-06]、展開不可 [SL-05]
    /// Finder の「ロック」（`.isUserImmutableKey`）。コンテキストメニューで
    /// 「ロック」/「ロック解除」のどちらを出すかの判定に使う
    /// [`FolderTreeContextMenu` 参照]。**`children(of:)` が子の一覧を作る
    /// ついでにまとめて読む**——メニューを組み立てるたびに 1 行ずつ
    /// `resourceValues` を呼ぶと、行数分のファイルシステムアクセスが描画の
    /// たびに発生するため（中央ペインが `FolderEntry.isLocked` を
    /// `reload()` で一括取得しているのと同じ考え方）。
    public var isLocked: Bool = false
    /// 取り出せるボリュームか [1-16、Finder の「取り出す」相当]。ボリューム
    /// ルート行にだけ意味があり、それ以外は常に `false`。`isLocked` と同じく
    /// **一覧を作るときにまとめて読む**（メニューを組み立てるたびに
    /// `resourceValues` を呼ばない）。
    public var isEjectableVolume: Bool = false
    /// ネットワーク越しのボリュームか [NV-96]。取り出す操作の**呼び名**を
    /// 「接続解除」に変えるためだけに使う（Finder に合わせる）。
    public var isNetworkVolume: Bool = false

    public enum Kind: Sendable, Hashable {
        case volume, temporary, library, plainFolder
    }

    public init(
        url: URL, displayName: String? = nil, kind: Kind,
        isOnline: Bool = true, isSymlink: Bool = false, isLocked: Bool = false,
        isEjectableVolume: Bool = false,
        isNetworkVolume: Bool = false
    ) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.kind = kind
        self.isOnline = isOnline
        self.isSymlink = isSymlink
        self.isLocked = isLocked
        self.isEjectableVolume = isEjectableVolume
        self.isNetworkVolume = isNetworkVolume
    }

    /// 子ノードを列挙する。実 FileManager 呼び出しを伴う（読み取りのみ、
    /// FileOps 隔離検査の対象である「変更系 API」ではない）。
    /// アクセス権がない場合は `FolderTreeAccessError` を投げる [SB-04]。
    public static func children(of node: FolderTreeNode) throws -> [FolderTreeNode] {
        guard !node.isSymlink else { return [] } // [SL-05] 展開不可

        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: node.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUserImmutableKey],
                options: [.skipsHiddenFiles]
            )
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {
            // **「読めなかった」を全部「アクセス権がありません」に丸めない** [1-17]。
            //
            // ボリュームが取り外されただけでも `NSCocoaErrorDomain` の失敗に
            // なるため、以前はそのとき環境設定「アクセス権」タブへ誘導して
            // いた——許可を足しても直らないので、ユーザーは行き止まりに入る。
            // 原因が違えば次の一手も違う。
            //
            // 判定はマウント表と突き合わせるだけで、**当のパスには触れない**
            // [NV6-02]——触れば、応答しない共有ではそこでまた止まる。
            if MountTable.current().isOnAnUnmountedVolume(node.url) {
                throw FolderTreeAccessError.volumeNotMounted
            }
            throw FolderTreeAccessError.denied(underlying: error)
        }

        return contents
            .compactMap { url -> FolderTreeNode? in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUserImmutableKey])
                guard values?.isDirectory == true else { return nil } // ツリーはフォルダのみ
                // ライブラリ配下の .qooarchive はツリーに表示しない [LP-08][FA-11]
                if url.lastPathComponent == ".qooarchive" { return nil }
                return FolderTreeNode(
                    url: url,
                    kind: node.kind == .volume ? .volume : node.kind,
                    isSymlink: values?.isSymbolicLink ?? false,
                    isLocked: values?.isUserImmutable ?? false
                )
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// トップレベル: マウント中のボリューム一覧 [LP2 表: ボリューム グループ]。
    public static func mountedVolumes() -> [FolderTreeNode] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return urls.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            return FolderTreeNode(
                url: url,
                displayName: name,
                kind: .volume,
                isEjectableVolume: VolumeEjector.isEjectable(url), // [1-16]
                isNetworkVolume: VolumeEjector.isNetworkVolume(url) // [NV-96]
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

public enum FolderTreeAccessError: Error {
    /// アクセス権が無い [SB-04]。環境設定「アクセス権」タブで許可すれば直る。
    case denied(underlying: NSError)
    /// ボリュームが接続されていない [1-17][SB-05]。**許可を足しても直らない**
    /// ので、`denied` とは別に扱って別の案内を出す。
    case volumeNotMounted
}
