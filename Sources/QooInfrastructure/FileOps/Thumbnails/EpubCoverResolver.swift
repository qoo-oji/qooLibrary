import Foundation
import QooKit

/// EPUB（固定レイアウトの画像ベースのコミック EPUB を主な対象とする）から、
/// 先頭ページの画像データを取り出す [ユーザー要望: qooLibrary は qooViewer
/// のフロントエンドとして設計されており、qooViewer が対応するファイル形式
/// （PDF・EPUB）は qooLibrary 側でも網羅する必要がある]。
///
/// 姉妹プロジェクト qooViewer の `Services/EpubStructureResolver.swift`
/// （container.xml → package document(OPF) → spine → 各項目の画像解決）と
/// 同じアルゴリズムを、**サムネイル1枚分**にスコープを絞って移植したもの。
/// qooViewer 版と異なり、ページ全体の読み順・目次（nav.xhtml）・見開き
/// ヒント・読み方向は qooLibrary には不要なため持たない——spine の先頭から
/// 実際に画像1枚を特定できる項目が見つかるまで走査するだけに留める
/// （通常は1件目で見つかる）。
///
/// EPUB 自体は zip コンテナのため、読み取りは既存の `ArchiveReading`
/// （既定 `LibarchiveBackend.shared`）をそのまま使う。**`ArchiveFormat`
/// による拡張子判定を経由せず直接呼ぶ**——EPUB を「展開・圧縮できる
/// アーカイブ」として `ArchiveBackendRegistry`/中央ペインの「展開」メニュー
/// 等に一般公開すると意味が変わってしまう（EPUB はユーザーが個別ファイルへ
/// ばらして展開する対象ではない）ため、あくまでサムネイル生成専用の内部
/// 利用に限定している。libarchive のアーカイブ読み取り自体は拡張子ではなく
/// 実際のバイト列（zip シグネチャ）で判定するため、`.epub` のまま渡しても
/// 正しく zip として読める。
public enum EpubCoverResolver {
    private static let containerPath = "META-INF/container.xml"

