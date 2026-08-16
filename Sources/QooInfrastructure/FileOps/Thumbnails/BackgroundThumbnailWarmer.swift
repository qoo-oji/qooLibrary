import Foundation
import QooKit

/// 登録済みライブラリ／テンポラリフォルダ配下（サブフォルダを含む）の**動画**の
/// サムネイルを、アプリ起動中にバックグラウンドで先回り生成する
/// [ユーザー要望、要件定義書には無い。9.6 節「バックグラウンド動画サムネイル生成」]。
///
/// ## 実行時機は「アプリ起動中のみ」[設計判断、ユーザー確認済み]
/// 常駐ヘルパー（launchd エージェント等）による終了中の生成は採らない —
/// app-scope の Security-Scoped Bookmark（`files.bookmarks.app-scope`）は
/// 作成したアプリ本体しか解決できず、別プロセスに登録フォルダへのアクセス権を
/// 持たせるには権限管理を丸ごと二重化することになるため。起動直後に掃引を
/// 始めれば、次回以降はキャッシュ済み分をすべて飛ばす差分だけになる。
///
/// ## 生成そのものは `ThumbnailService` に委ねる
/// この型が持つのは「何を・いつ・どの順で頼むか」だけで、実際の生成・
/// キャッシュ保存・同時実行の制限 [PF-11]・動画のタイムアウト・全体トグルの
/// 関門 [DS-05] はすべて既存の `ThumbnailService.thumbnail(for:)` がそのまま
/// 効く。掃引は**逐次 1 本**（スロット 4 本のうち最大 1 本しか使わない）かつ
/// `.background` 優先度で回すため、UI のオンデマンド要求（可視セル）が常に勝つ。
///
/// ## 形式単位のスキップ（このセッション限り）[ユーザー要望の核心]
/// 同じ拡張子が **1 度も成功しないまま
/// `AppLimits.Thumbnail.warmerFormatFailureThreshold` 回失敗**したら、その形式は
/// このセッションでは生成不能と見なして以降スキップする。**意図的に永続化しない**
/// — QuickLook 拡張（QLMedia 等）の有無を直接列挙する公開 API は無いため、
/// 「次回起動時に再試行する」ことが「対応する拡張機能をインストールしたら
/// 自動的に生成されるようになる」を検知コードなしで満たす、最も堅い方法になる。
/// なお対象ファイルの発見自体も `UTType.movie` 準拠（インストール済みアプリに
/// 依存する。mkv の CI 事例参照）なので、拡張導入後に自然に広がる。
///
/// ## 対象外にするもの
/// - **ネットワークボリューム上の登録フォルダ** [NV-37]: サムネイル生成は
///   ファイル本体を丸ごと読むため、共有への I/O 増幅の最大の発生源になる。
/// - **dataless なファイル** [NV-73]: 頼まれていないクラウドの全量ダウンロードを
///   起こさない（`ThumbnailService` 自身も確認するが、あちらの `nil` は
///   「生成失敗」と区別できないため、形式スキップの誤判定を防ぐ意味でも
///   ここで先に外す）。
/// - **DS-04 強制非表示の登録フォルダ**・**全体トグル非表示中** [DS-05]。
///
/// `FileManager` の変更系 API は使わない（読み取りとキャッシュ確認のみ）が、
/// `ThumbnailService`/`CoverImageCache` と一体で使われるためこのディレクトリに
/// 置いている。
@MainActor
public final class BackgroundThumbnailWarmer {
    public static let shared = BackgroundThumbnailWarmer()

    /// 環境設定「キャッシュ」タブのトグルと共有する `UserDefaults` キー
    /// [ユーザー要望: 環境設定から無効化できること]。既定は**有効**
    /// （キーが無ければ `true`）。
    public static let enabledKey = "qoo.thumbnails.backgroundVideoWarming"

    /// 掃引対象のルート 1 件。
    public struct SweepRoot: Sendable {
        public let url: URL
        /// [DS-04] この登録フォルダの配下ではサムネイルを常に表示しない
        /// → 生成もしない。
        public let hidesThumbnails: Bool

        public init(url: URL, hidesThumbnails: Bool) {
            self.url = url
            self.hidesThumbnails = hidesThumbnails
        }
    }

    /// 掃引 1 回分の依存一式。掃引本体（`runSweep`）は `nonisolated static` で
    /// 走るため、メインアクタの `self` を持ち込まず Sendable な値として渡す。
    private struct SweepContext: Sendable {
        let thumbnailService: ThumbnailService
        let cache: CoverImageCache
        let sweepRoots: @Sendable () async -> [SweepRoot]
        let isGloballyHidden: @Sendable () async -> Bool
        let isRemote: @Sendable (URL) -> Bool
        let isDataless: @Sendable (URL) -> Bool
        let maxPixelSize: Int
        let formatFailureThreshold: Int
    }

