//
//  同名ライブラリの区別 [RG3-31][19章 §19.3]。
//
//  **フォルダ名＝表示名**にしたので、同名のライブラリは普通にできうる
//  （`/Volumes/A/コミック` と `/Volumes/B/コミック` など）。ライブラリを
//  列挙する画面は、名前が衝突しているものにだけ**親フォルダのパス**を
//  併記して区別する——全行に出すと、衝突していない大多数の行で雑音になる。
//
import Foundation
import QooKit

public enum LibraryNameDisambiguation {

    /// 同名のライブラリがあるものにだけ、区別のための注記（親フォルダの
    /// パス）を返す。鍵に無い行は注記なしで描いてよい。
    ///
    /// **判定は表示名の完全一致。** 正規化（大小文字の同一視）まで畳むと、
    /// 画面上は違って見える 2 行に同じ注記が付き、かえって混乱する。
    public static func annotations(for libraries: [LibrarySummary]) -> [LibraryID: String] {
        var byName: [String: [LibrarySummary]] = [:]
        for library in libraries {
            byName[library.displayName, default: []].append(library)
        }
        var out: [LibraryID: String] = [:]
        for group in byName.values where group.count > 1 {
            for library in group {
                out[library.id] = parentPath(of: library.resolvedPath)
            }
        }
        return out
    }

    /// 親フォルダのパス。ホーム配下ならチルダで縮める（サンドボックスでは
    /// 実ホームに解決されないことがあるが、その場合は素のパスが出るだけ）。
    static func parentPath(of path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString)
            .abbreviatingWithTildeInPath
    }
}
