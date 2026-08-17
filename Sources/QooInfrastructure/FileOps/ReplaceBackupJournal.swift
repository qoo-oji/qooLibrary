import Foundation

/// **「置き換える」の途中で落ちても、ユーザーのファイルを見失わない** [NV-92]。
///
/// ## 何が起きるか
/// `.replace`（[FM-13]「置き換える」）は、健康なファイルを書き潰さないために
/// **既存の項目を同じフォルダへ退避してから書く**。書き終えたら退避をゴミ箱へ
/// 送り、失敗したら元へ戻す。
///
/// その 2 つの間に落ちると、**ユーザーの元ファイルは
/// `.qoo-replace-backup-<UUID>` という名前のまま残る**。先頭がドットなので
/// Finder にも本アプリにも見えない。ユーザーから見れば**ファイルが消えた**。
///
/// ローカルではこの窓は短く、稀な事象として許容していた。**ネットワークでは
/// 事情が変わる**（8章 §8.11）:
///
/// - 切断が例外ではなく通常状態なので、窓に入る確率が上がる
/// - しかも切断中は「元へ戻す」`moveItem` 自体も失敗する
/// - 4GB を SMB へ `.replace` で書くなら、窓は**分単位**で開いたままになる
///
/// ## なぜ走査ではなく記録なのか
/// 退避はユーザーが選んだ書き込み先に作られるので、起動時に探そうとすると
/// **登録フォルダ全体を再帰的に走査する**ことになる。それはネットワークで
/// いちばんやってはいけない I/O 増幅そのもので、しかも普段は 1 件も
/// 見つからない。
///
/// **作る前に「これから作る」と書き、片付けたら消す。** 起動時はその記録
/// だけを読めばよく、走査は 1 回も要らない（記録が空＝通常時は、ファイルを
/// 1 つ読むだけで終わる）。`SecureExtractor.cleanupResidualStaging()` と
/// 同じ「異常終了しても次回起動で必ず片付く」考え方を、位置が固定できない
/// 相手に対して成り立たせるための最小限の仕掛け。
///
/// ## 同期 API である理由
/// 呼ぶのは `FileIO.perform` の中を走るブロッキング側（`actor` ではない）
/// なので `await` できない。`.replace` のときだけ、1 回の小さな書き込みが
/// 増えるだけである。
public final class ReplaceBackupJournal: @unchecked Sendable {
    public static let shared = ReplaceBackupJournal()

    /// 記録 1 件。**退避先と、戻すべき場所の両方**を持つ。片方だけでは
    /// 復旧できない（退避先の名前は UUID で、元の名前を含まないため）。
    public struct Entry: Codable, Hashable, Sendable {
        let backupPath: String
        let targetPath: String
    }

    private let lock = NSLock()
    private let storageURL: URL

