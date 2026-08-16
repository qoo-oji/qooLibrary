import Foundation
import QooKit

/// Security-Scoped Bookmark の生成・解決を集約する [SB-02]。
/// ブックマーク解決は必ずこの型を通す。解決失敗時は例外を投げず `.offline`
/// を返す（フォルダツリーの表示を壊さないため）[SB-05]。
public protocol BookmarkResolving: Sendable {
    /// 登録時にブックマークを生成する。FS-02/FS-03 の検証を通過していることが前提。
    func makeBookmark(for url: URL) throws -> Data // [RG-07]

    /// 起動時・マウント時に解決する。失敗は throw せず `.offline` を返す。 [SB-05]
    ///
    /// **既定ではマウントを起こさない** [RG3-01][NV-91]。解決には
    /// **未マウントのボリュームを実際にマウントする副作用がある**（8章 §8.7.1 BM-5
    /// で実測）。ネットワークボリュームではこれが ①接続タイムアウト分のブロック
    /// （NFS の hard マウントなら無限）②**ユーザーが何も操作していないのに出る
    /// 認証ダイアログ** を意味する。起動時に全登録を解決する経路
    /// （`RegisteredFolderStore.loadAndActivateAll()` など）がこれを踏むと、
    /// **サーバ不在のときアプリが起動時に固まる。**
    ///
    /// - Important: これは同期のブロッキング API である。`actor` や async
    ///   文脈から呼ぶときは、extension の ``resolve(_:waitingAtMost:)``
    ///   （`FileIO` 経由・上限時間付き）を使うこと [NV6-05]。
    func resolve(_ data: Data) -> BookmarkResolution

    /// マウントを許して解決する。**ユーザーの明示的な操作からのみ呼ぶこと** [RG3-01]。
    ///
    /// 「オフラインの登録フォルダを開こうとした」のように、待たされることを
    /// ユーザーが理解している場面だけで使う。バックグラウンドの整合性チェックや
    /// 起動処理から呼んではならない。
    func resolveAllowingMount(_ data: Data) -> BookmarkResolution

    /// 解決した URL に対する startAccessing/stopAccessing をスコープ管理する。
    func withAccess<T: Sendable>(_ data: Data, _ body: @Sendable (URL) async throws -> T) async throws -> T
}

public enum BookmarkResolution: Sendable, Equatable {
    case resolved(url: URL, isStale: Bool)
    case offline(reason: OfflineReason)
}

public enum OfflineReason: Sendable, Equatable {
    case volumeNotMounted
    /// マウントは残っているが、上限時間内に解決が完了しなかった（サーバ無応答等）
    /// [NV6-05]。走っている解決自体は止まらない [NV6-03] が、後から完了しても
    /// 結果は捨てられる（セキュリティスコープは開始されない）。
    case unresponsive
    case permissionDenied
    case invalidBookmark
}

public enum BookmarkAccessError: Error, Sendable, Equatable {
    case offline(OfflineReason)
    case accessDenied
}

/// [ER-03]［監査で発見］。環境設定「アクセス権」タブの追加・取り消しなど、
/// この型がそのままユーザーへ提示される経路があるため、「エラー0」形式へ
/// 落ちないよう説明を持たせる。
extension BookmarkAccessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .offline(reason):
            switch reason {
            case .volumeNotMounted:
                return "このフォルダがあるボリュームが接続されていません。"
                    + "接続してから、もう一度お試しください。"
            case .unresponsive:
                return "このフォルダがある場所が応答していません。"
                    + "サーバや接続の状態を確かめてから、もう一度お試しください。"
            case .permissionDenied:
                return "このフォルダへアクセスする許可がありません。"
                    + "環境設定の「アクセス権」で、この場所へのアクセスを許可してください。"
            case .invalidBookmark:
                return "保存されていたフォルダの参照が使えなくなっています。"
                    + "いったん登録を解除して、選び直してください。"
            }
        case .accessDenied:
            return "このフォルダへアクセスできませんでした。"
                + "環境設定の「アクセス権」で、この場所へのアクセスを許可してください。"
        }
    }
}

// MARK: - FileIO 経由・上限時間付きの解決 [NV6-05]

extension BookmarkResolving {
    /// ブックマークを **`FileIO` 経由・上限時間付き**で解決する [NV6-05]。
    ///
    /// `resolve(_:)` は同期のブロッキング処理で、`.withoutMounting` を付けても
    /// **マウント済みなのに応答しない**共有へは対象を確かめるために出て行く
    /// （8章 §8.7.1 BM-5 / §8.11.17）。`actor` の中から同期のまま呼ぶと
    /// 協調スレッドプールのスレッドを占有する [NV6-01] ため、ストアからの
    /// 解決は必ずこちらを通すこと。
    ///
    /// 上限を過ぎたら**「待つのをやめる」だけで、解決自体は止まらない**
    /// [NV6-03]。その場合は `.offline(reason: .unresponsive)` を返す——後から
    /// 解決が完了しても結果は捨てられる（セキュリティスコープは開始されない）
    /// ので、失われるのは塞がったスレッド 1 本だけで済む。
    public func resolve(_ data: Data, waitingAtMost limit: Duration) async -> BookmarkResolution {
        do {
            return try await FileIO.perform(waitingAtMost: limit) { self.resolve(data) }
        } catch {
            Log.sandbox.warning("ブックマークの解決が \(limit.inSeconds) 秒以内に完了しません。応答なしとして扱います")
            return .offline(reason: .unresponsive)
        }
    }

    /// 複数のブックマークを**並行に**解決する [NV6-05]。
    ///
    /// 起動時の一括解決・入れ子チェックのように全登録を解決する経路で、
    /// 待ち時間の合計を「件数 × 上限」ではなく「上限 1 回分」に抑える
    /// （逐次だと、サーバ不在時にネットワーク上の登録 3 件で 15 秒待つことに
    /// なる）。`FileIO` は投入ごとに専用のスレッドを貰える（overcommit な
    /// 直列キュー、`FileIOExecutor` 参照）ため、この並行化は協調プールの幅にも
    /// CPU の空きにも縛られない。
    public func resolveMany(
        _ items: [(id: UUID, data: Data)], waitingAtMost limit: Duration
    ) async -> [UUID: BookmarkResolution] {
        await withTaskGroup(of: (UUID, BookmarkResolution).self) { group in
            for item in items {
                group.addTask {
                    let resolution = await self.resolve(item.data, waitingAtMost: limit)
                    return (item.id, resolution)
                }
            }
            var results = [UUID: BookmarkResolution](minimumCapacity: items.count)
            for await (id, resolution) in group {
                results[id] = resolution
            }
            return results
        }
    }
}
