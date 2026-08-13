import AppKit
import Foundation
import QooKit
import UniformTypeIdentifiers

/// アプリ関連付けの永続化・実装 [12章 §12.9、AS-01〜AS-07 の実装可能な範囲、
/// `AppAssociationService` のコメント参照]。`RegisteredFolderStore.swift` と
/// 同じ理由・同じパターン（SwiftData が無い Phase 1 の間に合わせとして JSON
/// で永続化する `actor`）で、同じディレクトリに置く。
///
/// 拡張子 → bundleID の対応表のみを永続化する。JSON ファイルへの書き込みは
/// アプリ内部の永続化データであり、期待変更台帳・Undo・操作履歴の対象外
/// （ユーザーへ見える最終位置ではない）ため、`RegisteredFolderStore`/
/// `SecureExtractor`/`CoverImageCache` と同じ理由で `FileOperationService` を
/// 経由しない。この理由により、本ファイルは FileOps 隔離検査（B-10）の対象外
/// ディレクトリ（`QooInfrastructure/FileOps/`）に置く。
public actor AppAssociationStore: AppAssociationService {
    public static let shared = AppAssociationStore()

    private let storageURL: URL
    private var associations: [String: String] = [:] // 拡張子（小文字） → bundleID
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

    public func candidates(for ext: String) async -> [AppCandidate] {
        guard let type = UTType(filenameExtension: ext) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
            .compactMap { Self.candidate(for: $0) }
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
        } else {
            associations.removeValue(forKey: key) // [AS-01] `nil` でシステムの既定へ戻す
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

    private static func candidate(for appURL: URL) -> AppCandidate? {
        guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: appURL.path)
        return AppCandidate(bundleID: bundleID, name: name, url: appURL)
    }

    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: storageURL) else { return }
        associations = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(associations)
        try data.write(to: storageURL, options: .atomic)
    }
}
