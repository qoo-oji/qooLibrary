import AppKit
import Foundation
import QooKit

/// ボリュームの取り出し（イジェクト）[1-16、Finder の「取り出す」相当]。
///
/// **`FileOperationService` を経由しない** [設計判断、`VolumeEligibilityChecker`
/// と同じ理由付けの系統]。`FileOperationService` が存在するのは期待変更台帳と
/// Undo をファイル変更操作へ集約するためだが、イジェクトはファイルを 1 つも
/// 変更せず、取り消しの概念も持たない（取り出したものを「元に戻す」のは
/// 物理的な再接続であってアプリの操作ではない）。B-10 の静的検査は
/// `FileManager` の変更系 API のみを見るため、このファイルの位置に制約は
/// 無いが、ボリューム関連のインフラという括りで `FileOps/` に置いている。
///
/// **サンドボックス下でも追加の entitlement 無しに動作することを実測で確認済み**
/// （1-16 着手前の使い捨てプローブ: `app-sandbox` + 実アプリと同じ entitlement で
/// アドホック署名した最小アプリから、読み取り権限すら無いボリューム
/// —— `contentsOfDirectory` が `Operation not permitted` になる状態 —— を
/// 実際にアンマウントできた）。ファイルアクセス権とイジェクト権限は別の
/// レイヤで、アクセスを許可していないボリュームも取り出せる。
public enum VolumeEjector {
    private static let classificationKeys: Set<URLResourceKey> = [
        .volumeIsRootFileSystemKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
    ]

    /// このボリュームが取り出せるか。**読み取り権限が無くても判定できる**
    /// （上記プローブで確認済み）ため、アクセスを許可していないボリュームでも
    /// メニュー項目の出し分けに使える。
    ///
    /// **`volumeIsEjectable`/`volumeIsRemovable` だけで判定してはならない**
    /// [実測で判明、当初この 2 つで実装して外付け SSD が対象外になった]。
    /// 同一マシンでマウント中のボリュームを実測した結果:
    ///
    /// | ボリューム | root | internal | removable | ejectable |
    /// |---|---|---|---|---|
    /// | `/`（起動） | true | true | false | false |
    /// | 外付け USB SSD（T7 / PRO-G40） | false | **false** | **false** | **false** |
    /// | ディスクイメージ | false | **nil** | true | true |
    ///
    /// 外付け SSD は `removable`/`ejectable` がどちらも `false`（これらは
    /// 「メディアを抜き差しできる」= SD カード・光学ドライブの意味に近い）。
    /// 一方でディスクイメージは `internal` が `false` ではなく **`nil`**。
    /// そのため次の 3 段で判定する:
    ///
    /// 1. 起動ボリュームは絶対に除く。
    /// 2. `ejectable`/`removable` のどちらかが立っていれば取り出せる
    ///    （ディスクイメージ・SD カード・光学ドライブ。**内蔵扱いの SD カード
    ///    スロットもここで拾える**ため、内蔵かどうかより先に見る）。
    /// 3. 残りは「内蔵でなければ取り出せる」——外付け SSD・ネットワーク
    ///    ボリュームがここに該当する（`nil` は内蔵と見なさない）。
    public static func isEjectable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: classificationKeys) else { return false }
        if values.volumeIsRootFileSystem == true { return false }
        if values.volumeIsEjectable == true || values.volumeIsRemovable == true { return true }
        return values.volumeIsInternal != true
    }

    /// マウント中の取り出し可能なボリューム一覧（「すべてを取り出す」用）。
    public static func ejectableVolumes() -> [URL] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(classificationKeys),
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.filter(isEjectable)
    }

    /// 取り出す。使用中などで失敗した場合は `VolumeEjectionError` を投げる。
    ///
    /// **`NSWorkspace` はメインスレッドを要求しない**が、アンマウントは実際の
    /// I/O を伴い（キャッシュのフラッシュ等）数秒かかることがあるため、
    /// 呼び出し側が待てるよう `async` にしている。
    public static func eject(_ url: URL) async throws {
        let name = displayName(of: url)
        Log.fileOps.info("ボリュームを取り出します: \(Log.path(url))")
        do {
            try await Task.detached {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            }.value
        } catch {
            Log.fileOps.error("ボリュームの取り出しに失敗しました: \(Log.path(url)) — \(error.localizedDescription)")
            throw VolumeEjectionError(volumeName: name, underlying: error)
        }
        Log.fileOps.info("ボリュームを取り出しました: \(Log.path(url))")
    }

    private static func displayName(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? url.lastPathComponent
    }
}

/// 取り出しの失敗。
///
/// **`UserPresentableError` には準拠させない** [既存の慣行に合わせた設計判断]。
/// ユーザー向け文言のローカライズカタログ（`Resources/Localizable.xcstrings`）は
/// アプリターゲットのリソースで、`QooInfrastructure` からは参照できない。
/// 既存のエラー型（`FileOperationError`/`RegisteredFolderError` 等）と同じく、
/// ここでは素材（ボリューム名と実際の失敗理由）だけを持ち、ER-03 の三要素は
/// アプリ層が `NotificationRouter.presentError(_:whatHappened:)` を呼ぶときに
/// 組み立てる。
///
/// 失敗の理由はほぼ「そのボリューム上のファイルをどこかのアプリが開いている」
/// だが、macOS 自身も原因アプリまでは教えてくれないことが多い。断定せず、
/// 実際に返ってきた説明をそのまま見せる。
public struct VolumeEjectionError: Error {
    public let volumeName: String
    public let underlying: Error
}
