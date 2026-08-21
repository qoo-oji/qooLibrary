//
//  EPUB の package document（OPF）を取り出す [EM-40]。
//
//  **カバー画像の解決（`EpubCoverResolver`）と埋め込みメタデータの読み取り
//  （`EmbeddedMetadataReader`）の両方が同じ手順を要する**ため、ここへ集約する。
//  片方だけ直る事故を構造的に避ける。
//
import Foundation
import QooKit

enum EpubPackageLocator {
    static let containerPath = "META-INF/container.xml"

    /// エントリのパス → エントリ。
    ///
    /// **`uniqueKeysWithValues:` は使わない** [2026-08 全体点検] — あちらは
    /// キー重複で fatalError する。zip に同名エントリが複数あるのは現実に
    /// あり得る形（更新エントリの追記）。畳み方は**先勝ち**——実際にバイト列を
    /// 読む `readEntry` がアーカイブを先頭から走査して最初の一致を返すため。
    static func index(_ listing: ArchiveListing) -> [String: ArchiveEntry] {
        Dictionary(listing.entries.map { ($0.pathname, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `META-INF/container.xml` を読んで OPF のパスを得る。
    static func opfPath(fromContainer data: Data) -> String? {
        let delegate = ContainerDelegate()
        guard SafeXMLParsing.parse(data, delegate: delegate) else { return nil }
        guard let path = delegate.opfPath, !path.isEmpty else { return nil }
        return path
    }

    /// 宣言されたパスを実在するエントリ名へ寄せる。
    ///
    /// zip の中のパスは `./` が付いたり、書き出したツールによって先頭の
    /// フォルダが違ったりする。完全一致 → `./` を落とした一致 → 末尾一致 の順で探す。
    static func matchExistingPath(_ candidate: String, in allPaths: Set<String>) -> String? {
        if allPaths.contains(candidate) { return candidate }
        let trimmed = candidate.hasPrefix("./") ? String(candidate.dropFirst(2)) : candidate
        if allPaths.contains(trimmed) { return trimmed }
        return allPaths.first { $0 == trimmed || $0.hasSuffix("/\(trimmed)") }
    }

    /// container.xml → OPF の 2 段を辿って package document のバイト列を返す。
    static func readPackageDocument(
        for url: URL, reader: any ArchiveReading, listing: ArchiveListing,
        entriesByPath: [String: ArchiveEntry], maxBytes: Int
    ) async -> Data? {
        guard let containerEntry = entriesByPath[containerPath],
              let containerData = try? await reader.readEntry(
                url, entry: containerEntry, encoding: listing.detectedEncoding, maxBytes: maxBytes),
              let rawPath = opfPath(fromContainer: containerData)
        else { return nil }

        let allPaths = Set(entriesByPath.keys)
        let path = matchExistingPath(rawPath, in: allPaths) ?? rawPath
        guard let entry = entriesByPath[path] else { return nil }
        return try? await reader.readEntry(url, entry: entry,
                                           encoding: listing.detectedEncoding, maxBytes: maxBytes)
    }

    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        private(set) var opfPath: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            guard opfPath == nil, elementName == "rootfile" else { return }
            opfPath = attributeDict["full-path"]
        }
    }
}
