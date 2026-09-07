//
//  アプリが持つ、DB の外にある再生成できないデータの控え [BK-06]。
//
//  置き場所と剪定は `BackupStore`、契機の配線は `BackupService`
//  （`QooApplication`）。ここは**集める／書き戻す**だけを持つ。
//
//  `FileManager` の変更系 API を使うため `FileOps/` 配下に置いている
//  [B-10。`BackupStore`/`CoverImageCache` と同じ設計判断: アプリ内部の
//  保管領域で、期待変更台帳・Undo の対象外]。
//
import Foundation
import QooKit

/// DB の外にあるデータを 1 つの束にまとめる [BK-06]。
///
/// ## なぜ要るのか
///
/// **`library.uuid` は登録フォルダ ID そのもの**なので、DB と
/// `registeredFolders.json` は**対でしか意味を持たない**。DB だけ戻しても
/// ブックマークが古ければライブラリは実体に到達できず、IE-16 の
/// 「1 操作で完全に戻せる」が成立しない——v2.17 まで、この前提のファイルが
/// バックアップの対象外だった。
public enum AppDataSnapshot {

    /// 写す対象の場所。
    ///
    /// **綴りは持ち主から受け取る**——ここで組み立て直すと、ストア側で
    /// ファイル名や置き場所を変えたときに黙ってずれる（そして気づくのは
    /// *復元してライブラリが消えて見えたとき*になる）。
    public struct Location: Sendable, Equatable {
        public var registeredFolders: URL
        public var volumeAccess: URL
        public var appAssociations: URL
        /// `usercovers/` の根。配下は `<libraryUUID>/<ref>`。
        public var userCovers: URL

        public init(registeredFolders: URL, volumeAccess: URL,
                    appAssociations: URL, userCovers: URL)
        {
            self.registeredFolders = registeredFolders
            self.volumeAccess = volumeAccess
            self.appAssociations = appAssociations
            self.userCovers = userCovers
        }

        /// 束の中の名前 → 実際の場所。**この対応が唯一の翻訳表**。
        var replacedFiles: [(name: String, url: URL)] {
            [(AppDataBundle.registeredFolders, registeredFolders),
             (AppDataBundle.volumeAccess, volumeAccess),
             (AppDataBundle.appAssociations, appAssociations)]
        }
    }

    public enum Failure: Error, Equatable {
        /// 束がアプリより新しい。**一部だけ復元しない** [IE-14 と同じ規則]。
        case tooNew(found: Int, supported: Int)
    }

    // MARK: - 集める

    /// 一式を集めて束にする [BK-06]。
    ///
    /// **カバーの複製は束に入れない**——`pool` へハードリンクし、束には参照の
    /// 一覧だけを持つ。素朴に中身を写すと、カバーを多く差し替えた利用者で
    /// **容量が世代数倍に膨らむ**［ユーザー要望: 意図しないところで肥大化させない］。
    /// 複製は保存のたびに UUID を振るので**中身が変わらない**から、リンクで
    /// 共有しても後から食い違わない。
    ///
    /// - Parameter pool: `backups/usercovers/`。無ければ作る。
    public static func capture(_ location: Location,
                               linkingCoversInto pool: URL) throws -> AppDataArchive
    {
        var files: [String: Data] = [:]
        var present: [String] = []
        var unreadable = 0
        for entry in location.replacedFiles {
            // **無いものは入れない。** 「その時点で存在しなかった」ことは
            // マニフェストの `files` に載らないことで表す——空の中身を入れると、
            // 復元で「空の登録一覧」を書き戻して全部消すことになる。
            //
            // **「無い」と「読めない」は分ける**［code-review で発見］。後者は
            // 束が静かに欠けたまま成功として書かれる状態で、カバーの
            // `userCoversSkipped` と同じく**数として残す**必要がある。
            guard FileManager.default.fileExists(atPath: entry.url.path) else { continue }
            guard let data = try? Data(contentsOf: entry.url) else {
                unreadable += 1
                Log.db.warning("控えに含められない（読めない）: \(Log.path(entry.url))")
                continue
            }
            files[entry.name] = data
            present.append(entry.name)
        }

        let (covers, skipped) = try linkCovers(from: location.userCovers, into: pool)
        let manifest = AppDataManifest(files: present.sorted(),
                                       userCovers: covers,
                                       userCoversSkipped: skipped,
                                       filesUnreadable: unreadable)
        return AppDataArchive(manifest: manifest, files: files)
    }

