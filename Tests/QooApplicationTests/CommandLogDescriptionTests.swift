import Foundation
import QooInfrastructure
import QooKit
import Testing

@testable import QooApplication

/// `Command.logDescription` が対象を**絶対パス**で表すことの検証
/// [LG2-06]。`displayName`（ユーザー向け、`lastPathComponent` を素で
/// 埋め込む）をそのまま診断ログへ書くと、書き出し時に匿名化されない
/// ファイル名がバンドルに残ってしまうため。
@Suite @MainActor struct CommandLogDescriptionTests {
    private let root = URL(fileURLWithPath: "/Volumes/Ext/Comics", isDirectory: true)
    private var a: URL { root.appendingPathComponent("作品A 第01巻.cbz") }
    private var b: URL { root.appendingPathComponent("作品A 第02巻.cbz") }
    private var destination: URL { root.appendingPathComponent("Done", isDirectory: true) }

    /// 「素のファイル名だけを含み絶対パスを含まない」＝匿名化から漏れる形。
    private func leaksBareName(_ text: String, name: String) -> Bool {
        text.contains(name) && !text.contains("/Volumes/Ext/Comics/\(name)")
    }

    @Test func everyFileCommandDescribesItsTargetsWithAbsolutePaths() {
        let commands: [any Command] = [
            MoveFilesCommand(items: [a, b], destination: destination),
            CopyFilesCommand(items: [a], destination: destination),
            RenameCommand(item: a, newName: "新しい名前.cbz"),
            TrashCommand(items: [a]),
            DeletePermanentlyCommand(items: [a]),
            CreateFolderCommand(url: destination),
            CreateAliasCommand(source: a, destinationFolder: destination),
            SetLockedCommand(items: [a], locked: true),
            CompressCommand(items: [a], destinationName: "まとめ", destinationFolder: destination),
            ExtractCommand(archiveURL: a, destination: destination),
        ]

        for command in commands {
            let description = command.logDescription
            #expect(!leaksBareName(description, name: "作品A 第01巻.cbz"), "\(type(of: command)): \(description)")
            #expect(description.contains("/Volumes/Ext/Comics"), "\(type(of: command)): \(description)")
        }
    }

    @Test func renameDescribesBothTheOldAndTheNewPath() {
        let command = RenameCommand(item: a, newName: "新しい名前.cbz")
        #expect(command.logDescription == "rename: \(Log.path(a)) → \(Log.path(root.appendingPathComponent("新しい名前.cbz")))")
    }

    @Test func longItemListsAreTruncated() {
        let many = (1...20).map { root.appendingPathComponent("vol\($0).cbz") }
        let description = MoveFilesCommand(items: many, destination: destination).logDescription
        #expect(description.contains("ほか 15 件"))
        #expect(!description.contains("vol20.cbz"))
    }

    @Test func compositeCommandUsesItsChildrenNotItsDisplayName() {
        // `CompositeCommand` の displayName は呼び出し側が渡す任意の文字列で、
        // ファイル名を含み得る。診断ログでは使わない。
        let composite = CompositeCommand(
            displayName: "「作品A 第01巻.cbz」で新規フォルダを作成",
            children: [CreateFolderCommand(url: destination), MoveFilesCommand(items: [a], destination: destination)]
        )
        #expect(!leaksBareName(composite.logDescription, name: "作品A 第01巻.cbz"))
        #expect(composite.logDescription.contains("createFolder:"))
        #expect(composite.logDescription.contains("move:"))
    }

    @Test func compressDoesNotLeakThePassphrase() {
        let command = CompressCommand(
            items: [a], destinationName: "まとめ", destinationFolder: destination,
            options: CompressionOptions(format: .zip, encryption: .aes256), passphrase: "SuperSecret123"
        )
        #expect(!command.logDescription.contains("SuperSecret123"))
        #expect(command.logDescription.contains("aes256")) // 暗号化の有無は残す
    }
}
