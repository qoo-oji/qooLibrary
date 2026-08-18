//
//  ブックフォルダ判定 [8.9][IF-01〜IF-05][BF-01]。
//
import Foundation
import QooKit

public struct DirectoryEntry: Sendable, Hashable {
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool

    public init(name: String, isDirectory: Bool, isSymbolicLink: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }

    /// 小文字化した拡張子（`.` は含まない）。
    public var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}

public enum BookFolderDetector {
    /// 既定の画像拡張子 [IF-02]。ライブラリ設定で追加・削除できる。
    public static let defaultImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "bmp", "tiff",
    ]

    /// 判定対象から外すフォルダ名 [IF-03]。
    public static let excludedFolderNames: Set<String> = ["covers", ".qooarchive"]

    /// ① サブフォルダを持たない ② 直下に対象拡張子ファイルが 0 件
    /// ③ 直下に画像ファイルが 1 件以上 [IF-01]。
    public static func isBookFolder(_ url: URL,
                                    targetExtensions: Set<String>,
                                    imageExtensions: Set<String> = defaultImageExtensions,
                                    entries: [DirectoryEntry]) -> Bool {
        let name = url.lastPathComponent
        if excludedFolderNames.contains(name) || name.hasPrefix(".") { return false }  // [IF-03]

        var sawImage = false
        for entry in entries {
            if entry.name.hasPrefix(".") { continue }          // 隠しファイルは数えない
            // シンボリックリンクは追跡しない [SL-03]。フォルダへのリンクを
            // 「サブフォルダあり」と数えると、リンクを置いただけで 1 冊扱いが
            // 解除されてしまう。
            if entry.isSymbolicLink { continue }
            if entry.isDirectory { return false }              // ①
            let ext = entry.fileExtension
            if targetExtensions.contains(ext) { return false } // ②
            if imageExtensions.contains(ext) { sawImage = true }
        }
        return sawImage                                        // ③
    }
}
