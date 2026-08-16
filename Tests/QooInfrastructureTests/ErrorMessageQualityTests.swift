import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **ユーザーに見えるすべての失敗が、三要素で説明されていること** [ER-03]。
///
/// ## この suite の役割
/// 個々の文言の良し悪しは人が読んで決めるしかない。ここが固定するのは、
/// **読まなくても機械的に判定できる性質**だけ:
///
/// - 「エラーN」形式（型名が出る既定文言）へ落ちていない
/// - 何が／なぜ が空でない
/// - **英語の生メッセージが本文に混ざっていない**（`strerror` や
///   libarchive の文言は `technicalDetail` へ回す約束）
/// - 対処を示せるものは示している
///
/// ## 新しいケースを足したときに漏れない仕組み
/// `UserPresentableError` が三要素と技術詳細を**型として要求する**ので、
/// ケースを足せばコンパイラが `switch` の網羅性で書き忘れを止める。
/// この suite はそのうえで「書いた内容が最低限の質を満たすか」を見る。
/// **新しいケースを足したら、下の一覧にも足すこと。**
@Suite struct ErrorMessageQualityTests {
    private let src = URL(fileURLWithPath: "/Volumes/USB/作品名 第01巻.cbz")
    private let dst = URL(fileURLWithPath: "/Volumes/USB/保存先/作品名 第01巻.cbz")
    private let folder = URL(fileURLWithPath: "/Volumes/USB/保存先")

