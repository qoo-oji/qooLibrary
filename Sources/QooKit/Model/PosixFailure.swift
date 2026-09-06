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
/// 文言は `Resources/<lang>.lproj/Localizable.strings` から引く。
/// **`String(localized:)` を使ってはならない**（理由は `LocalizedStrings`）。
public enum PosixFailure {
    /// 失敗が「どこで」起きたか。同じ `errno` でも、書き込み先の話なのか
    /// 対象そのものの話なのかで、ユーザーが次に取る行動が変わる。
    ///
    /// これを持たずに「書き込み先に書き込む権限がありません」と固定して
    /// いたため、**フォルダ登録の可否を確かめる場面**でも「書き込み先」と
    /// 出て文脈が噛み合わなかった［棚卸しで発見］。
    ///
    /// **場所を書式引数として文へ差し込む形は採れない**［2026-09-06 の
    /// ローカライズで判明］。日本語では「書き込み先の空き容量が…」と常に
    /// 文頭へ置けるが、英語では "at the destination"（前置詞句）にも
    /// "The destination is read-only"（主語）にもなり、**語順が文ごとに
    /// 違う**。そのため場所で文が変わる errno は、鍵そのものを
    /// `.destination` / `.subject` に分けてある。
    public enum Context: Sendable {
        /// 書き込み先（コピー・移動・展開の宛先）で起きた。
        case destination
        /// 対象そのもの（読み取り元・調べている項目）で起きた。
        case subject
    }

    /// 「なぜ失敗したか」。**対処は含まない**（`recovery` が返す）。
    ///
    /// 鍵は各分岐に literal で書く——変数へ畳むと
    /// `check-localization-keys` が鍵として認識できず、綴りを間違えても
    /// 生の鍵が画面に出るまで気づけない［`ScanReviewTitle` と同じ理由］。
    public static func reason(_ code: Int32, context: Context = .destination) -> String {
        switch (code, context) {
        case (ENOSPC, .destination):
            return QooKitStrings.text("posix.reason.noSpace.destination")
        case (ENOSPC, .subject):
            return QooKitStrings.text("posix.reason.noSpace.subject")
        case (EDQUOT, _):
            return QooKitStrings.text("posix.reason.quotaExceeded")
        case (EROFS, .destination):
            return QooKitStrings.text("posix.reason.readOnly.destination")
        case (EROFS, .subject):
            return QooKitStrings.text("posix.reason.readOnly.subject")
        case (EACCES, .destination), (EPERM, .destination):
            return QooKitStrings.text("posix.reason.noPermission.destination")
        case (EACCES, .subject), (EPERM, .subject):
            return QooKitStrings.text("posix.reason.noPermission.subject")
        case (ENOENT, .destination):
            return QooKitStrings.text("posix.reason.notFound.destination")
        case (ENOENT, .subject):
            return QooKitStrings.text("posix.reason.notFound.subject")
        case (EEXIST, _):
            return QooKitStrings.text("posix.reason.alreadyExists")
        case (ENOTDIR, .destination):
            return QooKitStrings.text("posix.reason.notADirectory.destination")
        case (ENOTDIR, .subject):
            return QooKitStrings.text("posix.reason.notADirectory.subject")
        case (EISDIR, .destination):
            return QooKitStrings.text("posix.reason.isADirectory.destination")
        case (EISDIR, .subject):
            return QooKitStrings.text("posix.reason.isADirectory.subject")
        case (ENAMETOOLONG, _):
            return QooKitStrings.text("posix.reason.nameTooLong")
        case (ELOOP, _):
            return QooKitStrings.text("posix.reason.tooManySymlinks")
        case (EXDEV, _):
            return QooKitStrings.text("posix.reason.crossDevice")
        case (EBUSY, _):
            return QooKitStrings.text("posix.reason.busy")
        case (EMFILE, _), (ENFILE, _):
            return QooKitStrings.text("posix.reason.tooManyOpenFiles")
        case (EFBIG, .destination):
            return QooKitStrings.text("posix.reason.fileTooLarge.destination")
        case (EFBIG, .subject):
            return QooKitStrings.text("posix.reason.fileTooLarge.subject")
        case (EIO, _):
            return QooKitStrings.text("posix.reason.ioError")
        case (ENOTEMPTY, _):
            // **「空ではありません」と言い切らない** [NV90-03]。SMB は
            // Windows 由来の delete-on-close 意味論を持ち、**消したファイルの
            // ハンドルを誰かが開いたままだと、空になっていてもこれを返す**
            // （1-16b の実測。ローカルの APFS では起きない）。空にしたのに
            // 消せない状況で「空にしてください」と案内すると嘘になる。
            return QooKitStrings.text("posix.reason.notEmpty")
        case (EINVAL, _):
            // フォルダを自身の中へ移そうとした場合などがここに来る。事前検査
            // （`FileOperationError.destinationInsideSource`）で先に弾いている
            // が、取りこぼした場合の説明として。
            return QooKitStrings.text("posix.reason.invalid")

        // MARK: ネットワークボリューム [NV-47]
        //
        // **1-16b まで、この区分の翻訳が 1 つも無かった。** ネットワーク上の
        // 失敗はすべて default に落ち、「原因を特定できないエラー」としか
        // 出ていなかった。ネットワークでは切断が例外ではなく通常状態なので
        // （§8.11.4）、いちばん頻度の高い失敗がいちばん説明されない状態だった。
        case (ETIMEDOUT, _):
            return QooKitStrings.text("posix.reason.timedOut")
        case (ENOTCONN, _), (ENETDOWN, _), (ENETUNREACH, _), (EHOSTDOWN, _),
             (EHOSTUNREACH, _), (ECONNRESET, _), (ECONNABORTED, _), (EPIPE, _):
            return QooKitStrings.text("posix.reason.disconnected")
        case (ESTALE, _):
            // NFS で顕著。共有側でファイルが差し替えられると、開いたままの
            // 参照が無効になる。
            return QooKitStrings.text("posix.reason.staleReference")
        case (ENOTSUP, _), (EOPNOTSUPP, _):
            // **これは「能力検出が外れたサイン」である**（§8.11 NV-80）。
            // 能力フラグを信じて選んだ速い経路が、実際には使えなかったときに来る。
            return QooKitStrings.text("posix.reason.unsupported")
        case (EINTR, _):
            // NFS の soft マウント等で、待機中の I/O が中断されたときに来る。
            return QooKitStrings.text("posix.reason.interrupted")
        case (EAUTH, _):
            // 認証失敗。`EACCES`（権限不足）とは対処が違うので分けて扱う。
            return QooKitStrings.text("posix.reason.authenticationFailed")
        default:
            // **英語の `strerror` を本文に混ぜない**［棚卸しで発見］。
            // 原因を名指しできないことは正直に言い、詳細は
            // `technicalDetail`（折りたたみ）へ回す。
            return QooKitStrings.text("posix.reason.unknown")
        }
    }

