import AppKit
import Foundation
import QooKit
import UniformTypeIdentifiers

/// アプリ関連付けの永続化・実装 [12章 §12.9、AS-01〜AS-07 の実装可能な範囲、
/// `AppAssociationService` のコメント参照]。`RegisteredFolderStore.swift` と
/// 同じ理由・同じパターン（SwiftData が無い Phase 1 の間に合わせとして JSON
/// で永続化する `actor`）で、同じディレクトリに置く。
///
/// 拡張子 → bundleID の対応表と、環境設定「ビューア」タブが管理する拡張子の
/// 一覧を永続化する。JSON ファイルへの書き込みはアプリ内部の永続化データであり、
/// 期待変更台帳・Undo・操作履歴の対象外（ユーザーへ見える最終位置ではない）
/// ため、`RegisteredFolderStore`/`SecureExtractor`/`CoverImageCache` と同じ
/// 理由で `FileOperationService` を経由しない。この理由により、本ファイルは
/// FileOps 隔離検査（B-10）の対象外ディレクトリ（`QooInfrastructure/FileOps/`）
/// に置く。
public actor AppAssociationStore: AppAssociationService {
    public static let shared = AppAssociationStore()

    /// [設計判断] 当初は `[String: String]`（拡張子 → bundleID）のみを直接
    /// 永続化していたが、拡張子リストを追加する際に構造体へ拡張した。
    /// 既存ユーザーの `[String: String]` 形式のファイルもそのまま読める
    /// よう、`ensureLoaded()` でフォールバックデコードする。
    private struct StorageDTO: Codable {
        var associations: [String: String]
        var customExtensions: [String]
        /// 「組み込み／カスタム」の分離を単一の一覧へ統合した移行が完了済みか
        /// [ユーザー要望「既定拡張子とカスタム拡張子を分離する意味はない」]。
        /// 統合前に保存されたファイルは、当時「組み込み」だった6形式（現在は
        /// 8形式）が一度も `customExtensions` に含まれていなかった——そのまま
        /// 読み込むと一覧から消えてしまうため、`ensureLoaded()` が最初の1回
        /// だけ `defaultExtensions` を合流させてから `true` にする。**旧形式の
        /// キー自体が無い JSON は自動的に `nil` にデコードされる**（Optional
        /// なので未定義キーでも decode エラーにならない）ため、専用のカスタム
        /// デコード処理を書かずに移行判定できる。
        var hasUnifiedDefaults: Bool?
    }

    /// 初回起動時（永続化ファイルが1つも存在しない、または `customExtensions`
    /// という概念自体が無かった旧形式ファイルを読み込んだ）にだけ投入する
    /// 既定の拡張子一覧 [ユーザー要望: 「既定の拡張子とカスタム拡張子を分離
    /// する意味はない」——qooLibrary が実際に読める形式（zip/cbz・7z/cb7・
    /// rar/cbr）と、qooViewer が対応する形式（pdf・epub）]。**一度でも
    /// `customExtensions` を持つ永続化ファイルが存在すれば、以後この定数は
    /// 一切参照されない**（ユーザーが明示的に削除した項目が、将来この一覧に
    /// 追加が増えても勝手に復活することはない。逆に将来この一覧へ追加が
    /// あっても、既存ユーザーには自動反映されない——カスタマイズ可能な
    /// 一覧としては一般的で無害な挙動であり、Finder のお気に入りサイドバー
    /// が新しい既定項目を既存ユーザーへ遡って追加しないのと同じ）。
    private static let defaultExtensions: Set<String> = ["zip", "cbz", "7z", "cb7", "rar", "cbr", "pdf", "epub"]

    private let storageURL: URL
    private var associations: [String: String] = [:] // 拡張子（小文字） → bundleID
    private var extensionSet: Set<String> = [] // このタブが管理する拡張子（小文字）
    private var didLoad = false

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.storageURL = appSupport.appendingPathComponent("qooLibrary/appAssociations.json")
        }
    }

    /// `nonisolated`: `associations`/`extensionSet`/`storageURL` のいずれにも
    /// 触れず、`Launch Services` への同期的な問い合わせだけで完結するため、
    /// actor 隔離を経由する理由が無い（`AppAssociationService` のコメント
    /// 参照 — 同期関数にした理由そのもの）。
    public nonisolated func candidates(for ext: String) -> [AppCandidate] {
        guard let type = UTType(filenameExtension: ext) else { return [] }
        return Self.candidates(forUTType: type)
    }

    public nonisolated func candidatesForFolders() -> [AppCandidate] {
        Self.candidates(forUTType: .folder)
    }

    private nonisolated static func candidates(forUTType type: UTType) -> [AppCandidate] {
        NSWorkspace.shared.urlsForApplications(toOpen: type)
            .compactMap { candidate(for: $0) }
    }

    public func primary(for ext: String) async -> AppCandidate? {
        ensureLoaded()
        guard let bundleID = associations[ext.lowercased()],
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return Self.candidate(for: url)
    }

    public func setPrimary(_ bundleID: String?, for ext: String) async throws {
        ensureLoaded()
        let key = ext.lowercased()
        if let bundleID {
            associations[key] = bundleID
            // 不変条件: 関連付けを持つ拡張子は必ず一覧にも載る。さもないと
            // 環境設定「ビューア」タブは `extensions()` だけを表示するため、
            // コンテキストメニューの「常にこのアプリケーションで開く」で
            // 設定した関連付けが画面に現れず、後から確認も変更もできない
            // 迷子の設定になる。呼び出し側ではなくストア側で保証する
            // （経路が増えても破れないようにするため）。
            extensionSet.insert(key)
        } else {
            associations.removeValue(forKey: key) // [AS-01] `nil` でシステムの既定へ戻す
            // 一覧からは外さない — 「システムの既定に従う」に戻しただけで、
            // その拡張子を管理対象から降ろしたわけではないため
            // （降ろすのは `removeExtension(_:)` の役割）。
        }
        try save()
    }

    /// `bundleID` が `nil` の場合、`primary(for:)`（qooLibrary 内部設定）→
    /// 無ければシステムの既定アプリの順にフォールバックする [FM-06]。
    public func open(_ urls: [URL], with bundleID: String?) async throws {
        guard !urls.isEmpty else { return }
        let resolvedBundleID: String?
        if let bundleID {
            resolvedBundleID = bundleID
        } else if let ext = urls.first?.pathExtension, !ext.isEmpty {
            resolvedBundleID = await primary(for: ext)?.bundleID
        } else {
            resolvedBundleID = nil
        }
        guard let resolvedBundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: resolvedBundleID) else {
            // システムの既定アプリで開く。`open(_ urls:)` の複数 URL 版は
            // 単一アプリを指定できないため、1件ずつ開く。
            for url in urls { NSWorkspace.shared.open(url) }
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func extensions() async -> [String] {
        ensureLoaded()
        return extensionSet.sorted()
    }

    public func addExtension(_ ext: String) async throws {
        ensureLoaded()
        extensionSet.insert(ext.lowercased())
        try save()
    }

    public func removeExtension(_ ext: String) async throws {
        ensureLoaded()
        let key = ext.lowercased()
        extensionSet.remove(key)
        associations.removeValue(forKey: key)
        try save()
    }

    private static func candidate(for appURL: URL) -> AppCandidate? {
        guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: appURL.path)
        return AppCandidate(bundleID: bundleID, name: name, url: appURL)
    }

    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: storageURL) else {
            extensionSet = Self.defaultExtensions // 初回起動
            return
        }
        if let dto = try? JSONDecoder().decode(StorageDTO.self, from: data) {
            associations = dto.associations
            extensionSet = Set(dto.customExtensions)
            if dto.hasUnifiedDefaults != true {
                // 統合前に保存されたファイル（このセッション中に実機で
                // mp4/mkv を追加したファイル等）。組み込み8形式を1回だけ
                // 合流させ、その場で確定させる（次回以降は再度合流させない
                // ——ユーザーがここから削除しても復活しない）。
                extensionSet.formUnion(Self.defaultExtensions)
                try? save()
            }
        } else {
            // 拡張前（`[String: String]` 単体）の旧形式へのフォールバック。
            // この形式には拡張子一覧という概念自体が無かったため、初回起動と
            // 同じく既定値で埋める。
            let legacy = try? JSONDecoder().decode([String: String].self, from: data)
            if legacy == nil {
                // どちらの形式でも読めなかった＝ファイルが壊れている。
                // ここは `RegisteredFolderStore`/`VolumeAccessStore` と違い
                // 失っても再設定で済む種類の設定なので退避まではしないが、
                // 「関連付けが勝手に消えた」と見える事象の原因になるため
                // 必ずログに残す。
                Log.fileOps.error("アプリ関連付けの永続化ファイルを読めません。既定値で続行します: \(Log.path(storageURL))")
            }
            associations = legacy ?? [:]
            extensionSet = Self.defaultExtensions
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let dto = StorageDTO(associations: associations, customExtensions: extensionSet.sorted(), hasUnifiedDefaults: true)
        let data = try JSONEncoder().encode(dto)
        try data.write(to: storageURL, options: .atomic)
    }
}
