import Foundation

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

    public enum Kind: Sendable, Hashable {
        case volume, temporary, library, plainFolder
    }

    public init(
        url: URL, displayName: String? = nil, kind: Kind,
        isOnline: Bool = true, isSymlink: Bool = false, isLocked: Bool = false
    ) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.kind = kind
        self.isOnline = isOnline
        self.isSymlink = isSymlink
        self.isLocked = isLocked
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
            return FolderTreeNode(url: url, displayName: name, kind: .volume)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

public enum FolderTreeAccessError: Error {
    case denied(underlying: NSError)
}
