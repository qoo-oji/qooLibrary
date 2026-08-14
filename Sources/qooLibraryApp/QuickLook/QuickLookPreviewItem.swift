import Foundation
import QuickLookUI

/// `QLPreviewPanel` に渡す 1 項目 [QL-01]。
///
/// パネルへ実際に渡す URL（``previewURL``）と、ユーザーが選んだ本来の項目
/// （``sourceURL``）を分けて持つ。コミックアーカイブやフォルダは「中の先頭
/// 画像を書き出した実ファイル」に差し替える [QL-03][QL-08] が、パネルの
/// タイトルは元のファイル名のままにしたいため。
///
/// 差し替えは非同期に確定する [QL-09]。生成前は ``previewURL`` が
/// ``sourceURL`` のままなので、標準 Quick Look がアーカイブアイコンを表示する
/// ——これがそのままプレースホルダとして機能し、カバーが用意できた時点で
/// `QLPreviewPanel.refreshCurrentPreviewItem()` により差し替わる。
///
/// ## この型を `@MainActor` にしてはならない（実機のクラッシュで判明）
/// **QuickLook は `previewItemURL` をメインスレッド以外から読む。** 当初この
/// 型を `@MainActor`（＋ `@MainActor QLPreviewItem` の隔離付き適合）で書いた
/// ところ、Space キーでプレビューを開いた瞬間に `EXC_BREAKPOINT` で即死した。
/// クラッシュログのフォルティングスレッドはメインスレッドではなく
/// `NSOperationQueue` のワーカーで、呼び出し元は
/// `-[QLPreviewView shouldUseAsyncLoading]` →
/// `-[QLPreviewDocument startLoadingWithForcedDisplayBundleID:hints:]` →
/// `NSFileCoordinator` の調整アクセスブロック——つまり QuickLook 側が
/// 非同期ロードの判定のためにバックグラウンドから `previewItemURL` を読み、
/// Swift 並行性のアクター隔離チェック（`_checkExpectedExecutor`）が
/// トラップしていた。
///
/// そのため、この型は**どのスレッドから読まれても安全**でなければならない。
/// 可変なのは ``previewURL`` だけなので `NSLock` で保護し、`sourceURL` は
/// `let`（＝スレッド安全）のままにしている。カバー解決の進行状況
/// （``coverState``/``resolveTask``）は `QuickLookController` からしか触らない
/// ため、個別に `@MainActor` を付けて隔離を保っている。
///
/// 教訓: AppKit / QuickLook のコールバックが常にメインスレッドで来るとは
/// 限らない。データ源として渡すオブジェクトは、UI コールバック（`delegate`）
/// と違い任意のスレッドから読まれ得ると考えること。
final class QuickLookPreviewItem: NSObject, QLPreviewItem, @unchecked Sendable {
    /// カバー画像の解決状態 [QL-09]。`previewPanel(_:previewItemAt:)` が
    /// 呼ばれた項目だけを遅延解決するため、項目ごとに状態を持つ。
    enum CoverState {
        /// まだ解決を試みていない。
        case notStarted
        /// 解決中（重複起動を防ぐ）。
        case resolving
        /// カバーへの差し替えが完了した。
        case resolved
        /// 標準 Quick Look に委ねる（差し替え不要 [QL-02]、またはカバーを
        /// 取り出せなかった）。
        case unavailable
    }

    /// ユーザーが選択した本来の項目。不変なのでどのスレッドから読んでもよい。
    let sourceURL: URL

    /// カバー解決の進行状況。`QuickLookController`（メインアクター）専用。
    @MainActor var coverState: CoverState = .notStarted
    /// 解決中のタスク。パネルを閉じる／選択が変わったときに取り消す。
    @MainActor var resolveTask: Task<Void, Never>?

    /// `previewURL` の保護。書き込みはメインアクターからだけだが、読み出しは
    /// QuickLook が任意のスレッドから行う（型のコメント参照）。
    private let lock = NSLock()
    private var storedPreviewURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        self.storedPreviewURL = sourceURL
        super.init()
    }

    /// パネルへ渡す URL。既定は ``sourceURL`` 自身（＝標準 Quick Look）。
    var previewURL: URL {
        get { lock.withLock { storedPreviewURL } }
        set { lock.withLock { storedPreviewURL = newValue } }
    }

    var previewItemURL: URL! { previewURL }

    /// 差し替えても元のファイル名を見せる。**ファイルサイズ等の併記はしない**
    /// ［設計判断］——QL-06 が求める「タイトル・シリーズ名・巻数・評価・ラベル・
    /// ファイルサイズ」のうち、フェーズ 1 に存在するのはファイル名とサイズだけで、
    /// どちらも常設インスペクタ（`InspectorPane`）に常に出ている。Finder と同じ
    /// 「ファイル名だけ」の見た目を優先し、QL-06 の残りはフェーズ 2 で
    /// 対応する（詳細は `QuickLookController` のコメント参照）。
    var previewItemTitle: String! { sourceURL.lastPathComponent }
}
