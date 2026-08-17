import Foundation
import Observation
import QooInfrastructure

/// 最近開いたフォルダ [1-16 移動メニュー、Finder の「最近使ったフォルダ」相当]。
///
/// **`UserDefaults` にパス文字列だけを保存し、Security-Scoped Bookmark は
/// 持たない** [設計判断]。この一覧は「以前ここへ行った」という履歴に過ぎず、
/// 実際にアクセスできるかどうかは既存の許可（環境設定「アクセス権」タブの
/// `VolumeAccessStore`、ライブラリ／テンポラリ登録の `RegisteredFolderStore`）が
/// 決める。ここでブックマークを持つと、同じフォルダに対して独立したアクセス
/// スコープが二重に開くことになり、`VolumeAccessStore` で実際に踏んだ
/// 「片方を取り消してももう片方の `stop` が対応づかない」リークと同種の問題を
/// 招く（フェーズ1完了前監査の記録参照）。
///
/// アクセスできなくなったフォルダを一覧に残し続けても意味が無いため、
/// 読み出し時に実体の存在を確認して落とす。
@MainActor
@Observable
public final class RecentFoldersStore {
    public static let shared = RecentFoldersStore()

    private static let storageKey = "qoo.recentFolders"
    /// Finder の「最近使ったフォルダ」も 10 件程度で頭打ちになる。
    private static let limit = 10

    /// 新しい順。`record(_:)`/`clear()` 以外からは変更しない。
    public private(set) var paths: [String]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.paths = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    /// メニューへ出す 1 件。表示名まで持つのは、`displayName(atPath:)` 自体が
    /// I/O だから——メニューを組み立てる側で呼ぶと、そこがまた止まる。
    public struct Entry: Identifiable, Hashable, Sendable {
        public let url: URL
        public let displayName: String
        public var id: URL { url }
    }

    /// 実体が存在するものだけを、新しい順に。**メニューはこれを同期的に読む。**
    ///
    /// 実体の確認（`fileExists`）は I/O なので、**読み出しのたびに行っては
    /// いけない** [NV6-02]。「移動」メニューの submenu を開くたびに、履歴に
    /// 入っている切断済みのネットワーク共有へ問い合わせることになり、
    /// メニューが開かないままアプリが固まる。`RegisteredFolderIndex` と同じく、
    /// **非同期に確かめた結果をここへ載せておく**。
    public private(set) var existingFolders: [Entry] = []

    /// 一覧を実体と突き合わせて更新する。起動時と、履歴が変わったときに呼ぶ。
    ///
    /// 存在確認を記録時ではなくここで行うのは、`record(_:)` の時点では存在して
    /// いたフォルダが後から消える（ゴミ箱・外部ボリュームのイジェクト・アプリ外
    /// での削除）ためで、`FolderTreePane` が登録フォルダの解決失敗を表示時に
    /// 判定しているのと同じ考え方。
    public func refresh() async {
        let snapshot = paths
        existingFolders = await FileIO.perform { Self.resolve(snapshot) }
    }

    /// **メインアクタの外で走る。** `FileIO.perform` の中からのみ呼ぶこと。
    private nonisolated static func resolve(_ paths: [String]) -> [Entry] {
        let fileManager = FileManager.default
        return paths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return nil }
            return Entry(
                url: URL(fileURLWithPath: path, isDirectory: true),
                displayName: fileManager.displayName(atPath: path)
            )
        }
    }

    /// 履歴に積む。既にあれば先頭へ繰り上げる（重複させない）。
    public func record(_ url: URL) {
        let path = url.standardizedFileURL.path
        // 起動直後の既定表示（ホーム）まで履歴に載ると、ユーザーが自分で開いた
        // わけではないものが常に一覧の先頭を占めてしまうため除外する。
        // **実ホームと仮想ホームの両方を除く** — 既定は実ホームだが、許可が
        // 無いときは仮想ホームへ落ちる（`StandardLocation.defaultHome`）ので、
        // どちらも「ユーザーが選んだわけではない行き先」になり得る。
        let homePaths = [
            StandardLocation.realHome.standardizedFileURL.path,
            StandardLocation.virtualHome.standardizedFileURL.path,
        ]
        guard !homePaths.contains(path) else { return }
        var updated = paths
        updated.removeAll { $0 == path }
        updated.insert(path, at: 0)
        if updated.count > Self.limit {
            updated.removeSubrange(Self.limit...)
        }
        paths = updated
        defaults.set(updated, forKey: Self.storageKey)
        Task { await refresh() }
    }

    /// Finder の「メニューを消去」相当。
    public func clear() {
        paths = []
        existingFolders = []
        defaults.removeObject(forKey: Self.storageKey)
    }
}
