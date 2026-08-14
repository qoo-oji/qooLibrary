import CoreGraphics
import Foundation
import QooKit

/// mkv（Matroska/EBML）コンテナのヘッダだけを軽量にパースし、映像トラックの
/// `PixelWidth`/`PixelHeight` を取り出す [ユーザー要望: 動画サムネイルの
/// アスペクト比を実際の動画に合わせたい]。
///
/// **動画本体のデコードは一切行わない**——コンテナのメタデータを読むだけの
/// 数百バイト〜数キロバイト程度の処理で、ファイルサイズが数GBでも高速に
/// 完了する。サードパーティ QuickLook 拡張の実装品質に依存せず（実機検証で
/// 動画のサムネイル拡張が常に正方形でスクイーズして返す実装だったことが
/// 判明したため、`QLThumbnailGenerator.Request` に渡すリクエストサイズ自体を
/// 実際のアスペクト比に合わせて事前に調整する）、qooLibrary 側だけで完結する。
///
/// EBML の基本構造（可変長 VINT の ID＋サイズ＋中身）のうち、
/// `Segment > Tracks > TrackEntry > Video > PixelWidth/PixelHeight` の経路
/// だけを理解する最小限の実装であり、Matroska 仕様全体を実装するものではない。
public enum MatroskaDimensionReader {
    private static let ebmlHeaderID: UInt64 = 0x1A45DFA3
    private static let segmentID: UInt64 = 0x1853_8067
    private static let clusterID: UInt64 = 0x1F43_B675 // 実フレームデータ本体、ここに来たら Tracks は無かった
    private static let tracksID: UInt64 = 0x1654_AE6B
    private static let trackEntryID: UInt64 = 0xAE
    private static let trackTypeID: UInt64 = 0x83
    private static let videoID: UInt64 = 0xE0
    private static let pixelWidthID: UInt64 = 0xB0
    private static let pixelHeightID: UInt64 = 0xBA
    private static let trackTypeVideo: UInt64 = 1

