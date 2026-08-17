import CoreGraphics
import Foundation
import QooKit

/// 複数の ``VideoThumbnailLoading`` を順に試し、最初に成功したものを返す
/// （`CompositeCommand` と同じ「並べて 1 つに見せる」型）。
///
/// 既定の順序は **QuickLook → `hev1` の再タグ付け**。
///
/// ## なぜ QuickLook を先に試すのか
/// フレームの選び方・アスペクト比の扱い・ハードウェアデコードの選択を OS 側の
/// 実装に任せられるうちは任せたい。`RetaggedHEVCThumbnailLoader` は対象を
/// `hev1` に絞った最小限の代替経路であり、**QuickLook が作れるものを
/// 置き換える意図は無い。**
///
/// ## 費用
/// 2 つ目以降が走るのは 1 つ目が `nil` を返したときだけ。`hev1` の判定は
/// トラックのメタデータを読むだけで、対象外なら即座に `nil` を返す。
/// 生成できないファイル（対応拡張が無い mkv、壊れたファイル）では両方が
/// 失敗するが、そこは元々 1 回失敗していた場所であり、`ThumbnailService` は
/// 失敗をキャッシュしない設計なので**次の掃引でも同じだけ試みる**
/// （`BackgroundThumbnailWarmer` の形式単位のスキップがこれを抑える）。
public struct CompositeVideoThumbnailLoader: VideoThumbnailLoading {
    /// `private` にしないのは、既定の並び（QuickLook → 再タグ付け）が逆に
    /// なっていないことをテストで確かめるため。
    let loaders: [any VideoThumbnailLoading]

    public init(loaders: [any VideoThumbnailLoading]) {
        self.loaders = loaders
    }

    /// 既定の組み合わせ。
    public init() {
        self.init(loaders: [QLVideoThumbnailLoader(), RetaggedHEVCThumbnailLoader()])
    }

    public func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        for loader in loaders {
            // 取り消されていたら次を試さない（高速スクロールで画面外へ出た
            // セルの要求が、フォールバックのぶんだけ余分に走らないように）。
            // `Cancellation.isRequested` を使うのは `FileOps/` の約束
            // （静的検査 `check-cancellation-usage.swift` が `Task.isCancelled`
            // を禁じる）。ここは借りたスレッドの外なので、実体は
            // `Task.isCancelled` に委譲される。
            if Cancellation.isRequested { return nil }
            if let image = await loader.makeThumbnail(for: url, maxPixelSize: maxPixelSize) {
                return image
            }
        }
        return nil
    }
}
