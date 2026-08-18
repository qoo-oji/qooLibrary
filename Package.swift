// swift-tools-version: 6.0
import Foundation
import PackageDescription

// `PERMISSIVE_ONLY_BUILD=1 swift build` excludes UnRAR entirely (not just as
// an unused dependency — the target itself is omitted below, so this build
// mode never requires ThirdParty/unrar/ to exist) and falls back to
// libarchive's RAR reader instead [LC-12][LC-13].
let permissiveOnlyBuild = ProcessInfo.processInfo.environment["PERMISSIVE_ONLY_BUILD"] != nil

var targets: [Target] = [
    // MARK: - Domain layer [A-01]
    // Foundation のみに依存する。SwiftData / AppKit / SwiftUI を import しない。
    .target(
        name: "QooKit",
        // プリセットテンプレート・既定巻数フォーマットは JSON リソースとして持つ
        // [MT-02]。コード内のリテラルにしない。
        resources: [.process("Resources")]
    ),

    // MARK: - Persistence layer (SQLite / GRDB) [A-02]
    // GRDB を import してよいのはこのターゲットだけ（静的検査 B-11 が強制する）。
    // 上位層は QooKit のリポジトリプロトコル越しにのみ触る。
    // SwiftData ではなく SQLite を選んだ根拠は Spikes/README.md「T-03 / T-04」。
    .target(
        name: "QooPersistence",
        dependencies: ["QooKit", .product(name: "GRDB", package: "GRDB.swift")]
    ),

    // MARK: - libarchive vendoring [LC-15][B-02]
    // Scripts/build-libarchive.sh が生成する xcframework(システムの
    // libarchive.dylib にはリンクしない)。
    .binaryTarget(
        name: "libarchiveBinary",
        path: "ThirdParty/libarchive/libarchive.xcframework"
    ),
    // Swift から archive.h / archive_entry.h を import するための薄いラッパー。
    // libarchive はビルド時に検出した system zlib / bz2 / iconv を前提にしている
    // ため、最終リンク時にこれらも解決する必要がある(Scripts/build-libarchive.sh
    // 参照。lzma/zstd/openssl/xml2/expat は --without- で無効化済み)。
    .target(
        name: "CLibarchive",
        dependencies: ["libarchiveBinary"],
        linkerSettings: [
            .linkedLibrary("z"),
            .linkedLibrary("bz2"),
            .linkedLibrary("iconv"),
        ]
    ),
]

// MARK: - UnRAR vendoring [LC-11][B-03], excluded under PERMISSIVE_ONLY_BUILD
var infrastructureDependencies: [Target.Dependency] = ["QooKit", "CLibarchive"]

if !permissiveOnlyBuild {
    targets.append(
        // Scripts/build-unrar.sh が生成する xcframework。
        .binaryTarget(
            name: "unrarBinary",
            path: "ThirdParty/unrar/libunrar.xcframework"
        )
    )
    targets.append(
        // C++ interop を直接使わず、Objective-C++ ラッパー 1 ファイル
        // (QooUnrarBridge.mm) に UnRAR 呼び出しを閉じ込める [設計判断: ビルド
        // 安定性を優先。T-13 の検証結果で見直す]。Swift から見えるのは
        // include/QooUnrarBridge.h の素の C API のみ。
        .target(
            name: "QooUnrarBridge",
            dependencies: ["unrarBinary"]
        )
    )
    infrastructureDependencies.append("QooUnrarBridge")
}

targets.append(
    // MARK: - Infrastructure layer [A-01]
    // QooPersistence とは相互依存しない。
    .target(
        name: "QooInfrastructure",
        dependencies: infrastructureDependencies,
        swiftSettings: permissiveOnlyBuild ? [.define("PERMISSIVE_ONLY_BUILD")] : []
    )
)

targets.append(
    // MARK: - Application layer
    .target(
        name: "QooApplication",
        dependencies: ["QooKit", "QooPersistence", "QooInfrastructure"]
    )
)

targets.append(
    // MARK: - Tests
    .testTarget(
        name: "QooKitTests",
        dependencies: ["QooKit"]
    )
)

targets.append(
    .testTarget(
        name: "QooInfrastructureTests",
        dependencies: ["QooInfrastructure", "CLibarchive"]
    )
)

targets.append(
    .testTarget(
        name: "QooPersistenceTests",
        dependencies: ["QooPersistence"]
    )
)

targets.append(
    // 層をまたぐ統合テスト（16章 §16.1「統合」）。スキャンのように
    // QooInfrastructure と QooPersistence の両方を要するものはここへ置く
    // ——両者は相互依存しないため、片方のテストターゲットからは書けない [A-01]。
    .testTarget(
        name: "IntegrationTests",
        dependencies: ["QooInfrastructure", "QooPersistence", "QooKit"]
    )
)

targets.append(
    .testTarget(
        name: "QooApplicationTests",
        dependencies: ["QooApplication"]
    )
)

targets.append(
    // MARK: - Spikes (technical verification, kept per 16章 §16.6)
    // T-13 (zip/7z half): proves libarchive can be driven from Swift via
    // the CLibarchive wrapper to list and extract an archive.
    .executableTarget(
        name: "LibarchiveSpike",
        dependencies: ["CLibarchive"],
        path: "Spikes/LibarchiveSpike"
    )
)

if !permissiveOnlyBuild {
    targets.append(
        // T-13 (RAR half): proves QooUnrarBridge can list/extract a .rar
        // archive from Swift. Not built under PERMISSIVE_ONLY_BUILD, since
        // QooUnrarBridge doesn't exist there.
        .executableTarget(
            name: "UnrarSpike",
            dependencies: ["QooUnrarBridge"],
            path: "Spikes/UnrarSpike"
        )
    )
}

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
    dependencies: [
        // SQLite への薄いラッパー（MIT）。永続化層のみが使う [A-02]。
        // 採用理由と実測値は Spikes/README.md「T-03 / T-04: 永続化層の性能」。
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
