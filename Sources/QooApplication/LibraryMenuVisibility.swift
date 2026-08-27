//
//  ライブラリ機能のメニューの出し分け [フェーズ 2 の結線]。
//
import Foundation

/// ライブラリ機能のメニュー項目の出し分け [フェーズ 2 の結線]。
///
/// **View の条件式ではなく値として持つ。** 実機検証で「無効化」を
/// オンライン条件で塞いでいた欠陥を踏んだ——**ボリュームを失うと
/// 二度と無効化できない**という、縮退状態でこそ困る形だった。
/// View に書いた条件はテストで固定できないので、判断だけを切り出す。
public enum LibraryMenuVisibility {
    /// - Parameters:
    ///   - isEnabled: この登録がライブラリとして有効か。
    ///   - isOnline: 根が `.online` か（`FolderTreeRowContext.allowsWriting`）。
    public static func items(isEnabled: Bool, isOnline: Bool) -> Set<Item> {
        guard isEnabled else {
            // 有効化は**オンラインを要る**——`resolvedPath`/`volumeUUID` を
            // 実測できないため [1-17]。
            return isOnline ? [.enable] : []
        }
        // 無効化・設定・ラベル編集は**ボリュームを要らない**。1 つ目は DB の
        // 行を消すだけ、2 つ目は DB の設定を書き換えるだけ、3 つ目は DB の
        // ラベルを書き換えるだけ。**縮退状態でこそ触りたい**ことがある
        // （登録し直す前に型を直す、外付けが無い間に表記ゆれを片付ける等）ので、
        // オンライン条件で塞がない——無効化をオンライン条件で囲って「外付けを
        // 失うと二度と片付けられない」欠陥を作った前例がある。
        // 再スキャンだけが実ファイルの列挙を伴うのでオンラインを要る。
        let offline: Set<Item> = [.settings, .labels, .labelVault, .fileVault,
                                  .orphanCleanup, .unresolvedFiles, .disable]
        return isOnline ? offline.union([.rescan]) : offline
    }

    public enum Item: Hashable, Sendable {
        case enable, settings, rescan, disable
        /// ラベルグループ編集ウインドウ [LE-01〜LE-12][15.2 節]。
        case labels
        /// ラベル保管庫の整理ウインドウ [LAW-01〜LAW-03][15.3 節]。
        ///
        /// **`labels` と同じくオンラインを要らない。** DB のアーカイブ属性を
        /// 書き換えるだけなので、外付けが無い間にこそ片付けたいことがある。
        case labelVault
        /// ファイル保管庫の整理ウインドウ [FAW-01〜FAW-05][15.4 節]。
        ///
        /// **一覧はオンラインを要らない**——`isArchived` は DB の属性で、
        /// 実体を 1 度も見ない。ただし**戻す・削除は実ファイルを動かす**ので
        /// そちらはウインドウ側が `canModify` で無効にする（ラベル保管庫
        /// [LAW-01] が最後まで DB だけで済むのとは事情が違う）。
        case fileVault
        /// 孤立ファイルの整理ウインドウ [OR-01〜OR-05][15.7 節]。
        ///
        /// **オンラインを要らない。** そのライブラリの一覧は出せない
        /// [OR2-06][ID-08] が、ウインドウは全ライブラリを持つので他へ
        /// 切り替えられ、行き止まりにならない。加えて**縮退している登録こそ
        /// 「孤立していないか」を確かめたくなる**——開いて「オフラインの
        /// ため表示できません（＝孤立とは判定していない）」と読めること
        /// 自体に意味がある [R-01]。
        case orphanCleanup
        /// 未解決ファイルの整理ウインドウ [UR-01〜UR-06][15.6 節]。
        ///
        /// **オンラインを要らない。** 未解決は「ファイル名がどのフォーマットにも
        /// 一致しなかった」という照合の結果で、実体を 1 度も見ない——孤立
        /// [OR2-06] とは逆に、オフラインでも正しく一覧できて書ける。
        /// 外付けが無い間にフォーマットを直しておく、はむしろ普通の場面。
        case unresolvedFiles
    }
}

