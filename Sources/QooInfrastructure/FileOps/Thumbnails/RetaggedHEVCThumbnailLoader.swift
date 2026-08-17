import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import QooKit
import VideoToolbox

/// `hev1` タグの HEVC からサムネイルを作る。**元ファイルは 1 バイトも書き換えない。**
///
/// ## なぜ必要か（実機のライブラリで踏んだ）
/// HEVC を mp4 に入れるとき、サンプルエントリのタグには 2 通りある:
///
/// | タグ | 意味 | Apple のメディアスタック |
/// |---|---|---|
/// | `hvc1` | パラメータセットがサンプルエントリにある | **再生・サムネイル可** |
/// | `hev1` | パラメータセットがビットストリーム内にもある | **一律で非対応** |
///
/// `hev1` は仕様上正当だが AVFoundation が**入口で断る**ため、QuickLook も
/// Finder のサムネイルも作れない（`QLThumbnailErrorDomain code 102` を
/// 0.02〜0.04 秒で即座に返す）。しかも **ffmpeg は libx265 の mp4 出力に
/// 既定で `hev1` を付ける**ので、動画ライブラリとしては継続的に踏む。
///
/// 実測での切り分け（同じサイト・同じシリーズ・1920×1080・HEVC+AAC）:
/// `hvc1` の 3 本はすべて成功し、`hev1` の 1 本だけが `decodable=false` で
/// 失敗した——違いはタグだけだった。`contentType` を差し替えても救えない
/// （型判定は正しく、断っているのはデコーダ側）。
///
/// ## どう回避するか
/// **「復号できない」のではなく「タグを見て断られている」だけ**だった。
/// 該当ファイルの `hvcC` には VPS/SPS/PPS が揃っており（実測: array 3 本、
/// nal_type 32/33/34）、ファイルは自己記述的である。そこで:
///
/// 1. `AVAssetReaderTrackOutput(track:, outputSettings: nil)`（パススルー＝
///    デコードしない）でキーフレームを取り出す。**`decodable=false` の
///    トラックでも読める**（実測）。
/// 2. 元の format description の extensions（`hvcC` を含む）をそのまま流用し、
///    subtype だけ `kCMVideoCodecType_HEVC`（= `hvc1`）で作り直す。
/// 3. 同じデータバッファに新しい description を付けた `CMSampleBuffer` を組む。
/// 4. `VTDecompressionSession` へ渡す。**VideoToolbox は受け付ける**（実測で
///    1920×1080 のフレームを取得、輝度 stddev 56 の実画像）。
///
/// ## 位置づけ
/// これは QuickLook が失敗したときだけ働くフォールバックであり、
/// `CompositeVideoThumbnailLoader` が順序を持つ。**先に QuickLook を試すのは、
/// フレーム選択やアスペクト比の扱いを OS 側の実装に任せられるうちは
/// 任せたいため**——ここは対象を `hev1` に絞った最小限の代替経路である。
public struct RetaggedHEVCThumbnailLoader: VideoThumbnailLoading {
    private let timeoutSeconds: Double
    private let keyframeScanLimit: Int

    public init(
        timeoutSeconds: Double = AppLimits.Thumbnail.defaultVideoThumbnailTimeoutSeconds,
        keyframeScanLimit: Int = AppLimits.Thumbnail.retaggedHEVCKeyframeScanLimit
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.keyframeScanLimit = keyframeScanLimit
    }

    /// AVFoundation が入口で断るタグ → VideoToolbox が受け付けるタグ。
    ///
    /// **実測で確かめた組み合わせだけを載せる。** Dolby Vision の
    /// `dvhe`/`dvh1` も同型の関係にあるが、検証できるファイルを持たないため
    /// 入れていない（推測で足すと、動くかどうか分からない経路が増えるだけ）。
    private static let retagTable: [FourCharCode: CMVideoCodecType] = [
        fourCharCode("hev1"): kCMVideoCodecType_HEVC, // 'hvc1'
    ]

