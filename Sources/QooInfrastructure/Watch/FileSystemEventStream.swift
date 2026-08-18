import CoreServices
import Foundation
import QooKit

/// FSEvents から届いた 1 件の変更。
///
/// `flags` の解釈はこの型に閉じ込める（呼び出し側が `kFSEventStreamEventFlag…`
/// のビット演算を書かなくて済むように）。
struct FileSystemChange: Sendable {
    /// 変更のあった項目の**絶対パス**。FSEvents はシンボリックリンクや
    /// firmlink を解決した実体のパスを返す（`/tmp/x` ではなく
    /// `/private/tmp/x`）ため、照合する側も同じ正規化を経ている必要がある
    /// [`DirectoryChangeHub.normalize(_:)` 参照]。
    let path: String
    let flags: FSEventStreamEventFlags

    /// 監視しているルート自身が改名・移動・削除された（または消えていた
    /// ルートが復活した）[`kFSEventStreamCreateFlagWatchRoot`]。
    ///
    /// **`IgnoreSelf` では抑止されない** — 自プロセスによる改名でも届く
    /// （実測で確認済み）。
    var isRootChanged: Bool { has(kFSEventStreamEventFlagRootChanged) }

    /// イベントが多すぎて個別に列挙できなかった。このパス配下はすべて
    /// 変わったものとして扱う [SY-04]。
    var mustScanSubDirectories: Bool { has(kFSEventStreamEventFlagMustScanSubDirs) }

    /// ボリュームのマウント／アンマウント [WA-07][VD-07]。`path` はマウント
    /// ポイント（`/Volumes/…`）。
    var isVolumeMountChange: Bool {
        has(kFSEventStreamEventFlagMount) || has(kFSEventStreamEventFlagUnmount)
    }

    private func has(_ bit: Int) -> Bool { flags & FSEventStreamEventFlags(bit) != 0 }
}

/// FSEvents の薄いラッパ。**「誰が何に関心を持っているか」は一切知らない**
/// （それは `DirectoryChangeHub` の役目）。このファイルが担うのは
/// 「与えられたルート集合を監視し、変更をそのまま流す」ことだけ。
///
/// ## 実測に基づく設計判断（サンドボックス下の最小アプリで計測、
///    実アプリと同一の entitlement）
///
/// | 検証項目 | 実測結果 | ここでの扱い |
/// |---|---|---|
/// | App Sandbox 下で動くか | 動く。追加 entitlement 不要 | そのまま使う |
/// | 読み取り権限の無いパスのイベント | **届く**（`contentsOfDirectory` が拒否される外部ボリュームでも全件到達）| 監視のために事前の許可は要らない |
/// | `/` を監視したときの量 | 待機時 約 2 件/秒。外部プロセスが 4,000 ファイルを作る最悪ケースで約 4,000 件/10 秒 | ボリュームのルート行を監視しても許容範囲と判断し、剪定を素直に行う |
/// | `IgnoreSelf` | 自プロセスの変更は抑止され、別プロセスの変更は届く | 自分の操作は `DirectoryChangeHub.noteLocalChanges` で明示的に伝える（後述）|
/// | 存在しないパスを含めた生成 | **成功する**。パスが出現した時点で `RootChanged` から配送が始まる | ルート集合から存在しないパスを除外しない |
/// | ルート集合の差し替え | `FSEventStreamGetLatestEventId` を `sinceWhen` に渡せば**空白期間のイベントも再生される** | 差し替えは取りこぼしを生まない |
/// | アンマウントの阻害 | しない（ファイル記述子を保持しないため）| 1-16 のイジェクトに影響しない |
///
/// **`kqueue`/`DispatchSource` を採らなかった理由**: ディレクトリごとに
/// ファイル記述子を開くことになり、そのボリュームのアンマウントが
/// `EBUSY` で失敗する。1-16 で実装したイジェクトを壊すため採用しない。
///
/// ## スレッド
/// コールバックは**専用のシリアルキュー**で受け取り、そこから `@MainActor`
/// へ渡す。
///
/// 当初はメインキュー（`FSEventStreamSetDispatchQueue(_, .main)`）を直接
/// 指定していた — 受け取った先でやることは経路の照合と世代番号の加算だけで、
/// いずれにせよ `@MainActor` 上で行う必要があるため。**が、それでは
/// メインキューが実際に回っている場面でしか配送されない。** `swift test`
/// の下では 1 件も届かず、統合テストが 4 件とも落ちることで発覚した
/// （アプリ本体は `NSApplicationMain` がメインループを回すので動いていたが、
/// 「メインスレッドが何かで塞がっていれば変更を取りこぼす」ことに変わりは
/// ない）。専用キューなら誰が何をしていても受け取れる。
///
/// 順序は保証しない（世代番号を増やすだけで、実際の中身は購読側が読み直して
/// 確かめるため、前後しても結果は変わらない）。
@MainActor
final class FileSystemEventStream {
    private let onChanges: @Sendable ([FileSystemChange]) -> Void

