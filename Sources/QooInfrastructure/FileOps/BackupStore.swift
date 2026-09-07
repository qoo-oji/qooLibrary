//
//  自動バックアップの置き場所と世代管理 [BK-01][BK2-03][07章 §7.1]。
//
//  **`FileOperationService` を経由しない**——ここはユーザー非可視のアプリ内部
//  領域で、期待変更台帳 [FO-12] と Undo の対象外。`CoverImageCache` /
//  `UserCoverStore` / `RegisteredFolderStore` と同じ設計判断で、そのため静的
//  検査 [B-10] の許可ディレクトリである `FileOps/` 配下に置いてある。
//
//  **[BK-04]（利用者が選んだフォルダへの書き出し）はここに足さないこと。**
//  行き先はユーザーに見える場所なので、そちらは `FileOperationService.copy`
//  を通す——この型の免除はあくまで「アプリ内部の領域だから」であって、
//  バックアップだからではない。
//
import Foundation
import QooKit

/// 世代の置き場所。**状態を持たない。**
///
/// 他のストア（`RegisteredFolderStore` 等）が `actor` なのは読み込み済みの
/// 一覧を抱えるためで、こちらは毎回ディレクトリを列挙する。**同期のまま
/// 呼べることが要る**——[MG-10] の移行前スナップショットは
/// `QooDatabase.open` の中の**同期**フックから呼ばれる。
public struct BackupStore: Sendable {
    public let directory: URL

