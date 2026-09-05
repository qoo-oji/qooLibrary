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
    public func totalByteCount() throws -> Int64 {
        try generations().reduce(0) { $0 + $1.byteCount }
    }
}