    /// `NotificationRouter.presentError` と同じ規則で本文を組む
    /// （表示されるものそのものを検査するため）。
    private func body(_ error: any UserPresentableError) -> String {
        var parts = [error.whatHappened, error.whyItHappened]
        if error.recoverySuggestions.isEmpty, let hint = error.recoveryHint { parts.append(hint) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 本文に混ざってはいけない断片。英語の system メッセージと型名。
    private func expectPresentable(
        _ error: any UserPresentableError,
        label: String,
        needsRecovery: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let text = body(error)
        #expect(!text.isEmpty, "\(label): 本文が空", sourceLocation: sourceLocation)
        #expect(!error.whatHappened.isEmpty, "\(label): 何が起きたかが空", sourceLocation: sourceLocation)
        for forbidden in ["Error", "error 0", "エラー0", "エラー1", "エラー2"] {
            #expect(
                !text.contains(forbidden),
                "\(label): 本文に「\(forbidden)」が混ざっている → \(text)",
                sourceLocation: sourceLocation
            )
        }
        // `strerror` の英語が本文に出ていないこと（技術詳細へ回す約束）。
        for english in ["No space left", "Permission denied", "Read-only file system",
                        "File too large", "Unknown error", "Write error"] {
            #expect(
                !text.contains(english),
                "\(label): 英語の system メッセージが本文に出ている → \(text)",
                sourceLocation: sourceLocation
            )
        }
        if needsRecovery {
            #expect(
                error.recoveryHint?.isEmpty == false || !error.recoverySuggestions.isEmpty,
                "\(label): 次に何ができるかが無い",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - ファイル操作

    @Test func everyFileOperationErrorExplainsItself() {
        let cases: [(String, FileOperationError, Bool)] = [
            ("sourceNotFound", .sourceNotFound(src), true),
            ("conflictResolutionRequired", .conflictResolutionRequired(source: src, destination: dst), true),
            // 自由文の受け皿。呼び出し側がすでに完結した文を入れている。
            ("operationFailed", .operationFailed("「新規フォルダ」という名前の項目はすでに存在します。"), false),
            ("copyFailed/ENOSPC", .copyFailed(source: src, destination: dst, errnoCode: ENOSPC), true),
            ("copyFailed/EACCES", .copyFailed(source: src, destination: dst, errnoCode: EACCES), true),
            ("copyFailed/EROFS", .copyFailed(source: src, destination: dst, errnoCode: EROFS), true),
            ("copyFailed/ENOENT", .copyFailed(source: src, destination: dst, errnoCode: ENOENT), true),
            ("copyFailed/EFBIG", .copyFailed(source: src, destination: dst, errnoCode: EFBIG), true),
            ("copyFailed/ENAMETOOLONG", .copyFailed(source: src, destination: dst, errnoCode: ENAMETOOLONG), true),
            // 原因を名指しできない errno でも、本文に英語を出さないこと。
            ("copyFailed/未知", .copyFailed(source: src, destination: dst, errnoCode: 9999), false),
            ("insufficientFreeSpace", .insufficientFreeSpace(required: 4_000_000_000, available: 2_800_000_000, destination: folder), true),
            ("destinationInsideSource", .destinationInsideSource(source: folder, destination: folder.appendingPathComponent("中")), true),
            ("destinationIsReadOnly", .destinationIsReadOnly(folder), true),
            ("invalidName/セパレータ", .invalidName("親/子", reason: .forbiddenCharacter("/")), true),
            ("invalidName/空", .invalidName("", reason: .empty), true),
            ("invalidName/予約", .invalidName("..", reason: .reservedDotName), true),
            ("invalidName/長すぎ", .invalidName("あ", reason: .tooLong(units: 300)), true),
            ("sourceChangedDuringOperation", .sourceChangedDuringOperation(src), true),
            ("nameTooLongForDestination", .nameTooLongForDestination(name: "あ", item: src, length: 304, limit: 255, unitIsBytes: true), true),
            ("fileTooLargeForDestination", .fileTooLargeForDestination(item: src, size: 5_000_000_000, limit: 4_294_967_295, destination: folder), true),
            ("pathTooLong", .pathTooLong(item: src, destination: folder, resultingBytes: 1100, limitBytes: 1023), true),
        ]
        for (label, error, needsRecovery) in cases {
            expectPresentable(error, label: label, needsRecovery: needsRecovery)
        }
    }

    /// 数字で示せるものは数字で示すこと（「足りません」だけでは、どれだけ
    /// 空ければよいのか分からない）。
    @Test func shortagesAreExpressedWithNumbers() {
        let error = FileOperationError.insufficientFreeSpace(
            required: 4_000_000_000, available: 2_800_000_000, destination: folder
        )
        #expect(error.whyItHappened.contains("4"))
        #expect(error.whyItHappened.contains("2.8"))
    }

    /// 技術詳細は**本文ではなく**技術詳細として運ばれること。
    @Test func systemDetailIsCarriedSeparately() {
        let error = FileOperationError.copyFailed(source: src, destination: dst, errnoCode: ENOSPC)
        let detail = try? #require(error.technicalDetail)
        #expect(detail?.contains("errno 28") == true)
        #expect(detail?.contains("No space left") == true)
        #expect(!body(error).contains("errno"))
    }

    // MARK: - 圧縮・展開

    @Test func everyExtractErrorExplainsItself() {
        let cases: [(String, ExtractError, Bool)] = [
            ("unsupportedFormat", .unsupportedFormat, true),
            ("passwordProtected", .passwordProtected, true),
            ("incorrectPassphrase", .incorrectPassphrase, true),
            ("insufficientFreeSpace", .insufficientFreeSpace(required: 8_000_000_000, available: 1_000_000_000), true),
            ("insufficientStagingSpace", .insufficientStagingSpace(required: 8_000_000_000, available: 1_000_000_000), true),
            ("tooManyEntries", .tooManyEntries(limit: 100_000), true),
            ("expansionLimitExceeded", .expansionLimitExceeded(limit: 20_000_000_000), true),
            ("compressionRatioExceeded", .compressionRatioExceeded(limit: 1000), true),
            // 中断はユーザー自身の操作。次の手を促さない。
            ("cancelled", .cancelled, false),
            ("writeFailed", .writeFailed(reason: PosixFailure.reason(ENOSPC)), false),
            ("backendFailure", .backendFailure("Write error"), true),
            ("entryNotFound", .entryNotFound("cover.jpg"), true),
            ("entryReadLimitExceeded", .entryReadLimitExceeded(limit: 512_000_000), false),
        ]
        for (label, error, needsRecovery) in cases {
            expectPresentable(error, label: label, needsRecovery: needsRecovery)
        }
    }

    /// 中断は失敗ではないので、割り込んで見せない [ER-01]。
    @Test func cancellationIsNotPresentedAsAFailure() {
        #expect(ExtractError.cancelled.severity == .logOnly)
    }

    /// libarchive/UnRAR の英語は技術詳細へ回すこと。
    @Test func libraryMessagesStayOutOfTheBody() {
        let error = ExtractError.backendFailure("Truncated zip archive")
        #expect(!body(error).contains("Truncated"))
        #expect(error.technicalDetail == "Truncated zip archive")
    }

    /// 上限は桁区切りで読ませること（「100000 件」は読みにくい）。
    @Test func limitsAreGrouped() {
        #expect(ExtractError.tooManyEntries(limit: 100_000).whyItHappened.contains("100,000"))
    }

    // MARK: - 登録・アクセス権

    @Test func everyRegistrationErrorExplainsItself() {
        expectPresentable(RegisteredFolderError.nestedRegistration, label: "nested")
        expectPresentable(
            RegisteredFolderError.unsupportedFileSystem(.noPersistentFileID(fileSystem: "SMB (OS X)")),
            label: "unsupportedFS"
        )
        expectPresentable(VolumeEligibilityError.readOnlyVolume(fileSystem: "APFS"), label: "readOnly")
        expectPresentable(VolumeEligibilityError.probeSetupFailed(errnoCode: EACCES), label: "probeFailed")
    }

    /// 登録の可否を調べる場面で「書き込み先」と言わないこと（文脈が違う）。
    @Test func registrationTalksAboutTheItemNotADestination() {
        let error = VolumeEligibilityError.probeSetupFailed(errnoCode: EACCES)
        #expect(!error.whyItHappened.contains("書き込み先"))
    }

    // MARK: - POSIX の翻訳

    /// よく出る `errno` はすべて日本語で理由を言えること。
    @Test(arguments: [ENOSPC, EDQUOT, EROFS, EACCES, EPERM, ENOENT, EEXIST, ENOTDIR,
                      EISDIR, ENAMETOOLONG, ELOOP, EXDEV, EBUSY, EMFILE, EFBIG, EIO, ENOTEMPTY, EINVAL])
    func everyCommonErrnoHasAJapaneseReason(_ code: Int32) {
        let reason = PosixFailure.reason(code)
        #expect(!reason.isEmpty)
        #expect(!reason.contains("Error"), "英語が出ている: \(reason)")
    }

    /// ユーザーが手を打てる `errno` には対処があること。
    @Test(arguments: [ENOSPC, EDQUOT, EROFS, EACCES, EPERM, ENOENT, EEXIST, ENAMETOOLONG, EBUSY, EFBIG])
    func actionableErrnosOfferANextStep(_ code: Int32) {
        #expect(PosixFailure.recovery(code)?.isEmpty == false, "対処が無い: errno \(code)")
    }

    /// **ネットワークボリュームの `errno` を「不明」に落とさない** [NV-47]。
    ///
    /// 1-16b までこの区分の翻訳が 1 つも無く、**ネットワークでいちばん頻度の
    /// 高い失敗（切断・無応答）がいちばん説明されない**状態だった。
    /// ネットワークでは切断が例外ではなく通常状態である（8章 §8.11）。
    @Test(arguments: [ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH,
                      ECONNRESET, ECONNABORTED, EPIPE, ESTALE, ENOTSUP, EINTR, EAUTH])
    func networkErrnosAreExplainedAndActionable(_ code: Int32) {
        let reason = PosixFailure.reason(code)
        #expect(!reason.contains("原因を特定できない"), "既定の文言に落ちている: errno \(code)")
        #expect(!reason.contains("Error"), "英語が出ている: \(reason)")
        #expect(PosixFailure.recovery(code)?.isEmpty == false, "対処が無い: errno \(code)")
    }
}
