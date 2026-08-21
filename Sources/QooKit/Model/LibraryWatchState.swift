//
//  監視と差分スキャンに要るライブラリの状態 [SY-01〜SY-05][VD-01〜VD-06]。
//
//  `LibrarySummary` はフォルダツリーやメニューが読む「見せるための要約」で、
//  こちらは**調整役（`LibrarySyncCoordinator`）だけが読む内部の状態**。
//  分けてあるのは、`LibrarySummary` にイベント ID のような実装の都合を
//  足すと、それを見せる必要のない層まで再描画の対象になるため。
//
import Foundation

/// 差分スキャンの起点 [SY-02][SY-03][WA-10]。
///
/// ## なぜ ID だけでは足りないのか [実測、10章 §10.1.0]
/// FSEvents の履歴はボリューム単位の DB に載っており、消去・purge・カウンタの
/// 巻き戻りで別物に差し替わる。SDK の `FSEvents.h` は
///
/// > 保存したイベント ID は `FSEventsCopyUUIDForDevice()` の UUID とセットで
/// > 保存し、UUID が一致するときだけ渡してよい。**NULL が返る場合は
/// > `kFSEventStreamEventIdSinceNow` 以外を渡してはならない。**
///
/// と定めている。実測すると、**NULL のボリューム（SMB）へ起点を渡した場合、
/// 履歴が 1 件も再生されないのにエラーもフラグも出ない**——`HistoryDone` すら
/// 正常に届く。取りこぼしを検出する手段が UUID の照合しかない。
public struct FSEventsCheckpoint: Sendable, Equatable {
    /// 最後に処理したイベント ID [SY-02]。`0` は「まだ無い」。
    public var eventID: UInt64
    /// そのイベント ID が属する FSEvents データベースの識別子。
    /// `nil` は「引けなかった＝履歴が使えない」。
    public var deviceUUID: String?

    public init(eventID: UInt64, deviceUUID: String?) {
        self.eventID = eventID
        self.deviceUUID = deviceUUID
    }

    /// 起点として使えない（＝履歴を要求してはいけない）ことを表す値。
    public static let unusable = FSEventsCheckpoint(eventID: 0, deviceUUID: nil)

    /// FSEvents が「今から」を表すのに使う番兵（`kFSEventStreamEventIdSinceNow`
    /// ＝ `UInt64.max`）。**実在のイベント ID ではない。**
    ///
    /// ストリームが 1 件もイベントを処理していないと
    /// `FSEventStreamGetLatestEventId` はこの値を返す。**それを起点として
    /// 保存すると、次回「使える起点」と判定されたうえで「今から」を意味する
    /// 値が渡り、非起動中の変更が黙って落ちる**——実機検証で実際に
    /// `lastFSEventID = -1`（`Int64` で見た `UInt64.max`）が保存された。
    public static let sinceNowSentinel = UInt64.max

    /// いま引いたデバイス UUID に照らして、この起点で履歴を要求してよいか
    /// [SY-04][WA-11][WA-12]。
    ///
    /// - Parameter currentDeviceUUID: `FSEventsHistory.deviceUUID(for:)` の結果。
    ///   `nil`（＝履歴なし）なら常に `false`。
    public func isUsable(currentDeviceUUID: String?) -> Bool {
        guard eventID != 0 else { return false }          // まだ一度も保存していない
        guard eventID != Self.sinceNowSentinel else { return false }   // 「今から」の番兵
        guard let current = currentDeviceUUID else { return false }  // 履歴が無い
        guard let stored = deviceUUID else { return false }          // 検証できない
        return stored == current
    }
}

/// 調整役が 1 ライブラリについて知る必要のあること。
public struct LibraryWatchState: Sendable, Equatable, Identifiable {
    public let id: LibraryID
    /// 外部識別子（フェーズ 1 の登録フォルダ ID）。
    public let uuid: UUID
    public let displayName: String
    /// 保存されている根の物理パス。実体の確認はしていない。
    public let resolvedPath: String
    public let volumeUUID: String
    public let isOnline: Bool
    public let checkpoint: FSEventsCheckpoint
    /// 最後にフルスキャンした時刻 [SY-05]。`nil` は「一度もしていない」。
    public let lastFullScanAt: Date?

    public init(id: LibraryID, uuid: UUID, displayName: String, resolvedPath: String,
                volumeUUID: String, isOnline: Bool, checkpoint: FSEventsCheckpoint,
                lastFullScanAt: Date?) {
        self.id = id
        self.uuid = uuid
        self.displayName = displayName
        self.resolvedPath = resolvedPath
        self.volumeUUID = volumeUUID
        self.isOnline = isOnline
        self.checkpoint = checkpoint
        self.lastFullScanAt = lastFullScanAt
    }

    /// 最後のフルスキャンから `interval` 秒以上たっているか [SY-05]。
    /// 一度もしていなければ `true`。
    public func needsPeriodicFullScan(interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastFullScanAt else { return true }
        return now.timeIntervalSince(lastFullScanAt) >= interval
    }
}
