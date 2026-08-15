import Foundation

/// プロセスの実行環境についての判定を 1 箇所に集める。
enum RuntimeEnvironment {
    /// 実行中のプロセスがテストランナーかどうか。
    ///
    /// SwiftPM の Swift Testing（`swiftpm-testing-helper`）は `XCTest` の
    /// クラスも `XCTestConfigurationFilePath` 環境変数も持たないことを実測で
    /// 確認済みのため、プロセス名も判定材料に含めている。
    ///
    /// 用途は「テスト実行が開発機の実環境を汚さないようにする」こと:
    /// - `DiagnosticLog` … 実ログを一時ディレクトリへ振り替える（本物の
    ///   ログがテストのノイズで押し流されないように）
    /// - `SystemSoundPlayer` … 音を鳴らさない（テストのたびにゴミ箱音が
    ///   鳴るのを防ぐ）
    static var isRunningTests: Bool {
        let info = ProcessInfo.processInfo
        if info.environment["XCTestConfigurationFilePath"] != nil { return true }
        if ["xctest", "swiftpm-testing-helper"].contains(info.processName) { return true }
        return NSClassFromString("XCTestCase") != nil
    }
}
