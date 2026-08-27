//
//  未解決ファイルを整理するコマンド [AL-33][UR-05][UD-03]。
//
//  ## ここに無いもの
//  - **ラベルの手動付与** [UR-03][AL-32] は `AssignLabelCommand` が担う。
//    右ペインで作った仕組みをそのまま使う——同じ操作に独立した経路を
//    2 つ作ると、片方だけ直して取り残す（このリポジトリで 6 度踏んだ形）。
//  - **再マッチング** [AL-34] はコマンドにしない［設計判断］。走査と同じ
//    収束型の処理で、⌘Z で「解決したことを取り消す」のは意味が薄い
//    ——戻したいのは普通「足したフォーマット」のほうで、それは設定の編集
//    （草案 ＋ 保存）という別の経路にある。
//
import Foundation
import QooInfrastructure
import QooKit

/// 「以後無視する」の切り替え [AL-33][UR-05]。
///
/// **変更前の値を 1 件ずつ持つ。** 一括で立てた／解いたときの選択には元から
/// 無視だったものが混ざりうるので、`undo()` が `previous` 全件を一律に反転
/// させると「触っていないもの」まで裏返る——しかも画面上は「戻った」ように
/// 見えるので気づけない（`SetRatingCommand` で同じ理由から採った形）。
///
/// 守り方は 2 枚ある: ①実際に値が変わったものだけを対象にする（`changing`）
/// ②その 1 件ごとの元の値へ戻す。**片方だけでも正しくなるが、両方置く**——
/// 変異検証で、片方を外しただけの変異はもう片方に吸収されて空振りした。
@MainActor
public final class SetUnresolvedIgnoredCommand: Command {
    /// 変更前の状態 1 件ぶん。
    public struct Previous: Sendable, Hashable {
        public let fileID: FileID
        public let isIgnored: Bool

        public init(fileID: FileID, isIgnored: Bool) {
            self.fileID = fileID
            self.isIgnored = isIgnored
        }
    }

    private let previous: [Previous]
    private let ignored: Bool
    private let names: [String]
    private let services: LibraryServices

    /// 実際に値が変わるものだけ。**書き戻しの対象をここで絞る**——変化の
    /// 無いものまで `undo()` が触ると、混在した選択への一括操作を取り消した
    /// ときに「元から無視だったもの」まで解けてしまう。
    ///
    /// なお「そもそも走らせない」判断は呼び出し側（`UnresolvedFileModel`）に
    /// ある——`CommandStack.run` は結果によらず履歴へ積むため。
    private var changing: [Previous] { previous.filter { $0.isIgnored != ignored } }

    public init(previous: [Previous], ignored: Bool, names: [String],
                services: LibraryServices) {
        self.previous = previous
        self.ignored = ignored
        self.names = names
        self.services = services
    }

    /// **名詞句にする。** Undo メニューは「〜を取り消す」を後ろに付ける。
    public var displayName: String {
        let verb = ignored ? "以後無視する設定" : "無視の解除"
        return names.count == 1
            ? "「\(names[0])」の\(verb)"
            : "\(names.count) 件のファイルの\(verb)"
    }

    public var logDescription: String {
        "setUnresolvedIgnored(\(ignored)): "
            + names.map { Log.redactable($0) }.joined(separator: ", ")
    }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        let targets = changing
        guard !targets.isEmpty else { return .success }
        try await services.setUnresolvedIgnored(targets.map(\.fileID), ignored)
        return .success
    }

    public func undo() async throws -> UndoResult {
        let targets = changing
        guard !targets.isEmpty else { return .complete }
        do {
            // 値ごとにまとめて書き戻す。**一律に戻さない**（上記）。
            let wasIgnored = targets.filter(\.isIgnored).map(\.fileID)
            let wasNot = targets.filter { !$0.isIgnored }.map(\.fileID)
            if !wasIgnored.isEmpty { try await services.setUnresolvedIgnored(wasIgnored, true) }
            if !wasNot.isEmpty { try await services.setUnresolvedIgnored(wasNot, false) }
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}