    /// テストでは独立した一時ディレクトリを渡せる。
    ///
    /// **`swift test` 中は既定の場所も一時ディレクトリへ振り替える**
    /// [`UserCoverStore` / `DiagnosticLog` と同じ防御]。ここは剪定が
    /// **ファイルを消す**領域なので、注入を忘れた 1 箇所が開発機の実際の
    /// バックアップを削りにいく——注入に頼らず既定そのものを安全側にする。
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if RuntimeEnvironment.isRunningTests {
            self.directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qooLibrary-tests/backups", isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = appSupport
                .appendingPathComponent("qooLibrary/backups", isDirectory: true)
        }
    }

    // MARK: - 読む

    /// 置いてある世代を**新しい順**に返す。
    ///
    /// 解釈できない名前は落とす——利用者が同じフォルダへ置いた無関係な
    /// ファイルを世代として数えると、**剪定がそれを消しにかかる**。
    public func generations() throws -> [BackupGeneration] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let names = try fm.contentsOfDirectory(atPath: directory.path)
        var result: [BackupGeneration] = []
        for name in names {
            guard let parts = BackupFileName.parse(name) else { continue }
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value
            result.append(BackupGeneration(
                fileName: name, date: parts.date, reason: parts.reason,
                kind: parts.kind, byteCount: size ?? 0, url: url))
        }
        // 同じミリ秒に 2 件あっても順序が定まるよう、名前で決着させる。
        return result.sorted {
            $0.date == $1.date ? $0.fileName > $1.fileName : $0.date > $1.date
        }
    }

    /// 直近の 1 件。`reason` を渡すとその理由のものだけを見る
    /// （起動時スナップショットの間隔判定 [BK-01] に使う）。
    public func latest(kind: BackupGeneration.Kind,
                       reason: BackupReason? = nil) throws -> BackupGeneration?
    {
        try generations().first {
            $0.kind == kind && (reason == nil || $0.reason == reason)
        }
    }

    // MARK: - 書く

    /// JSON スナップショットを書く [BK-01][BK-05]。
    public func writeDocument(_ data: Data, reason: BackupReason, date: Date = Date()) throws -> URL {
        let url = try prepare(reason: reason, kind: .document, date: date)
        // **`.atomic`**——書いている途中で落ちると、半分だけの JSON が
        // 「1 世代」として残り、いざ復元しようとして初めて分かる。
        try data.write(to: url, options: .atomic)
        return url
    }

    /// DB の外にあるデータの束を書く [BK-06]。
    public func writeAppData(_ archive: AppDataArchive, reason: BackupReason,
                             date: Date = Date()) throws -> URL
    {
        let url = try prepare(reason: reason, kind: .appData, date: date)
        try BackupCoding.encode(archive).write(to: url, options: .atomic)
        return url
    }

    public func readAppData(at url: URL) throws -> AppDataArchive {
        try BackupCoding.decodeAppData(Data(contentsOf: url))
    }

    /// カバーの複製を溜める共有プール [BK-06]。
    ///
    /// **世代ごとに写さない**——複製は保存のたびに UUID を振るので中身が
    /// 変わらず、ハードリンクで全世代から共有できる［実測: 実占有は 1 つ分］。
    /// 素朴に世代へ写すと、カバーを多く差し替えた利用者で容量が世代数倍に
    /// 膨らむ［ユーザー要望: 意図しないところで肥大化させない］。
    public var userCoverPool: URL {
        directory.appendingPathComponent(AppDataBundle.userCoverPool, isDirectory: true)
    }

    /// どの世代からも参照されなくなった複製を捨てる [BK-06]。
    ///
    /// **剪定の後に呼ぶ**——先に呼ぶと、これから消える世代の参照を数えて
    /// しまい、消せるものが残る。
    @discardableResult
    public func pruneUserCoverPool() throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: userCoverPool.path) else { return 0 }

        // 生きている参照を集める。
        //
        // **読めない束が 1 つでもあれば掃除しない**［code-review で発見］
        // ——「参照ゼロ」とみなすと、一過性の読み取り失敗で*再生成できない*
        // カバー [CV-08] を恒久的に失う。同じ変更の `AppDataSnapshot.restore`
        // が「消すと取り返しがつかない」として追加だけに留めているのと
        // 方針を揃える。容量を食い続けるほうが、取り返しのつかない削除より軽い。
        var referenced: [String: Set<String>] = [:]
        for generation in try generations() where generation.kind == .appData {
            guard let archive = try? readAppData(at: generation.url) else {
                Log.db.warning(
                    "束を読めないので共有プールの掃除を見送る: \(Log.path(generation.url))")
                return 0
            }
            for (uuid, refs) in archive.manifest.userCovers {
                referenced[uuid, default: []].formUnion(refs)
            }
        }

        var removed = 0
        let libraries = (try? fm.contentsOfDirectory(at: userCoverPool,
                                                     includingPropertiesForKeys: nil)) ?? []
        for library in libraries {
            let live = referenced[library.lastPathComponent] ?? []
            let refs = (try? fm.contentsOfDirectory(at: library,
                                                    includingPropertiesForKeys: nil)) ?? []
            for ref in refs where !live.contains(ref.lastPathComponent) {
                // 1 件の失敗で残りを諦めない（`prune` と同じ理由）。
                do { try fm.removeItem(at: ref); removed += 1 }
                catch {
                    Log.db.warning(
                        "共有プールの複製を消せない: \(Log.path(ref)) — \(error.localizedDescription)")
                }
            }
            // 空になったライブラリのディレクトリも畳む。残すと、次の走査で
            // 毎回開いて数えるだけの殻が積み上がる。
            if let rest = try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil),
               rest.isEmpty {
                try? fm.removeItem(at: library)
            }
        }
        return removed
    }

    /// ストア複製の宛先を用意して返す [BK-03]。
    ///
    /// **書くのは呼び出し側**（`QooDatabase.backup(to:)`）——SQLite の
    /// オンラインバックアップは接続レベルの API なので、この層からは触れない
    /// [A-01]。ここは置き場所だけを決める。
    public func prepareStoreDestination(reason: BackupReason, date: Date = Date()) throws -> URL {
        try prepare(reason: reason, kind: .store, date: date)
    }

    private func prepare(reason: BackupReason, kind: BackupGeneration.Kind,
                         date: Date) throws -> URL
    {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(
            BackupFileName.make(date: date, reason: reason, kind: kind), isDirectory: false)
    }

    // MARK: - 剪定 [BK2-03]

    /// 新しいほうから `keep` 件を残し、残りを消す。消したものを返す。
    ///
    /// **スナップショットを取った「後」に呼ぶ**——先に消すと、作成に失敗した
    /// ときに世代数が `keep` を下回る。
    ///
    /// なお「良いバックアップを壊れた状態で上書きする」［外部調査］への答えは
    /// この順序ではなく、**世代を毎回新しい名前で書くこと**（`BackupFileName`）
    /// と**整合性検査を通ってから書くこと**（`BackupService`）のほうにある。
    /// - Parameter matching: 数える対象を絞る。**別枠で守りたい契機**
    ///   （移行前 [MG-10]）を、日常的な契機と同じ枠で数えないために要る。
    @discardableResult
    public func prune(kind: BackupGeneration.Kind, keep: Int,
                      matching: (BackupReason) -> Bool = { _ in true }) throws -> [BackupGeneration]
    {
        let keep = max(AppLimits.Backup.minGenerations, keep)
        let all = try generations().filter { $0.kind == kind && matching($0.reason) }
        guard all.count > keep else { return [] }
        let doomed = Array(all.dropFirst(keep))
        var removed: [BackupGeneration] = []
        for generation in doomed {
            // 1 件の失敗で残りを諦めない——読めないファイルが 1 つ紛れ込む
            // だけで、以後まったく剪定されなくなる。
            do {
                try removeFiles(of: generation)
                removed.append(generation)
            } catch {
                Log.db.warning(
                    "バックアップの世代を消せない: \(Log.path(generation.url)) — \(error.localizedDescription)")
            }
        }
        return removed
    }

    /// 書きかけの複製を捨てる [BK3-09]。
    ///
    /// **`QooPersistence` が自分で消せないので、ここが引き取る**——あの層は
    /// 削除系の `FileManager` API を呼べない（[B-10]。層の依存方向 [A-01] に
    /// より `FileOps` を呼べない）。失敗を握りつぶすのは、後始末の失敗で
    /// 元の失敗を隠さないため。
    public func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// 世代の隣に残った `-wal` / `-shm` を捨てる。
    ///
    /// **`QooPersistence` が自分で消せないので、ここが引き取る**（`discard`
    /// と同じ理由——あの層は削除系の `FileManager` API を呼べない [B-10]）。
    ///
    /// ジャーナルを畳んだ直後に呼ぶ [QooDatabase.normalizeJournal]。畳む
    /// ために一度 WAL のまま開くので、**その最中に `-shm` が作られ、閉じても
    /// 残る**［実測、2026-09-06］。畳んだ後の `-shm` は意味を持たないが、
    /// `generations()` は解釈しないので**見えないまま容量を食い、剪定にも
    /// かからない**。
    public func discardSidecars(of url: URL) {
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    public func remove(_ generation: BackupGeneration) throws {
        try removeFiles(of: generation)
    }

    /// 本体と、SQLite が作りうる付随ファイルをまとめて消す。
    ///
    /// **複製先は WAL にしていない**（`QooDatabase.backupTargetConfiguration`）
    /// ので、いまは付随ファイルはできない。ここで一緒に消すのは、**それ以前に
    /// 作られた世代**を取り残さないため——`generations()` は `-wal` を
    /// 解釈しないので、残ると誰にも見えないまま容量を食い続ける。
    private func removeFiles(of generation: BackupGeneration) throws {
        try FileManager.default.removeItem(at: generation.url)
        for suffix in ["-wal", "-shm"] {
            let sidecar = generation.url.deletingLastPathComponent()
                .appendingPathComponent(generation.fileName + suffix, isDirectory: false)
            try? FileManager.default.removeItem(at: sidecar)
        }
    }

    /// 置いてある全世代の合計サイズ。環境設定の表示に使う。
    /// 世代と共有プールが**実際に使っている**容量 [BK-06]。
    ///
    /// **プールのうち、まだ `usercovers/` からも参照されているものは数えない**
    /// ——ハードリンクなので、その間バックアップが追加で使っている容量は
    /// ゼロである［実測: `du` は 1 つ分］。数えると「使っていない容量」を見せて、
    /// 利用者が要らぬ判断（世代数を減らす）をすることになる。
    ///
    /// 実際に容量を食うのは「利用者が差し替えて `usercovers/` からは消えたが、
    /// まだどれかの世代が参照しているもの」だけで、それはリンクが 1 本になる。
    public func totalByteCount() throws -> Int64 {
        try generations().reduce(0) { $0 + $1.byteCount } + exclusivePoolByteCount()
    }

    /// 共有プールのうち、リンクが 1 本だけ（＝実占有）のものの合計。
    func exclusivePoolByteCount() -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: userCoverPool,
                                         includingPropertiesForKeys: [.fileSizeKey,
                                                                      .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular else { continue }
            let links = (attributes[.referenceCount] as? Int) ?? 1
            guard links <= 1 else { continue }   // 元からも参照されている
            total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    // MARK: - 復元の予約 [BK-03][IE-16]

    private var pendingRestoreURL: URL {
        directory.appendingPathComponent(PendingRestore.fileName, isDirectory: false)
    }

    /// 「次の起動で復元する」印を置く。
    public func writePendingRestore(_ pending: PendingRestore) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // **`.atomic`**——書いている途中で落ちて半分だけの印が残ると、
        // 次の起動が「解釈できない印」で止まる（世代の JSON と同じ理由）。
        try encoder.encode(pending).write(to: pendingRestoreURL, options: .atomic)
    }

    /// 印を読む。**解釈できなければ `nil`**（壊れた印で起動を止めない）。
    public func readPendingRestore() -> PendingRestore? {
        guard let data = try? Data(contentsOf: pendingRestoreURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingRestore.self, from: data)
    }

    /// 印を消す。**成功しても失敗しても必ず呼ぶ**——残すと起動のたびに
    /// 同じ復元を試み、しかも失敗する理由（世代が無い・壊れている）は
    /// 起動を繰り返しても変わらない。
    public func clearPendingRestore() {
        try? FileManager.default.removeItem(at: pendingRestoreURL)
    }

    // MARK: - 差し替え [BK-03][IE-16]

    /// 現ストアを退避してから、世代を所定の場所へ写す。
    ///
    /// **`QooDatabase.open` の前にだけ呼ぶこと。** 誰もストアを掴んでいない
    /// この一瞬だけが、ファイルを直接動かしてよい唯一の機会である
    /// ［外部調査: 掴まれていると復元が失敗し、しかも「破損」と誤報告される］。
    ///
    /// 順序は **①退避（移動）→ ②複製（コピー）→ ③失敗したら①を巻き戻す**。
    /// 退避を*移動*にしてあるのは、
    /// - 壊れたストアでも接続を要さずに保管でき（オンラインバックアップは
    ///   開ける必要があるが、いま戻したいのはまさに開けないストアである）、
    /// - 71 MB を写し直さずに済み［Spikes T-03 実測］、
    /// - `-wal` を道連れにできる（置き去りにすると**別の DB の WAL が
    ///   新しいストアの隣に残る**——それは破損の作り込みそのもの）
    /// ため。
    ///
    /// **剪定はここでは行わない。** この最中に剪定が走ると、いま写している
    /// 元の世代を消しにかかりうる。次の通常のスナップショットに任せる。
    ///
    /// - Returns: 退避先（`beforeRestore` の世代）。
    /// - Parameter archivedTo: 退避先を**失敗した場合でも**呼び出し側へ返す。
    ///   戻り値だけだと、巻き戻しに失敗したとき（＝**ストアが 1 つも無い**
    ///   最悪の状態）に「退避なし」と報告してしまう——実際には退避した
    ///   ストアが `backups/` に居るので、そこから戻せることを言えなければ
    ///   ならない［code-review で発見］。
    @discardableResult
    public func swapInStore(from generation: URL, storeURL: URL,
                            date: Date = Date(),
                            archivedTo: inout URL?) throws -> URL?
    {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: storeURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        // ① 退避。**ストアがまだ無い初回起動でも復元できる**ので、
        //    存在しなければ退避せずに進む。
        var archived: URL?
        if fm.fileExists(atPath: storeURL.path) {
            let destination = try prepare(reason: .beforeRestore, kind: .store, date: date)
            try moveStore(from: storeURL, to: destination)
            archived = destination
            archivedTo = destination
        }

        // ② 複製。
        do {
            try copyStore(from: generation, to: storeURL)
        } catch {
            // ③ 巻き戻す。**ここで諦めるとストアが 1 つも無い状態で起動する**
            //    ——復元しようとしただけで蔵書の記録を失ったように見える。
            if let archived {
                removeStoreFiles(at: storeURL)
                do {
                    try moveStore(from: archived, to: storeURL)
                    archivedTo = nil   // 元へ戻したので退避は残っていない
                } catch {
                    // **巻き戻しにも失敗した。** ストアが 1 つも無い状態だが、
                    // 退避したものは `backups/` に居る——`archivedTo` はその
                    // ままにして、呼び出し側がそれを言えるようにする。
                    Log.db.error(
                        "復元の巻き戻しにも失敗した。退避先: \(Log.path(archived))")
                }
            }
            throw error
        }
        return archived
    }

    /// ストア本体と `-wal` / `-shm` をまとめて動かす。
    ///
    /// 通常の世代は WAL を持たない（`QooDatabase.backupTargetConfiguration` が
    /// `journal_mode = DELETE` にする [BK3-08]）が、**退避したライブストアは
    /// 持つ**。本体だけを動かすと WAL の末尾——直前のトランザクション——が
    /// 置き去りになる。
    private func moveStore(from source: URL, to destination: URL) throws {
        removeStoreFiles(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        // **`-wal` だけを連れて行く。** あれは本体へまだ書き戻されていない
        // トランザクションを持つので、置き去りにすると直前の変更が落ちる。
        let wal = URL(fileURLWithPath: source.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            try? FileManager.default.moveItem(
                at: wal, to: URL(fileURLWithPath: destination.path + "-wal"))
        }
        // **`-shm` は連れて行かない。** あれは WAL の索引を載せた共有メモリで、
        // 中身は `-wal` から再構築できる（SQLite の仕様）。連れて行っても
        // 使われず、しかも**誰も消さないまま世代の隣に残る**——`generations()`
        // は解釈しないので、見えないまま容量を食い、剪定にもかからない
        // ［実測、2026-09-06: ここを移していたせいで実際に残った］。
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: source.path + "-shm"))
    }

    private func copyStore(from source: URL, to destination: URL) throws {
        removeStoreFiles(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try? FileManager.default.copyItem(
                at: from, to: URL(fileURLWithPath: destination.path + suffix))
        }
    }

    /// 差し替え先に**古い `-wal` / `-shm` を残さない**。
    ///
    /// **これは守りであって、いま何かを防いでいる証拠は無い**［実測、
    /// 2026-09-06］——外しても復元は成功する。SQLite は WAL の magic・salt・
    /// チェックサムを DB と突き合わせ、**一致しない WAL は無視して捨てる**
    /// ので、取り残された sidecar が誤って再生されることはなかった
    /// （変異を当てて確認済み。作れる入力の範囲では等価）。
    ///
    /// それでも消しておくのは、①誰にも見えないまま容量を食い続けるのを
    /// 避けるため ②「本体だけ消して sidecar を残す」形をコードに残すと、
    /// 次に読む人が SQLite の検証に頼ってよいと読み替えかねないため。
    private func removeStoreFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
