//
//  シリーズの提案を適用する／無視する [SS-05][SS-06][UD-03][UD-04]。
//
//  ## 新しい書き込み口は作っていない
//  適用は既にある `setFileFields(_:id:protectedScopes:)` [PR-03] を、無視は
//  ステージ 10 で足した 1 列 [SS-05] を使う。**値と保護は同じ呼び出しで書く**
//  ので、「シリーズ名は入ったが保護が付いていない」（＝次の走査で黙って
//  消える）状態が構造的に作れない。
//
import Foundation
import QooInfrastructure
import QooKit

/// 提案をグループまるごと適用する [SS-06]。
///
/// **1 グループが 1 つの Undo 単位** [UD-04]。メンバーごとに 3 回押させると、
/// その途中に「半分だけシリーズになった」状態が残る。
@MainActor
public final class ApplySeriesSuggestionCommand: Command {
    /// 変更前の状態 1 件ぶん。**ファイルごとに控える**——一律に書き戻すと、
    /// 元から保護されていたファイルの保護まで落とす（`SetRatingCommand` の教訓）。
    public struct Previous: Sendable {
        public let fileID: FileID
        public let fields: FileFieldEdit
        public let scopes: Set<ProtectionScope>

        public init(fileID: FileID, fields: FileFieldEdit, scopes: Set<ProtectionScope>) {
            self.fileID = fileID
            self.fields = fields
            self.scopes = scopes
        }
    }

    private let suggestion: SeriesSuggestion
    private let previous: [Previous]
    private let services: LibraryServices
    /// 実際に書けたもの。`undo()` はここだけを戻す——書けていないファイルへ
    /// 「元の値」を書き戻すのは無害だが、部分的に失敗したときに何が起きたかを
    /// 記録から追えなくなる。
    private var applied: [Previous] = []

    public init(suggestion: SeriesSuggestion, previous: [Previous],
                services: LibraryServices) {
        self.suggestion = suggestion
        self.previous = previous
        self.services = services
    }

    /// **名詞句にする。** Undo メニューは「〜を取り消す」を後ろに付ける。
    public var displayName: String {
        "「\(suggestion.seriesName)」\(suggestion.members.count) 冊のシリーズ設定"
    }

    public var logDescription: String {
        "applySeriesSuggestion(\(suggestion.members.count)): "
            + Log.redactable(suggestion.seriesName)
    }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        let volumes = Dictionary(uniqueKeysWithValues:
            suggestion.members.map { ($0.id, $0.volume) })
        applied = []
        var failures: [FailedItem] = []
        for item in previous {
            var next = item.fields.settingSeriesName(suggestion.seriesName)
            // **巻数は提案があるときだけ書く** [SS-07]。「番号の無い 1 冊目」に
            // 1 を割り当てないのと同じ理由で、無いものを作らない。
            if let volume = volumes[item.fileID], volume.kind == .numeric {
                next = next.settingVolume(volume)
            }
            do {
                // 値と保護を同じ呼び出しで書く [PR-03][SS-06]。
                try await services.setFileFields(next, id: item.fileID,
                                                 protectedScopes: item.scopes.union([.basic]))
                applied.append(item)
            } catch {
                failures.append(FailedItem(item: name(of: item.fileID),
                                           reason: error.localizedDescription))
            }
        }
        // **投げ直さない** [ER-13]。`CommandStack.run` は `execute()` が投げると
        // Undo スタックへ積まないので、投げると書けたぶんを戻す手段が消える。
        guard failures.isEmpty else {
            return .partial(succeeded: applied.count, failed: failures)
        }
        return .success
    }

    public func undo() async throws -> UndoResult {
        // **どこまで戻せたかを伝える**［code-review の指摘］。途中で失敗した
        // ときに `.impossible` を返すと、実際には戻っているファイルがあるのに
        // 「何も戻らなかった」と伝えることになる（`FileCommands` と同じ形）。
        var reverted = 0
        for item in applied {
            do {
                try await services.setFileFields(item.fields, id: item.fileID,
                                                 protectedScopes: item.scopes)
                reverted += 1
            } catch {
                let failure = [FailedItem(item: name(of: item.fileID),
                                          reason: error.localizedDescription)]
                return reverted == 0
                    ? .impossible(reason: error.localizedDescription)
                    : .partial(succeeded: reverted, failed: failure)
            }
        }
        return .complete
    }

    private func name(of id: FileID) -> String {
        suggestion.members.first { $0.id == id }.map { Log.redactable($0.title) } ?? "?"
    }
}

/// 「以後この提案を出さない」の付け外し [SS-05]。
///
/// **印はファイル単位**（要件がそう定める）。グループ単位で押した操作は、
/// メンバー全員に印を立てる形で表される。
///
/// 値は**印を立てた時点のタイトル**で、読み出し側は現在のタイトルと一致する
/// ときだけ無視とみなす——名前が変われば判断の前提が消えるので、印を落として
/// 回る見張りが要らない（`unresolvedFile` は走査が突き合わせているが、
/// この提案は走査の外にある）。
@MainActor
public final class SetSeriesSuggestionIgnoredCommand: Command {
    /// 変更前の状態 1 件ぶん。`title` が `nil` なら無視していなかった。
    public struct Previous: Sendable, Hashable {
        public let fileID: FileID
        public let ignoredTitle: String?

        public init(fileID: FileID, ignoredTitle: String?) {
            self.fileID = fileID
            self.ignoredTitle = ignoredTitle
        }
    }

    private let previous: [Previous]
    /// 立てるときの値（ファイルごとの現在のタイトル）。空なら解除。
    private let marks: [FileID: String]
    private let seriesName: String
    private let services: LibraryServices

    public init(previous: [Previous], marks: [FileID: String],
                seriesName: String, services: LibraryServices) {
        self.previous = previous
        self.marks = marks
        self.seriesName = seriesName
        self.services = services
    }

    private var isIgnoring: Bool { !marks.isEmpty }

    public var displayName: String {
        isIgnoring
            ? "「\(seriesName)」の提案を以後出さない設定"
            : "「\(seriesName)」の提案の無視の解除"
    }

    public var logDescription: String {
        "setSeriesSuggestionIgnored(\(isIgnoring)): \(Log.redactable(seriesName))"
    }

    public let isUndoable = true

    public func execute() async throws -> CommandResult {
        let clearing = isIgnoring ? [] : previous.map(\.fileID)
        try await services.updateSeriesSuggestionIgnored(set: marks, clear: clearing)
        return .success
    }

    public func undo() async throws -> UndoResult {
        do {
            // **1 件ずつ元の値へ戻す。** 一律に解くと、元から無視だったものまで
            // 裏返る（`SetUnresolvedIgnoredCommand` と同じ理由）。
            var restore: [FileID: String] = [:]
            var clear: [FileID] = []
            for item in previous {
                if let title = item.ignoredTitle { restore[item.fileID] = title }
                else { clear.append(item.fileID) }
            }
            try await services.updateSeriesSuggestionIgnored(set: restore, clear: clear)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
    }
}
