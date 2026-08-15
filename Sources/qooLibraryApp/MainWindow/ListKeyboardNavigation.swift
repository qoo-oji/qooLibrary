import Foundation
import QooKit

/// 一覧のキーボード操作のうち、**表示モードに依らない部分**をまとめる。
///
/// リスト表示（`Table`）は矢印キーでの選択移動を AppKit から無償で受け取るが、
/// アイコン表示（`LazyVGrid`）には何も無い。同じ計算を 2 か所に書くと片方だけ
/// 直されて挙動がずれるため、純粋な関数としてここへ出す（テストもしやすい）。
enum ListKeyboardNavigation {
    // MARK: - type-select（先頭文字で項目へ飛ぶ）

    /// 打鍵をためておく箱。
    ///
    /// Finder と同じく、**続けて打った文字は積み上がり、少し間が空くと
    /// リセットされる**（"re" と打てば `readme` へ飛び、間を置いて "s" と
    /// 打てば `sample` へ飛ぶ）。1 文字ずつ独立に扱うと、名前の頭文字が
    /// 同じファイルが並ぶフォルダでまったく使い物にならない。
    struct TypeSelectBuffer {
        /// 打鍵が途切れたとみなすまでの時間。macOS の既定の type-select と
        /// 同じ感覚になるよう 1 秒にしている。
        static let resetInterval: Duration = .seconds(1)

        private var text = ""
        private var lastKeystrokeAt: ContinuousClock.Instant?

        /// 1 文字受け取り、いま検索すべき文字列を返す。
        mutating func append(_ character: Character) -> String {
            let now = ContinuousClock.now
            if let last = lastKeystrokeAt, now - last > Self.resetInterval { text = "" }
            lastKeystrokeAt = now
            text.append(character)
            return text
        }

        mutating func reset() {
            text = ""
            lastKeystrokeAt = nil
        }
    }

    /// type-select で飛ぶ先。見つからなければ `nil`（＝選択を変えない）。
    ///
    /// **いま選んでいる項目の次から探して一周する。** 同じ頭文字の項目が
    /// 並んでいるとき、同じ文字を続けて打つと順に送れるようにするため
    /// （Finder と同じ）。ただし打鍵が積み上がっている間（`prefix` が 2 文字
    /// 以上）は先頭から探す — "sa" と打った時点で `sample` に居るのに
    /// `sample2` へ飛んでしまうと、絞り込んでいるつもりの操作と食い違う。
    static func typeSelectTarget<Item>(
        in items: [Item],
        prefix: String,
        currentIndex: Int?,
        name: (Item) -> String
    ) -> Int? {
        guard !items.isEmpty, !prefix.isEmpty else { return nil }
        let startsFromNext = prefix.count == 1
        let offset = startsFromNext ? (currentIndex.map { $0 + 1 } ?? 0) : 0
        for step in 0..<items.count {
            let index = (offset + step) % items.count
            if NameFilter.hasPrefix(name: name(items[index]), prefix: prefix) { return index }
        }
        return nil
    }

    // MARK: - 格子上の移動（アイコン表示）

    enum Direction {
        case up, down, left, right
    }

    /// `count` 個の項目が 1 行 `columns` 個で並んでいるときの移動先。
    ///
    /// **端では止まる**（行をまたいで折り返さない）。Finder のアイコン表示と
    /// 同じで、← を押し続けても勝手に前の行の末尾へ回り込まない。ただし
    /// ↓ で最終行に降りるとき、その列に項目が無ければ**最後の項目**へ寄せる
    /// （Finder も同じ。降りられないと最下段の右側に届かなくなる）。
    static func gridTarget(from index: Int, direction: Direction, count: Int, columns: Int) -> Int? {
        guard count > 0, columns > 0, index >= 0, index < count else { return nil }
        switch direction {
        case .left:
            return index % columns == 0 ? nil : index - 1
        case .right:
            return (index % columns == columns - 1 || index + 1 >= count) ? nil : index + 1
        case .up:
            return index - columns >= 0 ? index - columns : nil
        case .down:
            let below = index + columns
            if below < count { return below }
            // 同じ列に項目が無い最終行への移動。すでに最終行なら動かない。
            let lastRowStart = ((count - 1) / columns) * columns
            return index < lastRowStart ? count - 1 : nil
        }
    }
}
