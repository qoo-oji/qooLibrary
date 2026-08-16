import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **実際のネットワーク共有に対して、1-16b の実装が期待どおりに振る舞うか**を
/// 確かめる統合テスト [8章 §8.11]。
///
/// ## なぜ環境変数で opt-in にするのか
/// ネットワーク共有はテストから用意できない（`TinyVolume` のようにその場で
/// 作れない）。かといって「マウントされている共有があれば勝手に使う」形に
/// すると、**たまたまマウントされていた誰かの本番共有へ書き込む**ことに
/// なる。`QOO_NETWORK_TEST_VOLUME` に共有上の**使い捨てにしてよい場所**を
/// 明示してもらったときだけ走らせる。
///
/// ```
/// QOO_NETWORK_TEST_VOLUME=/Volumes/Private swift test --filter NetworkVolume
/// ```
///
/// ## 何を守るためのテストか
/// SMB は本アプリが実際に使われる主要な場所でありながら、ローカルとは
/// 意味論が違う（`volumeUUIDString` が nil、ゴミ箱が無い、delete-on-close）。
/// **ローカルで緑でも SMB で壊れる**経路が実在するため、環境がある開発機では
/// これを回しておきたい。
@Suite(.serialized) struct NetworkVolumeIntegrationTests {

    // MARK: - 使い捨ての作業場

    /// 共有の上に使い捨てのフォルダを作り、終わったら必ず消す。
    /// **既存のデータには一切触れない。**
    private struct Workspace: ~Copyable {
        let root: URL
        init?() {
            guard let base = ProcessInfo.processInfo.environment["QOO_NETWORK_TEST_VOLUME"],
                  !base.isEmpty
            else { return nil }
            let root = URL(fileURLWithPath: base)
                .appendingPathComponent(".qoo-probe-\(UUID().uuidString)")
            guard (try? FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)) != nil
            else { return nil }
            self.root = root
        }
        /// **後片付けも試し直す。** 共有の上では削除が一過性に失敗するため
        /// （実測 5 回に 1 回）、`try?` 1 回だと**検証のたびに使い捨てフォルダが
        /// 相手の共有に溜まっていく**。実際に 4 つ残して気づいた——製品側の
        /// 不具合を、まず自分の後始末が踏んだ形になった。
        deinit {
            // **`fileExists` で成否を判定しない。** SMB は dirent を最大 30 秒
            // キャッシュするので、削除に失敗していても古い `false` が返り、
            // 「消した」つもりで相手の共有に残る（実際に踏んだ）。
            if let error = removeThrowawayDirectory(at: root) {
                FileHandle.standardError.write(Data(
                    "[NetworkVolumeIntegrationTests] 使い捨てフォルダを消せませんでした: \(root.path) — \(error)\n".utf8))
            }
        }