    /// FSEvents の配送先。`FileSystemEventStream` ごとに 1 本。
    private let deliveryQueue = DispatchQueue(label: "com.qoolibrary.fsevents", qos: .utility)

    /// 現在監視しているルート（正規化済み・剪定済み）。
    private(set) var roots: [String] = []

    /// `deinit`（`nonisolated`）から破棄するため `nonisolated(unsafe)`。
    /// メインアクタ上のメソッドからのみ書き換え、`deinit` の時点では
    /// 他に参照が無いため競合しない。
    private nonisolated(unsafe) var stream: FSEventStreamRef?

    /// 直前のストリームが最後に処理したイベント ID。ルート集合を差し替える
    /// ときに `sinceWhen` として渡し、停止から再開までの空白を埋める。
    private var lastEventID = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

    /// 生成を待っている間に集合が変わったかを見分けるための世代番号。
    /// ``setRoots(_:)`` の注記を参照。
    private var generation = 0

    init(sinceWhen: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
         onChanges: @escaping @Sendable ([FileSystemChange]) -> Void) {
        self.onChanges = onChanges
        self.lastEventID = sinceWhen
    }

    /// 直近に処理したイベント ID。監視を止めるときに保存し、次回の
    /// `sinceWhen` に渡して空白を埋める [WA-02][WA-03][SY-02][SY-03]。
    var latestEventID: FSEventStreamEventId { lastEventID }

    deinit {
        // **待たない。** 破棄も相手が居なければ待たされ得るので、
        // 解放だけを別の実行先へ投げる（``tearDownWithoutWaiting`` 参照）。
        if let stream { Self.tearDownWithoutWaiting(stream) }
    }

    /// 監視するルート集合を差し替える。同じ集合なら何もしない。
    /// 空を渡すと監視を止める。
    ///
    /// **`async` なのは `FSEventStreamCreate` がブロックし得るため** [NV-94]。
    /// 遮断計測で、**到達できない共有上のパスを含めると 30 秒返らない**
    /// ことが分かった（しかも最後は「成功」する）。ここはメインアクタなので、
    /// そのまま呼ぶと**共有が落ちた瞬間にアプリが 30 秒固まる**——しかも
    /// 監視ルートの組み直しは、フォルダを移動するたびに起きる。
    func setRoots(_ newRoots: [String]) async {
        guard newRoots != roots else { return }
        stopStream()
        roots = newRoots
        // 生成を待っている間に集合がまた変わり得る。**戻ってきたときに
        // 自分がまだ最新かを確かめ、そうでなければ捨てる** — さもないと
        // 30 秒前の古い集合を監視するストリームを据えてしまう。
        //
        // **空集合でも世代は必ず進める**［フェーズ1完了時の監査で発見]。
        // 以前は空のとき世代を進めずに戻っていたため、待ちの最中の生成が
        // 古い世代のまま「まだ最新」と判定され、**関心が 1 つも無いのに
        // 古いルートを監視する幽霊ストリーム**が据え付けられた（次に空でない
        // 集合が来るまで、イベントの配送とストリームが漏れ続ける）。
        generation &+= 1
        guard !newRoots.isEmpty else { return }
        let mine = generation
        let handle = onChanges
        let queue = deliveryQueue
        let requested = newRoots
        let sinceWhen = lastEventID

        let created = await FileIO.perform {
            Self.makeStream(roots: requested, sinceWhen: sinceWhen, queue: queue, onChanges: handle)
        }

        guard generation == mine else {
            if let created { Self.tearDownWithoutWaiting(created.ref) }
            return
        }
        guard let created else { return } // 失敗は致命的ではない（下記）
        stream = created.ref
        Log.watch.debug("ファイル監視を開始: \(requested.count) ルート")
    }

    // MARK: - 内部

    private func stopStream() {
        guard let stream else { return }
        // **停止する前に**読む（無効化後は取得できない）。これは構造体の
        // フィールドを読むだけでブロックしない。
        lastEventID = FSEventStreamGetLatestEventId(stream)
        self.stream = nil
        // 破棄も相手が居ないと待たされ得るので、**待たずに投げる**。
        // 参照は既に手放してあるので、ほかから触られることはない。
        Self.tearDownWithoutWaiting(stream)
    }

    /// 破棄を別の実行先へ投げ、完了を待たない。
    ///
    /// `FSEventStreamRef` は `FSEventStreamCreate` が返した +1 の所有権で、
    /// `tearDown` がそれを解放する。渡した時点でこちらは参照を捨てているので、
    /// 二重に触ることはない。
    private nonisolated static func tearDownWithoutWaiting(_ stream: FSEventStreamRef) {
        let box = StreamBox(stream)
        FileIOExecutor.makeLane().async { tearDown(box.ref) }
    }

