import Foundation

/// 開くアプリの候補 [12章 §12.9]。
public struct AppCandidate: Sendable, Equatable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let url: URL

    public init(bundleID: String, name: String, url: URL) {
        self.bundleID = bundleID
        self.name = name
        self.url = url
    }
}

/// 拡張子以外の関連付けキー。
///
/// 画像フォルダ（ブックフォルダ [IF-01]）は拡張子を持たないので、
/// 「開くアプリ」の保存には擬似キーを使う [§19.10 ステージ 2]。
/// **定義はここ 1 箇所**——書く側（登録ウィザード・環境設定「ビューア」）と
/// 読む側（IF-18 の開く経路）が別々の文字列を持つと、保存した設定を
/// 誰も読まない迷子になる。
public enum AppAssociationKeys {
    /// 画像フォルダの擬似キー。実在の拡張子と衝突しない語を選んである。
    /// このキーは `extensions()` の一覧（＝拡張子の管理一覧）には**載せない**
    /// ——専用の行として描く（`AppAssociationStore.setPrimary` 参照）。
    public static let folder = "folder"
}

/// アプリ関連付け [12章 §12.9、AS-01〜AS-07]。**qooLibrary 内部だけの
/// 「既定アプリ」上書きであり、macOS システム全体の既定関連付け（Finder や
/// 他アプリにも影響するもの）は一切変更しない**［設計判断］。AS2-01
/// 「設定のない拡張子はシステムの関連付けに従う」は、システム既定の上に
/// 乗る内部設定と解釈した。
///
/// 仕様の `setSecondary`（副次アプリの固定リストをコンテキストメニューに
/// 表示する、AS-06）は対象外にした — 「アプリケーションで開く」サブメニューが
/// `candidates(for:)` を毎回動的に列挙するため、別途「副次アプリ」を保存・
/// 管理する意味が薄いと判断した［設計判断、`RegisteredFolderStore` 等と
/// 同じ「実装可能な範囲に絞る」方針を踏襲、CLAUDE.md 参照］。
public protocol AppAssociationService: Sendable {
    /// 拡張子（ドット無し、小文字）を開ける候補アプリを列挙する
    /// [LSCopyApplicationURLsForURL 相当]。**同期関数**（`Launch Services`
    /// への問い合わせのみで実際の非同期処理を伴わないため）[実機検証で
    /// 発見: 当初 `async` にしていたところ、中央ペインの「このアプリケー
    /// ションで開く」サブメニューで実際に選ぶまで候補が一切表示されず
    /// 「その他…」しか出ない不具合があった。原因は AppKit へブリッジされた
    /// 一度表示済みのコンテキストメニュー（`NSMenu`）は、`.task` の非同期
    /// 完了後に `@State` を更新しても再構築されないこと——`candidates(for:)`
    /// 自体は正しい結果を返していたことをログで確認済み（`urlsForApplications`
    /// は元々同期 API）。メニューを開く前（body 評価時）に同期的に結果を
    /// 確定させる必要があるため、`async` を撤去した]。
    func candidates(for ext: String) -> [AppCandidate]
    /// フォルダを開ける候補アプリを列挙する（`public.folder` 準拠）
    /// ［ユーザー指摘: フォルダのコンテキストメニューにも「このアプリケー
    /// ションで開く」が無いのはおかしい］。`candidates(for:)` は拡張子
    /// ベースのためフォルダには使えず、別メソッドとして分離している。
    func candidatesForFolders() -> [AppCandidate]
    /// qooLibrary 内部で設定済みの既定アプリ。未設定なら `nil`
    /// （システムの関連付けに従う）[AS2-01]。
    func primary(for ext: String) async -> AppCandidate?
    /// `nil` を渡すと「システムの既定に従う」に戻す [AS-01]。
    ///
    /// 実装は、関連付けを設定したとき（`bundleID` が `nil` でないとき）その
    /// 拡張子を `extensions()` の一覧にも必ず加えること — 環境設定「ビューア」
    /// タブは一覧に載っている拡張子しか表示しないため、載せないと設定した
    /// 関連付けを後から確認・変更できなくなる。
    func setPrimary(_ bundleID: String?, for ext: String) async throws
    /// 指定したアプリで開く。`bundleID` が `nil` なら `primary(for:)` →
    /// 無ければシステムの既定アプリの順にフォールバックする [FM-06]。
    func open(_ urls: [URL], with bundleID: String?) async throws

    /// 環境設定「ビューア」タブで管理している拡張子の一覧（小文字、
    /// `sorted()` 済み）［ユーザー要望: 本アプリはコミック向けが主だが、
    /// 動画ライブラリとしても使えるよう任意の拡張子を追加できるようにする］。
    /// **[訂正] 以前は「組み込み（qooLibrary が実際に読める形式）」と
    /// 「カスタム（ユーザーが任意追加）」を別管理していたが、この区別に
    /// 意味が無いというユーザー指摘を受けて撤廃した——このタブは単に
    /// 「ダブルクリック／Enter で開くアプリ」を指定するだけの設定であり、
    /// qooLibrary が中身を読めるかどうか（サムネイル生成対応など）とは
    /// 無関係の別の関心事のため。zip/cbz/7z/cb7/rar/cbr/pdf/epub は初回起動
    /// 時に既定でこの一覧へ加えられるだけの「最初から入っている項目」に
    /// すぎず、他の項目と全く同じ操作（削除・追加）ができる。**
    func extensions() async -> [String]
    /// 拡張子をこの一覧に追加する（大文字小文字を区別しない、既に追加済み
    /// なら何もしない）。
    func addExtension(_ ext: String) async throws
    /// 拡張子をこの一覧から外す。設定済みの `primary` もあわせて削除する。
    func removeExtension(_ ext: String) async throws
}
