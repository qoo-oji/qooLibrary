import QooInfrastructure
import QooKit
import SwiftUI

/// 完全削除の実行前確認 [FM-15][PD-02][UD-10]。**取り消せない操作なので、
/// この確認を経ずに `DeletePermanentlyCommand` を実行してはならない。**
///
/// 要件が求める「対象件数と合計サイズ」[FM-15] のうち、合計サイズはフォルダ
/// の再帰列挙を要し、大きなフォルダでは数秒かかる。表示を待たせないため、
/// **シートは即座に開いて件数を見せ、サイズは計算が終わり次第その場で
/// 更新する**（計算中も「キャンセル」は常に押せる）[ユーザー判断:
/// ネイティブ `.alert` ではなく専用シートを選択]。
///
/// `.alert` を選ばなかった理由はもう 1 つある: `.alert` の中身は AppKit の
/// `NSAlert` へブリッジされる際に一度構築されると更新されず、非同期に
/// 確定する値を後から差し込めない（`OpenWithMenu` で実際に踏んだ、
/// メニュー／アラート系ブリッジ共通の制約）。
struct PermanentDeleteConfirmationSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    let request: PendingPermanentDeletion
    let onConfirm: () -> Void

    @State private var preflight = PermanentDeletionPreflight()

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            header

            Divider()

            VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                LabeledContent("permanentDelete.itemCount", value: "\(request.urls.count)")
                LabeledContent("permanentDelete.totalSize") {
                    if preflight.isComplete {
                        Text(Self.sizeFormatter.string(fromByteCount: preflight.totalSize))
                    } else {
                        // 計算中も件数だけは確定しているため、サイズだけを
                        // 進行中表示にする。
                        HStack(spacing: Tokens.spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("permanentDelete.calculating")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !request.urls.isEmpty {
                targetList
            }

            if preflight.lockedCount > 0 {
                // [PD-06] 実行中に 1 件ずつ確認が入ることを予告しておく。
                calloutRow(
                    icon: "lock.fill",
                    text: String(format: String(localized: "permanentDelete.lockedNotice", locale: locale), preflight.lockedCount)
                )
            }

            if !preflight.registeredFolders.isEmpty {
                // [ユーザー判断] 実行自体は妨げないが、登録が強制解除される
                // ことを事前に必ず知らせる。
                calloutRow(
                    icon: "exclamationmark.triangle.fill",
                    text: registeredWarningText,
                    isWarning: true
                )
            }

            if request.becauseNoTrash {
                // **黙って別の動作に落ちない** [NV-81]。ゴミ箱に入れるつもりが
                // 完全削除になる、という食い違いをここで必ず埋める。
                calloutRow(
                    icon: "trash.slash",
                    text: String(localized: "permanentDelete.noTrashOnVolume", locale: locale),
                    isWarning: true
                )
            }

            Text("permanentDelete.irreversible") // [UD-10] 取り消せないことの明示
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)

            QooDialogFooter(
                confirm: DialogButton(
                    title: String(localized: "permanentDelete.confirmButton", locale: locale),
                    role: .destructive
                ) {
                    onConfirm()
                    dismiss()
                },
                cancel: DialogButton(title: String(localized: "common.cancel", locale: locale), role: .cancel) {
                    dismiss()
                },
                // **集計が終わるまで決定できないようにする** [レビューで発見]。
                // 合計サイズだけでなく、ロック済み項目の予告と「登録が解除
                // される」警告も集計の完了を待って現れる。取り消せない操作を
                // それらを見ないまま確定できてしまうのは危険。
                // キャンセルは（`QooDialogFooter` の仕様どおり）常に押せる。
                confirmDisabled: !preflight.isComplete
            )
        }
        .padding(Tokens.spacing.l)
        .frame(width: 420)
        // 選択が変わることはない（シート表示中は操作できない）ため id は固定。
        // 大きなフォルダでも UI を止めないよう actor 分離の外で数える
        // [`InspectorPane.computeFolderCounts` と同じ理由]。
        .task {
            preflight = await PermanentDeletionPreflight.compute(for: request.urls)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.spacing.s) {
            Image(systemName: "trash.slash.fill")
                .font(.system(size: Tokens.fontSize.title2))
                .foregroundStyle(.red)
            Text(titleText)
                .font(.system(size: Tokens.fontSize.title2, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleText: String {
        if request.urls.count == 1 {
            return String(
                format: String(localized: "permanentDelete.titleSingle", locale: locale),
                request.urls[0].lastPathComponent
            )
        }
        return String(format: String(localized: "permanentDelete.titleMultiple", locale: locale), request.urls.count)
    }

    /// 何を消すのかを具体的に見せる。多すぎるときは先頭数件＋残数にする
    /// （ダイアログが画面を埋め尽くさないように）。
    @ViewBuilder
    private var targetList: some View {
        let shown = request.urls.prefix(Self.maxListedTargets)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(shown), id: \.self) { url in
                Text(url.lastPathComponent)
                    .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if request.urls.count > Self.maxListedTargets {
                Text(String(
                    format: String(localized: "permanentDelete.andMore", locale: locale),
                    request.urls.count - Self.maxListedTargets
                ))
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.spacing.s)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
    }

    private var registeredWarningText: String {
        let names = preflight.registeredFolders.map(\.folder.displayName).joined(separator: ", ")
        return String(format: String(localized: "permanentDelete.registeredWarning", locale: locale), names)
    }

    private func calloutRow(icon: String, text: String, isWarning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Tokens.spacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(isWarning ? .red : .secondary)
            Text(text)
                .font(.system(size: Tokens.fontSize.caption))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let maxListedTargets = 8

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

// MARK: - 事前集計

/// 確認ダイアログに出す集計値 [FM-15][PD-02]。フォルダは再帰的に数える
/// （Finder の「情報を見る」と同じく、実際に消える総量を見せるため）。
struct PermanentDeletionPreflight {
    var totalSize: Int64 = 0
    /// ロックされた項目の数 [PD-06 の予告に使う]。フォルダは配下も数える。
    var lockedCount = 0
    /// 削除すると実体を失うライブラリ／テンポラリ登録 [ユーザー要望]。
    var registeredFolders: [InvalidatedRegistration] = []
    var isComplete = false

    static func compute(for urls: [URL]) async -> PermanentDeletionPreflight {
        // 登録フォルダの照合は actor 越しなので先に済ませる。
        let registrations = await RegisteredFolderStore.shared.registrationsInvalidated(byDeleting: urls)
        var result = await measure(urls)
        result.registeredFolders = registrations
        result.isComplete = true
        return result
    }

    /// **`Task.detached` を使わない。** detached タスクは呼び出し元の
    /// キャンセルを引き継がないため、シートを閉じても `Task.isCancelled` が
    /// 永久に `false` のままになり、5 万件規模の走査が最後まで走り続けて
    /// しまう（`InspectorPane.computeFolderCounts` に同じ問題がある）
    /// [レビューで発見]。`nonisolated` な async 関数は呼び出し元のアクターを
    /// 引き継がないので、`@MainActor` の `.task` から呼んでも UI は止まらず、
    /// かつキャンセルは正しく伝わる。
    /// 実際の走査。`NSDirectoryEnumerator` の for-in は async コンテキストでは
    /// 使えない（`makeIterator` が unavailable）ため、同期関数に切り出す。
    /// `Task.isCancelled` は同期コードからでも呼び出し元タスクの状態を返すので、
    /// キャンセルの伝搬は保たれる。
    ///
    /// - Note: **協調プールではなく専用のスレッド源で走らせる** [NV6-01]。
    ///   `nonisolated` にするだけではメインアクタを外れるだけで、走る先は
    ///   協調スレッドプールのまま。削除対象がネットワーク上にあって応答が
    ///   無いと、その 1 本がプールのスレッドを占有し続ける。
    nonisolated private static func measure(_ urls: [URL]) async -> PermanentDeletionPreflight {
        await FileIO.perform { scan(urls) }
    }

    nonisolated private static func scan(_ urls: [URL]) -> PermanentDeletionPreflight {
        var result = PermanentDeletionPreflight()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isUserImmutableKey, .isSymbolicLinkKey]
        let fm = FileManager.default
        for url in urls {
            // **`Task.isCancelled` ではない** — `FileIO.perform` が借りた
            // スレッドには Task の文脈が無く、常に `false` を返す
            // [`Cancellation` のコメント参照]。
            if Cancellation.isRequested { return result }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            // [PD-06] 実行時に確認が入る単位は「操作対象 1 件」であって配下の
            // 個々のロック項目ではない（`FileOperationService` 参照）。予告の
            // 件数もその単位に合わせる — 配下を数え上げると「N 件を 1 件ずつ
            // 確認します」という案内が実際の挙動と食い違う [レビューで発見]。
            var containsLocked = values.isUserImmutable == true
            if values.isSymbolicLink != true, values.isDirectory == true,
               let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) {
                for case let child as URL in enumerator {
                    if Cancellation.isRequested { return result }
                    guard let childValues = try? child.resourceValues(forKeys: keys) else { continue }
                    if childValues.isUserImmutable == true { containsLocked = true }
                    if childValues.isDirectory != true {
                        result.totalSize += Int64(childValues.fileSize ?? 0)
                    }
                }
            } else if values.isDirectory != true {
                result.totalSize += Int64(values.fileSize ?? 0)
            }
            if containsLocked { result.lockedCount += 1 }
        }
        return result
    }
}

/// 完全削除の確認シートを出すための保留状態
/// [`PendingCompression`/`PendingExtractionPassword` と同じパターン]。
struct PendingPermanentDeletion: Identifiable {
    let id = UUID()
    let urls: [URL]
    /// **ユーザーが「ゴミ箱に入れる」を選んだのに、その場所にゴミ箱が
    /// 無かったため完全削除へ振り替えた** [NV4-02]。Finder と同じく、
    /// 「なぜ完全削除の確認が出ているのか」を必ず説明するために持つ。
    var becauseNoTrash: Bool = false
    let onSuccess: @MainActor () -> Void
}
