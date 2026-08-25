//
//  カバー画像の解決順序 [IV-02][IV-03][QL-05][9章 §9.6]。
//
//  ①ユーザー指定 → ②サイドカー → ③先頭画像。**この順序をここ 1 箇所に持つ。**
//  出どころが DB（①）・実体（②）・`ThumbnailService`（③）と分かれているので、
//  判定を呼び出し側へ散らすと「いま何が出ているのか」を誰も答えられなくなる。
//
//  読み手は 2 つある——右ペイン（`CoverEditorModel`、選択 1 件）と、ライブラリ
//  表示モードの一覧のセル（`ThumbnailImage`、可視ぶんだけ遅延で）。**同じに
//  見えるものに独立した実装を 2 つ作らない**（このリポジトリが 4 度踏んでいる
//  「片方だけ直して取り残す」を避ける）。
//
import Foundation
import QooInfrastructure
import QooKit

public enum CoverResolution {

    /// 解決の結果。
    public struct Resolved: Sendable, Equatable {
        /// 表示に使う画像。`nil` なら自動抽出＝対象そのものを `ThumbnailService`
        /// へ渡す。
        public let imageURL: URL?
        /// 実際に何が出ているか [IV-03]。**DB の値ではない**——ユーザー指定
        /// なのに複製が失われていれば `.sidecar` や `.auto` になる。
        public let source: CoverSource

        public init(imageURL: URL?, source: CoverSource) {
            self.imageURL = imageURL
            self.source = source
        }

        /// サムネイルを要求する URL。呼び出し側が分岐せずに済むよう、
        /// 自動抽出のときは対象そのものを返す。
        public func previewURL(for url: URL) -> URL { imageURL ?? url }
    }

    /// 同期版。**`FileIO` の中から呼ぶこと** [NV6-02]——ライブラリはネットワーク
    /// 上にあり得る。
    ///
    /// - Parameter userCoverURL: ①の複製の場所。`nil` なら①は無い。
    ///   **存在確認はここで行う**——参照はあるが実体が無い（複製が消えた）とき、
    ///   黙って②③へ落ちるのが正しい [CV-08 の裏返し]。
    nonisolated public static func resolve(url: URL,
                                           assignment: CoverAssignment,
                                           userCoverURL: URL?) -> Resolved {
        if assignment.source == .userSpecified, let userCoverURL,
           FileManager.default.fileExists(atPath: userCoverURL.path) {
            return Resolved(imageURL: userCoverURL, source: .userSpecified)   // ①
        }
        if let sidecar = SidecarCoverLocator.locate(for: url) {
            return Resolved(imageURL: sidecar, source: .sidecar)              // ②
        }
        return Resolved(imageURL: nil, source: .auto)                         // ③
    }

    /// `FileIO` へ逃がす版。**①②をまとめて 1 回の `perform` で行う**のが要点
    /// ——複製の存在確認（ローカル）とサイドカーの探索（ネットワークかもしれない）
    /// を別々に逃がすと、1 件につき 2 回待つことになる。
    nonisolated public static func resolve(url: URL,
                                           assignment: CoverAssignment,
                                           userCoverURL: URL?) async -> Resolved {
        await FileIO.perform { resolve(url: url, assignment: assignment,
                                       userCoverURL: userCoverURL) }
    }
}
