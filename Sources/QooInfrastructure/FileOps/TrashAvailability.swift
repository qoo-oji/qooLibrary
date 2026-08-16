import Foundation

/// **その場所にゴミ箱があるかを、操作を始める前に確かめる** [NV4-01]。
///
/// ## なぜ要るのか（1-16b の実測）
/// **SMB 3 系統（Samba/QNAP・Apple・Windows）すべてでゴミ箱は存在しなかった**
/// （8章 §8.11.4）。存在しない場所で「ゴミ箱に入れる」を実行すると、
/// `NSWorkspace.recycle` は **macOS のシステム確認ダイアログ**
/// （「この項目はすぐに削除されます。取り消せません」）を出し、承諾すると
/// **完全削除して成功を返すが、ゴミ箱先の URL は 0 件**で返る。結果:
///
/// - ユーザーは「ゴミ箱に入れる」を選んだのに**完全削除の確認**が出る
/// - しかもアプリ自身の確認シート（件数・合計サイズ [PD-02]、
///   登録フォルダの強制解除 [PD-14]）を通らない
/// - 返却 URL が無いので `TrashReceipt.trashURL` が `nil` になり、
///   **⌘Z が無言で何もしない**（Edit メニューの「取り消す」は有効に見える）
///
/// **先に確かめれば、この 3 つがまとめて消える。** 判定は実測で **0.01 秒**
/// なので、操作のたびに呼んで構わない。
///
/// ## 「常に無い」と決め打ちしない
/// AFP 3 は共有ルートの `.Trash` を使う経路を持ち、**ネットワークホーム
/// フォルダ**はプロトコルによらず例外的にゴミ箱が働く（[文献]）。
/// ボリューム種別で分岐せず**実際に尋ねる**、という §8.11 の原則どおりにする。
public enum TrashAvailability {
    /// `url` のある場所にゴミ箱があるか。
    ///
    /// **`.trashDirectory` の問い合わせで判定する** [RG3-03 と同じ手法]。
    /// 1-14 の実測で、この API はボリュームによって `NSCocoaErrorDomain 3328`
    /// （未サポート）で失敗することが分かっており、**その失敗自体が判定になる**。
    ///
    /// - Note: `create: false` を渡す。存在を確かめたいだけで、
    ///   **こちらの都合でユーザーのボリュームに `.Trashes` を作らない**
    ///   （[NV-86] 共有上にアプリ由来のものを作らない、の精神）。
    public static func hasTrash(for url: URL) -> Bool {
        do {
            _ = try FileManager.default.url(
                for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false
            )
            return true
        } catch {
            Log.fileOps.debug("ゴミ箱を持たない場所と判定: \(Log.path(url)) — \(error.localizedDescription)")
            return false
        }
    }

    /// 複数項目のうち、**1 つでもゴミ箱を持たない場所にあれば `false`**。
    ///
    /// 混在（ローカルの項目とネットワークの項目を同時に選択）した場合に
    /// 一部だけゴミ箱へ行くのは、ユーザーから見て結果が予測できない。
    /// 全部まとめて「すぐに削除」の確認へ倒すほうが説明しやすい [NV-81]。
    ///
    /// 同じボリュームの項目を何度も問い合わせないよう、**マウントポイント
    /// ごとに 1 回だけ**尋ねる [NV-98]。
    public static func hasTrash(forAll urls: [URL]) -> Bool {
        var checked: Set<String> = []
        for url in urls {
            let key = volumeKey(for: url)
            guard checked.insert(key).inserted else { continue }
            if !hasTrash(for: url) { return false }
        }
        return true
    }

    /// 問い合わせを 1 回で済ませるための、ボリュームの粗い識別子。
    ///
    /// `volumeURLKey` は**サンドボックス配下の経路で解決に失敗する**ことが
    /// 分かっている（1-6 の D&D で踏み、`volumeUUIDStringKey` へ切り替えた）。
    /// ここは「同じ場所をもう一度尋ねないため」の鍵にすぎず、多少粗くても
    /// 正しさに影響しない（外れれば余分に 1 回尋ねるだけ）ので、
    /// `/Volumes/<name>` かそれ以外か、という単純な分け方にする。
    private static func volumeKey(for url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            return "/Volumes/" + components[2]
        }
        return "/"
    }
}
