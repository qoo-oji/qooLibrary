//
//  プリセット改訂の差分 [LT-10〜LT-17][12章 §12.5 TU-01〜TU-06]。
//
//  ## 三項の差分である
//  | 項 | 何 | どこから |
//  |---|---|---|
//  | base | そのライブラリが**登録された時点**のプリセット定義 | `library.registeredTemplateJSON` |
//  | new  | 最新のプリセット定義 | `BuiltInTemplates.libraryTypes()` |
//  | current | ライブラリの現在の設定 | `settingsDraft(libraryID:)` |
//
//  base が要るのは **LT-15（ローカル編集済みの明示）のため**——「プリセットが
//  改訂した項目」と「利用者が自分で変えた項目」は、base が無いと区別できない。
//  base 無しで new と current だけを比べると、**利用者が自分で消したフォーマットが
//  毎回「追加されました」として並び続ける**。
//
//  ## 比較は草案へ畳んでから行う
//  `draft(from:)` は決定的なので、テンプレートさえあれば当時の草案を完全に
//  再現できる。しかも**プリセットが持たない項目**（対象拡張子・保護文字列・
//  区切り・シリーズ名の組み立て）は base 側と new 側で同じ既定値になるため、
//  **差分から自動的に外れる**——除外リストを手で書く必要がない。
//
//  ## フィールドの削除は差分に出さない［設計判断］
//  `updateSettings` はフィールドを草案から外すと `labelGroup` 行を消し、
//  **連鎖でラベルと紐づけも消える**（`writeFields` のコメント参照）。つまり
//  ①利用者の資産であるラベルが失われ ②`updateSettings(旧草案)` で戻しても
//  新しい行 ID の空フィールドが復活するだけなので **LT-16 の「1 つの Undo
//  単位」を満たせない**。プリセットがそのフィールドを持たなくなっても、
//  走査が新しく付けなくなるだけで既存のラベルは有効なままでよい。
//
//  フォーマット・階層割り当ての削除は行を消すだけでラベルに触れず、
//  `updateSettings` で完全に戻せるので差分に出す。
//
//  ## 色は差分に出さない
//  プリセットは配色を持たず、`draft(from:)` が `LabelColorPalette` から
//  **件数に応じて**割り当てる。フィールドが 1 つ増えれば全フィールドの色が
//  変わるので、出すと「本当に見てほしい 1 項目」が色の変更に埋もれる。
//
import Foundation

// MARK: - 差分

public struct TemplateDiff: Sendable, Equatable {

    public enum Category: String, Sendable, Hashable, CaseIterable {
        case field
        case filenameFormat
        case filenameFormatOrder
        case volumeFormat
        case folderLevel
    }

    public enum Change: String, Sendable, Hashable {
        case added, removed, modified, reordered
    }

    /// 適用の実体。**表示用の文字列とは別に持つ**——文字列から操作を
    /// 復元する形にすると、訳語を変えただけで適用が壊れる。
    public enum Action: Sendable, Hashable {
        /// フィールドの追加。`index` は**空いていれば**その番号を使う
        /// [Stage 5: 番号はフィールドの身元ではない]。束縛も同じ項目で運ぶ
        /// ——別項目にすると、束縛だけ選んだときに存在しないフィールドを
        /// 指す設定ができてしまい、草案の検証で保存できなくなる [RW-16]。
        case addField(index: Int, name: String, assignsAutomatically: Bool,
                      bindings: [SemanticKeyword])
        case renameField(index: Int, name: String)
        case setFieldAutoAssign(index: Int, value: Bool)
        /// `after` はプリセット上で直前に来るフォーマット。**そこへ挿す**
        /// ——末尾へ足すと、プリセットが上位の優先順で入れたつもりの
        /// フォーマットが最下位に落ちて意図と食い違う [FF-03]。見つから
        /// なければ末尾へ。
        case addFilenameFormat(source: String, after: String?)
        case removeFilenameFormat(source: String)
        /// プリセットの相対順に合わせる。**共通するフォーマットの並びだけ**を
        /// 指定し、利用者が自分で足したものは末尾に残す [D3: 更新で利用者の
        /// 項目を落とさない]。
        case reorderFilenameFormats(order: [String])
        case addVolumeFormat(source: String, kind: VolumePatternKind)
        case removeVolumeFormat(source: String, kind: VolumePatternKind)
        /// `assignment` が `nil` なら行ごと削除。
        case setFolderLevel(level: Int, assignment: FolderLevelDraft.Assignment?)
    }

    public struct Item: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let category: Category
        public let change: Change
        public let action: Action
        /// 変更後の値（表示用）。フォーマットならソース文字列そのもの。
        public let subject: String
        /// 変更前の値（表示用）。`.modified` / `.reordered` のときだけ。
        public let previous: String?
        /// **利用者がこの項目を自分で変えている** [LT-15]。適用すると
        /// その編集が上書きされる。
        public let isLocallyEdited: Bool
        /// 既定の選択 [LT-14]。**ローカル編集済みだけ既定で外す**——
        /// 上書きは利用者が明示的に選んだときだけ起こるべきで、逆に
        /// 全部を外すと「全部押す」作業を強いることになる。
        public var isSelected: Bool

        public init(id: UUID = UUID(), category: Category, change: Change, action: Action,
                    subject: String, previous: String? = nil, isLocallyEdited: Bool) {
            self.id = id
            self.category = category
            self.change = change
            self.action = action
            self.subject = subject
            self.previous = previous
            self.isLocallyEdited = isLocallyEdited
            self.isSelected = !isLocallyEdited
        }
    }

    public var items: [Item]
    /// 改訂の前後 [LT-10]。
    public let fromVersion: Int
    public let toVersion: Int

    public init(items: [Item], fromVersion: Int, toVersion: Int) {
        self.items = items
        self.fromVersion = fromVersion
        self.toVersion = toVersion
    }

    public var isEmpty: Bool { items.isEmpty }
    public var selected: [Item] { items.filter(\.isSelected) }
}
