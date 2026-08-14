import CoreGraphics
import Foundation
import ImageIO
import QooKit

/// 画像読み込みの防御 [9.5 節、EX-30〜EX-34]。ヘッダのみでの寸法チェックと
/// `ImageIO` のサムネイル生成 API を使い、悪意ある/巨大な画像でアプリ全体を
/// 巻き込まないようにする。実ファイルには触れない（`FileManager` を使わない）
/// ため `FileOps/` の他ファイルとは異なり B-10 の対象ではないが、`readEntry`
/// や `CoverImageCache` と一緒に使われることが多いためこのディレクトリに
/// 置いている。
public protocol ImageLoading: Sendable {
    /// ヘッダのみを読んで寸法を取得する（デコードしない）[EX-31]
    func imageSize(from data: Data) -> CGSize?
    /// ピクセル数上限 [IM-01] に収まっているか。上限値そのものは実装が持つ
    /// （`makeThumbnail` が内部で行う事前判定と同じ基準）。
    ///
    /// デコードせずに画像を丸ごと他所へ渡す経路——Quick Look へ原画像を
    /// そのまま書き出す `QuickLookCoverStore` [IM-05][QL-10]——が、同じ上限を
    /// 自前で持ち直さずに判定できるようにするためのもの。
    func isWithinPixelCountLimit(_ data: Data) -> Bool
    /// `ImageIO` のサムネイル生成 API を使い、全画素を展開しない [EX-33]
    func makeThumbnail(from data: Data, maxPixelSize: Int) throws -> CGImage
}

public enum ImageLoadingError: Error, Sendable, Equatable {
    /// ヘッダから読み取った寸法がピクセル数上限を超えている [IM-01]。
    case pixelCountExceedsLimit
    case decodingFailed
}

/// `ImageIO` を使った既定実装 [IM-01〜IM-04]。
public struct DefaultImageLoader: ImageLoading {
    /// ピクセル数上限 [IM-01]。既定 1 億。テストでは巨大な画像を実際に
    /// 生成せずに上限超過パスを検証できるよう、注入可能にしている。
    public let maxPixelCount: Int

    public init(maxPixelCount: Int = AppLimits.Thumbnail.defaultMaxPixelCount) {
        self.maxPixelCount = maxPixelCount
    }

    public func imageSize(from data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// 寸法が読めない場合は「上限内」とみなす（`makeThumbnail` 側も同じ扱い）。
    /// 寸法を判定できない時点で `ImageIO` がその画像を扱えていない可能性が
    /// 高く、実際のデコード／描画側で自然に失敗するため。
    public func isWithinPixelCountLimit(_ data: Data) -> Bool {
        guard let size = imageSize(from: data) else { return true }
        return Int(size.width) * Int(size.height) <= maxPixelCount
    }

    /// 生成に失敗しても（寸法超過・デコード失敗いずれも）例外を投げるのみで、
    /// アプリを落とさない [IM-04]。既定アイコンへのフォールバックは
    /// 呼び出し側（`ThumbnailService`）の責務にする。
    public func makeThumbnail(from data: Data, maxPixelSize: Int) throws -> CGImage {
        guard isWithinPixelCountLimit(data) else {
            throw ImageLoadingError.pixelCountExceedsLimit // [IM-01]
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageLoadingError.decodingFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, // [IM-03]
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true, // Exif の回転情報を反映する
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoadingError.decodingFailed
        }
        return thumbnail
    }
}