    /// `nil` の場合、mkv でない・読み取り上限内でトラック情報が見つからない・
    /// 壊れている、のいずれか。呼び出し側は正方形のリクエストへフォールバック
    /// する [IM-04 と同じ「防御的に諦める」方針]。
    public static func dimensions(
        of url: URL,
        maxScanBytes: Int = AppLimits.Thumbnail.defaultMatroskaHeaderScanBytes
    ) -> CGSize? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxScanBytes), data.count > 8 else { return nil }
        let bytes = [UInt8](data)

        var offset = 0
        guard let headerID = readElementID(bytes, &offset), headerID == ebmlHeaderID else { return nil }
        guard let headerSize = readVINTSize(bytes, &offset), !headerSize.isUnknownSize else { return nil }
        offset += Int(headerSize.value) // EBML ヘッダの中身（バージョン情報等）は不要

        while offset < bytes.count {
            guard let id = readElementID(bytes, &offset) else { return nil }
            guard let size = readVINTSize(bytes, &offset) else { return nil }
            if id == segmentID {
                let end = size.isUnknownSize ? bytes.count : min(bytes.count, offset + Int(size.value))
                return dimensionsInSegment(bytes, offset: offset, end: end)
            }
            guard !size.isUnknownSize else { return nil }
            offset += Int(size.value)
        }
        return nil
    }

    private static func dimensionsInSegment(_ bytes: [UInt8], offset start: Int, end: Int) -> CGSize? {
        var offset = start
        while offset < end {
            guard let id = readElementID(bytes, &offset) else { return nil }
            guard let size = readVINTSize(bytes, &offset) else { return nil }
            guard !size.isUnknownSize else { return nil }
            let contentEnd = min(end, offset + Int(size.value))
            if id == tracksID {
                return dimensionsInTracks(bytes, offset: offset, end: contentEnd)
            }
            if id == clusterID {
                return nil // フレームデータに到達 = Tracks は見つからなかった
            }
            offset = contentEnd
        }
        return nil
    }

    private static func dimensionsInTracks(_ bytes: [UInt8], offset start: Int, end: Int) -> CGSize? {
        var offset = start
        while offset < end {
            guard let id = readElementID(bytes, &offset) else { return nil }
            guard let size = readVINTSize(bytes, &offset) else { return nil }
            guard !size.isUnknownSize else { return nil }
            let contentEnd = min(end, offset + Int(size.value))
            if id == trackEntryID, let dims = dimensionsInTrackEntry(bytes, offset: offset, end: contentEnd) {
                return dims
            }
            offset = contentEnd
        }
        return nil
    }

    private static func dimensionsInTrackEntry(_ bytes: [UInt8], offset start: Int, end: Int) -> CGSize? {
        var offset = start
        var isVideo = false
        var videoRange: (Int, Int)?
        while offset < end {
            guard let id = readElementID(bytes, &offset) else { return nil }
            guard let size = readVINTSize(bytes, &offset) else { return nil }
            guard !size.isUnknownSize else { return nil }
            let contentEnd = min(end, offset + Int(size.value))
            if id == trackTypeID {
                isVideo = readUInt(bytes, offset: offset, length: contentEnd - offset) == trackTypeVideo
            } else if id == videoID {
                videoRange = (offset, contentEnd)
            }
            offset = contentEnd
        }
        guard isVideo, let (videoStart, videoEnd) = videoRange else { return nil }
        return dimensionsInVideo(bytes, offset: videoStart, end: videoEnd)
    }

    private static func dimensionsInVideo(_ bytes: [UInt8], offset start: Int, end: Int) -> CGSize? {
        var offset = start
        var width: UInt64?
        var height: UInt64?
        while offset < end {
            guard let id = readElementID(bytes, &offset) else { return nil }
            guard let size = readVINTSize(bytes, &offset) else { return nil }
            guard !size.isUnknownSize else { return nil }
            let contentEnd = min(end, offset + Int(size.value))
            if id == pixelWidthID {
                width = readUInt(bytes, offset: offset, length: contentEnd - offset)
            } else if id == pixelHeightID {
                height = readUInt(bytes, offset: offset, length: contentEnd - offset)
            }
            offset = contentEnd
            if let width, let height {
                guard width > 0, height > 0, width < 100_000, height < 100_000 else { return nil }
                return CGSize(width: Double(width), height: Double(height))
            }
        }
        return nil
    }

    // MARK: - EBML 基礎（VINT: 可変長整数）

    private static func vintLength(_ firstByte: UInt8) -> Int {
        var mask: UInt8 = 0x80
        for length in 1...8 {
            if firstByte & mask != 0 { return length }
            mask >>= 1
        }
        return 0
    }

    /// Element ID はマーカービットを剥がさず、そのままの値を ID として使う。
    private static func readElementID(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        guard offset < bytes.count, bytes[offset] != 0 else { return nil }
        let length = vintLength(bytes[offset])
        guard length > 0, offset + length <= bytes.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<length {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        offset += length
        return value
    }

    private struct VINTSize {
        let value: UInt64
        let isUnknownSize: Bool
    }

    /// サイズの VINT はマーカービットを剥がして数値化する。値のビットが全て 1
    /// の場合は「サイズ不明」（ストリーミング等）を意味する。
    private static func readVINTSize(_ bytes: [UInt8], _ offset: inout Int) -> VINTSize? {
        guard offset < bytes.count, bytes[offset] != 0 else { return nil }
        let first = bytes[offset]
        let length = vintLength(first)
        guard length > 0, offset + length <= bytes.count else { return nil }
        let marker: UInt8 = 0x80 >> (length - 1)
        var value = UInt64(first & (marker - 1))
        var isMaxValue = value == UInt64(marker - 1)
        for i in 1..<length {
            let byte = bytes[offset + i]
            value = (value << 8) | UInt64(byte)
            if byte != 0xFF { isMaxValue = false }
        }
        offset += length
        return VINTSize(value: value, isUnknownSize: isMaxValue)
    }

    /// EBML の "uinteger" 要素（ビッグエンディアン、可変長）を読む。
    private static func readUInt(_ bytes: [UInt8], offset: Int, length: Int) -> UInt64? {
        guard length > 0, length <= 8, offset + length <= bytes.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<length {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }
}
