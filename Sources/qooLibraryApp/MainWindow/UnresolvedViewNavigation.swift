//
//  未整理ビューを開く要求を受け渡す [UR3-01][UR2-02、ステージ 4]。
//
//  **未整理は専用ウインドウではなくメインウインドウの一覧**になった [UR3-02]
//  ので、`openWindow(id:)` では飛ばせない——`WindowState` を触る必要がある。
//  他の整理ウインドウ（`MaintenanceNavigation` 等）と同じ「受け皿へ置いて、
//  見た側が消費する」形にしてある。
//
//  ## 最初に気づいたウインドウが引き受ける
//  メインウインドウは複数開ける [MW-01] ので、全部が同じ要求に反応すると
//  **開いている枚数だけ未整理ビューへ切り替わる**。要求を読んだ時点で `nil` に
//  戻し、1 枚だけが応じるようにする。どの 1 枚かは決まらないが、
//  「キーウインドウか」を `@Environment(\.controlActiveState)` で判定する形は
//  1-12b で実際に壊れた（アラートが出なくなった）ので採らない。
//
import QooKit
import Observation

@MainActor
@Observable
final class UnresolvedViewNavigation {
    static let shared = UnresolvedViewNavigation()
    var pendingLibraryID: LibraryID?
    private init() {}

    /// 開く経路はここ 1 つ [CP-02]。走査結果のシートと通知履歴の両方が通る。
    static func open(libraryID: LibraryID) {
        shared.pendingLibraryID = libraryID
    }
}
