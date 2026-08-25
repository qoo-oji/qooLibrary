//
//  `managedFile.searchKey` の組み立て [SR-03][SR-06][DB-03]。
//
//  ライブラリ表示モードの検索はファイル名に加えて**タイトル名・シリーズ名**も
//  対象にする [SR-03]。フォルダ表示モードの検索は実体の再帰走査（別経路）で
//  名前しか見ないので、ここが効くのはライブラリ表示モードだけである。
//
//  **どの値を混ぜるかをここ 1 箇所で決める。** 書き込み口は 4 つある
//  （insert / `updateInPlace` / `applyParsedFields` / `setFields`）ので、
//  規則を散らすと「タイトルを直したのに検索に出ない」といった、片方だけ
//  取り残された状態が静かに残る——実際 2-9 の時点でそうなっていた。
//
import Foundation
import QooKit

enum ManagedFileSearchKey {
    /// 検索キーを組み立てる。
    ///
    /// - Parameter stem: 拡張子を除いたファイル名（`FileSnapshot.nameWithoutExtension`
    ///   と**同じ導出**であること。食い違うと走査と手動編集で別の鍵が入る）。
    static func make(stem: String, title: String?, seriesName: String?,
                     options: NormalizationOptions) -> String {
        TextNormalizer.searchKey(joining: [stem, title, seriesName], options: options)
    }

    /// ファイル名から stem を取る。`FileSnapshot.nameWithoutExtension` の写し。
    ///
    /// **`FileSnapshot` を持たない経路**（`applyParsedFields` / `setFields` は
    /// DB の `filename` 列しか持たない）のために要る。
    static func stem(ofFilename filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }
}
