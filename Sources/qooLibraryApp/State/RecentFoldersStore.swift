import Foundation
import Observation

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

    /// 実体が存在するものだけを、新しい順に返す。
    ///
    /// 存在確認をここ（読み出し時）で行うのは、`record(_:)` の時点では存在して
    /// いたフォルダが後から消える（ゴミ箱・外部ボリュームのイジェクト・アプリ外
    /// での削除）ためで、`FolderTreePane` が登録フォルダの解決失敗を表示時に
    /// 判定しているのと同じ考え方。
    public var existingFolders: [URL] {
        let fileManager = FileManager.default
        return paths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// 履歴に積む。既にあれば先頭へ繰り上げる（重複させない）。
    public func record(_ url: URL) {
        let path = url.standardizedFileURL.path
        // 起動直後の既定表示（仮想ホーム）まで履歴に載ると、ユーザーが自分で
        // 開いたわけではないものが常に一覧の先頭を占めてしまうため除外する。
        guard path != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path else { return }
        var updated = paths
        updated.removeAll { $0 == path }
        updated.insert(path, at: 0)
        if updated.count > Self.limit {
            updated.removeSubrange(Self.limit...)
        }
        paths = updated
        defaults.set(updated, forKey: Self.storageKey)
    }

    /// Finder の「メニューを消去」相当。
    public func clear() {
        paths = []
        defaults.removeObject(forKey: Self.storageKey)
    }
}
