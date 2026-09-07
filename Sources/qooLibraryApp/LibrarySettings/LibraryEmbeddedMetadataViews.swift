//
//  ライブラリ設定 — 埋め込みメタデータ [EM-06][EM-30〜EM-35][15.1 節]。
//
import QooApplication
import QooKit
import SwiftUI

/// 埋め込みメタデータの設定 [EM-06][EM-35]。
///
/// **ここに残すのは読み取りの有無だけ**——`ComicInfo.xml` の巻数をどちらから
/// 取るか [EM-30] は高度な設定「巻数フォーマット」へ移した
/// （`ComicInfoVolumeSourceSettingsView`、ユーザー判断 A9・2026-09-07）。
/// コミック専用かつ一度決めたら触らない設定で、基本に置く理由が無かった。
///
/// **`Form` の中に置く節として切り出してある** [§19.7]——独立したセクション
/// だったものを「基本」の中へ統合したため（`LibraryBasicsSettingsView` 参照）。
/// 呼び出し側の `Form` に属することで、他の節と同じ地の色・余白で並ぶ。
struct EmbeddedMetadataFormSections: View {
    @Binding var draft: LibrarySettingsDraft

    var body: some View {
        // **`Form` の中に `Divider()` を置かない。**`.formStyle(.grouped)` は
        // 各要素を 1 行として描くので、区切り線が「中身の無い行」になって
        // 空の枠が見える［実機で確認］。関心事の分割は `Section` で行う。
        Section {
            Toggle("librarySettings.embeddedMetadata.enabled",
                   isOn: $draft.readsEmbeddedMetadata)
        } header: {
            Text("librarySettings.section.embeddedMetadata")
        }
    }
}

/// 判断待ちの件数と導線 [EM-35]。**0 件なら何も描かない**——見るものが無いのに
/// 場所を取ると、本当に判断が要るときの 1 行が埋もれる。
struct EmbeddedMetadataPendingCard: View {
    let pending: [VolumeDecisionCandidate]
    let onReview: () -> Void

    var body: some View {
        if !pending.isEmpty {
            HStack(spacing: Tokens.spacing.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                    Text(String(format: AppStrings.text("librarySettings.embeddedMetadata.pendingCount"),
                                pending.count))
                    Text("librarySettings.embeddedMetadata.pendingHint")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("librarySettings.embeddedMetadata.review", action: onReview)
            }
            .padding(Tokens.spacing.m)
            .background(RoundedRectangle(cornerRadius: Tokens.radius.m)
                .fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}

// MARK: - 巻数の確認ダイアログ [EM-32][EM-33][15.1.2]

/// `Number` と `Volume` のどちらを巻数として採るかを決める。
///
/// **一覧で見せてから選ばせる**［ユーザー判断: 通知 → 一括ダイアログ］。
/// 1 件ずつ順に聞く形（衝突処理のシートと同じ）にすると、初回取り込みで
/// 何十回も止まる。どちらを選ぶかは**ファイル名との突き合わせ**で決まるので、
/// ファイル名・`Number`・`Volume` を横に並べる [VC-01]。
struct VolumeDecisionDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let candidates: [VolumeDecisionCandidate]
    /// `(選択, 以後も同じ判断を使うなら その側)`。
    let onConfirm: ([FileID: ComicInfoVolumeSource], ComicInfoVolumeSource?) -> Void

    @State private var choices: [FileID: ComicInfoVolumeSource] = [:]
    @State private var remember = false

    /// 全行が同じ側を選んでいるならその側。混在していれば `nil`。
    private var unanimousChoice: ComicInfoVolumeSource? {
        let values = Set(candidates.map { choices[$0.id] ?? .volume })
        return values.count == 1 ? values.first : nil
    }

    var body: some View {
        DialogScaffold(
            width: 640,
            confirm: DialogButton(title: AppStrings.text("common.apply", locale: locale)) {
                onConfirm(resolvedChoices, remember ? unanimousChoice : nil)
                dismiss()
            },
            cancel: DialogButton(title: AppStrings.text("common.cancel", locale: locale),
                                 role: .cancel) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                Text("librarySettings.volumeDecision.explanation")
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Tokens.spacing.s) {
                    Text("librarySettings.volumeDecision.setAll")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                    Button("librarySettings.volumeDecision.allNumber") { setAll(.number) }
                    Button("librarySettings.volumeDecision.allVolume") { setAll(.volume) }
                    Spacer()
                }

                header
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates) { candidate in
                            row(candidate)
                            Divider()
                        }
                    }
                }
                // **件数にあわせて縮める。**固定の高さにすると、1 件しか
                // 無いときに大きな空白が残る［実機で確認］。上限は残す
                // ——何十件もあるときにダイアログが画面を埋めないため。
                .frame(height: min(CGFloat(candidates.count) * 34 + 10, 240))
                .background(RoundedRectangle(cornerRadius: Tokens.radius.s)
                    .fill(Color(nsColor: .textBackgroundColor)))

