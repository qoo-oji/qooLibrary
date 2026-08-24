import Foundation
import QooKit

/// サイドカーのカバー画像を探す [IV-02②][IV-03][CL-04]。
///
/// 圧縮ファイルが置かれているフォルダに `covers` フォルダがあり、そこに
/// **拡張子だけが異なる同名の画像**があれば、それをカバーとして使う。
/// ライブラリの走査は `covers` を飛ばす（`LibraryEnumerator`）ので、この
/// 画像自身が蔵書として取り込まれることはない。
///
/// ## 名前の突き合わせ
/// - 拡張子を除いた名前で比べる。**Swift の `String` 比較は正準等価**なので、
///   NFD で置かれたファイルと NFC の名前でも一致する [3 章の実測]。
/// - 完全一致を優先し、無ければ大小文字を無視して探す。ボリュームが大小文字を
///   区別するかは `covers` を作った人ではなくファイルシステムの都合なので、
///   **見つからないより見つけすぎるほうが害が小さい**（誤って拾っても
///   「既定に戻す」[CV-07] で外せる）。
///
/// 実ファイルの**読み取り**しか行わないため B-10 の対象ではないが、
/// カバーの解決順序を 1 箇所にまとめる目的でこのディレクトリに置いている
/// （`CoverImageSourceResolver` と同じ理由）。
public enum SidecarCoverLocator {
    /// `url` に対応するサイドカー画像。無ければ `nil`。
    ///
    /// - Note: ライブラリはネットワーク上にあり得るので `FileIO` の上で読む
    ///   [NV6-02]。
    public static func sidecarCover(for url: URL) async -> URL? {
        await FileIO.perform { locate(for: url) }
    }

    /// 同期版（`FileIO` の中から呼ぶこと）。
    public static func locate(for url: URL) -> URL? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return nil }
        let directory = url.deletingLastPathComponent()
            .appendingPathComponent("covers", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }
        let images = entries.filter {
            PreviewableFileKind.isImageFilename($0.lastPathComponent)
        }
        // 自然順に並べてから選ぶ——同名で拡張子違いが複数あるとき、
        // 実行のたびに違うものが選ばれると「たまに絵が変わる」ことになる。
        let sorted = images.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        if let exact = sorted.first(where: { $0.deletingPathExtension().lastPathComponent == stem }) {
            return exact
        }
        return sorted.first {
            $0.deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(stem) == .orderedSame
        }
    }
}
