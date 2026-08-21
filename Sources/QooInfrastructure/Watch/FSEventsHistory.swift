//
//  FSEvents の履歴が使えるかを答える [SY-03][SY-04][WA-10〜WA-12]。
//
//  ここだけが `FSEventsCopyUUIDForDevice` を呼ぶ。**保存した差分の起点
//  （`FSEventsCheckpoint`）を使ってよいかの判断は、この UUID の照合でしか
//  できない**——10章 §10.1.0 の実測どおり、履歴を持たないボリュームへ起点を
//  渡しても**エラーもフラグも出ず、ただ 1 件も再生されない**（`HistoryDone`
//  すら正常に届く）。
//
import CoreServices
import Foundation
import QooKit

public enum FSEventsHistory {

    /// `url` があるボリュームの FSEvents データベース識別子。
    ///
    /// `nil` は「履歴が利用できない」。SDK の `FSEvents.h` はこの場合
    /// **`kFSEventStreamEventIdSinceNow` 以外を `sinceWhen` に渡してはならない**
    /// と定めている。実測で `nil` になったのは:
    ///
    /// - **ネットワークボリューム（SMB）** ← 実運用でありうる
    /// - Time Machine のバックアップ先（FSEvents が無効）
    /// - 読み取り専用ボリューム（ヘッダに明記）
    /// - システムが管理する補助ボリューム（`/System/Volumes/Preboot` 等）
    ///
    /// - Important: **存在するパスに対して呼ぶこと。** 存在しないパスへの
    ///   `stat` は失敗するので、その結果を「履歴なし」と読むと判定が嘘になる
    ///   （§10.1.0 の実測で一度やった）。存在しない場合も `nil` を返すが、
    ///   呼び出し側は「根が無い」ことを先に確かめてから使う。
    /// - Important: I/O を伴う（`stat` と fseventsd への問い合わせ）。
    ///   メインスレッドから呼ばず、``FileIO/perform(_:)`` の中で使うこと [NV6-02]。
    public static func deviceUUID(for url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        guard let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// システム全体で最後に発行されたイベント ID。
    ///
    /// ストリームをまだ張っていない段階で起点を作るのに使う。**ボリューム
    /// ごとではなくシステム全体で単調**なので、どのライブラリの起点としても
    /// 使える（ヘッダいわく「global, system-wide clock のように振る舞う」）。
    public static func currentEventID() -> UInt64 {
        UInt64(FSEventsGetCurrentEventId())
    }

    /// いまの実体に照らして、保存済みの起点で履歴を要求してよいかを判定する
    /// [SY-04][WA-11][WA-12]。
    ///
    /// - Returns: 使えるなら渡してよい起点、使えないなら `nil`。
    ///   **`nil` を返したライブラリはフルスキャンへ落とすこと**——履歴が
    ///   再生されないことを検出できるのはここだけで、素通りさせると
    ///   非起動中の変更が黙って失われる。
    public static func usableCheckpoint(_ stored: FSEventsCheckpoint,
                                        rootURL: URL) -> FSEventsCheckpoint? {
        let current = deviceUUID(for: rootURL)
        guard stored.isUsable(currentDeviceUUID: current) else { return nil }
        return stored
    }
}
