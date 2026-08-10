import AppKit
import QooInfrastructure
import SwiftUI

/// D&D の共通処理 [DD-01〜DD-05]。すべて `FileOperationService` 経由 [FO-01]。
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
                if !copyTargets.isEmpty {
                    _ = try await FileOperationService.shared.copy(copyTargets, to: destination, options: options)
                }
                if !moveTargets.isEmpty {
                    _ = try await FileOperationService.shared.move(moveTargets, to: destination, options: options)
                }
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
