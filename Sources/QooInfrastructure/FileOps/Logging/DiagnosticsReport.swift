import Foundation
import QooKit

/// 書き出しバンドルに同梱する `diagnostics.json` の中身 [LG2-05][CB-22]。
///
/// 「不具合の報告に添付されたログだけを見て状況を再現できる」ことを目的に、
/// ログ本文からは読み取れない環境情報をまとめる。
///
/// **`database` はフェーズ1では常に `nil`**。CB-22 は「DB のレコード数」を
/// 求めているが、SwiftData の導入自体がフェーズ2の対象で、この時点では
/// 数えるべきストアが存在しない。フェーズ2で DB を導入する際に
/// `DatabaseInfo` を実際に埋めること。
public struct DiagnosticsReport: Codable, Sendable, Equatable {
    public struct AppInfo: Codable, Sendable, Equatable {
        public var bundleIdentifier: String?
        public var shortVersion: String?
        public var buildVersion: String?
        /// `Debug` / `Release`。
        public var buildConfiguration: String
        /// `PERMISSIVE_ONLY_BUILD` の有無 [B-01][LC-13]。
        public var permissiveOnlyBuild: Bool
        /// 実際に使われる RAR バックエンド名 [B-01]。
        public var rarBackend: String
    }

    public struct SystemInfo: Codable, Sendable, Equatable {
        public var osVersion: String
        public var architecture: String
        public var isSandboxed: Bool
        public var preferredLanguages: [String]
        public var physicalMemoryBytes: UInt64
        public var processorCount: Int
    }

    public struct LoggingInfo: Codable, Sendable, Equatable {
        public var level: String
        public var pathsAnonymized: Bool
        public var files: [LogFileInfo]
    }

    public struct LogFileInfo: Codable, Sendable, Equatable {
        public var name: String
        public var bytes: Int64
    }

    public struct RegisteredFolderCounts: Codable, Sendable, Equatable {
        public var library: Int
        public var temporary: Int
        /// 起動時にセキュリティスコープを開始できた登録の数。
        ///
        /// `library + temporary` との差が、実体を失っている（ボリューム
        /// 未接続・削除など）登録の数になる。1-17 の縮退状態の診断に直結する。
        ///
        /// **「解決できない件数」を直接数える形にはしない** — その計算は
        /// 全登録のブックマークを解決することになり、`.withoutMounting` を
        /// 付けていない現在の解決はイジェクト済みのボリュームを再マウント
        /// してしまう（§8.7.1 BM-5）。**診断情報を書き出しただけでディスクが
        /// マウントされる**のは明らかに驚きの副作用なので、副作用の無い
        /// `RegisteredFolderStore.activeAccessCount()` を使う。
        public var activeAccess: Int
    }

    public struct DatabaseInfo: Codable, Sendable, Equatable {
        public var schemaVersion: String
        public var recordCounts: [String: Int]
    }

    public var generatedAt: Date
    public var app: AppInfo
    public var system: SystemInfo
    public var logging: LoggingInfo
    public var registeredFolders: RegisteredFolderCounts
    public var volumeAccessGrants: Int
    public var database: DatabaseInfo?

    public init(
        generatedAt: Date,
        app: AppInfo,
        system: SystemInfo,
        logging: LoggingInfo,
        registeredFolders: RegisteredFolderCounts,
        volumeAccessGrants: Int,
        database: DatabaseInfo? = nil
    ) {
        self.generatedAt = generatedAt
        self.app = app
        self.system = system
        self.logging = logging
        self.registeredFolders = registeredFolders
        self.volumeAccessGrants = volumeAccessGrants
        self.database = database
    }

    /// 実行中のアプリから診断情報を収集する [CB-22]。
    ///
    /// `RegisteredFolderStore`/`VolumeAccessStore`（どちらも同一モジュール内の
    /// 共有シングルトン）を直接参照する。テストからは
    /// `DiagnosticLogging.exportBundle(anonymizePaths:to:report:)` に明示的な
    /// `report` を渡すことで、実際のストアに触れずに検証できる。
    public static func current(
        level: LogLevel,
        pathsAnonymized: Bool,
        logFiles: [URL]
    ) async -> DiagnosticsReport {
        let registered = await registeredFolderCounts()
        let grants = await VolumeAccessStore.shared.grantedAccess().count

        return DiagnosticsReport(
            generatedAt: Date(),
            app: appInfo(),
            system: systemInfo(),
            logging: LoggingInfo(
                level: level.identifier,
                pathsAnonymized: pathsAnonymized,
                files: logFiles.map { url in
                    LogFileInfo(
                        name: url.lastPathComponent,
                        bytes: (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
                    )
                }
            ),
            registeredFolders: registered,
            volumeAccessGrants: grants,
            database: nil // フェーズ1では SwiftData 未導入
        )
    }

    /// ログ本文の先頭に 1 行で書く環境情報（`Log.startSession()` から使う）。
    /// `diagnostics.json` を伴わずログ本文だけを共有された場合でも、
    /// 最低限どのビルド・どの macOS の記録なのかが分かるようにする。
    public static func sessionBanner() -> String {
        let app = appInfo()
        let system = systemInfo()
        let version = [app.shortVersion, app.buildVersion.map { "(\($0))" }]
            .compactMap { $0 }
            .joined(separator: " ")
        return [
            "qooLibrary \(version.isEmpty ? "バージョン不明" : version)",
            app.buildConfiguration,
            "RAR=\(app.rarBackend)",
            system.osVersion,
            system.architecture,
            "sandbox=\(system.isSandboxed)",
        ].joined(separator: " / ")
    }

    /// JSON へ整形する。差分を見やすくするためキーを整列し、日付は ISO8601。
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    // MARK: - 収集

    private static func appInfo() -> AppInfo {
        let bundle = Bundle.main
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        #if PERMISSIVE_ONLY_BUILD
        let permissive = true
        #else
        let permissive = false
        #endif
        return AppInfo(
            bundleIdentifier: bundle.bundleIdentifier,
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            buildConfiguration: configuration,
            permissiveOnlyBuild: permissive,
            rarBackend: ArchiveBackendRegistry.rarBackendName
        )
    }

    private static func systemInfo() -> SystemInfo {
        let info = ProcessInfo.processInfo
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return SystemInfo(
            osVersion: info.operatingSystemVersionString,
            architecture: architecture,
            // サンドボックス下では、この環境変数にコンテナ ID が入る。
            isSandboxed: info.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            preferredLanguages: Locale.preferredLanguages,
            physicalMemoryBytes: info.physicalMemory,
            processorCount: info.processorCount
        )
    }

    private static func registeredFolderCounts() async -> RegisteredFolderCounts {
        let store = RegisteredFolderStore.shared
        return await RegisteredFolderCounts(
            library: store.folders(kind: .library).count,
            temporary: store.folders(kind: .temporary).count,
            activeAccess: store.activeAccessCount()
        )
    }
}
