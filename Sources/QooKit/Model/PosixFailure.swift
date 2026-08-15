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
/// `QooKit` に置くのは `ExtractError`（`QooKit`）と `FileOperationError`
/// （`QooInfrastructure`）の両方から使うため。依存方向は
/// `QooInfrastructure → QooKit` なのでこの向きしか成立しない [A-01]。
///
/// 文言は日本語のリテラル。この層は文字列カタログ（アプリターゲットの
/// リソース）を参照できないため［既知の限界、`FileOperationError` と同じ］。
public enum PosixFailure {
    /// `errno` の説明。原因と、ユーザーが次にできることをこの順で並べる。
    ///
    /// **知らない `errno` でも必ず何か返す** — 空文字を返すと、呼び出し側が
    /// 「理由が書かれていないダイアログ」を出してしまう。最後は
    /// `strerror` の内容を括弧付きで添える。
    public static func explain(_ code: Int32) -> String {
        switch code {
        case ENOSPC:
            return "書き込み先の空き容量が足りません。不要な項目を削除してから、もう一度お試しください。"
        case EDQUOT:
            return "ディスク使用量の割り当てを超えています。不要な項目を削除してから、もう一度お試しください。"
        case EROFS:
            return "書き込み先が読み取り専用です。書き込みできる別の場所を選んでください。"
        case EACCES, EPERM:
            return "書き込み先に書き込む権限がありません。"
                + "環境設定の「アクセス権」でこの場所へのアクセスを許可するか、"
                + "項目のロックが掛かっていないか確認してください。"
        case ENOENT:
            return "項目または書き込み先が見つかりません。ほかのアプリで移動・削除された可能性があります。"
        case EEXIST:
            return "同じ名前の項目がすでに存在します。"
        case ENOTDIR:
            return "書き込み先がフォルダではありません。"
        case EISDIR:
            return "書き込み先が既存のフォルダです。"
        case ENAMETOOLONG:
            return "名前またはパスが長すぎます。フォルダの階層を浅くするか、名前を短くしてください。"
        case ELOOP:
            return "シンボリックリンクがたどれないほど連鎖しています。"
        case EXDEV:
            return "別のボリュームをまたぐため、この方法では処理できません。"
        case EBUSY:
            return "対象がほかの処理で使用中です。しばらく待ってから、もう一度お試しください。"
        case EMFILE, ENFILE:
            return "同時に開けるファイル数の上限に達しました。ほかのアプリを終了してから、もう一度お試しください。"
        case EFBIG:
            return "書き込み先のファイルシステムが扱える大きさを超えています。"
        case EIO:
            return "入出力エラーが起きました。ディスクが壊れているか、接続が外れた可能性があります。"
        case ENOTEMPTY:
            return "フォルダの中身が空ではありません。"
        case EINVAL:
            // フォルダを自身の中へ移そうとした場合などがここに来る。事前検査
            // （`FileOperationError.destinationInsideSource`）で先に弾いている
            // が、取りこぼした場合の説明として。
            return "この組み合わせでは処理できません。移動先が移動する項目自身やその中にないか確認してください。"
        default:
            return "処理できませんでした。（\(systemReason(code))）"
        }
    }

    /// `strerror` の内容。技術詳細として添えるためのもので、これ単体を
    /// ユーザー向けの説明として使わないこと（英語のため）。
    public static func systemReason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
