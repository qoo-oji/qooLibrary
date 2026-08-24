import CoreGraphics
import Foundation
import QooKit

/// フォルダ表示モードでの先頭画像サムネイル生成 [9.6 節、IV-01][IV-08][IV-09]。
///
/// 仕様書の `resolveCover` は ①ユーザー指定 → ②サイドカー → ③先頭画像 の
/// 3 段階だが、**このサービスが担うのは③だけ**。①②は DB とライブラリの
/// 実体を見る必要があるため `CoverEditorModel`（`QooApplication`、2-10）が
/// 持ち、そこが「表示に使う URL 1 つ」を決めてからここへ渡す
/// ——①②の実体はどちらも素の画像ファイルなので、この経路にそのまま乗る。
public actor ThumbnailService {
    public static let shared = ThumbnailService()

    private let maxConcurrent: Int
    private let cache: CoverImageCache
    private let imageLoader: ImageLoading
    private let videoThumbnailLoader: VideoThumbnailLoading
    private let pdfThumbnailLoader: PDFThumbnailLoading
    /// [DS-05] 非表示中は生成・キャッシュを一切行わないための問い合わせ口。
    ///
    /// **`ThumbnailVisibility` の値を写し取らず、都度読む**（`ThumbnailVisibility`
    /// のコメント参照: 二重に持つと「表示に戻した直後だけサービスがまだ非表示だと
    /// 思っている」競合が生じる）。クロージャにしているのは、`@MainActor` の
    /// `ThumbnailVisibility.shared` を `actor` の非同期メソッドから読むための
    /// ホップをここに閉じ込めつつ、テストで注入できるようにするため。
    ///
    /// 実際には呼び出し側（UI）も同じ状態を見て「そもそも要求しない」ため、
    /// この関門を通るのは通常「非表示ではない」ケースだけ——つまりホップの
    /// コストは 1 リクエストにつき 1 回、しかもその後に控えるデコードに比べて
    /// 無視できる。**それでもここに置くのは、DS-05 が本質的に I/O の要件で
    /// あり、将来の呼び出し元が確認を忘れても成立させるため**
    /// [`FileOperationService` への集約と同じ「構造で保証する」方針]。
    private let isGloballyHidden: @Sendable () async -> Bool
    private let isDataless: @Sendable (URL) -> Bool

    // PF-11: 同時実行数を制限したタスクキュー。実際の重い処理（アーカイブ
    // 読み込み・デコード）はアクター分離の外（`Task.detached`）で行うが、
    // 「同時に何本まで」の管理はここに集約する。
    private var activeCount = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    /// キャンセルによって起こされた（＝スロットを獲得していない）待機者の印。
    private var cancelledWaiterIDs: Set<UUID> = []

    public init(
        maxConcurrent: Int = AppLimits.Thumbnail.defaultMaxConcurrent,
        cache: CoverImageCache = DefaultCoverImageCache.shared,
        imageLoader: ImageLoading = DefaultImageLoader(),
        // QuickLook を先に試し、それが作れないもの（`hev1` タグの HEVC）だけを
        // 再タグ付けの経路が引き取る（`CompositeVideoThumbnailLoader` 参照）。
        videoThumbnailLoader: VideoThumbnailLoading = CompositeVideoThumbnailLoader(),
        pdfThumbnailLoader: PDFThumbnailLoading = CoreGraphicsPDFThumbnailLoader(),
        // 既定値が**クロージャリテラル**なのが要点: `ThumbnailVisibility.shared`
        // は `@MainActor` 隔離のため、`actor` の（非隔離な）`init` から直接は
        // 触れない。クロージャの中なら評価が非同期文脈まで遅れるので触れる。
        //
        // **`@MainActor in` を明示している。** 省略しても Swift はこの
        // クロージャを `@MainActor` と推論し、`@Sendable () async -> Bool` へ
        // 変換したうえで呼び出し時にホップする（使い捨てのプローブで、
        // 呼び出し元は actor のスレッド・クロージャ本体はメインスレッド、と
        // 実測して確認済み）。ただし推論に任せると本体側の `await` が
        // 「不要な await」と警告され、**あたかも隔離を跨いでいないかのように
        // 読めてしまう**。隔離をここに書いておけば、意図が推論に依存しない。
        isGloballyHidden: @escaping @Sendable () async -> Bool = { @MainActor in
            ThumbnailVisibility.shared.isGloballyHidden
        },
        // テストから差し替えられるようにしておく。dataless なファイルは
        // iCloud に預けた実ファイルでしか作れず、検証のたびにユーザーの
        // クラウドへ書き込むわけにはいかないため。
        isDataless: @escaping @Sendable (URL) -> Bool = { CloudMaterialization.isDataless($0) }
    ) {
        self.maxConcurrent = maxConcurrent
        self.cache = cache
        self.imageLoader = imageLoader
        self.videoThumbnailLoader = videoThumbnailLoader
        self.pdfThumbnailLoader = pdfThumbnailLoader
        self.isGloballyHidden = isGloballyHidden
        self.isDataless = isDataless
    }

    /// `url` はフォルダ、または対応アーカイブ形式のファイル。フォルダ表示モード
    /// でのアイコン表示 [IV-01] から呼ばれる想定。キャッシュ済みなら即座に
    /// 返し、無ければ生成してキャッシュする。生成できない場合は `nil`
    /// （呼び出し側が既定アイコンにフォールバックする [IM-04]）。
    ///
    /// `url` 自身が動画ファイルの場合は `VideoThumbnailLoading`
    /// （`QLThumbnailGenerator` 経由）で生成する［ユーザー要望、動画ライブラリ
    /// としての利用を見据えた拡張］。フォルダ／アーカイブ内の「先頭の動画」を
    /// カバーとして使う対応は対象外（IV-01 が要求する「先頭画像」の範囲を
    /// 超えるため、必要になれば別途検討する）。
    ///
    /// `url` 自身が PDF・EPUB の場合もそれぞれ専用の経路で生成する
    /// ［ユーザー要望: qooLibrary は qooViewer のフロントエンドであり、
    /// qooViewer が対応する形式は qooLibrary 側でも網羅する必要がある］。
    /// PDF は `PDFThumbnailLoading`（CoreGraphics でページ1を直接描画）、
    /// EPUB は `EpubCoverResolver`（zip コンテナとして読み、spine の先頭
    /// ページの画像データを取り出して以降は通常の画像デコード経路に合流）。
    ///
    /// 種別の判定は `PreviewableFileKind`、「中の先頭画像 1 枚」の取り出しは
    /// `CoverImageSourceResolver` に委ねる（どちらも Quick Look の独自カバー
    /// プレビュー [QL-03][QL-08] と共有する。1-14 で切り出した）。
    public func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        // [DS-05] キャッシュの読み出しより**前**に打ち切る。非表示中は
        // 「持っているものを返す」ことすらしない——呼び出し側が既定アイコンへ
        // フォールバックするのが非表示時の正しい表示 [DS-01] だからで、
        // キャッシュ済みかどうかで見た目が変わってはならない。
        if await isGloballyHidden() { return nil }
        // **dataless 判定・stat・種別判定は 1 回の `FileIO.perform` にまとめる**
        // [NV6-01][NV6-02、フェーズ1完了時の監査で発見]。以前はこの 3 つを
        // actor の上（協調プール）で同期に呼んでおり、対象がネットワーク上で
        // 相手が応答しないと、**この actor 自体が最大 30 秒塞がり、アプリ全体の
        // サムネイル要求が直列に凍る**うえ、協調プールのスレッドも 1 本占有した
        // （`BackgroundThumbnailWarmer` は最初から `FileIO` 経由にしてあり、
        // それが本来の契約だった）。
        //
        // - dataless: クラウドにしか実体が無いファイルは、サムネイルのために
        //   ダウンロードしない［実測に基づく判断。一覧を開いただけで蔵書全体の
        //   ダウンロードが始まるのを防ぐ。Quick Look・展開・開くといった
        //   明示的な操作は別経路で従来どおり実体化する]。
        // - stamp: **キャッシュの鍵は `FileIdentity` ではなく `FileContentStamp`**
        //   （更新日時とサイズを含む）。識別子だけで引くと、外部で差し替えた
        //   ファイルに古いサムネイルが出続け、inode 再利用では無関係な
        //   ファイルのサムネイルが出る [`FileContentStamp` のコメント参照]。
        let isDatalessCheck = isDataless
        let probe = await FileIO.perform { () -> (stamp: FileContentStamp, kind: PreviewableFileKind)? in
            if isDatalessCheck(url) { return nil }
            guard let stamp = try? FileMetadata.stamp(of: url) else { return nil }
            return (stamp, PreviewableFileKind.of(url))
        }
        guard let (stamp, kind) = probe else { return nil }
        if let cached = cache.loadCachedImage(for: stamp) {
            return cached
        }

        guard await acquireSlot() else { return nil }
        defer { releaseSlot() }
        // [フェーズ1完了時のリソースリーク監査で追加] `IconGridView` の
        // `.task(id:)` はセルが画面外へスクロールされると自動的にキャンセル
        // される。スロット待ちの間にキャンセルされたリクエストが、順番が
        // 回ってきた後もそのまま重いデコード処理へ進んでしまわないよう、
        // スロット取得直後にここで打ち切る。
        if Cancellation.isRequested { return nil }

        let generated: CGImage?
        switch kind {
        case .video:
            generated = await videoThumbnailLoader.makeThumbnail(for: url, maxPixelSize: maxPixelSize)
        case .pdf:
            generated = await pdfThumbnailLoader.makeThumbnail(for: url, maxPixelSize: maxPixelSize)
        case .folder, .image, .epub, .archive, .other:
            guard let data = await CoverImageSourceResolver.firstImageData(for: url) else { return nil }
            let loader = imageLoader
            let task = Task.detached(priority: .utility) { () -> CGImage in
                try loader.makeThumbnail(from: data, maxPixelSize: maxPixelSize)
            }
            generated = try? await task.value
        }

        guard let generated else {
            // [IM-04] 生成できなくてもアプリは落とさず既定アイコンへ
            // フォールバックする。ただし「なぜサムネイルが出ないのか」は
            // 実機で頻繁に問われるため、診断ログには残す。既定レベル
            // （`info`）では出さない — 対応していない形式のファイルが
            // 並んでいるだけで大量に出てしまうため。
            Log.image.debug("サムネイルを生成できません（\(kind)）: \(Log.path(url))")
            return nil
        }
        do {
            _ = try cache.store(generated, for: stamp)
        } catch {
            Log.image.warning("サムネイルのキャッシュ保存に失敗: \(Log.path(url)) — \(error.localizedDescription)")
        }
        return generated
    }

    /// フォルダ直下のファイルのサムネイルを、自然順で最大 `limit` 枚
    /// ［ユーザー要望: アイコン表示でフォルダの中身を複数枚見せたい］。
    /// 対象の選び方は `CoverImageSourceResolver.coverSourceChildren` 参照。
    ///
    /// **自前でスロットを取らない。** 1 枚ずつ ``thumbnail(for:maxPixelSize:)``
    /// に委ね、スロット管理はそちらに任せる——ここで先に確保してしまうと、
    /// スロットを持ったまま `thumbnail` がスロットを待つ自己デッドロックになる。
    ///
    /// **逐次で回す**（`withTaskGroup` で並行にしない）[設計判断]。並行にすると
    /// 1 フォルダで `limit` 個のスロットを一度に占め、可視セルが数十ある画面で
    /// キューが偏る。逐次なら「見えているフォルダから順に埋まっていく」挙動に
    /// なり、スクロールで画面外へ出れば `Cancellation.isRequested` 経由で即座に降りる。
    ///
    /// 生成できなかった子は黙って飛ばす（呼び出し側は返ってきた枚数だけ描く）。
    /// 1 枚も取れなければ空配列——呼び出し側は既定のフォルダアイコンへ
    /// フォールバックする [IM-04]。
    public func folderCoverThumbnails(
        for folder: URL,
        maxPixelSize: Int,
        limit: Int = AppLimits.Thumbnail.defaultFolderCoverCount
    ) async -> [CGImage] {
        // [DS-05] 非表示中はディレクトリの列挙すら行わない。
        if await isGloballyHidden() { return [] }
        let children = await CoverImageSourceResolver.coverSourceChildren(for: folder, limit: limit)
        var images: [CGImage] = []
        for child in children {
            if Cancellation.isRequested { break }
            if let image = await thumbnail(for: child, maxPixelSize: maxPixelSize) {
                images.append(image)
            }
        }
        return images
    }

    /// 手動コマンド「サムネイルを再生成」用 [MX 一覧]。指定したファイルの
    /// キャッシュを消すだけで、実際の再生成は次回の `thumbnail(for:)` 呼び出し
    /// 時に自然に行われる。
    /// **内容の版によらず、そのファイルのキャッシュをすべて捨てる**
    /// [レビューで指摘]。鍵に更新日時とサイズが入ったため、今の版の鍵だけを
    /// 消すと「一番新しい 1 件だけ消して、古い版は残す」という逆の動きに
    /// なってしまう（この関数の呼び出し元はまだ無いが、意味として誤っている）。
    public func invalidate(_ urls: [URL]) async {
        for url in urls {
            guard let identity = try? FileMetadata.identity(of: url) else { continue }
            await cache.removeEntries(for: identity)
        }
    }

    // MARK: - 同時実行数の制限 [PF-11]

    /// スロット待ちの件数。**検証のためだけにある** — 「キャンセルされた
    /// 待機者が幻のスロットを獲得しない」ことは、待ち行列の状態を外から
    /// 観測できないと確かめようがないため（`ReplaceBackupJournal.pendingBackupCount`
    /// と同じ位置づけ）。
    func pendingWaiterCount() -> Int { waiters.count }

    /// - Returns: スロットを実際に獲得したか。**`false` のときは
    ///   `releaseSlot()` を呼んではならない**（獲得していないものは返せない）。
    private func acquireSlot() async -> Bool {
        if activeCount < maxConcurrent {
            activeCount += 1
            return true
        }
        // [フェーズ1完了時のリソースリーク監査で追加] 素の `withCheckedContinuation`
        // はタスクのキャンセルを観測しないため、`waiters` に積まれたまま
        // どのリクエストからも `releaseSlot()` が呼ばれなければ継続が永久に
        // 迷子になり得た（実機での再現経路: アイコン表示を高速スクロールし、
        // 同時実行数の上限を超えて `waiters` に積まれた直後にスクロールし
        // 続けてそのセルが二度と表示されない場合）。`withTaskCancellationHandler`
        // でキャンセルを検知し、まだ順番待ちであれば即座に解放する。
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.resumeWaiterIfStillWaiting(id) }
        }
        // **キャンセルで起こされた場合はスロットを獲得していない**［同監査の
        // 再点検で発見]。ここで無条件に `activeCount += 1` すると、空きが無い
        // まま起こされたのに獲得済みとして数え、直後の `releaseSlot()` が
        // 別の待機者を起こす——高速スクロールでキャンセルが重なるたびに
        // 実行中のデコードが `maxConcurrent + k` 本まで膨らみ、PF-11 の
        // 上限が実質的に無効になっていた。
        if cancelledWaiterIDs.remove(id) != nil { return false }
        activeCount += 1
        return true
    }

    /// キャンセルされたリクエストの継続が `waiters` に残っていれば取り除いて
    /// 即座に再開させる。既に順番が回ってきて resume 済みなら何もしない
    /// （`withTaskCancellationHandler` の `onCancel` と通常の `releaseSlot()`
    /// が同じ継続を二重に resume してしまわないための安全策）。
    /// 「キャンセルで起こした」印を残し、起こされた側がスロットを
    /// 数えないようにする（`acquireSlot()` の戻り値の根拠）。
    private func resumeWaiterIfStillWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        cancelledWaiterIDs.insert(id)
        waiters.remove(at: index).continuation.resume()
    }

    private func releaseSlot() {
        activeCount -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        }
    }

    // MARK: - 内部

}
