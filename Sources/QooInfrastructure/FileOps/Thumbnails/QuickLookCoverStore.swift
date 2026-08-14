import CoreGraphics
import Foundation
import ImageIO
import QooKit
import UniformTypeIdentifiers

/// Quick Look の独自カバープレビュー [QL-03][QL-08] に渡す「実ファイル」を用意する。
///
/// **なぜ実ファイルが要るのか**: `QLPreviewPanel` は項目ごとに独自ビューを
/// 差し込む API を持たない（`QLPreviewPanel.h` を実際に確認済み。データ源は
/// `QLPreviewItem.previewItemURL`、つまりファイル URL だけ）。そのため
/// 「コミックアーカイブのカバーを大きく表示する」には、アーカイブ内の先頭
/// 画像をいったんファイルとして書き出し、その URL をパネルへ渡す必要がある
/// [設計判断、仕様書 9.7 節 QL2-08 の記述を実際の API に合わせて訂正した]。
///
/// **書き出すのは再エンコードしない原画像のバイト列そのもの**［設計判断］。
/// サムネイルキャッシュ（`CoverImageCache`、グリッド用に縮小した PNG）を
/// 流用すると Quick Look の大きな表示ではぼやけるため、専用にこの store を
/// 設ける。原画像をそのまま渡すことで、標準 Quick Look の画像ビューアが持つ
/// ズーム・フルスクリーン・実寸表示がそのまま活きる。
///
/// **キャッシュはセッション限り**［設計判断］。アプリ起動時に ``purgeAll()``
/// で丸ごと捨てる（`SecureExtractor.cleanupResidualStaging()` と同じ、
/// 異常終了しても次回起動で必ず片付く方式）。プレビューは都度の一時的な
/// 表示であり、再起動をまたいで保持する価値が薄い一方、原画像をそのまま
/// 置くためサイズが大きくなりやすいため。
///
/// `FileManager` の変更系 API（ディレクトリ作成・削除）を使うため、B-10 の
/// 許可ディレクトリである `QooInfrastructure/FileOps/` 配下に置いている
/// ——ユーザーに見えないアプリ内部のキャッシュで、期待変更台帳・Undo の
/// 対象外という点で `SecureExtractor`/`CoverImageCache` と同じ設計判断。
public protocol QuickLookCoverProviding: Sendable {
    /// `url`（アーカイブ・フォルダ等）のカバー画像を書き出し、その URL を返す。
    /// カバーを取り出せない場合は `nil`（呼び出し側は元の URL のまま標準
    /// Quick Look に委ねる）。
    func coverFileURL(for url: URL) async -> URL?
    /// 書き出し済みのカバーをすべて捨てる。アプリ起動時に一度呼ぶ。
    func purgeAll() async
}

