import Foundation
import QuickLookUI

/// `QLPreviewPanel` のデータ源。**どのスレッドから問い合わされても安全**な
/// ように、項目の配列をロックで保護した専用の型に切り出している。
///
/// ## なぜ `QuickLookController` に直接実装しないのか
/// 当初は `@MainActor` のコントローラに `@MainActor QLPreviewPanelDataSource`
/// として実装していたが、**QuickLook はプレビューの読み込みをバックグラウンド
/// で行い、その過程でこちらのオブジェクトを触ってくる**ことが実機のクラッシュで
/// 判明した（詳細は `QuickLookPreviewItem` のコメント。`previewItemURL` が
/// `NSOperationQueue` のワーカーから読まれ、アクター隔離チェックで即死した）。
/// 実際にクラッシュしたのは項目側だけだが、同じ前提——「AppKit / QuickLook の
/// コールバックは必ずメインスレッドで来る」——に依存している箇所を残さないため、
/// データ源もメインアクターから切り離した。
///
/// 一方 `QLPreviewPanelDelegate` 側（キーイベント・ズーム元矩形・
/// `windowWillClose`）は本質的に UI イベントで、メインスレッド以外から来る
/// 余地が無いため `QuickLookController` に `@MainActor` のまま置いている。
///
/// 書き込むのは常にメインアクター（`QuickLookController`）だけで、読み出しが
/// 複数スレッドから来る、という単純な構図なので `NSLock` で足りる。
final class QuickLookItemSource: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedItems: [QuickLookPreviewItem] = []
    /// パネルがある項目を表示しようとしたときの通知先 [QL-09 の遅延解決]。
    /// 呼ばれるスレッドは不定なので、受け手（`QuickLookController`）が
    /// メインアクターへ移し替える。
    private var storedWillDisplay: (@Sendable (QuickLookPreviewItem) -> Void)?

    var items: [QuickLookPreviewItem] {
        get { lock.withLock { storedItems } }
        set { lock.withLock { storedItems = newValue } }
    }

    func setWillDisplayHandler(_ handler: (@Sendable (QuickLookPreviewItem) -> Void)?) {
        lock.withLock { storedWillDisplay = handler }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        lock.withLock { storedItems.count }
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let (item, willDisplay) = lock.withLock { () -> (QuickLookPreviewItem?, (@Sendable (QuickLookPreviewItem) -> Void)?) in
            guard storedItems.indices.contains(index) else { return (nil, nil) }
            return (storedItems[index], storedWillDisplay)
        }
        guard let item else { return nil }
        willDisplay?(item)
        return item
    }
}
