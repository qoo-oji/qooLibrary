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
/// **mkv/webm/avi 等、対応する QuickLook 拡張（例: QLVideo,
/// github.com/Marginal/QuickLookVideo）を要する形式は、実機検証の結果、
/// 現状うまく機能しないことを確認済み。** QLVideo をインストール・有効化
/// （`pluginkit` に登録、`com.apple.mediaextension.formatreader`）した状態でも、
/// `representationTypes: .thumbnail`/`.lowQualityThumbnail` は
/// `QLThumbnailErrorDomain code 102`（詳細未公開のエラー）で一貫して失敗する
/// ——サンドボックス内外・qooLibrary 内外を問わず、素の非サンドボックス
/// スクリプトからの直接呼び出しでも同じ結果になることを確認済みのため、
/// qooLibrary 側のサンドボックス・アクセス権の問題ではない。`.icon` 表現型は
/// 成功するが、`NSWorkspace.icon(forFile:)` と同様に**ファイルによらず同一の
/// 汎用アイコン**（2つの異なる mkv で MD5 完全一致を確認済み）で、実質的な
/// プレビューにはならない。`qlmanage -t`（CLI）も無反応でハングする。
///
/// 一方 **Finder の実際のアイコン表示は、ファイルごとに異なる本物の
/// サムネイルを表示できている**（ユーザー実機で確認済み）。つまり Finder は
/// 上記のいずれの公開 API とも異なる、サードパーティプロセスには公開されて
/// いない内部的な経路を使っていると考えられる。QLVideo 側の Media
/// Extensions 実装がまだ `QLThumbnailGenerator` の `.thumbnail` パスに
/// 完全対応していない可能性が高い（QLVideo の GitHub Issue で報告する価値が
/// ある具体的な再現手順・エラーコードは確保済み）。
///
/// 対応できない場合は `nil` を返すだけで、呼び出し側（`ThumbnailService`）が
/// 既定アイコンへフォールバックする [IM-04 と同じ方針]。
public protocol VideoThumbnailLoading: Sendable {
    func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage?
}

/// `QLThumbnailGenerator` を使った既定実装。
public struct QLVideoThumbnailLoader: VideoThumbnailLoading {
    private let timeoutSeconds: Double

    public init(timeoutSeconds: Double = AppLimits.Thumbnail.defaultVideoThumbnailTimeoutSeconds) {
        self.timeoutSeconds = timeoutSeconds
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
        let box = RequestBox(request: QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixelSize, height: maxPixelSize),
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
            }
            for await _ in group {} // 残りの子タスクを drain してから抜ける

            if case .generated(let image) = first {
                return image
            }
            return nil
        }
    }
}
