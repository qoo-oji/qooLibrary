import Foundation
import Testing

@testable import QooInfrastructure

/// **失敗の理由がユーザーに伝わること**を固定する [ER-03]。
///
/// 実機で、空き 2.8GB のボリュームへ 4GB のファイルをコピーして失敗したとき、
/// ダイアログにもログにも
/// 「操作を完了できませんでした。（QooInfrastructure.FileOperationError エラー2）」
/// としか出ず、**容量不足だと分からなかった**。原因は `FileOperationError` が
/// `LocalizedError` に準拠しておらず、payload に入れていた説明が
/// `localizedDescription` に出ていなかったこと。
///
/// この suite は「エラーN」形式へ戻る退行を捕まえる。文言そのものより、
/// **原因を名指しできているか**を見ている。
@Suite struct FileOperationErrorMessageTests {
    /// 既定文言（`… エラー2` の形）へ戻っていないこと。
    private func expectNotTheFallback(_ error: FileOperationError, sourceLocation: SourceLocation = #_sourceLocation) {
        let message = error.localizedDescription
        #expect(!message.contains("FileOperationError"), "型名が出ている: \(message)", sourceLocation: sourceLocation)
        #expect(!message.isEmpty, sourceLocation: sourceLocation)
    }

    @Test func insufficientFreeSpaceNamesTheShortfall() {
        let error = FileOperationError.insufficientFreeSpace(
            required: 4_000_000_000,
            available: 2_800_000_000,
            destination: URL(fileURLWithPath: "/Volumes/QooDst/bbb")
        )
        expectNotTheFallback(error)
        let message = error.localizedDescription
        #expect(message.contains("空き容量"))
        #expect(message.contains("bbb"))
        // 必要量と空き容量の両方を数字で示す（どれだけ足りないかが分かる）。
        #expect(message.contains("4") && message.contains("2"))
    }

    /// 書き始めた後に容量が尽きた場合（事前検査を通り抜けた場合）も、
    /// errno から容量不足だと言えること。
    @Test func copyFailureExplainsDiskFull() {
        let error = FileOperationError.copyFailed(
            source: URL(fileURLWithPath: "/Volumes/QooSrc/huge.bin"),
            destination: URL(fileURLWithPath: "/Volumes/QooDst/bbb/huge.bin"),
            errnoCode: ENOSPC
        )
        expectNotTheFallback(error)
        #expect(error.localizedDescription.contains("空き容量"))
        #expect(error.localizedDescription.contains("huge.bin"))
    }

    @Test func copyFailureExplainsPermission() {
        let error = FileOperationError.copyFailed(
            source: URL(fileURLWithPath: "/tmp/a.txt"),
            destination: URL(fileURLWithPath: "/tmp/locked/a.txt"),
            errnoCode: EACCES
        )
        expectNotTheFallback(error)
        #expect(error.localizedDescription.contains("権限"))
    }

    /// 知らない errno でも、少なくとも対象名と system の説明は出す。
    @Test func copyFailureFallsBackToTheSystemReason() {
        let error = FileOperationError.copyFailed(
            source: URL(fileURLWithPath: "/tmp/a.txt"),
            destination: URL(fileURLWithPath: "/tmp/b.txt"),
            errnoCode: EIO
        )
        expectNotTheFallback(error)
        #expect(error.localizedDescription.contains("a.txt"))
    }

    @Test func everyCaseHasItsOwnDescription() {
        let cases: [FileOperationError] = [
            .conflictResolutionRequired(
                source: URL(fileURLWithPath: "/tmp/a.txt"),
                destination: URL(fileURLWithPath: "/tmp/b.txt")
            ),
            .operationFailed("独自のメッセージ"),
            .copyFailed(
                source: URL(fileURLWithPath: "/tmp/a.txt"),
                destination: URL(fileURLWithPath: "/tmp/b.txt"),
                errnoCode: ENOSPC
            ),
            .insufficientFreeSpace(
                required: 10, available: 1, destination: URL(fileURLWithPath: "/tmp")
            ),
        ]
        for error in cases { expectNotTheFallback(error) }
        // payload の文字列はそのまま出す（既存の呼び出し元が説明を入れている）。
        #expect(FileOperationError.operationFailed("独自のメッセージ").localizedDescription == "独自のメッセージ")
    }
}
