import AppKit
import Foundation
import QooKit

/// **ファイルシステムへの変更はすべてこのサービスを経由する** [FO-01]。
/// 他のレイヤから `FileManager` の変更系 API を呼んではならない。CI の静的検査
/// （`Scripts/check-fileops-isolation.swift`、B-10）が `QooInfrastructure/FileOps/`
/// 以外からの呼び出しを検出したらビルドを失敗させる [FO-02]。
///
/// フェーズ 1 (1-5) の時点では `ExpectedChangeLedger`（自己変更識別、2-2 で実装）は
/// まだ無いため、`OpReceipt` を返すところまでを担う。呼び出し側（`QooApplication`
/// の `Command` 群、1-11 で実装）がそれを使って Undo を組み立てる、という設計
/// [FS2-01] はそのまま踏襲している。エラーの提示自体は呼び出し側が
/// `NotificationRouter`（1-12b で実装）経由で行う。
///
/// # ブロッキング I/O は必ず ``FileIO/perform(_:)-swift.type.method`` の中で行う [NV6-01]
///
/// **この型の `async` メソッドの本体で `FileManager`・`stat`・`copyfile` を
/// 直に呼んではならない。** それらは応答しないサーバに当たると戻ってこず、
/// `actor` のメソッドは協調スレッドプールの上で走るため、コア数ぶん塞ぐと
/// **アプリの `async` 処理が全部止まる**（1-16b の実測、8章 §8.11.6）。
/// SMB なら 30 秒で解放されるが、NFS の hard マウント（既定）では
/// スレッドが永久に失われる。
///
/// したがって各メソッドは次の形をとる:
///
/// ```
/// public func something(...) async throws -> Result {
///     defer { announce(...) }                    // 通知は actor 上
///     return try await FileIO.perform {          // ← ここから先がブロッキング
///         ... FileManager / stat / copyfile ...
///     }
/// }
/// ```
///
/// ## 副次的な効果 — `actor` も手放される
/// `FileIO.perform` は呼び出し元を**必ず中断させる**ので、I/O のあいだ
/// この `actor` は解放される。この型は**保持する状態を 1 つも持たない**ため
/// 手放しても正しさを損なわず、**1 件のハングが他のファイル操作を巻き添えに
/// しなくなる**。代償として同時に走る操作が交錯し得るが、`RENAME_EXCL` /
/// `COPYFILE_EXCL` が「取りこぼした衝突で健康なファイルを黙って書き潰す」
/// ことを構造的に防いでいるので、最悪でも `EEXIST` のエラーで済む
/// （外部プロセスが同じ名前を作る可能性は元々あり、そちらと同じ扱い）。
///
/// ## 境界を見分ける目印
/// `FileIO.perform` に渡すクロージャは `@Sendable` なので、その中から
/// 呼べるのは `static` か `nonisolated` の要素だけ。**この型の
/// `nonisolated` / `static` なメンバは「ブロッキング側」**、
/// 素の（isolated な）メソッドは「オーケストレーション側」と読める。
public actor FileOperationService {
    /// アプリ全体で単一のインスタンスを使う想定（`CommandStack.shared`/`LockManager.shared`
    /// と同じ方針 [11章 §11.2, §11.3]）。テストでは `init()` で独立インスタンスを作れる。
    public static let shared = FileOperationService()

    public init() {}

    // MARK: - 表示への反映 [10章 §10.0]

    /// この操作で見た目が変わり得る場所を `DirectoryChangeHub` に伝え、
    /// 表示中のフォルダを読み直させる。
    ///
    /// **呼ぶのはこのファイルの中だけ、かつ各操作から必ず 1 回**。
    /// ファイルシステムを変更する経路はすべてこのサービスを通ることが静的検査
    /// [FO-01][FO-02][B-10] で強制されているので、ここに置けば「新しい操作を
    /// 足したのに画面が更新されない」が構造的に起こらない
    /// （`CommandStack.record()` が実行・取り消し・やり直しのログを 1 箇所に
    /// 集めているのと同じ考え方）。**FSEvents は `IgnoreSelf` で自プロセスの
    /// 変更を落とすため、この通知が無いと自分の操作だけ反映されない。**
    ///
    /// 各操作では `defer` で呼ぶ — 一括処理が途中で失敗しても、そこまでに
    /// 実際に動いたファイルは画面へ反映しなければならないため。多めに伝えても
    /// 読み直しは冪等なので害が無い。
    ///
    /// 渡すのは「変更された項目そのもの」でよい。フォルダの一覧が変わった
    /// ことは受け手が親をたどって判断する（`DirectoryChangeHub.apply` 参照）。
    /// 書き込み先フォルダのように、項目ではなく**そのフォルダの中身**が
    /// 変わった場合はそのフォルダ自身を渡す。
    private nonisolated func announce(_ urls: [URL]) {
        DirectoryChangeHub.noteLocalChanges(at: urls)
    }

    // MARK: - 基本操作 [7.1 節]

    @discardableResult
    public func createDirectory(at url: URL, options: OpOptions = .init()) async throws -> OpReceipt {
        defer { announce([url]) }
        // 名前の妥当性は URL を組み立てる前に呼び出し側でも見ているが、
        // ここでも徹底する（`FileOperationService` を直に使う経路が増えても
        // 「`/` を含む名前で入れ子のフォルダが 2 つできる」事故が起きないよう
        // にするため。実測で再現済み）。I/O を伴わないのでこの位置でよい。
        _ = try Self.validated(url.lastPathComponent)
        return try await FileIO.perform {
            // `withIntermediateDirectories: true` は対象がすでに存在していても
            // エラーを投げない（Foundation の標準動作）。「新規フォルダ」は
            // Finder と同じく既存の同名項目との衝突をエラーとして扱うべきのため、
            // 事前に明示チェックする [実機検証で発見: 同名フォルダを重複作成しても
            // 何も起きなかった]。
            let parent = url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path) else {
                throw FileOperationError.operationFailed(
                    "「\(parent.lastPathComponent)」が見つからないため、この中にフォルダを作成できません。"
                )
            }
            try Self.checkDestinationIsWritable(parent)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw FileOperationError.operationFailed("「\(url.lastPathComponent)」という名前の項目はすでに存在します。")
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) // [FM-01]
            Log.fileOps.info("createDirectory: \(Log.path(url))")
            return OpReceipt(before: nil, after: try? Self.identity(of: url), fromURL: url, toURL: url, kind: .createDirectory)
        }
    }

    public func copy(_ items: [URL], to destination: URL, options: OpOptions = .init()) async throws -> [OpReceipt] {
        try await transfer(items, to: destination, options: options, kind: .copy) { source, target, onBytes in
            try FileCopyEngine.copy(
                from: source, to: target, pauseToken: options.pauseToken, onBytesCopied: onBytes
            )
        }
    }

    public func move(_ items: [URL], to destination: URL, options: OpOptions = .init()) async throws -> [OpReceipt] {
        try await transfer(items, to: destination, options: options, kind: .move) { source, target, onBytes in
            try Self.moveItem(
                from: source, to: target, pauseToken: options.pauseToken, onBytesCopied: onBytes
            )
        }
    }

    /// 移動の実体。
    ///
    /// **同一ボリュームなら `rename(2)` で一瞬**（バイトを 1 つも運ばない）。
    /// 別ボリュームへは Foundation と同じく「コピーしてから元を消す」しかなく、
    /// そこは時間がかかるので `FileCopyEngine` に任せて進捗と中断を効かせる。
    ///
    /// 中断された場合は**元を消さない** — 運びきれていないのに消したら
    /// データを失う。
    /// - Note: `internal`（`private` ではない）にしてあるのは、**処理中に元が
    ///   書き換えられた場合に元を消さない**ことをテストから確かめるため。
    ///   `onBytesCopied` はコピー中に間引きなしで呼ばれる唯一の掛かりで、
    ///   ここから元を書き換えれば「処理中の書き換え」を決定的に再現できる
    ///   （進捗の報告は 100ms 間引きのため、速いコピーでは完了後にしか出ず
    ///   再現に使えないことを実測で確認した）。
    static func moveItem(
        from source: URL, to target: URL, pauseToken: PauseToken? = nil,
        onBytesCopied: @escaping (Int64) -> Void
    ) throws -> FileCopyEngine.Outcome {
        // **`renamex_np` + `RENAME_EXCL` を使う** [レビューで発見]。素の
        // `rename(2)` は宛先を**黙って上書きする**ため、`FileManager.moveItem`
        // が持っていた「既にあるなら失敗する」安全弁を失っていた（コピー側は
        // `COPYFILE_EXCL` を保っているのに移動側だけ穴が空いている、という
        // 非対称な状態だった）。衝突は事前に解決してある約束なので、ここは
        // 取りこぼしたときに健康なファイルを書き潰さないための最後の砦。
        // `Darwin.` を明示するのは、素の名前がこの型自身の
        // `rename(_:to:options:)` に解決されてしまうため。
        if Darwin.renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 {
            return .completed(bytes: 0)
        }
        let renameErrno = errno
        guard renameErrno == EXDEV else {
            // **`copyFailed` に寄せる** [ER-03]。以前はここだけ `strerror` の
            // 英語（「Read-only file system」等）を素で埋め込んでおり、
            // コピーなら出るはずの「空き容量が足りません」「書き込む権限が
            // ありません」といった説明も対処法も出なかった。同じ errno なら
            // 同じ説明になるよう、翻訳は `PosixFailure` に一本化してある。
            throw FileOperationError.copyFailed(
                source: source, destination: target, errnoCode: renameErrno
            )
        }
        // **運ぶ前後で元ファイルが変わっていないことを確かめてから消す**
        //［監査で発見、実測で再現］。
        //
        // 他のアプリが書き込み中のファイル（ダウンロード中、書き出し中の動画
        // など）をコピーすると、`copyfile` は**その時点の姿を写して成功を
        // 返す**。実測では 72.3MB を写したあと元は 84.9MB まで伸びた。
        // 移動はこのあと元を消すので、**書き足された 12.6MB は永久に失われる**。
        // `flock` は掛かっていないことも実測済みで、排他では検出できない。
        //
        // 変わっていたら**元を消さない**。写した内容は最新ではないので、
        // 中途半端なコピーの方を片付けて失敗として返す。
        let before = try? FileMetadata.stamp(of: source)
        let outcome = try FileCopyEngine.copy(
            from: source, to: target, pauseToken: pauseToken, onBytesCopied: onBytesCopied
        )
        guard case .completed = outcome else { return outcome }
        if let before, let after = try? FileMetadata.stamp(of: source), before != after {
            try? FileManager.default.removeItem(at: target)
            throw FileOperationError.sourceChangedDuringOperation(source)
        }
        // **更新日時に依存しない確認を重ねる**［ユーザー指摘: NAS の OS は
        // 千差万別で、手元の 1 台で確かめられたことを一般化できない］。
        //
        // 上の検査は更新日時とサイズを見るが、その精度は書き込み先次第で、
        // FAT は 2 秒（実測でナノ秒が常に 0）。1 秒精度のサーバなら、
        // 「同じ大きさのまま中身が入れ替わる」書き込み（プリアロケートした
        // 領域へ書く torrent など）を取り逃がす。**取り逃がした先にあるのは
        // 元ファイルの削除＝データ喪失**なので、内容そのものを抜き取りで
        // 突き合わせてから消す（`MoveVerification`）。
        guard MoveVerification.looksIdentical(source: source, destination: target) else {
            Log.fileOps.error("移動の検証に失敗したため元を残します: \(Log.path(source))")
            try? FileManager.default.removeItem(at: target)
            throw FileOperationError.sourceChangedDuringOperation(source)
        }
        try FileManager.default.removeItem(at: source)
        return outcome
    }

    /// 展開のステージングディレクトリ直下の項目を最終位置へ移送する [EX-04]。
    /// `SecureExtractor` がすべての安全検証（EX-10〜EX-24）を終えた**後**に
    /// 呼ぶことが前提。ステージングディレクトリ自体の削除はここでは行わない
    /// （呼び出し側の責務、`SecureExtractor` 参照）。
    public func promoteFromStaging(
        _ staging: URL, to destination: URL, options: OpOptions = .init()
    ) async throws -> [OpReceipt] {
        let items = try await FileIO.perform {
            try FileManager.default.contentsOfDirectory(
                at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        }
        return try await transfer(items, to: destination, options: options, kind: .promoteFromStaging) { source, target, onBytes in
            try Self.moveItem(
                from: source, to: target, pauseToken: options.pauseToken, onBytesCopied: onBytes
            )
        }
    }

    /// - Parameter newName: **`appendingPathComponent` に渡す前に検証する。**
    ///   `/` を含んだままだとパス区切りとして解釈され、リネームのつもりが
    ///   **別フォルダへの移動**になる（実測で再現。ユーザーから見ると
    ///   「名前を変えたはずのファイルが一覧から消える」）。
    @discardableResult
    public func rename(_ item: URL, to newName: String, options: OpOptions = .init()) async throws -> OpReceipt {
        let validName = try Self.validated(newName)
        let target = item.deletingLastPathComponent().appendingPathComponent(validName)
        defer { announce([item, target]) }

        // **書き換え先が「その項目自身」なら衝突ではない**［監査で発見］。
        //
        // 大文字小文字を区別しないボリューム（APFS/HFS+/exFAT/FAT の既定）では
        // `comic.cbz` → `Comic.cbz` の改名で `fileExists(Comic.cbz)` が **true**
        // になる。相手は自分自身なのに衝突と判定され、
        // 「『Comic.cbz』がすでに存在するため、処理を続けられませんでした」という
        // ユーザーには意味の分からない文言で弾かれていた。Finder では普通にできる
        // 操作で、`FileManager.moveItem` 自体も通す（実測で確認）。
        // 正規化だけを変える改名（NFD → NFC）も全形式で同じ事情になる。
        //
        // 同一実体かどうかは inode（`FileIdentity`）で判定する。実測では
        // 同一実体どうしは一致し、別実体とは一致しないことを確認済み。
        let resolved: ResolvedDestination
        if await FileIO.perform({ Self.refersToSameEntry(item, target) }) {
            resolved = ResolvedDestination(target: target, backupOfReplaced: nil)
        } else if let decided = try await resolveDestination(item, target, options: options) {
            resolved = decided
        } else {
            throw FileOperationError.operationFailed("rename of \(item.path) skipped by conflict policy")
        }
        return try await FileIO.perform {
            try Self.checkDestinationIsWritable(target.deletingLastPathComponent())
            let before = try? Self.identity(of: item)
            try Self.withReplaceBackupCleanup(resolved) {
                try FileManager.default.moveItem(at: item, to: resolved.target) // [FM-05]
            }
            Log.fileOps.info("rename: \(Log.path(item)) → \(Log.path(resolved.target))")
            return OpReceipt(
                before: before, after: try? Self.identity(of: resolved.target),
                fromURL: item, toURL: resolved.target, kind: .rename
            )
        }
    }

    public func trash(_ items: [URL], options: OpOptions = .init()) async throws -> [TrashReceipt] {
        // ゴミ箱側の行き先も伝える（ゴミ箱を開いているウインドウにも反映される）。
        var trashedURLs: [URL] = []
        defer { announce(items + trashedURLs) }
        // 識別子の取得（項目ごとに `stat`）と、ゴミ箱の有無の問い合わせ
        // （ボリュームごとに 1 回、実測 0.01 秒）はどちらも I/O。
        let identities = try await FileIO.perform { () -> [URL: FileIdentity] in
            var identities: [URL: FileIdentity] = [:]
            for item in items {
                identities[item] = try? Self.identity(of: item)
            }
            // **ゴミ箱を持たない場所では呼ばない** [NV4-01]。呼び出し側（UI）が
            // 先に判定して完全削除の経路へ振り分けるのが本筋だが、ここでも
            // 徹底する——`FileOperationService` を直に使う経路が増えても、
            // 「ゴミ箱に入れたつもりが OS のダイアログを経て完全削除される」
            // 事故が起きないようにするため（`createDirectory` の名前検証と同じ考え方）。
            if let first = items.first, !TrashAvailability.hasTrash(forAll: items) {
                throw FileOperationError.trashUnavailable(first)
            }
            return identities
        }
        // NSWorkspace.shared.recycle(_:completionHandler:) を使い、Finder の
        // 「元に戻す」と互換にする [FM-04][TR2-01]。
        //
        // これは完了ハンドラで返る非同期 API なので `FileIO.perform` には
        // 載せない（載せる意味も無い — 待っているスレッドが無いため）。
        // 代わりに ``FileIO/withDeadline(_:_:)`` で**待つのをやめられる**
        // ようにしてある [NV4-04]。
        let mapping: [URL: URL]
        do {
            mapping = try await FileIO.withDeadline(.seconds(AppLimits.FileOperations.trashTimeoutSeconds)) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[URL: URL], Error>) in
                    NSWorkspace.shared.recycle(items) { urls, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: urls)
                        }
                    }
                }
            }
        } catch {
            Log.fileOps.error("trash に失敗: \(items.map(\.path).joined(separator: ", ")) — \(error.localizedDescription)")
            throw error
        }
        trashedURLs = Array(mapping.values)
        Log.fileOps.info("trash 完了: \(mapping.count)/\(items.count) 件")
        for (original, trashed) in mapping {
            Log.fileOps.debug("trash: \(Log.path(original)) → \(Log.path(trashed))")
        }
        return items.compactMap { original in
            guard let id = identities[original] else { return nil }
            return TrashReceipt(originalURL: original, trashURL: mapping[original], identity: id)
        }
    }

    /// ゴミ箱を経由しない完全削除 [FM-14][8章 §8.5]。**取り消せない** —
    /// 呼び出し側は必ず事前確認を経ること [FM-15][PD-02][UD-10]。
    ///
    /// 他の一括操作と違い、**1 件の失敗で全体を中断しない** [ER-13]。成功・
    /// 失敗・スキップを `DeletionOutcome` に個別に集めて返し、呼び出し側が
    /// 結果サマリを提示する [ER-12][ER-14]。部分的な成功はロールバックしない
    /// （そもそも復元手段が無い）[ER-16]。
    ///
    /// ロック済み項目（`.isUserImmutableKey`）は `options.lockedItemResolver`
    /// に判断を委ねる [PD-06]。フォルダについては**中にロック済みの項目を
    /// 含む場合も**尋ねる — `FileManager.removeItem` はロック済みの子に
    /// 当たった時点で失敗し、そこまでに消した子だけが失われた中途半端な
    /// 状態を残すため、先に確認を取ってからまとめてロックを解除する。
    @discardableResult
    public func deletePermanently(
        _ items: [URL], options: DeletePermanentlyOptions = .init()
    ) async throws -> DeletionOutcome {
        defer { announce(items) }
        var receipts: [OpReceipt] = []
        var failures: [DeletionFailure] = []
        var skipped: [URL] = []

        // **取り消せない操作** [PD-05] のため、他の操作より詳しく記録する。
        Log.fileOps.info("deletePermanently 開始: \(items.count) 件")
        for item in items {
            // 存在確認とロックの有無。後者は配下を再帰的に歩くので、
            // ネットワーク上の大きなフォルダでは十分に長い I/O になる。
            let inspection = await FileIO.perform { () -> (exists: Bool, hasLocked: Bool) in
                guard Self.itemExists(at: item) else { return (false, false) }
                return (true, Self.hasAnyLockedItem(at: item))
            }
            guard inspection.exists else {
                Log.fileOps.warning("deletePermanently: 項目が見つかりません \(Log.path(item))")
                failures.append(DeletionFailure(url: item, reason: "項目が見つかりません"))
                continue
            }
            if inspection.hasLocked {
                let decision = await options.lockedItemResolver?(item) ?? .skip
                guard decision == .delete else {
                    Log.fileOps.info("deletePermanently: ロック済みのためスキップ \(Log.path(item))")
                    skipped.append(item)
                    continue
                }
            }
            let result = await FileIO.perform {
                Self.removeOne(item, unlockingFirst: inspection.hasLocked)
            }
            switch result {
            case .removed(let before):
                Log.fileOps.info("deletePermanently: 削除しました \(Log.path(item))")
                receipts.append(OpReceipt(before: before, after: nil, fromURL: item, toURL: item, kind: .deletePermanently))
            case .failed(let reason):
                // [ER-12][ER-13] 判断の要らない失敗（権限・I/O）は中断せず記録し、
                // 呼び出し側が完了後にまとめて提示する。
                Log.fileOps.error("deletePermanently に失敗: \(Log.path(item)) — \(reason)")
                failures.append(DeletionFailure(url: item, reason: reason))
            }
        }
        Log.fileOps.info(
            "deletePermanently 完了: 削除 \(receipts.count) 件 / 失敗 \(failures.count) 件 / スキップ \(skipped.count) 件"
        )
        return DeletionOutcome(receipts: receipts, failures: failures, skipped: skipped)
    }

    /// ``removeOne(_:unlockingFirst:)`` の結果。
    private enum RemovalResult {
        case removed(before: FileIdentity?)
        case failed(reason: String)
    }

    /// 1 項目を完全に消す、ひとかたまりのブロッキング処理 [NV6-01]。
    /// `FileIO.perform` の中からのみ呼ぶこと。
    ///
    /// ロック解除と削除を**同じかたまりに収めてある**のが要点で、
    /// 「解除したが削除は別の往復」にすると、その隙間で中断されたときに
    /// 「消えてもいないのにロックだけ解除された」状態が残る。
    private nonisolated static func removeOne(_ item: URL, unlockingFirst: Bool) -> RemovalResult {
        // 削除の途中でロックに当たって中断しないよう、先にまとめて外す。
        let unlocked = unlockingFirst ? unlockRecursively(item) : []
        let before = try? identity(of: item)
        do {
            try FileManager.default.removeItem(at: item) // [FM-14]
            return .removed(before: before)
        } catch {
            // 削除できなかった以上、外したロックは元に戻す。さもないと
            // 「消えてもいないのにロックだけ解除された」状態が残る
            // [完全削除実装時のレビューで発見]。
            relock(unlocked)
            return .failed(reason: error.localizedDescription)
        }
    }

    /// シンボリックリンク自体の存在も「ある」と判定する。
    /// `FileManager.fileExists(atPath:)` はリンクを**辿る**ため、リンク切れの
    /// シンボリックリンクを「無い」と誤判定し、削除できなくなってしまう
    /// [完全削除実装時のレビューで発見。素の `removeItem` にはこの問題が
    /// 無かったので、存在チェックを足したことによる退行だった]。
    private nonisolated static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// `url` 自身、またはその配下のいずれかがロックされているか。
    /// 見つかった時点で打ち切るため、通常は即座に返る。
    private nonisolated static func hasAnyLockedItem(at url: URL) -> Bool {
        if isLocked(url) { return true }
        return lockedDescendants(of: url, stopAtFirst: true).isEmpty == false
    }

    /// ロック解除は**削除の直前にだけ**行い、実際に解除した URL を返す。
    /// 削除が失敗した場合は呼び出し側が `relock(_:)` で元に戻す。
    private nonisolated static func unlockRecursively(_ url: URL) -> [URL] {
        var cleared: [URL] = []
        if isLocked(url) {
            setImmutable(url, false)
            cleared.append(url)
        }
        for child in lockedDescendants(of: url, stopAtFirst: false) {
            setImmutable(child, false)
            cleared.append(child)
        }
        return cleared
    }

    private nonisolated static func relock(_ urls: [URL]) {
        for url in urls where itemExists(at: url) {
            setImmutable(url, true)
        }
    }

    /// 配下のロック済み項目。**シンボリックリンクの先へは入らない** —
    /// `.isDirectoryKey` はリンクを辿るため、これを使ってディレクトリ判定を
    /// すると「ディレクトリへのシンボリックリンク」でリンク先を列挙して
    /// しまい、削除対象ですらないリンク先のロックを外しかねない
    /// （`removeItem` はリンク自体しか消さない）[レビューで発見]。
    private nonisolated static func lockedDescendants(of url: URL, stopAtFirst: Bool) -> [URL] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true, values?.isDirectory == true else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isUserImmutableKey], options: []
        ) else { return [] }
        var result: [URL] = []
        for case let child as URL in enumerator where isLocked(child) {
            result.append(child)
            if stopAtFirst { return result }
        }
        return result
    }

    private nonisolated static func isLocked(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable == true
    }

    private nonisolated static func setImmutable(_ url: URL, _ locked: Bool) {
        var mutable = url
        var values = URLResourceValues()
        values.isUserImmutable = locked
        try? mutable.setResourceValues(values)
    }

    /// Finder の「エイリアスを作成」相当。`URL.bookmarkData(options: .suitableForBookmarkFile)`
    /// で本物の Finder エイリアス（シンボリックリンクではない）を作る。
    @discardableResult
    public func createAlias(for source: URL, in destinationFolder: URL, options: OpOptions = .init()) async throws -> OpReceipt {
        let aliasName = "\(source.lastPathComponent) のエイリアス"
        let target = destinationFolder.appendingPathComponent(aliasName)
        defer { announce([target]) }
        guard let resolved = try await resolveDestination(source, target, options: options) else {
            throw FileOperationError.operationFailed("alias creation for \(source.path) skipped by conflict policy")
        }
        return try await FileIO.perform {
            let bookmarkData = try source.bookmarkData(options: [.suitableForBookmarkFile])
            try Self.withReplaceBackupCleanup(resolved) {
                try URL.writeBookmarkData(bookmarkData, to: resolved.target)
            }
            Log.fileOps.info("createAlias: \(Log.path(source)) → \(Log.path(resolved.target))")
            return OpReceipt(
                before: nil, after: try? Self.identity(of: resolved.target),
                fromURL: source, toURL: resolved.target, kind: .createAlias
            )
        }
    }

    /// Finder の「ロック」/「ロック解除」相当。
    public func setLocked(_ items: [URL], locked: Bool) async throws -> [OpReceipt] {
        defer { announce(items) }
        return try await FileIO.perform {
            var receipts: [OpReceipt] = []
            for item in items {
                var mutableItem = item
                var values = URLResourceValues()
                values.isUserImmutable = locked
                do {
                    try mutableItem.setResourceValues(values)
                } catch {
                    Log.fileOps.error(
                        "setLocked(\(locked)) が \(receipts.count) 件成功後に失敗: \(item.path) — \(error.localizedDescription)"
                    )
                    throw error
                }
                let id = try? Self.identity(of: item)
                receipts.append(OpReceipt(before: id, after: id, fromURL: item, toURL: item, kind: .setLocked))
            }
            Log.fileOps.info("setLocked(\(locked)) 完了: \(receipts.count)/\(items.count) 件")
            return receipts
        }
    }

    public func restoreFromTrash(_ receipts: [TrashReceipt]) async throws -> [OpReceipt] {
        defer { announce(receipts.map(\.originalURL) + receipts.compactMap(\.trashURL)) }
        return try await FileIO.perform {
            var results: [OpReceipt] = []
            for receipt in receipts {
                guard let trashURL = receipt.trashURL else { continue }
                do {
                    try FileManager.default.moveItem(at: trashURL, to: receipt.originalURL) // [UD-08]
                } catch {
                    Log.fileOps.error(
                        "restoreFromTrash に失敗: \(trashURL.path) → \(receipt.originalURL.path) — \(error.localizedDescription)"
                    )
                    throw error
                }
                Log.fileOps.info("restoreFromTrash: \(Log.path(trashURL)) → \(Log.path(receipt.originalURL))")
                results.append(OpReceipt(
                    before: nil, after: try? Self.identity(of: receipt.originalURL),
                    fromURL: trashURL, toURL: receipt.originalURL, kind: .restoreFromTrash
                ))
            }
            return results
        }
    }

    // MARK: - 事前検査 [ER-03]
    //
    // **「やってみて失敗する」より「始める前に断る」**。ここに集めた検査は
    // すべて、実行しなくても結果が分かるもの。1 バイトも書かずに済むうえ、
    // 失敗の理由も正確に言える（実行してから返る `errno` は、原因が
    // 複数考えられる場面では曖昧になる）。

    /// ユーザーが入力した名前を検証する。使えなければ理由付きで投げる。
    private static func validated(_ name: String) throws -> String {
        do {
            return try FileNameValidation.sanitized(name)
        } catch let failure as FileNameValidation.Failure {
            throw FileOperationError.invalidName(name, reason: failure)
        }
    }

    /// 2 つのパスが**同じ実体**を指しているか。
    ///
    /// 「名前は違って見えるのに同じファイル」は、大文字小文字を区別しない
    /// ボリューム（`comic.cbz` と `Comic.cbz`）と、Unicode 正規化の違い
    /// （NFC の `が` と NFD の `が`）で起きる。**後者は大文字小文字を区別する
    /// ボリュームでも起きる**（実測で APFS 大文字小文字区別版・UDF でも同一視
    /// されることを確認）。
    ///
    /// 名前の文字列比較では判定できない（どの規則で同一視されるかは
    /// ボリューム次第）ので、`FileIdentity`（volumeUUID + inode）で見る。
    /// どちらかが存在しなければ当然「別」。
    private static func refersToSameEntry(_ a: URL, _ b: URL) -> Bool {
        guard let idA = try? FileMetadata.identity(of: a),
              let idB = try? FileMetadata.identity(of: b)
        else { return false }
        return idA == idB
    }

    /// 1 ファイルが書き込み先のファイルシステムの上限に収まること。
    ///
    /// **FAT32 の上限は 4GB 弱**（実測: `volumeMaximumFileSize` が
    /// 4.29 GB を返し、それを超える大きさへ伸ばそうとすると `EFBIG` で
    /// 拒否される）。動画ファイルでは普通に超えるため、USB メモリへ運ぼうと
    /// して 4GB 書いたところで失敗する、という無駄が現実に起こる。
    ///
    /// 上限は OS が答えるので推測は要らない。答えない形式では検査を飛ばす
    /// （`VolumeCapacity` と同じ判断 — 分からないときに断ると、正当な操作が
    /// できなくなる）。
    ///
    /// 同一ボリューム内の移動・クローンではそもそも呼ばれない
    /// （`ProgressTracker` が走査しないため）。同じボリュームに既に在る
    /// ファイルは、定義上その上限に収まっている。
    private static func checkFileSizeFits(_ size: Int64, item: URL, destination: URL) throws {
        guard let limit = (try? destination.resourceValues(forKeys: [.volumeMaximumFileSizeKey]))?
            .volumeMaximumFileSize, limit > 0
        else { return }
        guard size > Int64(limit) else { return }
        throw FileOperationError.fileTooLargeForDestination(
            item: item, size: size, limit: Int64(limit), destination: destination
        )
    }

    /// 名前が書き込み先の上限に収まること。
    ///
    /// **入口の検査（`FileNameValidation`）だけでは足りない。** あちらは
    /// いちばん緩い規則（NFD 後 255 単位＝APFS/HFS+）を使っており、それより
    /// 短い上限を持つ書き込み先を知らない。実測では **SMB は UTF-8 で
    /// 255 バイト**なので、日本語 86 文字以上の名前は「Mac 内では作れるのに
    /// 書き込み先では作れない」。同人誌・コミックのファイル名では十分あり得る
    /// 長さで、一括コピーの途中で止まる原因になる。
    ///
    /// 規則を持たない形式では何もしない（`NameLengthLimit` の判断）。
    private static func checkNameFits(_ name: String, item: URL, destination: URL) throws {
        guard let rule = NameLengthLimit.rule(forVolumeAt: destination) else { return }
        guard !rule.accepts(name) else { return }
        throw FileOperationError.nameTooLongForDestination(
            name: name, item: item,
            length: rule.length(of: name), limit: rule.maximum,
            unitIsBytes: rule.unit == .bytes
        )
    }

    /// 書き込み先に実際に書けること。
    ///
    /// 実測では、読み取り専用ボリュームへの書き込みは `EROFS` になり、
    /// Foundation 経由なら「ボリュームは読み取り専用です」と説明も付く。
    /// それでも**先に断る**のは、一括処理で 100 件目まで進んでから同じ
    /// エラーを返すのではなく、1 件目に触る前に止めたいため。
    ///
    /// ## `volumeIsReadOnly` だけでは足りない [NV-89]
    /// **書き込み権限の無い Windows 共有で、モードビットと `volumeIsReadOnly` の
    /// 両方が嘘をついた**（1-16b の実測、8章 §8.11）:
    ///
    /// | 情報源 | 答え |
    /// |---|---|
    /// | `ls -l` / `stat` のモードビット | `drwx------`（書ける）→ **嘘** |
    /// | `volumeIsReadOnly` | `×`（読み取り専用でない）→ **役に立たない** |
    /// | **`access(2)` の `W_OK`** | **`false`（正しい）** |
    ///
    /// SMB ではサーバ側の共有アクセス許可と ACL が POSIX パーミッションへ
    /// 正しく写らないため（NV-29）、モードビットは信用できない。`access(2)` は
    /// サーバが返す実効アクセスマスクに基づくので正しく答える。
    ///
    /// **呼ぶのは操作ごとに 1 回**（項目ごとに呼ばない）[NV-98]。ネットワーク
    /// ボリュームでは 1 回ごとに往復が発生し得るため、`pathLimit` と同じ理由。
    private static func checkDestinationIsWritable(_ destination: URL) throws {
        let values = try? destination.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if values?.volumeIsReadOnly == true {
            throw FileOperationError.destinationIsReadOnly(destination)
        }
        // 存在しない書き込み先（これから作るフォルダ等）はここでは判定しない
        // ——`access` は存在しないパスに対して当然失敗するが、それは
        // 「書けない」ではない。作成の可否は呼び出し側が別途確かめている。
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        guard access(destination.path, W_OK) != 0 else { return }
        let code = errno
        Log.fileOps.warning(
            "書き込み先に書き込めません（access W_OK）: \(Log.path(destination)) errno=\(code)"
        )
        throw FileOperationError.destinationNotWritable(destination, errnoCode: code)
    }

    /// 書き込み先が、運ぼうとしている項目自身またはその配下でないこと。
    ///
    /// **実測**: 同一ボリュームの移動は `rename(2)` が `EINVAL` で止めてくれるが、
    /// **コピーは止まらない** — `copyfile(3)` が 332 階層まで自己増殖し、
    /// ユーザーのフォルダの中にゴミの木を作ってから `ENAMETOOLONG` で
    /// 失敗した。Finder もこの操作は実行前に断る。
    private static func checkDestinationIsNotInsideSource(_ item: URL, _ destination: URL) throws {
        let source = item.standardizedFileURL.resolvingSymlinksInPath()
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
        let sourcePath = source.path
        let targetPath = target.path
        if targetPath == sourcePath || targetPath.hasPrefix(sourcePath + "/") {
            throw FileOperationError.destinationInsideSource(source: item, destination: destination)
        }
    }

    /// 出来上がるパスが、そのボリュームで許される長さに収まること。
    ///
    /// **実測**: macOS がマウントし得る形式すべて（APFS / HFS+ / exFAT /
    /// FAT12・16・32 / UDF / SMB）で、いずれも 1019〜1023 バイトで
    /// `ENAMETOOLONG` になった。ファイルシステム固有ではなく OS の
    /// `PATH_MAX`（1024）が効いている。
    ///
    /// - Parameter limit: **呼び出し側が 1 回だけ求めて渡す**［ユーザーの
    ///   「SMB は常時接続できるわけではない」という指摘を受けて修正］。
    ///   上限の取得は `pathconf`＝書き込み先への問い合わせで、ネットワーク
    ///   ボリュームでは 1 回ごとに往復が発生し得る。項目ごとに呼ぶと
    ///   1,000 件の一括処理で 1,000 回問い合わせることになり、接続が
    ///   不安定なときに待ち時間を桁違いに増やす。上限はボリュームの性質で
    ///   項目には依らないので、1 回で足りる。
    private static func checkResultingPathFits(
        destination: URL, relativePath: String, item: URL, limit: Int
    ) throws {
        let resulting = PathLimits.resultingPathBytes(destination: destination, relativePath: relativePath)
        guard resulting > limit else { return }
        throw FileOperationError.pathTooLong(
            item: item, destination: destination, resultingBytes: resulting, limitBytes: limit
        )
    }

    // MARK: - 内部処理

    /// 一括転送の骨組み。**ここは「段取り」だけを担い、ブロッキングな仕事は
    /// すべて `FileIO.perform` の中の 2 つの関数（``preflight`` と ``carry``）へ
    /// 追い出してある** [NV6-01]。
    ///
    /// 1 項目あたりのスレッド往復は通常 **2 回**（衝突の判定と、運ぶ処理）。
    /// 衝突をユーザーに尋ねる場合だけ 1 回増える。往復そのものは
    /// マイクロ秒規模で、実コピーの時間に対して無視できる。
    private func transfer(
        _ items: [URL],
        to destination: URL,
        options: OpOptions,
        kind: OperationKind,
        perform: @escaping @Sendable (URL, URL, @escaping (Int64) -> Void) throws -> FileCopyEngine.Outcome
    ) async throws -> [OpReceipt] {
        // 移動元の各項目（親フォルダの一覧が変わる）と、書き込み先フォルダ
        // （そのフォルダの一覧が変わる）の両方を伝える。
        defer { announce(items + [destination]) }

        let tracker = try await FileIO.perform {
            try Self.preflight(items: items, destination: destination, options: options, kind: kind)
        }
        tracker.begin()

        var receipts: [OpReceipt] = []
        for item in items {
            // ユーザーが中断したら、そこまでに運び終えた分だけを返す
            // （運び終えた項目は Undo できる状態で残る）[ER-16 の精神]。
            if Cancellation.isRequested { break }
            // 一時停止は項目の境界でも受ける（クローンのようにコールバックが
            // 一度も来ない経路でも効くようにするため）。
            //
            // **待つのは専用スレッドの上で**。`waitWhilePaused` は
            // `NSCondition` で実際にスレッドを止めるので、協調プールの上で
            // 待つと 1 件の一時停止がアプリの `async` 処理を巻き添えにする。
            // 止まっていない場合は往復しない（`isPaused` はロックを取るだけで
            // I/O を伴わない）。
            if let pauseToken = options.pauseToken, pauseToken.isPaused {
                await FileIO.perform { pauseToken.waitWhilePaused() }
            }
            if Cancellation.isRequested { break }
            tracker.startItem(item)
            let target = destination.appendingPathComponent(item.lastPathComponent)
            guard let resolved = try await resolveDestination(item, target, options: options) else {
                Log.fileOps.debug("\(kind.logLabel): 衝突方針によりスキップ \(Log.path(item))")
                tracker.finishItem()
                continue // [ConflictPolicy.skip]
            }
            let carried: CarriedItem
            do {
                carried = try await FileIO.perform {
                    try Self.carry(item, to: resolved, using: perform, tracker: tracker)
                }
            } catch {
                // **どの項目で止まったか**を必ず残す [LG2-01]。
                Log.fileOps.error(
                    "\(kind.logLabel) が \(receipts.count) 件成功後に失敗: \(item.path) → \(resolved.target.path) — \(error.localizedDescription)"
                )
                // **そこまでに動いた分の受領書を捨てない** [ER-13][ER-16]
                //［監査で発見］。以前はここで受領書ごと捨てていたため、
                // 実際に移動し終えた項目が Undo にも操作履歴にも残らず、
                // ユーザーには元に戻す手段が無かった。
                // 1 件も動いていなければ運ぶものが無いので、素の失敗として投げる。
                if receipts.isEmpty { throw error }
                throw PartialTransferFailure(receipts: receipts, failedItem: item, underlying: error)
            }
            if carried.cancelled {
                Log.fileOps.info("\(kind.logLabel) を中断しました（\(receipts.count)/\(items.count) 件まで完了）")
                break
            }
            Log.fileOps.debug("\(kind.logLabel): \(Log.path(item)) → \(Log.path(resolved.target))")
            receipts.append(OpReceipt(
                before: carried.before, after: carried.after,
                fromURL: item, toURL: resolved.target, kind: kind
            ))
            tracker.finishItem()
        }
        Log.fileOps.info("\(kind.logLabel) 完了: \(receipts.count)/\(items.count) 件 → \(Log.path(destination))")
        return receipts
    }

    /// **1 バイトも書く前に、分かる失敗はすべてここで断る** [ER-03]。
    /// 一括処理の途中で失敗すると、成功した分の `OpReceipt` が破棄されて
    /// Undo にも履歴にも残らない（既知の課題）ため、そもそも始めないのが
    /// いちばん安全。
    ///
    /// 総量の走査（`ProgressTracker` の初期化）は 5 万件のライブラリでは
    /// 数秒かかるので、**この関数全体がブロッキング**である。返り値の
    /// `ProgressTracker` は `@unchecked Sendable` なので `FileIO` の
    /// 境界をまたいで持ち出せる。
    private nonisolated static func preflight(
        items: [URL], destination: URL, options: OpOptions, kind: OperationKind
    ) throws -> ProgressTracker {
        try checkDestinationIsWritable(destination)
        // 書き込み先への問い合わせは**ここで 1 回だけ**。ネットワーク
        // ボリュームでは 1 回ごとに往復が発生し得るため、項目ごとに尋ねない
        // ［ユーザー指摘: SMB は常時接続できるわけではない］。
        let pathLimit = PathLimits.maxPathBytes(at: destination)
        for item in items {
            try checkDestinationIsNotInsideSource(item, destination)
            try checkResultingPathFits(
                destination: destination, relativePath: item.lastPathComponent,
                item: item, limit: pathLimit
            )
        }

        let tracker = ProgressTracker(
            reporter: options.progress,
            items: items,
            destination: destination
        )
        // 走査済みなら、いちばん深い項目まで含めて収まるか確かめる。
        // 走査していない場合（クローンで済む経路）は追加の走査をしてまでは
        // 見ない — その経路は同一ボリューム内で階層の深さが変わらないため。
        if let deepest = tracker.deepestRelativePath {
            try checkResultingPathFits(
                destination: destination, relativePath: deepest.path,
                item: deepest.item, limit: pathLimit
            )
        }
        if let largest = tracker.largestFile {
            try checkFileSizeFits(largest.size, item: largest.item, destination: destination)
        }
        if let longest = tracker.longestName {
            try checkNameFits(longest.name, item: longest.item, destination: destination)
        }
        // **足りないと分かっているなら、1 バイトも書かずに断る** [ER-03]。
        // 以前はそのまま書き始め、途中で `ENOSPC` になって「エラー2」とだけ
        // 表示していた（実機で 4GB を空き 2.8GB のボリュームへコピーして発覚。
        // 2.91GB まで書いてから失敗し、しかも理由が伝わらなかった）。Finder も
        // 開始前に確かめて断る。`SecureExtractor` の [EX-23] と同じ考え方。
        if let required = tracker.requiredBytes,
           let available = VolumeCapacity.available(at: destination) {
            // 余裕分はボリュームの大きさに応じて縮める（`VolumeCapacity.margin`）。
            // 固定 64MB のままだと、空きが 64MB を下回るボリュームで
            // どんな小さなコピーも拒否してしまう。
            let margin = VolumeCapacity.margin(
                requested: AppLimits.FileOperations.freeSpaceMargin, at: destination
            )
            if available < required + margin {
                Log.fileOps.error(
                    "\(kind.logLabel) を開始前に中止: 空き容量不足（必要 \(required) / 空き \(available)）→ \(Log.path(destination))"
                )
                throw FileOperationError.insufficientFreeSpace(
                    required: required, available: available, destination: destination
                )
            }
        }
        return tracker
    }

    /// 1 項目を運び終えた結果。`transfer` の受領書はこれから組み立てる。
    private struct CarriedItem {
        let before: FileIdentity?
        let after: FileIdentity?
        /// ユーザーが中断した。`transfer` はここで打ち切る。
        let cancelled: Bool
    }

    /// **1 項目を実際に運ぶ、ひとかたまりのブロッキング処理** [NV6-01]。
    /// `FileIO.perform` の中からのみ呼ぶこと。
    private nonisolated static func carry(
        _ item: URL,
        to resolved: ResolvedDestination,
        using perform: (URL, URL, @escaping (Int64) -> Void) throws -> FileCopyEngine.Outcome,
        tracker: ProgressTracker
    ) throws -> CarriedItem {
        let before = try? identity(of: item)
        // 運ぶ前の姿を控える。運び終えたあとに元が変わっていたら、
        // 写した内容は最新ではない（`moveItem` のコメント参照）。
        // 移動は `moveItem` の中で同じことを確かめてから元を消すので、
        // ここで効くのは主にコピー。
        let stampBefore = try? FileMetadata.stamp(of: item)
        // 中断は「成功しなかった」として扱う — `.replace` の退避を
        // 消させないため（`withReplaceBackupCleanup` のコメント参照）。
        let outcome = try withReplaceBackupCleanup(resolved, succeeded: { outcome in
            if case .completed = outcome { return true }
            return false
        }) {
            try perform(item, resolved.target) { bytes in tracker.addBytes(bytes) }
        }
        // **書き込み中のファイルを写していないか確かめる**［実測で確認］。
        // 他アプリが書き足している最中のファイルをコピーすると、
        // `copyfile` はその時点の姿を写して**成功を返す**。黙って
        // 中途半端なコピーを残すと、ユーザーは完全な控えを取ったと
        // 思い込む（そのあと元を消せばデータを失う）。
        // 元が残っている場合だけ比べる（移動では既に消えている）。
        if case .completed = outcome,
           let stampBefore,
           let stampAfter = try? FileMetadata.stamp(of: item),
           stampBefore != stampAfter {
            try? FileManager.default.removeItem(at: resolved.target)
            throw FileOperationError.sourceChangedDuringOperation(item)
        }
        if case .cancelled = outcome {
            // **中断した項目の書きかけを消す**［実機検証で発見］。
            // `copyfile` は 1 ファイルなら書きかけの宛先を自分で
            // 片付けるが、**再帰的なフォルダコピーを中断した場合は
            // 途中まで作った木を残す**（1.1GB のアーカイブ展開を
            // 止めたあと、134MB の中途半端なフォルダが残って発覚）。
            // 運び終えていない以上、受領書も返さない＝ Undo にも
            // 残らないので、ここで消さないと誰も片付けられない。
            //
            // 消してよいのは**この呼び出しで新しく作った場所**だから。
            // `.replace` で既存を退避している場合は
            // `restoreReplacedItem` が消して元へ戻すので触らない。
            if resolved.backupOfReplaced == nil {
                removePartialWrite(at: resolved.target)
            }
            return CarriedItem(before: before, after: nil, cancelled: true)
        }
        return CarriedItem(before: before, after: try? identity(of: resolved.target), cancelled: false)
    }

    /// `resolveDestination` の戻り値。`.replace` の場合、書き込みが失敗したときに
    /// 元へ戻せるよう退避先も一緒に返す。
    private struct ResolvedDestination: Sendable {
        let target: URL
        let backupOfReplaced: URL?
    }

    /// ``resolve(_:_:policy:)`` の結果。ユーザーに尋ねる必要が生じたかどうかを
    /// 呼び出し側（`actor` 側）へ返すために、決着とは別のケースを持つ。
    private enum ConflictResolution {
        case decided(ResolvedDestination)
        /// [ConflictPolicy.skip]
        case skip
        /// `.ask` で、実際に衝突していた。呼び出し側が `conflictResolver` を待つ。
        case needsUserDecision
    }

    /// 衝突判定と解決 [7.1 節]。戻り値が `nil` の場合はその項目をスキップする。
    ///
    /// **ブロッキングな部分（存在確認・退避・連番探し）と、ユーザーを待つ部分を
    /// 分けてある** [NV6-01]。前者は ``resolve(_:_:policy:)`` にまとまっていて
    /// `FileIO.perform` の中で走り、後者（`conflictResolver` の `await`）は
    /// この `actor` 上に残る。衝突が無い通常の経路は**往復 1 回**で済む。
    ///
    /// ユーザーが選んだあとにもう一度 ``resolve`` を通すのは、尋ねている間に
    /// 書き込み先が変わっている可能性があるため（考えている時間は長い）。
    private func resolveDestination(_ source: URL, _ destination: URL, options: OpOptions) async throws -> ResolvedDestination? {
        var resolution = try await FileIO.perform {
            try Self.resolve(source, destination, policy: options.conflictPolicy)
        }
        if case .needsUserDecision = resolution {
            guard let resolver = options.conflictResolver else {
                throw FileOperationError.conflictResolutionRequired(source: source, destination: destination)
            }
            let chosen = await resolver(source, destination)
            guard chosen != .ask else {
                throw FileOperationError.conflictResolutionRequired(source: source, destination: destination)
            }
            resolution = try await FileIO.perform {
                try Self.resolve(source, destination, policy: chosen)
            }
        }
        switch resolution {
        case .decided(let resolved): return resolved
        case .skip: return nil
        case .needsUserDecision:
            // `chosen != .ask` を確かめた直後なのでここへは来ないが、
            // 将来 `ConflictPolicy` にケースが増えたときに黙って通さない。
            throw FileOperationError.conflictResolutionRequired(source: source, destination: destination)
        }
    }

    /// 衝突判定と、**ユーザーに尋ねずに決められる範囲**の解決。
    /// `FileIO.perform` の中からのみ呼ぶこと [NV6-01]。
    private nonisolated static func resolve(
        _ source: URL, _ destination: URL, policy: ConflictPolicy
    ) throws -> ConflictResolution {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return .decided(ResolvedDestination(target: destination, backupOfReplaced: nil))
        }

        switch policy {
        case .ask:
            return .needsUserDecision
        case .replace:
            // [フェーズ1完了時のリソースリーク・ファイル安全性監査で追加、
            // ユーザー指摘: 「壊れたファイルで健康なファイルを書き潰してしまう
            // おそれはないか」] 既存の宛先ファイルを即座に削除せず、同じ
            // ディレクトリへ一時退避してから `perform` を呼ぶ。退避は同一
            // ディレクトリ内の `moveItem`（同一ボリュームなら実質 rename(2) で
            // 高速・原子的）で行う。`perform` が失敗した場合は
            // `withReplaceBackupCleanup` が退避先から元の場所へ戻すため、
            // 書き込み失敗時に新旧どちらのファイルも失われる事態を避けられる。
            // 退避ファイルは成功・失敗いずれの場合も後始末されるため通常は
            // 痕跡を残さないが、退避直後にアプリがクラッシュする等の極めて
            // まれなタイミングでは `.qoo-replace-backup-*` が残る可能性がある
            // （§3.12 の例外扱い、`SecureExtractor` の残存ステージングと同種の
            // リスクとして許容する — 中身は元ファイルそのものなので、万一残っても
            // 手動で拡張子を戻せば復元できる）。
            let backup = destination.deletingLastPathComponent()
                .appendingPathComponent(".qoo-replace-backup-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: destination, to: backup) // [FM-13]
            return .decided(ResolvedDestination(target: destination, backupOfReplaced: backup))
        case .keepBoth:
            return .decided(ResolvedDestination(target: nextAvailableName(for: destination), backupOfReplaced: nil)) // [CF-01]
        case .skip:
            return .skip
        }
    }

    /// `.replace` で退避したバックアップの後始末を一箇所に集約する。`operation` が
    /// 成功すればバックアップを削除し、失敗すればバックアップを元の場所へ書き戻して
    /// からエラーを再送出する（`.replace` 以外では `backupOfReplaced` が `nil` の
    /// ため何もしない）。
    /// - Parameter succeeded: `operation` の戻り値から「本当に書き終えたか」を
    ///   判定する。**中断は失敗として扱わなければならない** — `.replace` の
    ///   最中にキャンセルすると `copyfile` は書きかけの宛先を消すので、
    ///   成功扱いで退避まで消すと**退避元と書き込み先の両方を失う**
    ///   [レビューで発見。今回入れた変更の中で最も危険な経路だった]。
    private nonisolated static func withReplaceBackupCleanup<T>(
        _ resolved: ResolvedDestination,
        succeeded: (T) -> Bool = { _ in true },
        _ operation: () throws -> T
    ) throws -> T {
        do {
            let result = try operation()
            guard succeeded(result) else {
                restoreReplacedItem(resolved)
                return result
            }
            if let backup = resolved.backupOfReplaced {
                // **消さずにゴミ箱へ送る** [レビューで発見]。`.replace` が UI から
                // 到達できるようになった [FM-11] ことで、「置き換える」を選んだ
                // 直後に ⌘Z すると、コピーは取り消されるのに置き換えられた
                // 元のファイルはもう戻らない、という取り返しのつかない経路が
                // できていた。ゴミ箱にあれば手で戻せる（Undo が新たなデータ
                // 喪失を持ち込まない、という本コードベースの原則 [UD-03]）。
                moveReplacedItemToTrash(backup)
            }
            return result
        } catch {
            restoreReplacedItem(resolved)
            throw error
        }
    }

    /// 中断で書きかけになった宛先を片付ける。
    ///
    /// **黙って諦めない**。以前は `try?` 1 回で、失敗しても何も残らなかった。
    /// ここが失敗すると「中断したのに中途半端なフォルダが残る」——しかも
    /// 運び終えていない項目は受領書を返さない＝ Undo にも履歴にも載らないので、
    /// ユーザーには片付ける手立てが無い。
    ///
    /// 一時的な失敗（`EBUSY` など、直前まで書いていた相手なら起こり得る）に
    /// 備えて一度だけ待って試し直し、それでも駄目なら**ログには必ず残す**
    /// [ER-04: 無言で握りつぶさない]。これで消えない場合があるかどうかは
    /// 実測できていないが、消え残ったことに気づく手段が無い状態は避ける。
    private static func removePartialWrite(at url: URL) {
        let fm = FileManager.default
        for attempt in 0..<2 {
            do {
                try fm.removeItem(at: url)
                return
            } catch {
                guard fm.fileExists(atPath: url.path) else { return } // 既に無い＝目的は達成
                if attempt == 0 { Thread.sleep(forTimeInterval: 0.05); continue }
                Log.fileOps.warning(
                    "中断後の書きかけを片付けられませんでした: \(Log.path(url)) — \(error.localizedDescription)"
                )
            }
        }
    }

    /// 書き込みが完了しなかったときに、退避しておいた元の項目を戻す。
    private nonisolated static func restoreReplacedItem(_ resolved: ResolvedDestination) {
        guard let backup = resolved.backupOfReplaced else { return }
        try? FileManager.default.removeItem(at: resolved.target) // 中途半端な書き込み結果があれば破棄
        try? FileManager.default.moveItem(at: backup, to: resolved.target)
    }

    /// 置き換えられた元の項目をゴミ箱へ送る。送れなければ最後の手段として削除する
    /// （退避ファイルを残し続けると、次の同名操作で邪魔になる）。
    private nonisolated static func moveReplacedItemToTrash(_ backup: URL) {
        // **テスト中は実ゴミ箱に触れない** — 開発機のゴミ箱がテストの残骸で
        // 埋まる（`DiagnosticLog` がログの出力先を振り替えるのと同じ理由）。
        guard !RuntimeEnvironment.isRunningTests else {
            try? FileManager.default.removeItem(at: backup)
            return
        }
        var resulting: NSURL?
        if (try? FileManager.default.trashItem(at: backup, resultingItemURL: &resulting)) != nil { return }
        Log.fileOps.warning("置き換えた項目をゴミ箱へ送れませんでした: \(Log.path(backup))")
        try? FileManager.default.removeItem(at: backup)
    }

    /// Finder に倣い `name 2.ext` `name 3.ext` の形式で連番を付与する [CF-01]。
    /// 衝突先の名前に既に連番サフィックス（例: `name 2`）が付いている場合はそれを
    /// 剥がしてから採番する。剥がさないと `name 2` との衝突のたびに末尾へさらに
    /// ` 2` が積み重なり `name 2 2` のようになってしまう。
    private nonisolated static func nextAvailableName(for url: URL) -> URL {
        let ext = url.pathExtension
        let rawBase = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        let base = Self.strippingTrailingCopyNumber(from: rawBase)
        let directory = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
    }

    private static func strippingTrailingCopyNumber(from name: String) -> String {
        guard let range = name.range(of: #" \d+$"#, options: .regularExpression) else { return name }
        return String(name[..<range.lowerBound])
    }

    private nonisolated static func identity(of url: URL) throws -> FileIdentity {
        try FileMetadata.identity(of: url)
    }
}
