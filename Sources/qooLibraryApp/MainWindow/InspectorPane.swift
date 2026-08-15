import AppKit
import QooInfrastructure
import QooKit
import SwiftUI
import UniformTypeIdentifiers

/// 右ペイン（インスペクタ）[14章 §14.4、DT-01〜DT-07/DT-10]。単一選択時は
/// すべての情報、複数選択時は共通情報のみを表示する [RP-02]。何も選択されて
/// いない場合は現在のフォルダ自身の情報を表示する（Finder には無い挙動だが、
/// 常設インスペクタとして常に何か表示されている方が有用なため）[設計判断]。
///
/// タイトル編集・ラベル・評価・カバー画像の差し替え（DT-08/09/11、
/// RP-10〜12、RL-01〜09、RA-01〜08、CV2-02〜08）は SwiftData の
/// `Library`/`ManagedFile` が前提の Phase 2 機能のため未実装。アプリの
/// 関連付け表示（DT-07）も `AppAssociationService`（1-12 で実装予定）が無いため
/// 未実装。カバー画像の「表示」（CV2-01 相当）のみ、1-9 で作った
/// `ThumbnailService`/`FileIconProvider` を再利用して実装する。
struct InspectorPane: View {
    @Environment(\.locale) private var locale
    let folder: URL?
    let selection: Set<URL>
    /// カバー画像の表示もサムネイル一括トグルに従う [DS-06][CV2-01]。
    let thumbnailsHidden: Bool

    private var targets: [URL] {
        if selection.isEmpty {
            return folder.map { [$0] } ?? []
        }
        return Array(selection)
    }