    /// `usercovers/<libraryUUID>/<ref>` を共有プールへリンクし、参照の一覧を返す。
    private static func linkCovers(from source: URL,
                                   into pool: URL) throws -> ([String: [String]], Int)
    {
        let fm = FileManager.default
        guard let libraries = try? fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return ([:], 0)   // まだ 1 件も差し替えていない
        }

        var covers: [String: [String]] = [:]
        var skipped = 0
        for library in libraries {
            // ライブラリ UUID のディレクトリだけを見る。利用者が置いた
            // 無関係なものを世代の一部として数えない。
            guard UUID(uuidString: library.lastPathComponent) != nil,
                  let refs = try? fm.contentsOfDirectory(at: library,
                                                         includingPropertiesForKeys: nil)
            else { continue }

            let poolDirectory = pool.appendingPathComponent(library.lastPathComponent,
                                                            isDirectory: true)
            var linked: [String] = []
            for ref in refs where !ref.lastPathComponent.hasPrefix(".") {
                let destination = poolDirectory.appendingPathComponent(
                    ref.lastPathComponent, isDirectory: false)
                if fm.fileExists(atPath: destination.path) {
                    // 別の世代が既にリンク済み。**中身は同じ**（複製は保存の
                    // たびに UUID を振るので、同じ名前なら同じ実体）。
                    linked.append(ref.lastPathComponent)
                    continue
                }
                do {
                    try fm.createDirectory(at: poolDirectory, withIntermediateDirectories: true)
                    try fm.linkItem(at: ref, to: destination)
                    linked.append(ref.lastPathComponent)
                } catch {
                    // **複製へ落とさない**——落とすと肥大化を招き、この設計が
                    // 避けようとしている当のことになる。含めずに数だけ残し、
                    // 「守れていない」ことが分かるようにする。
                    skipped += 1
                    Log.db.warning(
                        "カバーの複製をバックアップへリンクできない: \(Log.path(ref)) — \(error.localizedDescription)")
                }
            }
            if !linked.isEmpty { covers[library.lastPathComponent] = linked.sorted() }
        }
        return (covers, skipped)
    }

    // MARK: - 書き戻す

    /// 束を書き戻す [BK-06]。
    ///
    /// **JSON は置き換え、カバーは追加する。** 前者は DB と整合していなければ
    /// 意味を持たない（古いブックマークと新しい DB が混ざると、行はあるのに
    /// 到達できないライブラリができる）。後者は参照されない複製が残っても
    /// 害が無く——起動時の掃除が片付ける——消すと取り返しがつかない [CV-08]。
    ///
    /// **束に入っていないファイルには触らない。** 復元は「戻す」操作であって
    /// 「消す」操作ではない。取った時点に無かったものが残っていても、余分な
    /// 許可が 1 つ残るだけで済む。
    public static func restore(_ archive: AppDataArchive, to location: Location,
                               restoringCoversFrom pool: URL) throws
    {
        guard archive.manifest.version <= AppDataManifest.currentVersion else {
            throw Failure.tooNew(found: archive.manifest.version,
                                 supported: AppDataManifest.currentVersion)
        }

        let fm = FileManager.default
        for entry in location.replacedFiles {
            guard let data = archive.files[entry.name] else { continue }
            try fm.createDirectory(at: entry.url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // **`.atomic`**——書いている途中で落ちると、半分だけの JSON が
            // 残り、次の起動で「壊れている」として退避されて空で続行する。
            try data.write(to: entry.url, options: .atomic)
        }

        for (uuidString, refs) in archive.manifest.userCovers {
            let poolDirectory = pool.appendingPathComponent(uuidString, isDirectory: true)
            let destinationDirectory = location.userCovers
                .appendingPathComponent(uuidString, isDirectory: true)
            for ref in refs {
                let source = poolDirectory.appendingPathComponent(ref, isDirectory: false)
                let destination = destinationDirectory.appendingPathComponent(ref,
                                                                             isDirectory: false)
                guard fm.fileExists(atPath: source.path),
                      !fm.fileExists(atPath: destination.path) else { continue }
                do {
                    try fm.createDirectory(at: destinationDirectory,
                                           withIntermediateDirectories: true)
                    try fm.linkItem(at: source, to: destination)
                } catch {
                    Log.db.warning(
                        "カバーの複製を戻せない: \(Log.path(destination)) — \(error.localizedDescription)")
                }
            }
        }
    }
}