                Toggle(isOn: $remember) {
                    VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                        Text("librarySettings.volumeDecision.remember")
                        // 混在しているときは何を憶えればよいか決まらない。
                        // **押せない理由をその場に書く**——チェックが灰色に
                        // なっているだけでは、なぜ選べないのか分からない。
                        if unanimousChoice == nil {
                            Text("librarySettings.volumeDecision.rememberNeedsUnanimous")
                                .font(.system(size: Tokens.fontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(unanimousChoice == nil)
            }
        }
        .onAppear {
            // 既定は `Volume`。日本語のタグ付けツールは Kavita 流（`Volume` に
            // 巻数）が多い——ただし**推測なので、値を並べて見せたうえで**選ばせる。
            setAll(.volume)
        }
    }

    private var resolvedChoices: [FileID: ComicInfoVolumeSource] {
        candidates.reduce(into: [:]) { $0[$1.id] = choices[$1.id] ?? .volume }
    }

    private var header: some View {
        HStack(spacing: Tokens.spacing.m) {
            Text("librarySettings.volumeDecision.column.file")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("librarySettings.volumeDecision.column.choice")
                .frame(width: 180, alignment: .leading)
        }
        .font(.system(size: Tokens.fontSize.caption, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private func row(_ candidate: VolumeDecisionCandidate) -> some View {
        HStack(spacing: Tokens.spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(candidate.relativePath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: Binding(
                get: { choices[candidate.id] ?? .volume },
                set: { choices[candidate.id] = $0 })
            ) {
                Text(verbatim: "Number: \(format(candidate.conflict.numberRaw))")
                    .tag(ComicInfoVolumeSource.number)
                Text(verbatim: "Volume: \(format(candidate.conflict.volumeRaw))")
                    .tag(ComicInfoVolumeSource.volume)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .padding(.horizontal, Tokens.spacing.s)
        .padding(.vertical, Tokens.spacing.xs)
    }

    private func format(_ raw: String) -> String { raw }

    private func setAll(_ source: ComicInfoVolumeSource) {
        for candidate in candidates { choices[candidate.id] = source }
    }
}

/// `ComicInfo.xml` の巻数をどちらの要素から取るか [EM-30〜EM-33]。
///
/// **高度な設定「巻数フォーマット」の末尾に置く**——巻数の読み方という
/// 同じ関心事で、しかも `Form` の外（`VStack`）に並ぶので、ここでは
/// `Section` ではなく見出し＋ラジオの形にする。読み取りが無効なら押せない。
struct ComicInfoVolumeSourceSettingsView: View {
    @Binding var draft: LibrarySettingsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            Text("librarySettings.embeddedMetadata.volumeSource")
                .font(.system(size: Tokens.fontSize.body, weight: .semibold))
            Picker("", selection: $draft.comicInfoVolumeSource) {
                Text("librarySettings.embeddedMetadata.volumeSource.ask")
                    .tag(ComicInfoVolumeSource.ask)
                Text("librarySettings.embeddedMetadata.volumeSource.number")
                    .tag(ComicInfoVolumeSource.number)
                Text("librarySettings.embeddedMetadata.volumeSource.volume")
                    .tag(ComicInfoVolumeSource.volume)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .disabled(!draft.readsEmbeddedMetadata)
        }
    }
}