    public func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        // 上限時間を付けるのは `QLVideoThumbnailLoader` と同じ理由 [PF-11]
        // ——1 件の異常なファイルで同時実行スロットを専有させない。
        try? await FileIO.withDeadline(.seconds(timeoutSeconds)) {
            await self.makeThumbnailWithoutDeadline(for: url, maxPixelSize: maxPixelSize)
        }
    }

    private func makeThumbnailWithoutDeadline(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        // `loadTracks`/`load` は AVFoundation 自身のキューで走るため、
        // 協調プールのスレッドを塞がない（`FileIO` は不要）。
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let original = (try? await track.load(.formatDescriptions))?.first,
              let retagged = Self.retaggedFormatDescription(for: original)
        else { return nil }

        let start = await Self.keyframeSearchStart(of: asset)
        // `AVAssetTrack` は Sendable ではないので箱に入れる。**1 本の借りた
        // スレッドへ渡して、そこだけで触る**（並行には触らない）ことを前提に
        // している——`QLVideoThumbnailLoader.RequestBox` と同じ扱い。
        let box = TrackBox(track: track)
        // 失敗しない（`nil` を返す）ので `FileIO.perform` の非 throwing 版が選ばれる。
        let image = await FileIO.perform {
            Self.thumbnailBlocking(
                asset: asset,
                track: box.track,
                retagged: retagged,
                startSeconds: start,
                maxPixelSize: maxPixelSize,
                scanLimit: self.keyframeScanLimit
            )
        }
        return image?.image
    }

    // MARK: - タグの差し替え

    /// subtype だけを差し替えた format description。対象外のタグなら `nil`
    /// （＝この経路では何もできないので、呼び出し側は素直に諦める）。
    private static func retaggedFormatDescription(
        for original: CMFormatDescription
    ) -> CMFormatDescription? {
        let subType = CMFormatDescriptionGetMediaSubType(original)
        guard let replacement = retagTable[subType] else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(original)
        // **extensions をそのまま引き継ぐのが要点** — ここに `hvcC`
        // （パラメータセット）が入っており、これがあるから VideoToolbox は
        // デコーダを組める。
        var retagged: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: replacement,
            width: dimensions.width,
            height: dimensions.height,
            extensions: CMFormatDescriptionGetExtensions(original),
            formatDescriptionOut: &retagged
        )
        guard status == noErr else { return nil }
        return retagged
    }

    // MARK: - キーフレームの取り出しとデコード（ブロッキング）

    /// 探し始める位置（秒）。**冒頭は黒画面やロゴであることが多い**ため少し
    /// 進んだ位置から探す。尺が分からなければ 0（先頭から）。
    private static func keyframeSearchStart(of asset: AVURLAsset) async -> Double {
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(seconds * AppLimits.Thumbnail.retaggedHEVCSeekFraction,
                   AppLimits.Thumbnail.retaggedHEVCSeekCapSeconds)
    }

    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]。
    ///   `copyNextSampleBuffer()` は実 I/O を伴い、応答しない共有では待たされる。
    ///   取り消しは `Cancellation.isRequested` で見る（`Task.isCancelled` は
    ///   借りたスレッドの上では常に `false`。`Cancellation` のコメント参照）。
    private static func thumbnailBlocking(
        asset: AVURLAsset,
        track: AVAssetTrack,
        retagged: CMFormatDescription,
        startSeconds: Double,
        maxPixelSize: Int,
        scanLimit: Int
    ) -> ImageBox? {
        // 少し進んだ位置で同期サンプルが見つからなければ先頭から取り直す
        // （尺の途中に同期サンプルを持たない構成でも諦めないため）。
        var sample = copyKeyframeBlocking(
            asset: asset, track: track, startSeconds: startSeconds, scanLimit: scanLimit
        )
        if sample == nil, startSeconds > 0 {
            sample = copyKeyframeBlocking(
                asset: asset, track: track, startSeconds: 0, scanLimit: scanLimit
            )
        }
        guard let sample,
              let retaggedSample = retag(sample, with: retagged),
              let image = decodeBlocking(retaggedSample, formatDescription: retagged)
        else { return nil }
        return ImageBox(image: downscale(image, maxPixelSize: maxPixelSize) ?? image)
    }

    private static func copyKeyframeBlocking(
        asset: AVURLAsset,
        track: AVAssetTrack,
        startSeconds: Double,
        scanLimit: Int
    ) -> CMSampleBuffer? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        // `outputSettings: nil` はパススルー（デコードしない）。**これが
        // `decodable=false` のトラックでも読める理由。**
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        // **コピーさせる。** `false` にすると返るバッファが後備ファイルの
        // メモリ写像を参照し得る。ネットワーク上のファイルで共有が落ちると
        // 写像へのフォルトが `SIGBUS` になり、`try` では捕まえられない
        // [NV6-08、遮断計測で実測]。1 フレーム分のコピーは些少。
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        if startSeconds > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                duration: .positiveInfinity
            )
        }
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var scanned = 0
        while scanned < scanLimit, !Cancellation.isRequested {
            guard let candidate = output.copyNextSampleBuffer() else { return nil }
            scanned += 1
            // 実データを持たない印だけのバッファ（フォーマット変化の通知等）は
            // 飛ばす。**これを飛ばさないと空バッファを「キーフレーム」と
            // 誤認する**（実装中に実際に踏んだ: numSamples=0 で無言に失敗した）。
            guard CMSampleBufferGetNumSamples(candidate) > 0,
                  CMSampleBufferGetDataBuffer(candidate) != nil
            else { continue }
            if isSyncSample(candidate) { return candidate }
        }
        return nil
    }

    /// 同期サンプル（キーフレーム）か。添付情報が無い場合は同期扱いにする
    /// （添付が無いのは「非同期という指定が無い」ことを意味する）。
    private static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    /// 同じデータバッファに、差し替えた format description を付けた新しい
    /// サンプルバッファ。
    private static func retag(
        _ sample: CMSampleBuffer,
        with formatDescription: CMFormatDescription
    ) -> CMSampleBuffer? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample)
        )
        let count = CMSampleBufferGetNumSamples(sample)
        var sizes = (0..<count).map { CMSampleBufferGetSampleSize(sample, at: $0) }
        // サイズが個別に取れない構成では合計を 1 件として渡す。
        if sizes.isEmpty || sizes.contains(0) {
            sizes = [CMSampleBufferGetTotalSampleSize(sample)]
        }
        guard sizes.allSatisfy({ $0 > 0 }) else { return nil }

        var retagged: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: dataBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(sizes.count),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: CMItemCount(sizes.count),
            sampleSizeArray: &sizes,
            sampleBufferOut: &retagged
        )
        guard status == noErr else { return nil }
        return retagged
    }

    private static func decodeBlocking(
        _ sample: CMSampleBuffer,
        formatDescription: CMFormatDescription
    ) -> CGImage? {
        var session: VTDecompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        // ここが失敗するのは `hvcC` にパラメータセットが無い等、差し替えても
        // デコーダを組めない場合。素直に諦める [IM-04 と同じ方針]。
        guard created == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        // 出力ハンドラは VideoToolbox 自身のスレッドから呼ばれ得るので、
        // 受け取り口は錠で守る。既に借りたスレッドの上に居るため、待ち合わせは
        // `WaitForAsynchronousFrames` に任せる（継続を使わないので、上限時間で
        // 見捨てられても継続が取り残されない）。
        let sink = ImageSink()
        let submitted = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &image)
            sink.store(image)
        }
        guard submitted == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return sink.take()
    }

    /// 生成したサムネイルを `maxPixelSize` に収める。デコードは常に元の解像度で
    /// 行われるため（1920×1080 等）、他のローダーと同じ大きさに揃えてキャッシュを
    /// 膨らませないようにする。
    private static func downscale(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize, longest > 0 else { return image }
        let scale = Double(maxPixelSize) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - 非 Sendable 型の受け渡し

    /// `AVAssetTrack` は Sendable ではない。1 本の借りたスレッドへ渡して
    /// そこだけで触るために包む（`QLVideoThumbnailLoader.RequestBox` と同じ扱い）。
    private struct TrackBox: @unchecked Sendable {
        let track: AVAssetTrack
    }

    /// `CGImage` を `FileIO.perform` の戻り値として運ぶための箱。
    private struct ImageBox: @unchecked Sendable {
        let image: CGImage
    }

    /// VideoToolbox のスレッドから書かれ、こちらのスレッドから読まれる 1 枚。
    private final class ImageSink: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?

        func store(_ newValue: CGImage?) {
            lock.lock()
            // 最初の 1 枚だけを採る（複数フレームが返ってきても先頭で足りる）。
            if image == nil { image = newValue }
            lock.unlock()
        }

        func take() -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return image
        }
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        Array(string.utf8).reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
    }
}
