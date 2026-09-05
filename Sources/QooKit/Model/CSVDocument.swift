//
//  CSV の書き出し [NW-07][OH-02]。
//
//  **通知履歴と操作履歴が同じ実装を使う。** RFC 4180 の引用規則も BOM の
//  要否も両者で違う理由が無く、2 箇所に書くと片方だけ直して取り残す
//  （このリポジトリが繰り返し踏んでいる形）。
//
//  **ストアではなく純粋関数にしてある**——書き出すのは「いま一覧に出ている
//  もの」であって DB 全件ではない（絞り込んでから書き出せないと、棚卸しの
//  用途に使えない）。ストアに置くと絞り込みの条件をもう一度渡し直すことに
//  なり、一覧と食い違う余地が生まれる。
//
import Foundation

public enum CSVDocument {
    /// RFC 4180。**先頭に BOM を付ける**——付けないと Excel が UTF-8 と
    /// 判定せず、日本語が化ける（利用者が最初に開くのはたいてい Excel か
    /// 「数値」である）。
    public static func encode(header: [String], rows: [[String]]) -> Data {
        var text = header.map(escape).joined(separator: ",") + "\r\n"
        for row in rows {
            text += row.map(escape).joined(separator: ",") + "\r\n"
        }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        return data
    }

    /// 引用符・カンマ・改行を含む値を囲む。**囲むと決めたら引用符は二重にする**
    /// （RFC 4180）。
    public static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
