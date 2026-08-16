import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// ボリュームの取り出し [1-16、Finder の「取り出す」相当]。
///
/// フォルダツリーのボリューム行のコンテキストメニューと、File メニューの
/// 「取り出す」／「すべてを取り出す」が**同じこの実装を共有する**
/// [`DiagnosticExportAction` と同じ方針: 同じに見える操作に独立した実装経路が
/// できると片方だけ直して取り残される。1-12 のアプリ関連付けで実際に起きた]。
///
/// ER-03 の三要素文言はここで組み立てる（`QooInfrastructure` はローカライズ
/// カタログを参照できないため、`VolumeEjectionError` は素材だけを運ぶ）。
@MainActor
enum VolumeEjectAction {
    /// 1 本取り出す。
    static func eject(_ url: URL) async {
        let locale = AppLanguage.effectiveLocale
        do {
            try await VolumeEjector.eject(url)
            // ツリーのボリューム一覧・中央ペインを更新する。取り出したボリューム
            // 配下を表示していたタブは、`FolderContentView.reload()` の失敗経路
            // から `relocateCurrentTabIfFolderVanished()` が拾う。
            SessionState.shared.reloadToken += 1
        } catch let error as VolumeEjectionError {
            let action = await NotificationRouter.shared.presentError(
                error,
                whatHappened: String(
                    format: String(localized: "eject.failed", locale: locale),
                    error.volumeName
                )
            )
            // [ER-03] 「次に何ができるか」——使用中が理由のことがほとんどで、
            // 他アプリを閉じてからやり直せば通ることが多いため、再試行を出す。
            if action?.kind == .retry {
                await eject(url)
            }
        } catch {
            await NotificationRouter.shared.presentError(
                error,
                whatHappened: String(localized: "eject.failedGeneric", locale: locale)
            )
        }
    }

    /// 取り出せるボリュームをすべて取り出す（Finder の「すべてを取り出す」）。
    ///
    /// **1 本失敗しても残りは続ける** [ER-13 の考え方]。失敗したものだけを
    /// まとめて 1 回提示する——1 本ごとにダイアログが出ると、複数が使用中の
    /// ときに何度も止められて煩わしいため。
    static func ejectAll() async {
        let locale = AppLanguage.effectiveLocale
        var failedNames: [String] = []
        for url in VolumeEjector.ejectableVolumes() {
            do {
                try await VolumeEjector.eject(url)
            } catch let error as VolumeEjectionError {
                failedNames.append(error.volumeName)
            } catch {
                failedNames.append(url.lastPathComponent)
            }
        }
        SessionState.shared.reloadToken += 1
        guard !failedNames.isEmpty else { return }
        await NotificationRouter.shared.present(NotificationItem(
            category: .error,
            severity: .sheet,
            title: String(localized: "eject.someFailed", locale: locale),
            body: failedNames.joined(separator: String(localized: "statusBar.separator", locale: locale))
        ))
    }

    /// `url` を含むボリュームのマウントポイント（取り出せる場合のみ）。
    ///
    /// File メニューの「取り出す」は、Finder と同じく**今表示しているものが
    /// 乗っているボリューム**を対象にする。`.volumeURLKey` はサンドボックス配下の
    /// 経路で解決に失敗することがある（1-6 の D&D で実際に踏んだ）ため、
    /// マウント中のボリューム一覧から前方一致で引き当てる。
    ///
    /// **`nonisolated` は必須。** ボリューム列挙は I/O を伴うため唯一の
    /// 呼び出し元（`MainWindowView.refreshEjectState`）は `FileIO.perform` の
    /// 中から呼ぶ [NV6-02] が、この型は `@MainActor` なので、外さないと
    /// FileIO のスレッド上で隔離検査の表明が破れ `dispatch_assert_queue_fail`
    /// → `EXC_BREAKPOINT` で**起動直後に即死する**（実機で発生。QuickLook の
    /// `previewItemURL` で踏んだのと同じ罠——コールバックが常にメインスレッド
    /// で来るとは限らない、の変種）。コンパイラは「call to main
    /// actor-isolated ... in a synchronous nonisolated context」という**警告**
    /// でしか教えてくれないため、この警告を無視しないこと。
    nonisolated static func ejectableVolume(containing url: URL?) -> URL? {
        guard let url else { return nil }
        let path = url.standardizedFileURL.path
        return VolumeEjector.ejectableVolumes()
            .filter { path == $0.standardizedFileURL.path || path.hasPrefix($0.standardizedFileURL.path + "/") }
            // 入れ子のマウントポイントがあり得るので、最も深く一致したものを選ぶ。
            .max { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
    }
}