    /// - Parameter storageURL: 記録の置き場所。既定はアプリコンテナ配下
    ///   （**共有の上には置かない** [NV-86]。切断中でも読み書きできる必要が
    ///   あり、そもそも記録は「共有が使えないときのため」のものなので、
    ///   同じ共有に置いては意味を成さない）。
    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
    }

    public static func defaultStorageURL() -> URL {
        // **テスト中は本物の記録に触れない** [`DiagnosticLog` と同じ理由]。
        // ここが共有されていると、テストが開発機に実在する退避の記録を
        // 読み、**ユーザーの本物のファイルを動かしてしまう**。
        let base: URL
        if RuntimeEnvironment.isRunningTests {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("qooLibraryTests", isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        return base
            .appendingPathComponent("qooLibrary", isDirectory: true)
            .appendingPathComponent("replace-backups.json")
    }

    // MARK: - 記録

    /// **退避を作る直前に呼ぶ。** 記録が先でなければ意味が無い
    /// （作った後に落ちたら記録が無く、見失う）。
    public func record(backup: URL, target: URL) {
        let entry = Entry(backupPath: backup.path, targetPath: target.path)
        mutate { entries in
            entries.removeAll { $0.backupPath == entry.backupPath }
            entries.append(entry)
        }
    }

    /// 退避を片付け終えたら呼ぶ（ゴミ箱へ送った／元へ戻した／消した）。
    public func forget(backup: URL) {
        mutate { entries in entries.removeAll { $0.backupPath == backup.path } }
    }

    /// いま記録されている退避の件数。**検証のためだけにある** — 「退避を作る
    /// 前に記録している」という順序は、コピーの最中に覗く以外に確かめようが
    /// ないため（`ReplaceBackupJournalTests` 参照）。
    public func pendingBackupCount() -> Int { load().count }

    // MARK: - 起動時の復旧

    /// 何が起きたか。ユーザーへ何を伝えるかがケースごとに違う。
    public enum Outcome: Equatable, Sendable {
        /// 退避が既に無い＝正常に片付いていた。記録だけが残っていた。
        case alreadyClean
        /// 元の場所へ戻した。**ユーザーから見れば「消えていたファイルが戻った」。**
        case restored(target: URL)
        /// 戻せなかった。退避はその名前のまま残っている。
        case orphaned(backup: URL, target: URL, reason: String)
    }

    /// 起動時に一度だけ呼ぶ [RB-07 と同じ位置づけ]。
    ///
    /// **元の場所に何も無いときだけ戻す。** 既に何かあるなら、それは
    /// 「書き込みが実は成功していた（新しい内容）」か「ユーザーが後から
    /// 別のものを置いた」かのどちらかで、**どちらの場合も上書きしては
    /// ならない**。その場合は退避を残したまま `orphaned` として報告し、
    /// 判断をユーザーに委ねる。
    public func recoverAll() -> [Outcome] {
        let entries = load()
        guard !entries.isEmpty else { return [] }
        var outcomes: [Outcome] = []
        var survivors: [Entry] = []
        let fm = FileManager.default

        for entry in entries {
            let backup = URL(fileURLWithPath: entry.backupPath)
            let target = URL(fileURLWithPath: entry.targetPath)
            // リンク切れも「ある」と数えたいので `attributesOfItem` を使う
            // （`fileExists` はリンクを辿る。完全削除で踏んだのと同じ罠）。
            guard (try? fm.attributesOfItem(atPath: backup.path)) != nil else {
                outcomes.append(.alreadyClean)
                continue
            }
            if (try? fm.attributesOfItem(atPath: target.path)) != nil {
                let reason = "元の場所にすでに別の項目があります"
                Log.fileOps.warning(
                    "退避したまま残っています: \(Log.path(backup)) → \(Log.path(target))（\(reason)）"
                )
                outcomes.append(.orphaned(backup: backup, target: target, reason: reason))
                survivors.append(entry)
                continue
            }
            do {
                try fm.moveItem(at: backup, to: target)
                Log.fileOps.info("置き換えの退避を元へ戻しました: \(Log.path(target))")
                outcomes.append(.restored(target: target))
            } catch {
                Log.fileOps.error(
                    "置き換えの退避を戻せませんでした: \(Log.path(backup)) → \(Log.path(target))"
                        + " — \(error.localizedDescription)"
                )
                outcomes.append(.orphaned(
                    backup: backup, target: target, reason: error.localizedDescription
                ))
                survivors.append(entry)
            }
        }
        // 戻せなかったものは記録に残す。次回起動でもう一度試せる
        // （相手がネットワークなら、次は繋がっているかもしれない）。
        //
        // **丸ごと差し替えてはならない**［フェーズ1完了時の監査で発見]。
        // 復旧は退避の移動（ネットワークなら遅い）を挟むので、その間に
        // 新しい `.replace` が `record()` した記録を、処理済みの一覧で
        // 上書きすると消してしまう——そのままプロセスが落ちれば、
        // まさに NV-92 が防ごうとした「記録の無い退避」になる。
        // **自分が処理した記録だけ**を取り除き、生き残りと新規は残す。
        let survivorSet = Set(survivors)
        mutate { current in
            current.removeAll { entries.contains($0) && !survivorSet.contains($0) }
        }
        return outcomes
    }

    // MARK: - 永続化
    //
    // 壊れていたら空として扱い、**元ファイルは退避して残す**
    // （`RegisteredFolderStore`/`VolumeAccessStore` と同じ扱い。中身は
    // ユーザーのファイルの居場所そのものなので、黙って捨てない）。

    private func load() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> [Entry] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            let backup = storageURL.deletingLastPathComponent()
                .appendingPathComponent("\(storageURL.lastPathComponent).corrupt-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: storageURL, to: backup)
            Log.fileOps.error("置き換え退避の記録が壊れていたため退避しました: \(Log.path(backup))")
            return []
        }
        return entries
    }

    private func mutate(_ change: (inout [Entry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        change(&entries)
        saveLocked(entries)
    }

    private func saveLocked(_ entries: [Entry]) {
        do {
            if entries.isEmpty {
                // 通常時はファイル自体を残さない — 起動時の読み込みが
                // 「無い」で即座に終わる。
                try? FileManager.default.removeItem(at: storageURL)
                return
            }
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(entries).write(to: storageURL, options: .atomic)
        } catch {
            // ここが失敗しても操作自体は続ける。**記録できないことを理由に
            // ユーザーの操作を止めない**——記録は保険であって目的ではない。
            Log.fileOps.error("置き換え退避の記録に失敗しました: \(error.localizedDescription)")
        }
    }
}
