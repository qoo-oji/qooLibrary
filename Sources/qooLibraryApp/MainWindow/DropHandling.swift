import AppKit
import QooApplication
import QooInfrastructure
import SwiftUI

/// D&D の共通処理 [DD-01〜DD-05]。すべて `FileOperationService` 経由 [FO-01]。
/// `Command`（`QooApplication`）が `@MainActor` プロトコルのため、それを
/// 構築するこの型も `@MainActor` にする（呼び出し元は SwiftUI の View
/// クロージャのみで、元々すべて MainActor 上だった）。
@MainActor
enum DropHandling {
    /// 本物の Finder と同じ規則 [DD-01][設計判断]: 同一ボリューム内のドラッグは既定で
    /// 移動、異なるボリューム間（Finder からの取り込みを含む）のドラッグは既定でコピー。
    /// Option キーはどちらの場合も既定動作を反転させる。SwiftUI の
    /// `dropDestination(for:action:)`/`onDrag` はモディファイアキーの状態を渡してこない
    /// ため、ドロップ確定時点の `NSEvent.modifierFlags` を見て判定する。
    /// 複数アイテムのドロップでボリュームが混在する場合はアイテムごとに判定する。
    static func performDrop(
        _ urls: [URL],
        into destination: URL,
        onComplete: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String) -> Void = { message in
            // 1-12b（NotificationRouter）実装までの既定はログのみ [ER-20 の趣旨に近い暫定対応]。
            print("D&D operation failed: \(message)")
        }
    ) {
        let targets = urls.filter {
            $0.deletingLastPathComponent().standardizedFileURL.path != destination.standardizedFileURL.path
        }
        guard !targets.isEmpty else { return }
        let optionHeld = NSEvent.modifierFlags.contains(.option)

        var copyTargets: [URL] = []
        var moveTargets: [URL] = []
        for url in targets {
            let defaultIsCopy = !isSameVolume(url, destination)
            if optionHeld != defaultIsCopy {
                copyTargets.append(url)
            } else {
                moveTargets.append(url)
            }
        }

        Task {
            do {
                let options = OpOptions(conflictPolicy: .keepBoth) // [CF-01]
                // コピー・移動が両方混在する 1 回の D&D ジェスチャは、1-11 の
                // Undo 基盤で 1 つの Undo 単位にまとめる [UD-04]。
                var children: [any Command] = []
                if !copyTargets.isEmpty {
                    children.append(CopyFilesCommand(items: copyTargets, destination: destination, options: options))
                }
                if !moveTargets.isEmpty {
                    children.append(MoveFilesCommand(items: moveTargets, destination: destination, options: options))
                }
                guard !children.isEmpty else { return }
                let command: any Command = children.count == 1
                    ? children[0]
                    : CompositeCommand(displayName: "ドラッグ＆ドロップ", children: children)
                _ = try await CommandStack.shared.run(command)
                await onComplete()
            } catch {
                await onFailure(error.localizedDescription)
            }
        }
    }

    /// ボリュームが判定できない場合は異なるボリューム扱い（既定コピー、安全側）にする。
    /// `VolumeEligibilityChecker` と同じ `.volumeUUIDStringKey` を使う（`.volumeURLKey`
    /// はサンドボックス配下のフォルダ一覧経路で解決に失敗することがあった）。
    private static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard
            let uuidA = try? a.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
            let uuidB = try? b.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        else {
            return false
        }
        return uuidA == uuidB
    }
}
