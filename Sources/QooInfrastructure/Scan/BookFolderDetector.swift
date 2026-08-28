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

    /// 設定の `imageExtensions` の実効値。**空は「既定」を意味する**——
    /// テンプレート草案は空で来る（`TemplateDefinition` 参照）ため、空を
    /// 文字どおり「画像拡張子なし」と読むと、ブックフォルダが 1 つも
    /// 検出されない。**この解釈はここ 1 箇所**——走査（`ScanEngine`）と
    /// 登録ウィザードの推定が同じ関数を通る（別々に解釈を持つと、
    /// ウィザードには出ないのに走査では検出される、という食い違いになる。
    /// 実機検証で実際に踏んだ形 [§19.10 ステージ 2]）。
    public static func effectiveImageExtensions(from configured: some Collection<String>) -> Set<String> {
        configured.isEmpty ? defaultImageExtensions
                           : Set(configured.map { $0.lowercased() })
    }

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
