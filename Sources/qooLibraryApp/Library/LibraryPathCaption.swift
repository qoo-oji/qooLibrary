//
//  同名ライブラリの行に添えるパスの注記 [RG3-31]。
//
//  フォルダ名＝表示名なので同名のライブラリはできうる。列挙する画面
//  （設定・保管庫・見つからない・未整理・ラベル編集）はこれを行の 2 行目に
//  置き、**衝突しているときだけ**親フォルダのパスで区別する。注記の要否は
//  `LibraryNameDisambiguation`（`QooApplication`、純粋関数）が決める。
//
import QooApplication
import QooKit
import SwiftUI

/// `annotations[library.id]` を渡す。`nil` なら何も描かない。
struct LibraryPathCaption: View {
    let annotation: String?

    var body: some View {
        if let annotation {
            Text(annotation)
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
