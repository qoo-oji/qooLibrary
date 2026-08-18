//
//  ライブラリの走査 [10.3][SE3-01][PF-13][SL-03][SY-10]。
//
//  実ファイルを列挙して `FileSnapshot` を作るだけ。DB とは突き合わせない
//  （それは `ScanEngine` の仕事）。**この分離のおかげで走査だけを単体で試せる。**
//
import Foundation
import QooKit

public struct LibraryEnumerator: Sendable {
    public struct Options: Sendable {
        public var targetExtensions: Set<String>
        public var imageExtensions: Set<String>
        /// 走査の起点（ライブラリ根からの相対パス）。空ならライブラリ全体。
        public var subPath: String
        public var recursive: Bool

        public init(targetExtensions: Set<String>,
                    imageExtensions: Set<String> = BookFolderDetector.defaultImageExtensions,
                    subPath: String = "", recursive: Bool = true) {
            self.targetExtensions = targetExtensions
            self.imageExtensions = imageExtensions
            self.subPath = subPath
            self.recursive = recursive
        }
    }

    public init() {}

    /// 走査して `FileSnapshot` を順に渡す。
    ///
    /// - Note: **`FileIO.perform` の中から呼ぶこと** [NV6-01][NV6-02]。列挙は
    ///   実 I/O を伴い、無応答の共有では最大 30 秒ブロックしうる。
    /// - Note: 取り消しは `Cancellation.isRequested` で見る——借りたスレッドの
    ///   上では `Task.isCancelled` が常に false を返す [NV6-03]。
    public func enumerate(root: URL, libraryID: LibraryID, volumeUUID: String,
                          options: Options,
                          onSnapshot: (FileSnapshot) throws -> Void) throws {
        let start = options.subPath.isEmpty
            ? root
            : root.appendingPathComponent(options.subPath)
        let rootPath = root.standardizedFileURL.path

        var stack: [URL] = [start]
        while let directory = stack.popLast() {
            if Cancellation.isRequested { return }
            let children = try Self.children(of: directory)

            // ブックフォルダなら 1 冊として登録し、中へは降りない [IF-10][IF-12]
            if directory != root,
               BookFolderDetector.isBookFolder(directory,
                                               targetExtensions: options.targetExtensions,
                                               imageExtensions: options.imageExtensions,
                                               entries: children.map(\.entry)) {
                if let snapshot = try Self.snapshot(at: directory, rootPath: rootPath,
                                                    libraryID: libraryID, volumeUUID: volumeUUID,
                                                    isBookFolder: true) {
                    try onSnapshot(snapshot)
                }
                continue
            }

            for child in children {
                if Cancellation.isRequested { return }
                // シンボリックリンク・エイリアスは対象外 [SL-03]
                if child.entry.isSymbolicLink { continue }
                if child.entry.name.hasPrefix(".") { continue }

                if child.entry.isDirectory {
                    guard options.recursive || directory == start else { continue }
                    // `covers` は走査対象外。`.qooarchive` は**対象に含める** [SY-10]
                    if child.entry.name == "covers" { continue }
                    if options.recursive { stack.append(child.url) }
                    continue
                }
                guard options.targetExtensions.isEmpty
                        || options.targetExtensions.contains(child.entry.fileExtension) else { continue }
                if let snapshot = try Self.snapshot(at: child.url, rootPath: rootPath,
                                                    libraryID: libraryID, volumeUUID: volumeUUID,
                                                    isBookFolder: false) {
                    try onSnapshot(snapshot)
                }
            }
            if !options.recursive { break }
        }
    }

    // MARK: - 内部

    struct Child: Sendable {
        let url: URL
        let entry: DirectoryEntry
    }

    /// 属性はまとめて取る [PF-13][SE3-01]。個別 `stat` を避ける。
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey,
        .fileSizeKey, .totalFileAllocatedSizeKey,
        .contentModificationDateKey, .creationDateKey,
        .fileResourceIdentifierKey,
    ]

    static func children(of directory: URL) throws -> [Child] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: resourceKeys,
            options: [.skipsSubdirectoryDescendants])
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            return Child(url: url, entry: DirectoryEntry(
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                isSymbolicLink: (values?.isSymbolicLink ?? false) || (values?.isAliasFile ?? false)))
        }
    }

    static func snapshot(at url: URL, rootPath: String, libraryID: LibraryID,
                         volumeUUID: String, isBookFolder: Bool) throws -> FileSnapshot? {
        guard let identity = FileMetadata.identity(of: url, volumeUUID: volumeUUID) else {
            return nil
        }
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        var relative = url.standardizedFileURL.path
        guard relative.hasPrefix(rootPath + "/") else { return nil }
        relative.removeFirst(rootPath.count + 1)

        return FileSnapshot(
            identity: identity,
            libraryID: libraryID,
            relativePath: relative,
            filename: url.lastPathComponent,
            fileSize: Int64(values?.fileSize ?? 0),
            createdAt: values?.creationDate ?? .distantPast,
            modifiedAt: values?.contentModificationDate ?? .distantPast,
            isBookFolder: isBookFolder)
    }
}