    private nonisolated static func tearDown(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// ストリームを 1 本作って開始する。**メインアクタの外で走る**
    /// （``FileIO/perform(_:)`` の中からのみ呼ぶこと）。
    ///
    /// `self` に一切触れないので `nonisolated static` にしてある——
    /// ここで状態を読み書きすると、待っている間に変わった値を使うことになる。
    /// 必要な材料はすべて引数で受け取る。
    private nonisolated static func makeStream(
        roots: [String],
        sinceWhen: FSEventStreamEventId,
        queue: DispatchQueue,
        onChanges: @escaping @Sendable ([FileSystemChange]) -> Void
    ) -> StreamBox? {
        // コールバックには `self` ではなく専用の箱を渡し、context の
        // retain/release に生存管理を任せる。`self` を渡すと
        // 「self → stream → self」の循環になり、`deinit` が呼ばれなくなる。
        // **`passUnretained` で渡す。** `retain`/`release` を指定した context は
        // CF の作法どおり、`FSEventStreamCreate` が同期的に `retain` を呼んで
        // 自分で所有権を取り、破棄時に `release` する。ここで `passRetained`
        // （+1）してしまうと合計 +2 に対して解放が 1 回だけになり、ストリームを
        // 作り直すたび（＝フォルダを移動するたび、ツリーを開くたび）に箱が
        // 1 つずつ漏れる [レビューで発見]。
        let box = CallbackBox(onChanges)
        // 以降 `roots`／`lastEventID` ではなく引数を使う（この関数は
        // どのアクタにも属さないので、状態を覗きにいってはならない）。
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: fsEventsRetainCallbackBox,
            release: fsEventsReleaseCallbackBox,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
            // 一次フィルタとしてのみ使う [FO-10]。自分の変更は
            // `DirectoryChangeHub.noteLocalChanges` で明示的に伝えるため、
            // ここで抑止されて困ることは無い。取りこぼしても再読み込みは
            // 冪等なので実害も無い。
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, fsEventsCallback, &context,
            roots as CFArray, sinceWhen, AppLimits.Watch.coalescingLatency, flags
        ) else {
            // 生成に失敗しても致命的ではない（アプリ復帰時の再同期と
            // ローカル変更の通知は生きている）。次に集合が変わったときに
            // もう一度試みられる。
            // 生成に失敗した場合、FSEvents は `retain` を呼んでいないので
            // ここで解放してはならない（`box` がスコープを抜けて消える）。
            Log.watch.warning("FSEventStreamCreate に失敗しました（監視ルート \(roots.count) 件）")
            return nil
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            Log.watch.warning("FSEventStreamStart に失敗しました（監視ルート \(roots.count) 件）")
            // ここで捨てる。呼び出し側は `nil` を受け取るだけで、
            // 半端に生きたストリームを持たされない。
            tearDown(created)
            return nil
        }
        return StreamBox(created)
    }

}

/// `FSEventStreamRef` を実行文脈の境界を越えて運ぶための箱。
///
/// 中身は不透明ポインタで、渡した側は必ず参照を手放してから渡す
/// （受け取った側だけが触る）ので、共有された可変状態にはならない。
private struct StreamBox: @unchecked Sendable {
    let ref: FSEventStreamRef
    init(_ ref: FSEventStreamRef) { self.ref = ref }
}

// MARK: - C へ渡すコールバック
//
// **`@MainActor` の型の内側に置いてはいけない** [実装中にクラッシュさせて発見]。
// `@MainActor` なメソッドやプロパティの初期化式に書いたクロージャは、C の
// 関数ポインタへ変換される際にもメインアクタ隔離とみなされ、Swift が
// 実行アクタの表明（`swift_task_checkIsolated`）を挿入する。FSEvents は
// これらを**自分のキュー**で呼ぶ（`release` はストリーム破棄時に
// `_FSEventStreamDeallocate` から）ため、その表明が破れて `SIGTRAP` で
// 落ちる。実際、テストスイート全体を走らせると `dispatch_assert_queue_fail`
// で異常終了した。ファイル直下に置けばどのアクタにも属さない。

/// FSEvents の `context.info` に載せるためだけの箱。C の `void *` を跨ぐために
/// 必要で、保持しているのは書き換えられない 1 本の `@Sendable` クロージャだけ。
private final class CallbackBox: Sendable {
    let handle: @Sendable ([FileSystemChange]) -> Void
    init(_ handle: @escaping @Sendable ([FileSystemChange]) -> Void) { self.handle = handle }
}

private let fsEventsRetainCallbackBox: CFAllocatorRetainCallBack = { pointer in
    guard let pointer else { return nil }
    _ = Unmanaged<CallbackBox>.fromOpaque(pointer).retain()
    return pointer
}

private let fsEventsReleaseCallbackBox: CFAllocatorReleaseCallBack = { pointer in
    guard let pointer else { return }
    Unmanaged<CallbackBox>.fromOpaque(pointer).release()
}

private let fsEventsCallback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
    guard let info else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
    // `kFSEventStreamCreateFlagUseCFTypes` を指定しているので `CFArray`。
    guard let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] else { return }
    var changes: [FileSystemChange] = []
    changes.reserveCapacity(count)
    for index in 0..<count where index < paths.count {
        changes.append(FileSystemChange(path: paths[index], flags: rawFlags[index]))
    }
    box.handle(changes)
}
