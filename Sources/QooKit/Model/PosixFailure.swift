import Foundation

/// POSIX の `errno` を「なぜ失敗したか」「次に何ができるか」に翻訳する
/// ただ 1 つの窓口 [ER-03]。
///
/// **なぜ共有するのか**: 同じ `ENOSPC` でも、コピーは
/// `FileOperationError.copyFailed`、移動は `operationFailed`、展開は
/// `ExtractError` と、経路ごとに別々の文言を持っていた。実際に、移動の失敗は
/// `strerror` の英語（「Read-only file system」）をそのまま埋め込むだけで、
/// コピーなら出るはずの「空き容量が足りません」も対処法も出なかった。
/// 翻訳をここ 1 箇所に集めておけば、経路が増えても説明の質が揃う。
///
/// **理由と対処を分けて返す**のは、`UserPresentableError` の三要素
/// （何が／なぜ／次に何ができるか）に素直に流し込むため。混ぜて 1 つの
/// 文字列にすると、呼び出し側が「なぜ」だけを使いたい場面で切り出せない。
///
/// `QooKit` に置くのは `ExtractError`（`QooKit`）と `FileOperationError`
/// （`QooInfrastructure`）の両方から使うため。依存方向は
/// `QooInfrastructure → QooKit` なのでこの向きしか成立しない [A-01]。
///
/// 文言は日本語のリテラル。この層は文字列カタログ（アプリターゲットの
/// リソース）を参照できないため［既知の限界、`FileOperationError` と同じ］。
public enum PosixFailure {
    /// 失敗が「どこで」起きたか。同じ `errno` でも、書き込み先の話なのか
    /// 対象そのものの話なのかで、ユーザーが次に取る行動が変わる。
    ///
    /// これを持たずに「書き込み先に書き込む権限がありません」と固定して
    /// いたため、**フォルダ登録の可否を確かめる場面**でも「書き込み先」と
    /// 出て文脈が噛み合わなかった［棚卸しで発見］。
    public enum Context: Sendable {
        /// 書き込み先（コピー・移動・展開の宛先）で起きた。
        case destination
        /// 対象そのもの（読み取り元・調べている項目）で起きた。
        case subject

        var place: String {
            switch self {
            case .destination: "書き込み先"
            case .subject: "この項目"
            }
        }
    }

    /// 「なぜ失敗したか」。**対処は含まない**（`recovery` が返す）。
    public static func reason(_ code: Int32, context: Context = .destination) -> String {
        let place = context.place
        switch code {
        case ENOSPC:
            return "\(place)の空き容量が足りません。"
        case EDQUOT:
            return "ディスク使用量の割り当てを超えています。"
        case EROFS:
            return "\(place)が読み取り専用です。"
        case EACCES, EPERM:
            return "\(place)を扱う権限がありません。"
        case ENOENT:
            return "項目または\(place)が見つかりません。"
        case EEXIST:
            return "同じ名前の項目がすでに存在します。"
        case ENOTDIR:
            return "\(place)がフォルダではありません。"
        case EISDIR:
            return "\(place)が既存のフォルダです。"
        case ENAMETOOLONG:
            return "名前またはパスが長すぎます。"
        case ELOOP:
            return "シンボリックリンクがたどれないほど連鎖しています。"
        case EXDEV:
            return "別のボリュームをまたぐため、この方法では処理できません。"
        case EBUSY:
            return "対象がほかの処理で使用中です。"
        case EMFILE, ENFILE:
            return "同時に開けるファイル数の上限に達しました。"
        case EFBIG:
            return "\(place)のファイルシステムが扱える大きさを超えています。"
        case EIO:
            return "入出力エラーが起きました。ディスクが壊れているか、接続が外れた可能性があります。"
        case ENOTEMPTY:
            return "フォルダの中身が空ではありません。"
        case EINVAL:
            // フォルダを自身の中へ移そうとした場合などがここに来る。事前検査
            // （`FileOperationError.destinationInsideSource`）で先に弾いている
            // が、取りこぼした場合の説明として。
            return "この組み合わせでは処理できません。"

        // MARK: ネットワークボリューム [NV-47]
        //
        // **1-16b まで、この区分の翻訳が 1 つも無かった。** ネットワーク上の
        // 失敗はすべて default に落ち、「原因を特定できないエラー」としか
        // 出ていなかった。ネットワークでは切断が例外ではなく通常状態なので
        // （§8.11.4）、いちばん頻度の高い失敗がいちばん説明されない状態だった。
        case ETIMEDOUT:
            return "サーバが応答しませんでした。"
        case ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ECONNRESET, ECONNABORTED, EPIPE:
            return "サーバとの接続が切れました。"
        case ESTALE:
            // NFS で顕著。共有側でファイルが差し替えられると、開いたままの
            // 参照が無効になる。
            return "この項目への参照が無効になりました。ほかのコンピュータから変更された可能性があります。"
        case ENOTSUP, EOPNOTSUPP:
            // **これは「能力検出が外れたサイン」である**（§8.11 NV-80）。
            // 能力フラグを信じて選んだ速い経路が、実際には使えなかったときに来る。
            return "この場所ではこの操作がサポートされていません。"
        case EINTR:
            // NFS の soft マウント等で、待機中の I/O が中断されたときに来る。
            return "処理が中断されました。"
        case EAUTH:
            // 認証失敗。`EACCES`（権限不足）とは対処が違うので分けて扱う。
            return "サーバの認証に失敗しました。"
        default:
            // **英語の `strerror` を本文に混ぜない**［棚卸しで発見］。
            // 原因を名指しできないことは正直に言い、詳細は
            // `technicalDetail`（折りたたみ）へ回す。
            return "原因を特定できないエラーが起きました。"
        }
    }