        @discardableResult
        func write(_ name: String, bytes: Int = 64) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(repeating: 0x51, count: bytes).write(to: url)
            return url
        }
    }

    /// この共有がそもそもネットワークか（ローカルを指定されていたら
    /// 検証の意味が変わるので、前提として確かめる）。
    private static func isNetwork(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
    }

    // MARK: - NV3-01 ボリュームの識別

    /// **ネットワーク共有が、起動ボリュームと別のボリュームとして識別できること。**
    ///
    /// ここが壊れていると（以前の `?? ""`）、共有上のファイルと起動ボリューム上の
    /// ファイルが同じ `FileIdentity` になり、**別の作品の表紙が出る**。
    @Test func theShareIsIdentifiedApartFromTheBootVolume() throws {
        guard let workspace = Workspace() else { return }
        #expect(Self.isNetwork(workspace.root), "指定された場所がネットワークではない")

        let identifier = try #require(VolumeIdentity.identifier(for: workspace.root))
        #expect(!identifier.isEmpty)
        let boot = try #require(VolumeIdentity.identifier(for: URL(fileURLWithPath: "/")))
        #expect(identifier != boot, "共有が起動ボリュームと同一視されている [NV3-01]")

        // 3 系統すべてで `volumeUUIDString` は nil だった（§8.11.2）。
        // 将来 macOS が返すようになったら前提が変わったと分かるようにしておく。
        let uuid = try? workspace.root
            .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        if uuid == nil {
            #expect(identifier.hasPrefix("net-"), "マウント元からの導出になっていない")
        }
    }

    /// **同じ共有の中の 2 つの場所は、同じボリュームだと分かること。**
    ///
    /// これが D&D の既定を決める（同一ボリュームなら移動、異なれば複製）。
    /// 以前はここが崩れていたため、**同一共有内のドラッグが移動ではなく
    /// 複製になっていた** — 4GB ならサーバ側の改名 1 回で済むはずのものが
    /// 全バイトの往復になる。
    @Test func twoPlacesInTheSameShareAgreeOnTheVolume() throws {
        guard let workspace = Workspace() else { return }
        let nested = workspace.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let a = try #require(VolumeIdentity.identifier(for: workspace.root))
        let b = try #require(VolumeIdentity.identifier(for: nested))
        #expect(a == b, "同一共有内で識別子が食い違う（D&D が複製に落ちる）")
    }

    /// **共有の中の別々のファイルは、別々の `FileIdentity` になること。**
    @Test func distinctFilesGetDistinctIdentities() throws {
        guard let workspace = Workspace() else { return }
        let one = try workspace.write("one.bin")
        let two = try workspace.write("two.bin")
        let idOne = try FileMetadata.identity(of: one)
        let idTwo = try FileMetadata.identity(of: two)
        #expect(idOne != idTwo, "別ファイルが同じ FileIdentity になっている")
    }

    /// **[NV3-03 の実地確認] 削除→同名で作り直したとき、同一性が再利用されるか。**
    ///
    /// Samba は `st_ino` をパス名から合成するため、ここで**同じ値が返る**
    /// （＝別のファイルが同一と判定される）。これは直せないと結論している
    /// 事象なので、テストは「どちらであっても失敗させない」。代わりに
    /// **キャッシュの鍵である `FileContentStamp` が実際に区別できているか**を
    /// 確かめる — そこが守れていればサムネイルの取り違えは起きない。
    @Test func recreatingTheSameNameIsDistinguishedByTheContentStamp() throws {
        guard let workspace = Workspace() else { return }
        let url = try workspace.write("recycled.bin", bytes: 64)
        let first = try FileMetadata.stamp(of: url)

        try FileManager.default.removeItem(at: url)
        // 大きさを変えて作り直す。Samba では identity が再利用され得るが、
        // stamp（identity + 更新日時 + サイズ）は区別できなければならない。
        try Data(repeating: 0x52, count: 128).write(to: url)
        let second = try FileMetadata.stamp(of: url)

        #expect(first != second, "内容の版を区別できていない（表紙の取り違えが起きる）")
    }

    // MARK: - NV4-01 ゴミ箱

    /// **共有にゴミ箱が無いことを、速く・確実に判定できること。**
    ///
    /// ここが誤ると `NSWorkspace.recycle` が呼ばれ、**macOS のシステム
    /// ダイアログを経て完全削除**になる（アプリの確認シートを通らない）。
    @Test func theShareIsRecognizedAsHavingNoTrash() throws {
        guard let workspace = Workspace() else { return }
        let file = try workspace.write("victim.bin")
        let started = Date()
        let hasTrash = TrashAvailability.hasTrash(for: file)
        let elapsed = Date().timeIntervalSince(started)
        // 実測では SMB 3 系統すべてで「無い」。ある環境（AFP・ネットワーク
        // ホーム）も文献上あり得るので、真偽そのものは断定しない。
        // **速いこと**は判定を毎回行う前提なので必ず守られていてほしい。
        #expect(elapsed < 1.0, "ゴミ箱の判定に時間がかかりすぎる: \(elapsed)s")
        if !hasTrash {
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    /// **ゴミ箱が無い共有で `trash` を呼んでも、`recycle` へ進まないこと** [NV4-01]。
    ///
    /// 進んでしまうと UI 文脈の無いプロセスでは完了ハンドラが永久に呼ばれず、
    /// UI のある本体ではユーザーが意図しないシステムダイアログが出る。
    @Test func trashRefusesInsteadOfFallingThroughToRecycle() async throws {
        guard let workspace = Workspace() else { return }
        let file = try workspace.write("victim.bin")
        guard !TrashAvailability.hasTrash(for: file) else { return } // ある環境では対象外

        let service = FileOperationService()
        await #expect(throws: FileOperationError.self) {
            _ = try await service.trash([file])
        }
        #expect(FileManager.default.fileExists(atPath: file.path), "拒否したのに消えている")
    }

    // MARK: - 書き込み先の事前検査

    /// **`access(2)` が共有に対して正しく答えること** [NV-89]。
    @Test func writabilityIsAnsweredForTheShare() throws {
        guard let workspace = Workspace() else { return }
        // 作業場を作れている時点で書けるはず。`access` もそう答えること。
        #expect(access(workspace.root.path, W_OK) == 0)
    }

    /// **名前とパスの上限が、共有の規則で答えられること。**
    @Test func lengthLimitsAreReportedForTheShare() throws {
        guard let workspace = Workspace() else { return }
        let pathLimit = PathLimits.maxPathBytes(at: workspace.root)
        #expect(pathLimit > 0, "パス長の上限が得られない")

        // SMB は UTF-8 で 255 バイト（実測）。規則が得られない形式もあるので
        // 存在しないこと自体は失敗にしない。
        if let rule = NameLengthLimit.rule(forVolumeAt: workspace.root) {
            #expect(rule.maximum > 0)
        }
    }

    /// **空き容量が得られること** [`VolumeCapacity` の 0 フォールバック]。
    ///
    /// 実測では SMB 3 系統すべてで `...ForImportantUsage` が **0** を返す。
    /// そのまま信じると「空きゼロ」と解釈して**あらゆるコピーを断ってしまう**。
    @Test func freeSpaceIsReportedDespiteTheImportantUsageKeyReturningZero() throws {
        guard let workspace = Workspace() else { return }
        let available = try #require(
            VolumeCapacity.available(at: workspace.root),
            "空き容量が得られない（すべての書き込みが断られる）"
        )
        #expect(available > 0, "空き 0 と報告されている [VolumeCapacity のフォールバック]")
    }

    // MARK: - 実際のファイル操作

    /// **同一共有内の移動が、実際に成功して受領書を返すこと。**
    @Test func movingWithinTheShareSucceeds() async throws {
        guard let workspace = Workspace() else { return }
        let destination = workspace.root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = try workspace.write("moving.bin")

        let service = FileOperationService()
        let receipts = try await service.move([file], to: destination, options: .init(conflictPolicy: .keepBoth))

        #expect(receipts.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path), "移動元が残っている")
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("moving.bin").path), "移動先に無い")
    }

    /// **`.replace` が共有上でも「退避してから書く」を守り、退避を残さないこと**
    /// [NV-92]。
    ///
    /// 共有上に `.qoo-replace-backup-*` が残ると、ユーザーから見れば
    /// **元ファイルが消えたのと同じ**になる。
    @Test func replaceOnTheShareLeavesNoBackupBehind() async throws {
        guard let workspace = Workspace() else { return }
        let destination = workspace.root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("same.bin")
        try Data(repeating: 0x41, count: 32).write(to: existing)
        let incoming = try workspace.write("same.bin", bytes: 64)

        let service = FileOperationService()
        _ = try await service.copy([incoming], to: destination, options: .init(conflictPolicy: .replace))

        let after = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(after == ["same.bin"], "退避ファイルが残っている: \(after)")
        let bytes = try Data(contentsOf: existing)
        #expect(bytes.count == 64, "置き換わっていない")
    }

    /// **中身のあるフォルダの完全削除が、繰り返しても必ず成功すること。**
    ///
    /// SMB では `FileManager.removeItem` が **5 回に 1 回ほど 1 回目に失敗する**
    /// （実測: 実 NAS で 30 回中 6 回、`EPERM`）。原因は自分で消した子が
    /// サーバ側で片付くまでのごく短い隙間で、待てば必ず解ける（6/6 が復帰、
    /// うち 4 件は 100ms 以内）。
    ///
    /// 直す前は、ユーザーが NAS 上のフォルダを完全削除しようとすると 2 割の
    /// 確率で失敗し、しかも Foundation の文言が
    /// **「アクセス権がないため削除できませんでした」**——権限は何も問題
    /// ないので、原因にたどり着けない案内になっていた。
    ///
    /// **1 回では捕まらない**ので繰り返す。10 回なら、直す前の実装が
    /// すり抜ける確率は 0.8^10 ≒ 11% まで下がる。
    @Test func deletingAFolderWithContentsSucceedsEveryTime() async throws {
        guard let workspace = Workspace() else { return }
        let service = FileOperationService()

        for round in 0..<10 {
            let folder = workspace.root.appendingPathComponent("victim-\(round)", isDirectory: true)
            let nested = folder.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            for i in 0..<3 {
                try Data(repeating: 0x51, count: 64)
                    .write(to: folder.appendingPathComponent("f\(i).bin"))
            }
            try Data(repeating: 0x51, count: 64).write(to: nested.appendingPathComponent("g.bin"))

            let outcome = try await service.deletePermanently([folder])
            #expect(outcome.failures.isEmpty,
                    "\(round) 回目で失敗: \(outcome.failures.map(\.reason))")
            #expect(!FileManager.default.fileExists(atPath: folder.path),
                    "\(round) 回目でフォルダが残った")
        }
    }

    /// **[NV-90] 開いたままのハンドルがあるとフォルダを消せないこと**を、
    /// この共有でも確認する。
    ///
    /// SMB は Windows 由来の delete-on-close 意味論を持つため、**中身を空に
    /// しても**最後のハンドルが閉じるまで `rmdir` が `ENOTEMPTY` になる。
    /// ローカル（APFS）では成功するので、ここはプロトコルの違いそのもの。
    ///
    /// 挙動はサーバ実装に依るので**どちらでも失敗させない**。確かめたいのは
    /// 「起きたときに `ENOTEMPTY` として観測できる」ことで、その文言は
    /// `PosixFailure` が「中を空にしてください」ではなく「開いているアプリが
    /// あるかもしれない」と説明する根拠になっている [NV90-03]。
    @Test func deleteOnCloseSemanticsAreObservable() throws {
        guard let workspace = Workspace() else { return }
        let folder = workspace.root.appendingPathComponent("closing")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("held.bin")
        try Data(repeating: 0x51, count: 32).write(to: child)

        let descriptor = open(child.path, O_RDONLY)
        try #require(descriptor >= 0)
        try FileManager.default.removeItem(at: child)

        errno = 0
        let heldResult = rmdir(folder.path)
        let heldErrno = errno
        close(descriptor)

        if heldResult != 0 {
            #expect(heldErrno == ENOTEMPTY,
                    "delete-on-close の観測結果が ENOTEMPTY 以外: errno=\(heldErrno)")
            // **閉じれば消せるようになる**（待っても直らない／閉じれば直る）
            // [NV90-01]。ただし閉じた直後の 1 回が一過性に失敗することは
            // 別途あり得るので（`EPERM`、実測 5 回に 1 回）、短く試し直す。
            var removed = false
            for _ in 0..<5 where !removed {
                if rmdir(folder.path) == 0 { removed = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            #expect(removed, "ハンドルを閉じても消せない")
        }
    }
}