    private let defaults: UserDefaults
    private let restartDebounce: Duration
    private let context: SweepContext
    /// 現在の（または直近の）掃引タスク。`stop()` は cancel するだけで
    /// 参照は残す — テストが「止めた掃引が実際に降りたこと」を
    /// ``awaitCurrentSweep()`` で決定的に待てるようにするため。
    private var sweepTask: Task<Void, Never>?

    /// テストでは独立した依存を注入できる（`ThumbnailService`/
    /// `RegisteredFolderStore` と同じ設計判断）。
    public init(
        thumbnailService: ThumbnailService = .shared,
        cache: CoverImageCache = DefaultCoverImageCache.shared,
        defaults: UserDefaults = .standard,
        // `nil` なら登録済みライブラリ／テンポラリフォルダ（`registeredFolderRoots()`）。
        // 既定引数式は public init では private static を参照できないため、
        // ここでは `nil` を置いて init 本体で畳む。
        sweepRoots: (@Sendable () async -> [SweepRoot])? = nil,
        // `@MainActor in` を明示する理由は `ThumbnailService.init` の同名
        // パラメータのコメント参照（推論に任せると意図が読めなくなる）。
        isGloballyHidden: @escaping @Sendable () async -> Bool = { @MainActor in
            ThumbnailVisibility.shared.isGloballyHidden
        },
        // `MountTable` はカーネルのマウント表しか読まないため、切断中でも
        // ブロックしない [NV6-02]。
        isRemote: @escaping @Sendable (URL) -> Bool = { MountTable.current().isRemote($0) },
        isDataless: @escaping @Sendable (URL) -> Bool = { CloudMaterialization.isDataless($0) },
        maxPixelSize: Int = AppLimits.Thumbnail.defaultWarmedThumbnailPixelSize,
        formatFailureThreshold: Int = AppLimits.Thumbnail.warmerFormatFailureThreshold,
        restartDebounce: Duration = .seconds(AppLimits.Thumbnail.warmerRestartDebounceSeconds)
    ) {
        self.defaults = defaults
        self.restartDebounce = restartDebounce
        self.context = SweepContext(
            thumbnailService: thumbnailService,
            cache: cache,
            sweepRoots: sweepRoots ?? { await BackgroundThumbnailWarmer.registeredFolderRoots() },
            isGloballyHidden: isGloballyHidden,
            isRemote: isRemote,
            isDataless: isDataless,
            maxPixelSize: maxPixelSize,
            formatFailureThreshold: formatFailureThreshold
        )
    }

    /// 環境設定のトグルの現在値。キーが無ければ有効。
    public var isEnabled: Bool {
        (defaults.object(forKey: Self.enabledKey) as? Bool) ?? true
    }

    /// 掃引を（やり直しも含めて）始める。呼び出しの入口はすべてここ:
    /// 起動時と登録フォルダの変化（`RegisteredFolderIndex.refresh()` に集約）、
    /// 全体トグルの再表示（`qooLibraryApp` が配線）、環境設定での有効化。
    public func restart() {
        sweepTask?.cancel()
        guard isEnabled else { return }
        // `swift test` 中は**共有インスタンス**の掃引を一切走らせない —
        // 開発機の実際の登録フォルダに対して実サムネイル生成が走り、実キャッシュへ
        // 書き込んでしまうため [`DiagnosticLog` のテスト時出力振り替えと同じ理由]。
        // テストは独立インスタンスを作って検証する。
        if self === Self.shared, RuntimeEnvironment.isRunningTests { return }
        let context = self.context
        let debounce = restartDebounce
        sweepTask = Task(priority: .background) {
            // 合図（登録の増減・アクセス権の変化等）は連続で来ることがあるため、
            // 少し待ち合わせて 1 回の掃引にまとめる。次の `restart()` が
            // このタスクを cancel するので、待っている間に合図が重なっても
            // 古い掃引は始まらない。
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Cancellation.isRequested else { return }
            await Self.runSweep(context)
        }
    }

    /// 掃引を止める（環境設定での無効化・全体トグルの非表示から呼ばれる）。
    /// 走っている生成 1 件は区切りまで進むが、次のファイルへは進まない。
    public func stop() {
        sweepTask?.cancel()
    }

    /// テスト用: 現在の掃引（cancel 済みを含む）が実際に降りるまで待つ。
    public func awaitCurrentSweep() async {
        await sweepTask?.value
    }

    // MARK: - 掃引本体（メインアクタの外）