    /// 「次に何ができるか」。示せることが無ければ `nil`。
    ///
    /// `context` は現状どの分岐でも使わないが、引数として受けておく——
    /// 場所によって手順が変わる対処（例: 書き込み先だけ別の場所を選べる）を
    /// 足すときに、呼び出し側の変更が要らないようにするため。
    public static func recovery(_ code: Int32, context: Context = .destination) -> String? {
        switch code {
        case ENOSPC, EDQUOT:
            return QooKitStrings.text("posix.recovery.noSpace")
        case EROFS:
            return QooKitStrings.text("posix.recovery.readOnly")
        case EACCES, EPERM:
            return QooKitStrings.text("posix.recovery.noPermission")
        case ENOENT:
            return QooKitStrings.text("posix.recovery.notFound")
        case EEXIST:
            return QooKitStrings.text("posix.recovery.alreadyExists")
        case ENAMETOOLONG:
            return QooKitStrings.text("posix.recovery.nameTooLong")
        case EBUSY:
            return QooKitStrings.text("posix.recovery.busy")
        case EMFILE, ENFILE:
            return QooKitStrings.text("posix.recovery.tooManyOpenFiles")
        case EFBIG:
            return QooKitStrings.text("posix.recovery.fileTooLarge")
        case EIO:
            return QooKitStrings.text("posix.recovery.ioError")
        case ENOTEMPTY:
            return QooKitStrings.text("posix.recovery.notEmpty")
        case ELOOP, EXDEV, ENOTDIR, EISDIR, EINVAL:
            return nil // 状況依存で、一般に示せる次の手が無い

        // MARK: ネットワークボリューム [NV-47]
        case ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH,
             ECONNRESET, ECONNABORTED, EPIPE, EINTR:
            return QooKitStrings.text("posix.recovery.network")
        case ESTALE:
            return QooKitStrings.text("posix.recovery.staleReference")
        case ENOTSUP, EOPNOTSUPP:
            // ユーザーには直せないことが多いので、別の場所を選ぶ以外の手は示さない。
            return QooKitStrings.text("posix.recovery.unsupported")
        case EAUTH:
            return QooKitStrings.text("posix.recovery.authenticationFailed")
        default:
            return nil
        }
    }

    /// 折りたたんで見せる技術詳細 [ER-03]。**本文には混ぜない。**
    ///
    /// ここだけは訳さない——`strerror` の英語は、利用者が検索したり
    /// 開発者へ伝えたりするための原文であって、読み物ではない。
    public static func technicalDetail(_ code: Int32) -> String {
        "errno \(code): \(String(cString: strerror(code)))"
    }
}
