import Foundation
import QooKit

/// 展開の司令塔 [9.3 節]。ステージングの作成・後始末、空き容量の事前確認
/// [EX-23]、バックエンドへの委譲、最終位置への移送（`FileOperationService`
/// 経由 [FO-01][EX-04]）を行う。エントリ単位の安全検証（EX-10〜EX-15）と
/// 展開爆弾対策（EX-20〜EX-21）はバックエンド側（`LibarchiveBackend`/
/// `UnrarBackend`）が担う。
///
/// ステージングディレクトリ自体の作成・削除はユーザーに見えないアプリ内部の
/// 一時領域に対する操作であり、期待変更台帳・Undo・操作履歴（いずれも
/// `FileOperationService` の存在理由）の対象外のため、`FileOperationService`
/// を経由しない [VolumeEligibilityChecker と同様の意図的な例外]。ユーザーの
/// 見える最終位置への移送だけは `FileOperationService.promoteFromStaging`
/// を必ず経由する。この理由により、本ファイル（および同じ事情を持つ
/// `LibarchiveBackend`/`UnrarBackend`）は FileOps 隔離検査（B-10）の対象外
/// ディレクトリ（`QooInfrastructure/FileOps/`）配下に置く。
public actor SecureExtractor {
    public static let shared = SecureExtractor()

    private let fileOps: FileOperationService
    /// テスト用に差し替え可能（既定は実際のアプリコンテナ配下）。共有の
    /// `stagingRoot()` をテストが直接使うと、他のテストスイートと並行実行
    /// された際に同じ実ディレクトリを取り合って不安定になる（CI で実際に
    /// 発生した）ため、インスタンスごとに独立したディレクトリを注入できる
    /// ようにしている。
    private let stagingRoot: URL

    /// 1 回の展開でログに書き出す拒否エントリの上限（`extract` のコメント参照）。
    static let rejectionLogLimit = 20

    public init(fileOps: FileOperationService = .shared, stagingRoot: URL = SecureExtractor.defaultStagingRoot()) {
        self.fileOps = fileOps
        self.stagingRoot = stagingRoot
    }

    /// アーカイブを展開し、`options.destination` へ移送する。失敗時・
    /// キャンセル時はステージングを残さない [EX-24]。
    public func extract(_ archiveURL: URL, options: ExtractOptions) async throws -> ExtractResult {
        guard let format = ArchiveFormat.from(filename: archiveURL.lastPathComponent) else {
            throw ExtractError.unsupportedFormat
        }
        let backend = ArchiveBackendRegistry.reader(for: format)
        guard await backend.canRead(archiveURL) else {
            throw ExtractError.unsupportedFormat
        }

        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // 成功時は `promoteFromStaging` が中身を移送済みで空の殻だけが残り、
        // 失敗時は展開途中の中身が残っている。どちらにせよステージング自体は
        // 必ず削除する [EX-03][EX-24]。
        defer {
            try? FileManager.default.removeItem(at: staging)
        }

        // 展開前チェック: 宣言された非圧縮サイズの合計と展開先の空き容量を
        // 比較する [EX-23]。実際の展開爆弾対策（実バイト数での判定）は
        // バックエンド内部で別途行う。
        let listing = try await backend.listEntries(archiveURL)
        if listing.entries.count > options.limits.maxEntries { // [EX-21]
            throw ExtractError.tooManyEntries(limit: options.limits.maxEntries)
        }
        let declaredTotal = listing.entries.reduce(Int64(0)) { $0 + $1.uncompressedSize }
        let available = Self.availableCapacity(at: options.destination)
        if available < declaredTotal + options.limits.freeSpaceMargin {
            throw ExtractError.insufficientFreeSpace(required: declaredTotal, available: available)
        }

        // `listEntries` が既にエンコーディングを判定済み [AR-02]。呼び出し側が
        // 明示的に指定していなければその結果を使い、`extract` 側での再判定
        // （＝アーカイブの再走査）を避ける。
        var extractOptions = options
        if extractOptions.encoding == nil {
            extractOptions.encoding = listing.detectedEncoding
        }

        // 注釈はパスの**前**に置く（パスの直後に文字を続けない）。
        // ファイル名にはあらゆる文字が入り得るため、パスの後ろに注釈を足すと
        // 匿名化がどこまでがパスなのかを判断しにくくなる [LG2-06]。
        Log.archive.info(
            "展開開始（\(format) / \(listing.entries.count) エントリ / エンコーディング \(extractOptions.encoding.map(String.init(describing:)) ?? "自動")）: \(Log.path(archiveURL)) → \(Log.path(options.destination))"
        )

        let result = try await backend.extract(archiveURL, to: staging, options: extractOptions)
        if Task.isCancelled { throw ExtractError.cancelled } // [EX-24]

        // 弾いたエントリ（パストラバーサル・絶対パス・シンボリックリンク等）は
        // ユーザーには件数しか見えないため、**何をなぜ弾いたか**をログに残す
        // [EX-10〜EX-15]。壊れた／悪意あるアーカイブの調査に直結する。
        //
        // **件数に上限を設ける**: 拒否は最大 `maxEntries`（既定 10 万件）まで
        // 起こり得る。全件書くと 1 つの細工されたアーカイブだけで数 MB の
        // ログが出て、ローテーションによって**まさに調べたい直前の履歴を
        // 押し流してしまう** [LG2-04]。原因の特定には先頭の数件で足りる。
        // エントリ名はアーカイブ内の名前で絶対パスではないため、匿名化の
        // 対象になるよう印を付ける [LG2-06]。
        for rejection in result.rejected.prefix(Self.rejectionLogLimit) {
            Log.archive.warning("展開時にエントリを拒否（\(rejection.reason)）: \(Log.redactable(rejection.entry))")
        }
        if result.rejected.count > Self.rejectionLogLimit {
            Log.archive.warning(
                "展開時の拒否は全 \(result.rejected.count) 件。ログには先頭 \(Self.rejectionLogLimit) 件のみ記録しました"
            )
        }

        let receipts = try await fileOps.promoteFromStaging(
            staging, to: options.destination, options: OpOptions(conflictPolicy: .keepBoth)
        )

        Log.archive.info(
            "展開完了（\(result.extractedCount) 件 / \(result.totalBytesWritten) バイト / 拒否 \(result.rejected.count) 件 / 改名 \(result.renamedForCaseCollision.count) 件）: \(Log.path(archiveURL))"
        )

        return ExtractResult(
            extractedCount: result.extractedCount,
            rejected: result.rejected,
            renamedForCaseCollision: result.renamedForCaseCollision,
            totalBytesWritten: result.totalBytesWritten,
            createdURLs: receipts.map(\.toURL) // [1-11、`ExtractCommand` の Undo 用]
        )
    }

    // MARK: - ステージング [EX-01][EX-03][CL-01]

    /// アプリコンテナ配下（サンドボックス外を汚さない）。
    public static func defaultStagingRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("qooLibrary", isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
    }

    /// 異常終了後の次回起動時に残存ステージングを削除する [RB-07][EX-03]。
    /// 常に実際のアプリコンテナ配下（`defaultStagingRoot()`）が対象。
    /// テスト用の `stagingRoot` 差し替えとは無関係（起動時に一度だけ呼ばれる
    /// グローバルな後始末のため）。
    public static func cleanupResidualStaging() async {
        let root = defaultStagingRoot()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for child in children {
            // ステージングはユーザー非可視のアプリ内部領域のため、ロック済みでも
            // 尋ねずに消す（`.unattended` のコメント参照）。既定の
            // `DeletePermanentlyOptions()` だとロック済み項目がスキップされ、
            // 残骸が永久に残ってしまう。
            _ = try? await FileOperationService.shared.deletePermanently([child], options: .unattended)
        }
    }

    private static func availableCapacity(at url: URL) -> Int64 {
        // 展開先がまだ存在しない場合は、存在する祖先ディレクトリまで遡る。
        var target = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        let values = try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