    /// 「次に何ができるか」。示せることが無ければ `nil`。
    public static func recovery(_ code: Int32, context: Context = .destination) -> String? {
        switch code {
        case ENOSPC, EDQUOT:
            return "不要な項目を削除して空きを増やすか、別の場所を選んでください。"
        case EROFS:
            return "書き込みできる別の場所を選んでください。"
        case EACCES, EPERM:
            return "環境設定の「アクセス権」でこの場所へのアクセスを許可するか、"
                + "項目のロックが掛かっていないか確認してください。"
        case ENOENT:
            return "ほかのアプリで移動・削除された可能性があります。一覧を最新にしてから、もう一度お試しください。"
        case EEXIST:
            return "別の名前を付けるか、既存の項目を移動してください。"
        case ENAMETOOLONG:
            return "階層の浅い場所を選ぶか、名前を短くしてください。"
        case EBUSY:
            return "しばらく待ってから、もう一度お試しください。"
        case EMFILE, ENFILE:
            return "ほかのアプリを終了してから、もう一度お試しください。"
        case EFBIG:
            return "exFAT など、大きなファイルを扱える形式の場所を選んでください。"
        case EIO:
            return "接続を確認し、ディスクユーティリティでボリュームを検査してください。"
        case ENOTEMPTY:
            return "中身を空にしてから、もう一度お試しください。"
        case ELOOP, EXDEV, ENOTDIR, EISDIR, EINVAL:
            return nil // 状況依存で、一般に示せる次の手が無い

        // MARK: ネットワークボリューム [NV-47]
        case ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH,
             ECONNRESET, ECONNABORTED, EPIPE, EINTR:
            return "ネットワーク接続とサーバの状態を確認してから、もう一度お試しください。"
        case ESTALE:
            return "一覧を最新にしてから、もう一度お試しください。"
        case ENOTSUP, EOPNOTSUPP:
            // ユーザーには直せないことが多いので、別の場所を選ぶ以外の手は示さない。
            return "別の場所を選ぶか、この場所で使える操作をお試しください。"
        case EAUTH:
            return "サーバへ接続し直して、認証をやり直してください。"
        default:
            return nil
        }
    }

    /// 折りたたんで見せる技術詳細 [ER-03]。**本文には混ぜない。**
    public static func technicalDetail(_ code: Int32) -> String {
        "errno \(code): \(String(cString: strerror(code)))"
    }
}
