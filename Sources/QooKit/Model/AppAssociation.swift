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
    /// [LSCopyApplicationURLsForURL 相当]。
    func candidates(for ext: String) async -> [AppCandidate]
    /// qooLibrary 内部で設定済みの既定アプリ。未設定なら `nil`
    /// （システムの関連付けに従う）[AS2-01]。
    func primary(for ext: String) async -> AppCandidate?
    /// `nil` を渡すと「システムの既定に従う」に戻す [AS-01]。
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
