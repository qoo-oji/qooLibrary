//
//  埋め込みメタデータの読み取り [EM-01〜EM-09][09章 §9.9]。
//
//  **容器を見分けて該当するバイト列を取り出すだけ**で、形式ごとの解釈は持たない
//  ——解釈は `QooKit` のパーサの仕事 [A-01]。この分離のおかげで、解釈の規則は
//  アーカイブを作らずにテストで固定できる。
//
//  `FileManager` の読み取り系しか使わない（変更系は使わない）が、
//  `CoverImageSourceResolver`／`EpubCoverResolver` と一体で使われるため
//  `FileOps/` 配下に置いている。
//
import Foundation
import QooKit

public protocol EmbeddedMetadataReading: Sendable {
    /// - Parameter kind: 呼び出し側が既に判定済みの種別。走査は列挙のときに
    ///   ディレクトリかどうかを知っているので、ここで `stat` を繰り返さない。
    func read(_ url: URL, kind: PreviewableFileKind,
              volumeSource: ComicInfoVolumeSource) async -> EmbeddedMetadata?
}

public struct EmbeddedMetadataReader: EmbeddedMetadataReading {

    /// アーカイブの読み取り。既定は形式ごとの選択（RAR は UnRAR）。
    /// テストからフェイクを刺せるよう関数で持つ。
    private let readerForURL: @Sendable (URL) -> (any ArchiveReading)?
    private let maxBytes: Int

    public init(readerForURL: @escaping @Sendable (URL) -> (any ArchiveReading)? =
                    { ArchiveBackendRegistry.reader(for: $0) },
                maxBytes: Int = AppLimits.Metadata.maxDocumentBytes) {
        self.readerForURL = readerForURL
        self.maxBytes = maxBytes
    }

    public func read(_ url: URL, kind: PreviewableFileKind,
                     volumeSource: ComicInfoVolumeSource = .ask) async -> EmbeddedMetadata? {
        switch kind {
        case .archive:
            return await readComicInfoFromArchive(url, volumeSource: volumeSource)
        case .folder:
            return await readComicInfoFromFolder(url, volumeSource: volumeSource)
        case .epub:
            return await readEpub(url)
        case .pdf:
            return await FileIO.perform { PDFMetadataExtractor.read(url) }
        case .image, .video, .other:
            return nil
        }
    }

    // MARK: - ComicInfo.xml

    private func readComicInfoFromArchive(_ url: URL,
                                          volumeSource: ComicInfoVolumeSource) async -> EmbeddedMetadata? {
        guard let reader = readerForURL(url) else { return nil }
        guard let listing = try? await reader.listEntries(url) else { return nil }
        guard let entry = ComicInfoLocator.find(in: listing) else { return nil }
        // 巨大なエントリは読まない [EM-61]。宣言サイズは信用しない [EX-20] ので
        // `readEntry` 側の上限でも守るが、開く前に分かるならそこで断る。
        guard entry.uncompressedSize <= Int64(maxBytes) else { return nil }
        guard let data = try? await reader.readEntry(url, entry: entry,
                                                     encoding: listing.detectedEncoding,
                                                     maxBytes: maxBytes) else { return nil }
        return ComicInfoParser.parse(data, volumeSource: volumeSource)
    }

    /// ブックフォルダ直下の `ComicInfo.xml` [EM-01]。
    private func readComicInfoFromFolder(_ url: URL,
                                         volumeSource: ComicInfoVolumeSource) async -> EmbeddedMetadata? {
        let maxBytes = maxBytes
        let data: Data? = await FileIO.perform {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                return nil
            }
            // 完全一致を優先しつつ、大文字小文字違いも拾う [EM-21]。
            let match = names.first { $0 == ComicInfoLocator.canonicalName }
                ?? names.first { $0.caseInsensitiveCompare(ComicInfoLocator.canonicalName) == .orderedSame }
            guard let match else { return nil }
            let file = url.appendingPathComponent(match)
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size <= maxBytes else { return nil }
            return try? Data(contentsOf: file)
        }
        guard let data else { return nil }
        return ComicInfoParser.parse(data, volumeSource: volumeSource)
    }

    // MARK: - EPUB

    private func readEpub(_ url: URL) async -> EmbeddedMetadata? {
        // EPUB は zip コンテナだが、`ArchiveFormat` は `.epub` を知らない
        // （「展開できるアーカイブ」として一般公開しない [`EpubCoverResolver`]）。
        // libarchive は拡張子ではなく実際のバイト列で判定するので、そのまま読める。
        let reader: any ArchiveReading = LibarchiveBackend.shared
        guard let listing = try? await reader.listEntries(url) else { return nil }
        let entriesByPath = EpubPackageLocator.index(listing)
        guard let opf = await EpubPackageLocator.readPackageDocument(
            for: url, reader: reader, listing: listing,
            entriesByPath: entriesByPath, maxBytes: maxBytes) else { return nil }
        return OPFMetadataParser.parse(opf)
    }
}