    var body: some View {
        Group {
            if targets.isEmpty {
                PlaceholderPane(title: String(localized: "inspector.title", locale: locale), subtitle: "")
            } else if targets.count == 1 {
                SingleItemInspector(url: targets[0], thumbnailsHidden: thumbnailsHidden)
            } else {
                MultiItemInspector(urls: targets)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SingleItemInspector: View {
    let url: URL
    let thumbnailsHidden: Bool

    @State private var info: FileDetailInfo?
    @State private var containedCounts: ContainedCounts?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                InspectorThumbnail(url: url, thumbnailsHidden: thumbnailsHidden)
                Text(url.lastPathComponent)
                    .font(.system(size: Tokens.fontSize.title2, weight: .semibold))
                    .lineLimit(3)

                if let info {
                    Divider()
                    LabeledContent("column.kind", value: info.kindDescription) // [DT-04]
                    if !info.isDirectory {
                        LabeledContent("column.size", value: Self.sizeFormatter.string(fromByteCount: info.size ?? 0)) // [DT-03]
                    }
                    LabeledContent("column.creationDate", value: info.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "—") // [DT-01]
                    LabeledContent("column.modificationDate", value: info.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—") // [DT-02]

                    if info.isDirectory || info.isArchive {
                        Divider()
                        if let containedCounts {
                            LabeledContent("inspector.containedFileCount", value: "\(containedCounts.fileCount)") // [DT-05]
                            LabeledContent("inspector.containedFolderCount", value: "\(containedCounts.folderCount)") // [DT-06]
                            if info.isDirectory {
                                LabeledContent("inspector.totalContentSize", value: Self.sizeFormatter.string(fromByteCount: containedCounts.totalSize))
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }

                    Divider()
                    LabeledContent("inspector.location") {
                        Text(url.deletingLastPathComponent().path)
                            .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("inspector.fullPath") { // [DT-10]
                        Text(url.path)
                            .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(6)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(Tokens.spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // `.task(id: url)` は選択が変わるたびに前のタスクを自動キャンセルする
        // ため、大きなフォルダを選んだ直後に別の項目へ切り替えても古い集計が
        // 表示され続けることはない。
        .task(id: url) {
            info = nil
            containedCounts = nil
            info = Self.loadInfo(for: url)
            guard let info, info.isDirectory || info.isArchive else { return }
            containedCounts = await Self.computeContainedCounts(for: url, isArchive: info.isArchive)
        }
    }

    private static func loadInfo(for url: URL) -> FileDetailInfo? {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ]) else { return nil }
        let isDirectory = values.isDirectory ?? false
        let isArchive = !isDirectory && ArchiveFormat.from(filename: url.lastPathComponent) != nil
        return FileDetailInfo(
            isDirectory: isDirectory,
            isArchive: isArchive,
            size: values.fileSize.map(Int64.init),
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            kindDescription: Self.kindDescription(for: url, isDirectory: isDirectory)
        )
    }

    /// `FolderContentView.FolderEntry.kindDescription` と同じロジック。
    /// 専用の共有ヘルパーに切り出すほどの規模ではないため、意図的にここでも
    /// 同じ数行を持つ（`ThumbnailService.identity(of:)` と同じ理由）。
    private static func kindDescription(for url: URL, isDirectory: Bool) -> String {
        let locale = AppLanguage.effectiveLocale
        if isDirectory { return String(localized: "kind.folder", locale: locale) }
        let ext = url.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription {
            return description
        }
        guard !ext.isEmpty else { return String(localized: "kind.document", locale: locale) }
        return String(format: String(localized: "kind.extensionFile", locale: locale), ext.uppercased())
    }

    /// [DT-05][DT-06] 遅延読み込み。仕様書は DB キャッシュを前提とするが、
    /// フェーズ1にはまだ DB が無いため、選択のたびに再計算する（キャッシュは
    /// フェーズ2で追加）。フォルダは実サイズも大きくなり得る（C-07: 1 ライブラリ
    /// 1万〜5万ファイル）ため `Task.detached` で actor 分離の外へ逃がし、
    /// 列挙ループ内で定期的にキャンセルを確認する。
    private static func computeContainedCounts(for url: URL, isArchive: Bool) async -> ContainedCounts? {
        if isArchive {
            return await computeArchiveCounts(url)
        }
        return await Task.detached(priority: .utility) {
            computeFolderCounts(url)
        }.value
    }

    nonisolated private static func computeFolderCounts(_ url: URL) -> ContainedCounts {
        var fileCount = 0
        var folderCount = 0
        var totalSize: Int64 = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else {
            return ContainedCounts(fileCount: 0, folderCount: 0, totalSize: 0)
        }
        for case let itemURL as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { continue }
            if values.isDirectory == true {
                folderCount += 1
            } else {
                fileCount += 1
                totalSize += Int64(values.fileSize ?? 0)
            }
        }
        return ContainedCounts(fileCount: fileCount, folderCount: folderCount, totalSize: totalSize)
    }

    private static func computeArchiveCounts(_ url: URL) async -> ContainedCounts? {
        guard let backend = ArchiveBackendRegistry.reader(for: url) else { return nil }
        guard let listing = try? await backend.listEntries(url) else { return nil }
        var fileCount = 0
        var folderCount = 0
        var totalSize: Int64 = 0
        for entry in listing.entries {
            if entry.isDirectory {
                folderCount += 1
            } else if !entry.isSymlink && !entry.isSpecialEntry {
                fileCount += 1
                totalSize += entry.uncompressedSize
            }
        }
        return ContainedCounts(fileCount: fileCount, folderCount: folderCount, totalSize: totalSize)
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct FileDetailInfo {
    let isDirectory: Bool
    let isArchive: Bool
    let size: Int64?
    let creationDate: Date?
    let modificationDate: Date?
    let kindDescription: String
}

private struct ContainedCounts {
    let fileCount: Int
    let folderCount: Int
    let totalSize: Int64
}

/// 複数選択時は共通情報のみ [RP-02]。ラベルの一括付与・削除は Phase 2
/// （ラベルドメイン型が無いため）。
private struct MultiItemInspector: View {
    @Environment(\.locale) private var locale
    let urls: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            Text(String(format: String(localized: "inspector.itemsSelected", locale: locale), urls.count))
                .font(.system(size: Tokens.fontSize.title2, weight: .semibold))
            Divider()
            LabeledContent("inspector.totalSize", value: Self.sizeFormatter.string(fromByteCount: Self.totalSize(of: urls)))
        }
        .padding(Tokens.spacing.m)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// `FileInfoSheet`（1-9 までの簡易版）と同じ単純化: フォルダは中身を
    /// 再帰的に足し込まず、ファイルのサイズだけを合計する（多数選択時に
    /// 重い再帰列挙を避けるため）。
    private static func totalSize(of urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { total, url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                  values.isDirectory != true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

/// フォルダ/アーカイブ/画像ファイルのサムネイル、生成できない場合は Finder
/// アイコンにフォールバックする [IV-01/08、`FileIconProvider` 参照]。
/// `IconGridView.ThumbnailImage` と似た構造だが、表示サイズ・余白の付け方が
/// 異なる（グリッドセルは正方形、こちらは横幅いっぱいの固定高さ）ため、
/// 専用の共有コンポーネントへ切り出すほどの規模ではないと判断し、意図的に
/// 個別実装にしている。
private struct InspectorThumbnail: View {
    let url: URL
    let thumbnailsHidden: Bool

    /// `IconGridView.ThumbnailImage.RequestKey` と同じ役割・同じ理由
    /// （非表示への切替で生成を取り消し、再表示で生成し直す [DS-05]）。
    private struct RequestKey: Equatable {
        let url: URL
        let hidden: Bool
    }

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: FileIconProvider.shared.icon(for: url))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(Tokens.spacing.xl)
            }
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
        .task(id: RequestKey(url: url, hidden: thumbnailsHidden)) {
            image = nil
            guard !thumbnailsHidden else { return } // [DS-06]
            guard let cgImage = await ThumbnailService.shared.thumbnail(for: url, maxPixelSize: 320) else { return }
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }
}
