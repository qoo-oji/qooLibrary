// swift-tools-version: 6.0
import Foundation
import PackageDescription

// `PERMISSIVE_ONLY_BUILD=1 swift build` excludes UnRAR and falls back to
// libarchive's RAR reader [LC-12][LC-13]. UnRAR is not vendored yet (see
// THIRD-PARTY-NOTICES.md); once it is, QooInfrastructure will conditionally
// depend on a CUnrar target here, matching 01_プロジェクト構成とビルド.md §1.2.
let permissiveOnlyBuild = ProcessInfo.processInfo.environment["PERMISSIVE_ONLY_BUILD"] != nil

let package = Package(
    name: "qooLibrary",
    platforms: [
        .macOS(.v15) // [C-01]
    ],
    products: [
        .library(name: "QooKit", targets: ["QooKit"]),
        .library(name: "QooPersistence", targets: ["QooPersistence"]),
        .library(name: "QooInfrastructure", targets: ["QooInfrastructure"]),
        .library(name: "QooApplication", targets: ["QooApplication"]),
    ],
    targets: [
        // MARK: - Domain layer [A-01]
        // Foundation のみに依存する。SwiftData / AppKit / SwiftUI を import しない。
        .target(
            name: "QooKit"
        ),

        // MARK: - Persistence layer (SwiftData) [A-02]
        .target(
            name: "QooPersistence",
            dependencies: ["QooKit"]
        ),

        // MARK: - libarchive vendoring [LC-15][B-02]
        // Scripts/build-libarchive.sh が生成する xcframework（システムの
        // libarchive.dylib にはリンクしない）。
        .binaryTarget(
            name: "libarchiveBinary",
            path: "ThirdParty/libarchive/libarchive.xcframework"
        ),
        // Swift から archive.h / archive_entry.h を import するための薄いラッパー。
        // libarchive はビルド時に検出した system zlib / bz2 / iconv を前提にしている
        // ため、最終リンク時にこれらも解決する必要がある（Scripts/build-libarchive.sh
        // 参照。lzma/zstd/openssl/xml2/expat は --without- で無効化済み）。
        .target(
            name: "CLibarchive",
            dependencies: ["libarchiveBinary"],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),

        // MARK: - Infrastructure layer [A-01]
        // QooPersistence とは相互依存しない。
        .target(
            name: "QooInfrastructure",
            dependencies: ["QooKit", "CLibarchive"],
            swiftSettings: permissiveOnlyBuild ? [.define("PERMISSIVE_ONLY_BUILD")] : []
        ),

        // MARK: - Application layer
        .target(
            name: "QooApplication",
            dependencies: ["QooKit", "QooPersistence", "QooInfrastructure"]
        ),

        // MARK: - Tests
        .testTarget(
            name: "QooKitTests",
            dependencies: ["QooKit"]
        ),

        // MARK: - Spikes (technical verification, kept per 16章 §16.6)
        // T-13 (zip/7z half): proves libarchive can be driven from Swift via
        // the CLibarchive wrapper to list and extract an archive.
        .executableTarget(
            name: "LibarchiveSpike",
            dependencies: ["CLibarchive"],
            path: "Spikes/LibarchiveSpike"
        ),
    ],
    swiftLanguageModes: [.v6]
)
