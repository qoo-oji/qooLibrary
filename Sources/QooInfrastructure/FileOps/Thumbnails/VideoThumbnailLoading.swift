import CoreGraphics
import Foundation
import QooKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

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
///   合わせて補正している（下記 `prepareBlocking(for:maxPixelSize:)` 参照）。
///
/// なお、上記のいずれの拡張も無い環境では mkv のサムネイルは得られず、
/// 呼び出し側（`ThumbnailService`）が既定アイコンへフォールバックする
/// [IM-04 と同じ方針]。
///
/// ## 実体と拡張子が食い違うファイル
/// `QLThumbnailGenerator` は UTI を**拡張子から**決めるため、実体が別の
/// コンテナだと必ず失敗する。`MediaContainerSniffer` で実体を見分け、
/// 食い違うときだけ `Request.contentType` で宣言し直す（詳細は
/// `MediaContainer.contentTypeToDeclare(forFileNamed:)`）。
///
/// ## QuickLook でどうしても作れないもの
/// `hev1` タグの HEVC は AVFoundation が入口で断るため、どんな
/// `contentType` を渡しても作れない（実測）。こちらは
/// `RetaggedHEVCThumbnailLoader` が引き取る——`CompositeVideoThumbnailLoader`
/// が「QuickLook → 失敗したら再タグ付け」の順に試す。
public protocol VideoThumbnailLoading: Sendable {
    func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage?
}

/// `QLThumbnailGenerator` を使った既定実装。
public struct QLVideoThumbnailLoader: VideoThumbnailLoading {
    private let timeoutSeconds: Double

    public init(timeoutSeconds: Double = AppLimits.Thumbnail.defaultVideoThumbnailTimeoutSeconds) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// 1 回のリクエストを組み立てるために、ファイルを 1 度だけ読んで得るもの。
    private struct Preparation: Sendable {
        /// リクエストする寸法（アスペクト比を補正済み）。
        let size: CGSize
        /// 拡張子が実体と食い違うときに宣言し直す型。食い違っていなければ `nil`。
        let contentType: UTType?
    }

    /// リクエストの寸法と宣言する型を、**先頭バイト列を 1 度読むだけ**で決める。
    ///
    /// ## 寸法（アスペクト比の補正）
    /// [ユーザー要望: 「リクエストサイズを実際のアスペクト比にあわせて
    /// ください」]。動画本体はデコードせず、コンテナのヘッダのみを読む
    /// （`MatroskaDimensionReader`）。取得できなければ正方形のリクエストへ
    /// フォールバックする（多くのサムネイル拡張は正方形リクエストでも
    /// アスペクト比を保って返すが、`QLMedia` のように厳密にリクエストサイズへ
    /// スクイーズする実装もあることが実機検証で判明したための対策）。
    ///
    /// ## 型の宣言し直し
    /// 実体と拡張子が食い違うファイル（実測: `.mp4` を名乗る Matroska）は、
    /// UTI が拡張子から決まるため誤ったパーサへ渡されて必ず失敗する。
    /// `MediaContainer.contentTypeToDeclare(forFileNamed:)` 参照。
    ///
    /// ## 判定を拡張子から実体へ移した理由（1 つの読み取りが 2 つの役目を兼ねる）
    /// 以前はアスペクト比補正の対象を**拡張子で**ゲートしていた（mp4/mov の
    /// ヘッダを 8MB 読まないための節約）。しかしそれだと**拡張子違いの mkv は
    /// 補正が効かず正方形になる**（実測で確認）。マジックバイト判定に置き換えると、
    /// 同じ 16 バイトの読み取りが「型の差し替え」と「8MB を読まないゲート」の
    /// 両方を兼ね、節約も維持したまま食い違いにも正しく効く。
    ///
    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01、
    ///   フェーズ1完了時の監査で発見]。以前は `makeThumbnail` が協調プールの
    ///   上で直接呼んでおり、ヘッダの読み取りが応答しない共有に当たると
    ///   スレッドを 1 本 30 秒占有した。
    private nonisolated static func prepareBlocking(for url: URL, maxPixelSize: Int) -> Preparation {
        let square = CGSize(width: maxPixelSize, height: maxPixelSize)
        let container = MediaContainerSniffer.sniffBlocking(at: url)
        let contentType = container?.contentTypeToDeclare(forFileNamed: url.lastPathComponent)

        // アスペクト比の補正が要るのは EBML（Matroska/WebM）だけ。
        guard container == .matroska,
              let dimensions = MatroskaDimensionReader.dimensions(of: url),
              dimensions.width > 0, dimensions.height > 0
        else {
            return Preparation(size: square, contentType: contentType)
        }
        let aspect = dimensions.width / dimensions.height
        let size = aspect >= 1
            ? CGSize(width: Double(maxPixelSize), height: Double(maxPixelSize) / aspect)
            : CGSize(width: Double(maxPixelSize) * aspect, height: Double(maxPixelSize))
        return Preparation(size: size, contentType: contentType)
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
        let preparation = await FileIO.perform { Self.prepareBlocking(for: url, maxPixelSize: maxPixelSize) }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: preparation.size,
            scale: 1,
            representationTypes: .thumbnail
        )
        // 実体と拡張子が食い違うときだけ宣言し直す。`contentType` は
        // `null_resettable` なので、既定（拡張子任せ）のままにするには
        // 代入しない——`nil` を代入しても既定へ戻るだけだが、
        // 「何もしない」意図を素直に表すため代入自体を避ける。
        if let contentType = preparation.contentType {
            request.contentType = contentType
        }
        let box = RequestBox(request: request)

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
