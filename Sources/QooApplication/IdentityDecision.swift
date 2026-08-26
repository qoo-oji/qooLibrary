//
//  同一性の確認 — 一覧の組み立て [ID-05][ID-09〜ID-12]。
//
//  走査は「名前が同じで inode が違う」ものを**自動では紐づけない**が、
//  かといって黙って見失うのでもない。走り切ってからまとめて問い合わせる
//  （巻数の確認 [EM-30〜EM-35] と同じ形）。
//
//  ## なぜ確認するのか、なぜ自動にしないのか
//  **同じパス・同じ名前で中身が違うファイルへの差し替えは頻繁に起こる**
//  ——スキャンした本を電子版へ、低画質版を高画質版へ、破損したものを取り直す、
//  圧縮し直す。いずれもサイズが変わるので [ID-03]①② では救えない。
//  一方で「名前が同じなら黙って同じもの」とするのも危うい——`第01巻.cbz` は
//  複数のシリーズに存在しうる。**走り切ってからまとめて聞く**ことで、日常的な
//  差し替えの手数を増やさずに、危険な取り違えだけを目に触れさせる。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——区画分けと既定の
//  選択を `swift test` から固定できるようにするため。SwiftUI に依存しない。
//
import Foundation
import QooKit

public enum IdentityDecision {

    /// 1 行＝「実体を失った記録」1 件と、その最有力候補 1 件。
    ///
    /// **候補が複数あっても先頭だけを出す。** `moreLikely`（同じ場所 → 大きさ
    /// 一致 → パス順）で並べてあるので先頭が最も確からしく、選択肢を増やすと
    /// 「どれを選ぶか」を毎回考えさせることになる——この画面は二択
    /// （同じものか、別物か）に絞る。
    public struct Row: Identifiable, Sendable, Hashable {
        public let file: OrphanedFile
        public let candidate: OrphanCandidate

        public var id: FileID { file.row.id }
        public var match: IdentityMatch {
            IdentityMatch(orphanID: file.row.id, candidateID: candidate.fileID)
        }
        /// 引き継がれるもの（ラベル件数）。0 なら失うものが無い。
        public var carriedLabels: Int { file.labelCount }

        public init(file: OrphanedFile, candidate: OrphanCandidate) {
            self.file = file
            self.candidate = candidate
        }
    }

    /// 区画 [ID-09]。**確信度がまったく違うものを混ぜない。**
    public struct Section: Identifiable, Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            /// 同じ相対パス＝差し替え。ほぼ確実に同じ本。
            case samePath
            /// 別の場所。移動かもしれないし、別シリーズの同名ファイルかもしれない。
            case elsewhere
        }

        public let kind: Kind
        public let rows: [Row]
        public var id: String { kind.rawValue }

        public init(kind: Kind, rows: [Row]) {
            self.kind = kind
            self.rows = rows
        }
    }

    /// **判定はここ 1 箇所。** View に書くとテストで固定できない。
    ///
    /// - 候補を持たない行は落とす（確認するものが無い）。
    /// - **同じ場所の区画を先に置く。** 迷いなく承認できるものを上に集める。
    /// - 行の並びは元のパス順で安定させる——順序が実行ごとに変われば、
    ///   既定でチェックが入る先も毎回変わって見える。
    nonisolated public static func sections(from files: [OrphanedFile]) -> [Section] {
        var samePath: [Row] = []
        var elsewhere: [Row] = []
        for file in files {
            guard let best = file.candidates.first else { continue }
            let row = Row(file: file, candidate: best)
            if best.samePath { samePath.append(row) } else { elsewhere.append(row) }
        }
        let byPath: (Row, Row) -> Bool = { $0.file.row.relativePath < $1.file.row.relativePath }
        return [Section(kind: .samePath, rows: samePath.sorted(by: byPath)),
                Section(kind: .elsewhere, rows: elsewhere.sorted(by: byPath))]
            .filter { !$0.rows.isEmpty }
    }

    /// 既定の選択 [ID-10]。**すべてにチェックを入れる**［ユーザー判断］。
    ///
    /// 差し替えは日常的に起こるので、通常は「適用」を押すだけで済むように
    /// する。危険な取り違え（別の場所の同名ファイル）は区画で分けて見せる
    /// [ID-09] ことで、外したい人が外せるようにする。
    nonisolated public static func defaultSelection(_ sections: [Section]) -> Set<FileID> {
        Set(sections.flatMap { $0.rows.map(\.id) })
    }

    /// 選択から、承認と却下の組を作る。
    ///
    /// **チェックを外したものは「別物」として記録される** [ID-11]——
    /// 「今は決めない」はキャンセルで表す（何も起きず、次回また聞かれる）。
    nonisolated public static func split(_ sections: [Section], selected: Set<FileID>)
        -> (accepted: [IdentityMatch], rejected: [IdentityMatch])
    {
        var accepted: [IdentityMatch] = []
        var rejected: [IdentityMatch] = []
        for row in sections.flatMap(\.rows) {
            if selected.contains(row.id) { accepted.append(row.match) }
            else { rejected.append(row.match) }
        }
        return (accepted, rejected)
    }
}