public actor QuickLookCoverStore: QuickLookCoverProviding {
    public static let shared = QuickLookCoverStore()

    private let baseDirectory: URL
    private let imageLoader: ImageLoading
    private let maxCacheSize: Int64
    /// 書き出し済みのカバー（キー → 実ファイル URL）。``purgeAll()`` を起動時に
    /// 呼ぶ前提のため、このセッションで書き出したものだけを持てば十分で、
    /// ディレクトリを走査し直す必要が無い。
    private var writtenCovers: [String: URL] = [:]

    /// テストでは独立した一時ディレクトリを渡せる（`DefaultCoverImageCache`/
    /// `SecureExtractor` の注入と同じ設計判断。CI でのテスト間の競合を避ける）。
    public init(
        baseDirectory: URL? = nil,
        imageLoader: ImageLoading = DefaultImageLoader(),
        maxCacheSize: Int64 = AppLimits.QuickLook.defaultCoverCacheMaxSize
    ) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = appSupport.appendingPathComponent("qooLibrary/quicklook", isDirectory: true)
        }
        self.imageLoader = imageLoader
        self.maxCacheSize = maxCacheSize
    }

    public func coverFileURL(for url: URL) async -> URL? {
        guard let key = Self.cacheKey(for: url) else { return nil }
        if let existing = writtenCovers[key], FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        guard let data = await CoverImageSourceResolver.firstImageData(for: url) else { return nil }
        guard let written = write(data, key: key) else { return nil }
        writtenCovers[key] = written
        pruneIfNeeded(keeping: written)
        return written
    }

    public func purgeAll() async {
        try? FileManager.default.removeItem(at: baseDirectory)
        writtenCovers.removeAll()
    }

    // MARK: - 書き出し

    private func write(_ data: Data, key: String) -> URL? {
        // [QL-10][IM-05] Quick Look 用の読み込みにも画像の安全上限を適用する。
        // ピクセル数が上限を超える画像は縮小せずに**諦める** [IM-01 の
        // 「超過は生成をスキップ」と同じ方針]。呼び出し側は元の URL のまま
        // 標準 Quick Look へ委ね、アーカイブアイコンが表示される。
        guard imageLoader.isWithinPixelCountLimit(data) else { return nil }
        // 拡張子は**エントリ名ではなく実データ**から決める。アーカイブ内の
        // エントリ名は拡張子を持たない／実体と食い違うことがあり、Quick Look は
        // 拡張子から描画方法を決めるため、実データの UTI を信頼するほうが確実。
        guard let fileExtension = Self.filenameExtension(of: data) else { return nil }
        let destination = baseDirectory.appendingPathComponent("\(key).\(fileExtension)")
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            Log.image.error("Quick Look 用カバーの書き出しに失敗: \(Log.path(destination)) — \(error.localizedDescription)")
            return nil
        }
    }

    /// `volumeUUID-inode-mtime`。**更新日時を含める**ことで、アーカイブが
    /// 差し替わったときに古いカバーを返さない（`CoverImageCache` は identity
    /// のみでキー付けしており同種の課題を抱えているが、こちらは毎起動で捨てる
    /// キャッシュのため素直に含められる）。
    ///
    /// **フォルダの場合の限界**: ディレクトリの更新日時は「項目の追加・削除・
    /// 改名」では変わるが、「配下の画像ファイルの中身だけを書き換えた」場合は
    /// 変わらない。その場合は同一セッション中に限り古いカバーが返る
    /// （アプリを再起動すればキャッシュごと捨てられる）。カバー画像を特定する
    /// までフォルダを走査しないと正確な判定ができず、キャッシュの目的
    /// （走査を省く）と矛盾するため、この限界は受け入れる [設計判断]。
    private static func cacheKey(for url: URL) -> String? {
        var statInfo = stat()
        guard stat(url.path, &statInfo) == 0 else { return nil }
        let volumeUUID = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? ""
        return "\(volumeUUID)-\(statInfo.st_ino)-\(statInfo.st_mtimespec.tv_sec)"
    }

    private static func filenameExtension(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier)
        else { return nil }
        return type.preferredFilenameExtension
    }

    // MARK: - 上限 [AppLimits.QuickLook.defaultCoverCacheMaxSize]

    /// 合計サイズが上限を超えていたら、古いものから削除する
    /// （`DefaultCoverImageCache.prune(toMaxSize:)` と同じ規則）。
    ///
    /// **今書き出したばかりのファイル（`keeping`）は削除対象から外す**——
    /// これから Quick Look へ渡す当のファイルを消してしまい、実体の無い URL を
    /// 返すことになるため（上限が 1 件ぶんも無いほど小さく設定された場合に
    /// 実際に起きる）。
    private func pruneIfNeeded(keeping: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: Array(keys)
        )) ?? []
        var entries = files.map { url -> (url: URL, size: Int64, date: Date) in
            let values = try? url.resourceValues(forKeys: keys)
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxCacheSize else { return }
        entries.sort { $0.date < $1.date }

        var removed: Set<URL> = []
        for entry in entries where entry.url != keeping {
            guard total > maxCacheSize else { break }
            try? FileManager.default.removeItem(at: entry.url)
            removed.insert(entry.url)
            total -= entry.size
        }
        // 削除したものを索引からも落とす（残しておくと、実体の無いファイルを
        // 「キャッシュ済み」として返してしまう）。
        writtenCovers = writtenCovers.filter { !removed.contains($0.value) }
    }
}