    /// 既定の掃引対象: 登録済みライブラリ／テンポラリフォルダの解決済み URL。
    /// 解決に失敗した登録（ボリューム未接続等 [SB-05]）は黙って外す —
    /// オフラインの共有へ手を出さないのはこの機能の趣旨そのもの。
    nonisolated private static func registeredFolderRoots() async -> [SweepRoot] {
        let store = RegisteredFolderStore.shared
        var roots: [SweepRoot] = []
        for kind in [RegisteredFolderKind.library, .temporary] {
            for folder in await store.folders(kind: kind) {
                guard let url = await store.resolvedURL(for: folder) else { continue }
                roots.append(SweepRoot(url: url, hidesThumbnails: folder.hidesThumbnails))
            }
        }
        return roots
    }

    nonisolated private static func runSweep(_ context: SweepContext) async {
        // [DS-05] 非表示中は列挙すら始めない。表示に戻れば `restart()` が
        // 呼ばれる（`ThumbnailVisibility.onGlobalVisibilityChanged` 経由）。
        if await context.isGloballyHidden() { return }
        let roots = await context.sweepRoots()

        var generatedCount = 0
        var failedCount = 0
        // 形式単位のスキップ（このセッション限り、型のコメント参照）。
        var failuresByExtension: [String: Int] = [:]
        var succeededExtensions: Set<String> = []
        var skippedExtensions: Set<String> = []

        for root in roots {
            if Cancellation.isRequested { return }
            if root.hidesThumbnails { continue } // [DS-04]
            if context.isRemote(root.url) { // [NV-37]
                Log.image.debug("バックグラウンド生成: ネットワークボリューム上のため対象外: \(Log.path(root.url))")
                continue
            }
            let videos = await enumerateVideoFiles(under: root.url)
            for video in videos {
                if Cancellation.isRequested { return }
                if await context.isGloballyHidden() { return } // [DS-05]
                let ext = video.pathExtension.lowercased()
                if skippedExtensions.contains(ext) { continue }
                // クラウドにしか実体が無いファイルはダウンロードさせない
                // [NV-73]。`ThumbnailService` 側の確認に任せず先に外すのは、
                // あちらの `nil` が「生成失敗」と区別できず、形式スキップを
                // 誤発動させてしまうため。
                if context.isDataless(video) { continue }
                // キャッシュ済みかを PNG のデコードなしで確かめる（存在確認
                // だけ）。`ThumbnailService.thumbnail` に任せるとキャッシュ命中
                // でも読み込み・デコードが走り、5 万件規模 [C-07] の掃引では
                // 無視できない。
                let cache = context.cache
                let alreadyCached = (try? await FileIO.perform { () -> Bool in
                    let stamp = try FileMetadata.stamp(of: video)
                    return FileManager.default.fileExists(atPath: cache.url(for: stamp).path)
                }) ?? true // stat できないもの（列挙後に消えた等）は対象外
                if alreadyCached { continue }

                if await context.thumbnailService.thumbnail(for: video, maxPixelSize: context.maxPixelSize) != nil {
                    generatedCount += 1
                    succeededExtensions.insert(ext)
                } else {
                    failedCount += 1
                    failuresByExtension[ext, default: 0] += 1
                    if !succeededExtensions.contains(ext),
                       failuresByExtension[ext, default: 0] >= context.formatFailureThreshold {
                        skippedExtensions.insert(ext)
                        Log.image.info(
                            "バックグラウンド生成: .\(ext) は生成できないため、このセッションでは以降スキップします"
                                + "（対応する QuickLook 拡張が入れば次回起動時に再試行）"
                        )
                    }
                }
            }
        }
        // 何も起きなかった掃引（全件キャッシュ済み等）は既定レベルでは
        // 出さない — 起動のたびに 1 行増えるだけの記録になるため。
        if generatedCount > 0 || failedCount > 0 {
            Log.image.info(
                "バックグラウンドの動画サムネイル生成が完了: 生成 \(generatedCount) 件 / 失敗 \(failedCount) 件"
            )
        }
    }

    /// `root` 配下の動画ファイルを再帰的に列挙する（読み取りのみ）。
    /// ブロッキングな走査なので `FileIO` に載せる [NV6-01]。
    nonisolated private static func enumerateVideoFiles(under root: URL) async -> [URL] {
        await FileIO.perform { () -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            var results: [URL] = []
            for case let url as URL in enumerator {
                if Cancellation.isRequested { break }
                guard PreviewableFileKind.isVideoFilename(url.lastPathComponent) else { continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                results.append(url)
            }
            // 一覧表示と同じ自然順で温めていく（掃引順の決定性も兼ねる）。
            results.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return results
        }
    }
}
