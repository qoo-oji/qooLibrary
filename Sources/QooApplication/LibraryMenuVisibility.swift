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
        // 無効化は**ボリュームを要らない**。DB の行を消すだけ。
        // 再スキャンだけが実ファイルの列挙を伴うのでオンラインを要る。
        return isOnline ? [.rescan, .disable] : [.disable]
    }

    public enum Item: Hashable, Sendable {
        case enable, rescan, disable
    }
}

