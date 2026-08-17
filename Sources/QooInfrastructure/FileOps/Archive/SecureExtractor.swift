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
        // **飽和加算でなければならない**［フェーズ1完了時の監査で発見]。
        // 宣言サイズは攻撃者が自由に書けるため、素の `+` だと `Int64.max` 級の
        // 値を 2 つ並べたアーカイブでここがトラップし、拒否ではなくクラッシュに
        // なる。飽和させれば直後の空き容量比較が正しく拒否する。負の宣言値も
        // 0 に切り上げて、合計を意図的に小さく見せる細工を無効にする。
        let declaredTotal = listing.entries.reduce(Int64(0)) {
            $0.addingClamped(Swift.max(0, $1.uncompressedSize))
        }
        // 空き容量が分からないボリュームでは検査を飛ばす（`VolumeCapacity`
        // 参照 — 断る側に倒すと、空のディスクイメージのように
        // `…ForImportantUsage` が 0 を返す先へ展開できなくなる）。
        // 余裕分はボリュームの大きさに応じて縮める（既定 1GB をそのまま
        // 使うと、1GB 未満のボリュームへは何も展開できなくなる）。
        let destinationMargin = VolumeCapacity.margin(
            requested: options.limits.freeSpaceMargin, at: options.destination
        )
        if let available = Self.availableCapacity(at: options.destination),
           available < declaredTotal.addingClamped(destinationMargin) {
            throw ExtractError.insufficientFreeSpace(required: declaredTotal, available: available)
        }
        // **ステージング側の空きも確かめる**［監査で発見］。展開は必ず
        // いったんアプリコンテナ配下（＝起動ボリューム）へ書き出してから
        // 最終位置へ移す。展開先が外部ボリュームでも、**全量ぶんの空きが
        // 起動ボリュームに要る**のに、以前はそちらを一切見ていなかった。
        // その結果、起動ボリュームが手薄なときは検査を素通りしてから
        // 書き込みの途中で失敗していた（しかも当時は書き込みの失敗が
        // Objective-C 例外になり、アプリごと落ちていた）。
        //
        // 展開先とステージングが同じボリュームなら二重に要求しない。
        if !Self.isSameVolume(staging, options.destination),
           let stagingAvailable = Self.availableCapacity(at: staging),
           stagingAvailable < declaredTotal.addingClamped(VolumeCapacity.margin(
               requested: options.limits.freeSpaceMargin, at: staging
           )) {
            throw ExtractError.insufficientStagingSpace(
                required: declaredTotal, available: stagingAvailable
            )
        }

        // `listEntries` が既にエンコーディングを判定済み [AR-02]。呼び出し側が
        // 明示的に指定していなければその結果を使い、`extract` 側での再判定
        // （＝アーカイブの再走査）を避ける。
        var extractOptions = options
        if extractOptions.encoding == nil {
            extractOptions.encoding = listing.detectedEncoding
        }
        // バックエンドは総数を知らない（知るには一覧を読み直すことになる）。
        // ここは既に `listEntries` を済ませているので、その値を足して渡す。
        if let reporter = options.progress {
            extractOptions.progress = ProgressThrottle.wrap(
                reporter,
                totalItems: listing.entries.filter { !$0.isDirectory }.count,
                totalBytes: declaredTotal
            )
        }

        // 注釈はパスの**前**に置く（パスの直後に文字を続けない）。
        // ファイル名にはあらゆる文字が入り得るため、パスの後ろに注釈を足すと
        // 匿名化がどこまでがパスなのかを判断しにくくなる [LG2-06]。
        Log.archive.info(
            "展開開始（\(format) / \(listing.entries.count) エントリ / エンコーディング \(extractOptions.encoding.map(String.init(describing:)) ?? "自動")）: \(Log.path(archiveURL)) → \(Log.path(options.destination))"
        )

        let result = try await backend.extract(archiveURL, to: staging, options: extractOptions)
        if Cancellation.isRequested { throw ExtractError.cancelled } // [EX-24]

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

        // 移送にも進捗を流す [UI-09]。ステージングは常にアプリコンテナ配下
        // （＝起動ボリューム）なので、展開先が外部ボリュームなら**ここは実
        // コピーになり数秒かかる**。流さないと、エントリを出し終えた 100% の
        // ままバーが止まって見える（実機で確認）。件数・バイト数は移送側の
        // 総量で数え直される（展開とは別の段階なので、それが素直）。
        let receipts = try await fileOps.promoteFromStaging(
            staging, to: options.destination,
            options: OpOptions(
                conflictPolicy: .keepBoth, progress: options.progress, pauseToken: options.pauseToken
            )
        )

        // **移送の途中で中断されたら、出しかけた分を片付ける**［実機検証で発見]。
        // `transfer` は中断時に「そこまで運び終えた分」を返す設計 [ER-16 の
        // 精神] で、コピーや移動ではそれが正しい（運んだものは残したい）。
        // だが展開では、ユーザーが止めたのに 20MB ぶんの中途半端なフォルダが
        // 残り、しかも成功として扱われていた。ここで作ったものは
        // `.keepBoth` で必ず新規に作った項目なので、消しても既存のファイルを
        // 巻き込まない。完全削除ではなくゴミ箱へ送る（取り違えても戻せる）。
        if Cancellation.isRequested {
            let created = receipts.map(\.toURL)
            if !created.isEmpty {
                Log.archive.info("展開を中断したため、出しかけた \(created.count) 件を片付けます")
                _ = try? await fileOps.trash(created)
            }
            throw ExtractError.cancelled
        }

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

    private static func availableCapacity(at url: URL) -> Int64? {
        VolumeCapacity.available(at: url)
    }

    /// 2 つの場所が同じボリュームか。判定できなければ「違う」とみなす
    /// （空き容量を二重に要求する側＝安全側に倒す）。`.volumeURLKey` ではなく
    /// `.volumeUUIDStringKey` を使うのは、サンドボックス配下の経路で前者の
    /// 解決に失敗することがあったため [1-6 の D&D で実際に踏んだ]。
    private static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard
            let idA = VolumeIdentity.identifier(for: a),
            let idB = VolumeIdentity.identifier(for: b)
        else { return false }
        return idA == idB
    }
}
