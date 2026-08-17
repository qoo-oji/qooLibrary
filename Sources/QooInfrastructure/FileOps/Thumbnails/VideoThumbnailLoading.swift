import CoreGraphics
import Foundation
import QooKit
import QuickLookThumbnailing

/// 動画ファイルのサムネイル生成 [IV-01 の自然な拡張、ユーザー要望: 本アプリは
/// コミックライブラリ管理が主だが、きちんと設定すれば動画ライブラリとしても
/// 使える想定のため、動画ファイルにもサムネイルを付けたい]。
///
/// `QLThumbnailGenerator`（QuickLookThumbnailing framework）を使う。macOS
/// 標準では mp4/mov 等の QuickTime 互換コンテナは確実にサムネイルが得られる。
///
/// **mkv 等、対応する QuickLook 拡張を要する形式は、インストールされている
/// 拡張の実装品質に完全に依存する**（qooLibrary 側のコードには依存しない）。
/// 実機検証で複数の候補を比較した:
/// - `QLVideo`（github.com/Marginal/QuickLookVideo）: `BUILDING.md` に
///   明記の通り、v3 はサムネイル専用の QuickLook 拡張点（`thumbnailer`）を
///   意図的に同梱していない（Media Extensions のみ）。`.thumbnail` は
///   常に `QLThumbnailErrorDomain code 102` で失敗する。
/// - `QLCodec-mkv`（github.com/Oil3/Mkv-Quicklook）: 正しい拡張点
///   （`com.apple.quicklook.thumbnail`）を実装しているが、**同時に複数の
///   サムネイルリクエストを投げると結果が別のファイルのものと入れ替わる**
///   （`QLSupportsConcurrentRequests: true` を宣言しているにも関わらず）、
///   かつ**画像が上下反転する**、という実装バグを実機で確認したため不採用。
/// - `QLMedia`（Mac App Store、開発者 Sergey Dikov）: 上記のいずれの問題も
///   無く、同時5件のリクエストでも正しく対応し、上下も正常だった。
///   ただし**返される画像は常に正方形**で、動画の実際のアスペクト比を
///   無視してスクイーズされる癖があるため、`MatroskaDimensionReader` で
///   事前にコンテナから寸法を読み、リクエストサイズ自体をアスペクト比に
///   合わせて補正している（下記 `requestSize(for:maxPixelSize:)` 参照）。
///
/// なお、上記のいずれの拡張も無い環境では mkv のサムネイルは得られず、
/// 呼び出し側（`ThumbnailService`）が既定アイコンへフォールバックする
/// [IM-04 と同じ方針]。
public protocol VideoThumbnailLoading: Sendable {
    func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage?
}

/// `QLThumbnailGenerator` を使った既定実装。
public struct QLVideoThumbnailLoader: VideoThumbnailLoading {
    private let timeoutSeconds: Double

    public init(timeoutSeconds: Double = AppLimits.Thumbnail.defaultVideoThumbnailTimeoutSeconds) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// リクエストする寸法をコンテナの実アスペクト比に合わせて計算する
    /// [ユーザー要望: 「リクエストサイズを実際のアスペクト比にあわせて
    /// ください」]。動画本体はデコードせず、コンテナのヘッダのみを読む
    /// （`MatroskaDimensionReader`、mkv 以外・読み取り失敗時は `nil`）。
    /// 取得できなければ、これまで通り正方形のリクエストにフォールバックする
    /// （多くのサムネイル拡張は正方形リクエストでもアスペクト比を保って
    /// 返してくれるが、`QLMedia` のように厳密にリクエストサイズへスクイーズ
    /// する実装もあることが実機検証で判明したための対策）。
    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01、
    ///   フェーズ1完了時の監査で発見]。以前は `makeThumbnail` が協調プールの
    ///   上で直接呼んでおり、ヘッダの読み取り（最大 8MB）が応答しない共有に
    ///   当たるとスレッドを 1 本 30 秒占有した。
    ///   **EBML コンテナ（mkv/webm/mka）のときだけ読む** — この補正は
    ///   `QLMedia` の正方形スクイーズ対策そのもので、mp4/mov は QuickLook が
    ///   正方形リクエストでもアスペクト比を保って返すため、全動画のヘッダを
    ///   読む必要は元々無かった。
    private nonisolated static func requestSizeBlocking(for url: URL, maxPixelSize: Int) -> CGSize {
        let square = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard ["mkv", "webm", "mka"].contains(url.pathExtension.lowercased()) else { return square }
        guard let dimensions = MatroskaDimensionReader.dimensions(of: url),
              dimensions.width > 0, dimensions.height > 0
        else {
            return square
        }
        let aspect = dimensions.width / dimensions.height
        if aspect >= 1 {
            return CGSize(width: Double(maxPixelSize), height: Double(maxPixelSize) / aspect)
        } else {
            return CGSize(width: Double(maxPixelSize) * aspect, height: Double(maxPixelSize))
        }
    }

    /// `QLThumbnailGenerator.Request` は `Sendable` 準拠が無いため、複数の
    /// 並行タスクに素朴に渡すと Swift 6 の厳格な並行性検査に引っかかる。
    /// タイムアウト用のタスクからは識別子として `cancel(_:)` に渡すためだけに
    /// 使い、実際に可変な状態を共有しないことを承知の上で `@unchecked Sendable`
    /// で包む。
    private struct RequestBox: @unchecked Sendable {
        let request: QLThumbnailGenerator.Request
    }

    public func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let size = await FileIO.perform { Self.requestSizeBlocking(for: url, maxPixelSize: maxPixelSize) }
        let box = RequestBox(request: QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 1,
            representationTypes: .thumbnail
        ))

        enum Outcome { case generated(CGImage?), timedOut }

        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: box.request) { thumbnail, _ in
                        continuation.resume(returning: .generated(thumbnail?.cgImage))
                    }
                }
            }
            group.addTask { [timeoutSeconds] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return .timedOut
            }

            let first = await group.next()
            if case .timedOut = first {
                // まだ実行中の生成リクエストを明示的にキャンセルする。呼ばないと
                // completion handler が発火せず、構造化並行性の性質上このスコープ
                // 自体が抜けられずハングし続ける（実機検証で `qlmanage -t` が
                // 実際に無限にハングした事例と同じ危険を避けるため）。
                QLThumbnailGenerator.shared.cancel(box.request)
            } else {
                // **生成が先に終わったら、眠っているタイムアウト子を起こす**
                // [フェーズ1完了時の監査で発見]。これが無いと下の drain が
                // `Task.sleep` の満了（既定 8 秒）まで待ち続け、**成功した
                // 動画サムネイル 1 件ごとに PF-11 のスロットを 8 秒占有**
                // していた（グリッドの動画セルが全スロットを塞ぎ、他の
                // サムネイルが順番待ちで凍る）。`Task.sleep` はキャンセルに
                // 即応するので、これで drain は一瞬で抜ける。
                group.cancelAll()
            }
            for await _ in group {} // 残りの子タスクを drain してから抜ける

            if case .generated(let image) = first {
                return image
            }
            return nil
        }
    }
}