    public static func firstPageImageData(
        for url: URL,
        reader: any ArchiveReading = LibarchiveBackend.shared,
        maxBytes: Int
    ) async -> Data? {
        guard let listing = try? await reader.listEntries(url) else { return nil }
        let entriesByPath = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.pathname, $0) })
        let allPaths = Set(entriesByPath.keys)

        guard let containerData = await read(entriesByPath[containerPath], url: url, reader: reader, listing: listing, maxBytes: maxBytes),
              let rawOpfPath = resolveOPFPath(from: containerData)
        else { return nil }
        let opfPath = matchExistingPath(rawOpfPath, in: allPaths) ?? rawOpfPath
        guard let opfData = await read(entriesByPath[opfPath], url: url, reader: reader, listing: listing, maxBytes: maxBytes)
        else { return nil }

        let packageDocument = parsePackageDocument(data: opfData)
        let opfDirectory = directory(of: opfPath)

        for idref in packageDocument.spineItemRefs {
            guard let manifestItem = packageDocument.manifestItems[idref] else { continue }
            guard let imagePath = await resolveImagePath(
                for: manifestItem, baseDirectory: opfDirectory, url: url, reader: reader,
                listing: listing, entriesByPath: entriesByPath, allPaths: allPaths, maxBytes: maxBytes
            ) else { continue }
            guard let imageData = await read(entriesByPath[imagePath], url: url, reader: reader, listing: listing, maxBytes: maxBytes)
            else { continue }
            return imageData
        }
        return nil
    }

    private static func read(
        _ entry: ArchiveEntry?, url: URL, reader: any ArchiveReading, listing: ArchiveListing, maxBytes: Int
    ) async -> Data? {
        guard let entry else { return nil }
        return try? await reader.readEntry(url, entry: entry, encoding: listing.detectedEncoding, maxBytes: maxBytes)
    }

    // MARK: - container.xml

    private static func resolveOPFPath(from data: Data) -> String? {
        let delegate = ContainerDocumentParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let opfPath = delegate.opfPath, !opfPath.isEmpty else { return nil }
        return opfPath
    }

    // MARK: - package document (OPF)

    private static func parsePackageDocument(data: Data) -> PackageDocumentParserDelegate {
        let delegate = PackageDocumentParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate
    }

    // MARK: - 各 spine 項目 → 実際の画像パスの解決 [qooViewer の resolveImagePath と同じ規則]

    private static func resolveImagePath(
        for manifestItem: PackageDocumentParserDelegate.ManifestItem,
        baseDirectory: String,
        url: URL,
        reader: any ArchiveReading,
        listing: ArchiveListing,
        entriesByPath: [String: ArchiveEntry],
        allPaths: Set<String>,
        maxBytes: Int
    ) async -> String? {
        let itemPath = resolvedPath(base: baseDirectory, relative: manifestItem.href)
        let mediaType = manifestItem.mediaType

        let looksLikeImage = mediaType.hasPrefix("image/")
            || (mediaType.isEmpty && isImageExtension(manifestItem.href))
        if looksLikeImage {
            return matchExistingPath(itemPath, in: allPaths)
        }

        let looksLikeMarkup = mediaType.contains("html") || mediaType.contains("xml")
            || (mediaType.isEmpty && looksLikeMarkupExtension(manifestItem.href))
        guard looksLikeMarkup, let resolvedItemPath = matchExistingPath(itemPath, in: allPaths) else { return nil }

        guard let contentData = await read(entriesByPath[resolvedItemPath], url: url, reader: reader, listing: listing, maxBytes: maxBytes)
        else { return nil }

        guard let imageHref = firstImageReference(in: contentData) else { return nil }
        let contentDirectory = directory(of: resolvedItemPath)
        let imagePath = resolvedPath(base: contentDirectory, relative: imageHref)
        return matchExistingPath(imagePath, in: allPaths)
    }

    private static func isImageExtension(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "tif", "tiff", "avif"].contains(ext)
    }

    private static func looksLikeMarkupExtension(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "xhtml" || ext == "html" || ext == "htm" || ext == "xml"
    }

    private static func firstImageReference(in data: Data) -> String? {
        let delegate = FirstImageReferenceParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        if parser.parse(), let href = delegate.imageHref {
            return href
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let patterns = [
            #"<img[^>]+src=["']([^"']+)["']"#,
            #"<image[^>]+(?:xlink:href|href)=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let hrefRange = Range(match.range(at: 1), in: text) {
                return String(text[hrefRange])
            }
        }
        return nil
    }

    // MARK: - パス解決のユーティリティ [qooViewer の EpubStructureResolver と同じ規則]

    private static func directory(of path: String) -> String {
        guard let slashIndex = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slashIndex])
    }

    private static func resolvedPath(base: String, relative: String) -> String {
        var relative = relative
        if let hashIndex = relative.firstIndex(of: "#") {
            relative = String(relative[..<hashIndex])
        }
        if let decoded = relative.removingPercentEncoding {
            relative = decoded
        }
        if relative.hasPrefix("/") {
            return String(relative.dropFirst())
        }

        var components = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/") {
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else if part == "." || part.isEmpty {
                continue
            } else {
                components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    private static func matchExistingPath(_ candidate: String, in allPaths: Set<String>) -> String? {
        if allPaths.contains(candidate) { return candidate }
        let trimmed = candidate.hasPrefix("./") ? String(candidate.dropFirst(2)) : candidate
        if allPaths.contains(trimmed) { return trimmed }
        return allPaths.first { $0 == trimmed || $0.hasSuffix("/\(trimmed)") }
    }
}

private nonisolated final class ContainerDocumentParserDelegate: NSObject, XMLParserDelegate {
    private(set) var opfPath: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        guard opfPath == nil, localName(of: elementName) == "rootfile" else { return }
        opfPath = attributeDict["full-path"]
    }
}

private nonisolated final class PackageDocumentParserDelegate: NSObject, XMLParserDelegate {
    struct ManifestItem {
        let href: String
        let mediaType: String
    }

    private(set) var manifestItems: [String: ManifestItem] = [:]
    private(set) var spineItemRefs: [String] = []

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(of: elementName) {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifestItems[id] = ManifestItem(href: href, mediaType: attributeDict["media-type"] ?? "")
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spineItemRefs.append(idref)
            }
        default:
            break
        }
    }
}

private nonisolated final class FirstImageReferenceParserDelegate: NSObject, XMLParserDelegate {
    private(set) var imageHref: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        guard imageHref == nil else { return }
        switch localName(of: elementName) {
        case "img":
            imageHref = attributeDict["src"]
        case "image":
            imageHref = attributeDict["xlink:href"] ?? attributeDict["href"]
        default:
            break
        }
    }
}

private nonisolated func localName(of elementName: String) -> String {
    guard let colonIndex = elementName.lastIndex(of: ":") else { return elementName }
    return String(elementName[elementName.index(after: colonIndex)...])
}
