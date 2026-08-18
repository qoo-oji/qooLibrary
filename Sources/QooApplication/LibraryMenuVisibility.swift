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
        // 無効化と設定は**ボリュームを要らない**。前者は DB の行を消すだけ、
        // 後者は DB の設定を書き換えるだけ。**縮退状態でこそ設定を見直したい**
        // ことがある（登録し直す前に型を直しておく等）ので、オンライン条件で
        // 塞がない——無効化をオンライン条件で囲って「外付けを失うと二度と
        // 片付けられない」欠陥を作った前例がある。
        // 再スキャンだけが実ファイルの列挙を伴うのでオンラインを要る。
        return isOnline ? [.settings, .rescan, .disable] : [.settings, .disable]
    }

    public enum Item: Hashable, Sendable {
        case enable, settings, rescan, disable
    }
}

