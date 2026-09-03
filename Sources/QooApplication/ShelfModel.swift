//
//  シェルフの状態 [SH-01〜SH-11][19章 §19.2]。`WindowState` が 1 つ持つ。
//
//  **一覧そのものはライブラリ単位の永続設定で全ウインドウ共有** [ST-23]
//  ——ピン留め [PN-04] やフィールドの並び順 [LG-07] と同じ。復元した結果
//  （どのラベルにチェックが入っているか）はウインドウ固有 [ST-20] で、
//  この分け方は既存の `LabelFilterModel` の作りをそのまま踏襲している。
//
//  ## 条件はこのモデルが組み立てない
//  シェルフが覚えるもののうち、**並び順は中央ペイン、検索語はタブ**が持って
//  いる。ここへ集めると 3 つ目の写しができて、どれが正かを言えなくなる
//  ——組み立ては持ち主（View 層）に任せ、このモデルは受け取った
//  `ShelfCondition` を保存・照合するだけにする。
//
import Foundation
import Observation
import QooInfrastructure
import QooKit

@MainActor
@Observable
public final class ShelfModel {
    public private(set) var library: LibrarySummary?
    /// 並び順で並んだ一覧 [SH-10]。
    public private(set) var shelves: [ShelfSummary] = []
    /// 最後に読み込みへ失敗した理由。UI が黙って空を見せないため [ER-01]。
    public private(set) var loadFailure: String?

    public init() {}

    public func load(library: LibrarySummary?, services: LibraryServices) async {
        self.library = library
        guard let library else {
            shelves = []
            loadFailure = nil
            return
        }
        do {
            shelves = try await services.shelves(libraryID: library.id)
            loadFailure = nil
        } catch {
            // 取り消しは失敗ではない（他のモデルと同じ扱い）。
            guard !CommandStack.isCancellation(error) else { return }
            shelves = []
            loadFailure = error.localizedDescription
        }
    }

    /// いまの絞り込みと同じ条件のシェルフ [SH-08]。
    ///
    /// **押した後に何も起きないように見えるのを避けるため**に要る——復元した
    /// 直後にそのシェルフが選択表示になれば、条件を 1 つ変えた瞬間に外れる
    /// ことで「もうそのシェルフではない」ことも同時に伝わる。
    /// - Parameter resolving: シェルフの条件を「いま解決できるラベルだけ」に
    ///   畳む写像（`LabelFilterModel.resolvable`）。**畳まずに比べてはいけない**
    ///   ——非表示のラベル [LA3-05] を 1 つ含むシェルフが二度と一致しなくなる
    ///   ［code-review の指摘］。
    public func matchingShelf(for condition: ShelfCondition,
                              resolving: (ShelfCondition) -> ShelfCondition = { $0 })
        -> ShelfSummary?
    {
        shelves.first { resolving($0.condition) == condition }
    }

    /// 並べ替え [SH-10]。**Undo の対象にしない**——フィールドの並び順
    /// [LF-03] と登録フォルダの並び順 [RG3-33] に揃える。
    public func reorder(_ ordered: [ShelfSummary], services: LibraryServices) async {
        shelves = ordered
        do {
            try await services.setShelfOrder(ordered.map(\.id))
        } catch {
            // **`loadFailure` に書いても直後の読み直しが消す**［code-review の
            // 指摘］。並べ替えの失敗は次の読み直しで元の順序に戻る形で目に
            // 見えるので、ここはログに残す（`LabelFilterModel.reorderFields`
            // と同じ扱い）。
            Log.ui.warning("シェルフの並び順を保存できない: \(String(describing: error))")
        }
        await load(library: library, services: services)
    }

    /// コマンドを実行した後に読み直す。
    public func reload(services: LibraryServices) async {
        await load(library: library, services: services)
    }
}
