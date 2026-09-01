//
//  右ペインの「未整理」[UR3-04][UR2-05]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（枠を出すかどうか・ヒントが
//  無いときの見せ方）を自動テストで固定できなくなる（`VaultEditorModel` と
//  同じ理由）。SwiftUI には依存しない。
//
import Foundation
import Observation
import QooKit

/// 右ペインが 1 つ持つ、選択中のファイルの「未整理」の状態。
@MainActor
@Observable
public final class UnresolvedHintModel {
    public enum State: Sendable, Equatable {
        /// ライブラリ経由で開いていない、ライブラリ機能が使えない、または
        /// **そのファイルは未整理ではない**。**枠ごと出さない**——
        /// 蔵書のほとんどは解決済みで、そこに「一致しています」と毎回書いても
        /// 場所を取るだけ [`VaultEditorModel.notInLibrary` と同じ判断]。
        case notApplicable
        case loading
        case ready(Subject)
        case failed(String)
    }

    public struct Subject: Sendable, Equatable {
        /// 「最も近いフォーマット」の本文 [UR2-05]。`nil` = 手がかりが無い
        /// （1 要素も満たしたフォーマットが無かった）。
        public let nearestFormatSource: String?
        /// 「以後無視する」[AL-33] が立っているか。**一覧から消えている理由**を
        /// ここでも言えるようにする——行の印は未整理ビューにしか出ないので、
        /// 通常の一覧で選んだときはここが唯一の手がかりになる。
        public let isIgnored: Bool

        public init(nearestFormatSource: String?, isIgnored: Bool) {
            self.nearestFormatSource = nearestFormatSource
            self.isIgnored = isIgnored
        }
    }

    public private(set) var state: State = .notApplicable

    private var loadedURL: URL?

    public init() {}

    public func load(url: URL?, library: LibrarySummary?, services: LibraryServices) async {
        guard let url, let library, services.isReady else {
            loadedURL = nil
            state = .notApplicable
            return
        }
        // **同じ対象の読み直しでは表示を消さない**（走査のたびに枠が
        // 点滅しないように）。対象そのものが変わったときだけ白紙に戻す。
        if loadedURL != url {
            state = .loading
            loadedURL = url
        }
        do {
            guard let row = try await services.fileRow(at: url, in: library),
                  let hint = try await services.unresolvedHint(id: row.id) else {
                state = .notApplicable
                return
            }
            state = .ready(Subject(nearestFormatSource: hint.nearestFormatSource,
                                   isIgnored: hint.isIgnored))
        } catch {
            // 取り消しは失敗ではない——次の読み込みがすぐ上書きする。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
