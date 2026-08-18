// swift-tools-version: 6.0
import PackageDescription

// T-03 / T-04 / PF-01〜PF-07 の実測スパイク。
// 本体の Package.swift からは独立させ、CI とアプリのビルドに影響させない。
let package = Package(
    name: "PersistenceSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "PersistenceSpike",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
