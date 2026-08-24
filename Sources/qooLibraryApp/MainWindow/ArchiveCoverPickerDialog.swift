//
//  アーカイブ／フォルダの中からカバーに使うページを選ぶ [CV-05][TH-06]。
//
//  **独立したモーダルウインドウで出す**（`AddLabelDialog` と同じ約束）——
//  右ペインは幅が狭く、ページの一覧を縦に積むと必ずどこかが隠れる。
//
import AppKit
import CoreGraphics
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

struct ArchiveCoverPickerDialog: View {
    let url: URL
    /// 選ばれたページの生バイト列。**キャンセルでは呼ばない。**
    let onPick: (Data) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    /// 一覧と読み出しの両方を持つ。**1 つを共有する**——セルごとに作ると
    /// アーカイブを人数分開き直すことになる。
    @State private var picker: ArchiveCoverPicker?
    @State private var candidates: [ArchiveCoverPicker.Candidate] = []
    @State private var selection: ArchiveCoverPicker.Candidate?
    @State private var isLoading = true
    @State private var isFetching = false

    private static let cellWidth: CGFloat = 108
    private static let cellHeight: CGFloat = 152

    var body: some View {
        DialogScaffold(
            width: 560,
            confirm: DialogButton(title: String(localized: "inspector.cover.usePage",
                                                locale: locale)) { pick() },
            cancel: DialogButton(title: String(localized: "common.cancel", locale: locale),
                                 role: .cancel) { dismiss() },
            confirmDisabled: selection == nil || isFetching
        ) {
            Text(url.lastPathComponent)
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            content
        }
        .task {
            let picker = ArchiveCoverPicker(url: url)
            self.picker = picker
            candidates = await picker.candidates()
            isLoading = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 360)
        } else if candidates.isEmpty {
            // **理由を書く**——空の枠だけだと、読めなかったのか中身が無いのかが
            // 区別できない [ER-01 の精神]。
            Text("inspector.cover.noPages")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cellWidth),
                                             spacing: Tokens.spacing.m)],
                          spacing: Tokens.spacing.m) {
                    ForEach(candidates) { candidate in
                        cell(candidate)
                    }
                }
                .padding(.vertical, Tokens.spacing.xs)
            }
            .frame(height: 360)
        }
    }

    private func cell(_ candidate: ArchiveCoverPicker.Candidate) -> some View {
        VStack(spacing: Tokens.spacing.xs) {
            PageThumbnail(candidate: candidate, picker: picker)
                .frame(width: Self.cellWidth, height: Self.cellHeight)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.radius.s)
                        .strokeBorder(selection == candidate ? Color.accentColor : .clear,
                                      lineWidth: 3)
                }
            Text((candidate.name as NSString).lastPathComponent)
                .font(.system(size: Tokens.fontSize.caption))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.cellWidth)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = candidate }
        // ダブルクリックでそのまま確定する（一覧から選ぶ画面の慣習）。
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selection = candidate
            pick()
        })
        .help(candidate.name)
    }

    private func pick() {
        guard let selection, let picker, !isFetching else { return }
        isFetching = true
        Task {
            let data = await picker.data(for: selection)
            isFetching = false
            guard let data else {
                await NotificationRouter.shared.presentError(
                    CoverReplacementError.notAnImage,
                    whatHappened: String(localized: "error.setCoverFailed", locale: locale))
                return
            }
            dismiss()
            onPick(data)
        }
    }
}

/// 1 ページぶんのサムネイル。**可視セルだけが読み込む**（`LazyVGrid`）ので、
/// 500 ページのアーカイブでも実際に読むのは十数件で済む。読み出しは
/// `ArchiveCoverPicker` が 1 本に直列化する [TH-02]。
private struct PageThumbnail: View {
    let candidate: ArchiveCoverPicker.Candidate
    let picker: ArchiveCoverPicker?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: candidate) {
            image = nil
            guard let picker, let data = await picker.data(for: candidate) else { return }
            guard let cgImage = await Self.decode(data) else { return }
            image = NSImage(cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    /// **メインアクタを外れて復号する。** `nonisolated` な async 関数は協調
    /// プールで走る——ここは I/O ではなく CPU 仕事なので、`FileIO` へ逃がす
    /// 必要は無い（逃がすと専用スレッドを 1 本占有するだけ）。
    nonisolated private static func decode(_ data: Data) async -> CGImage? {
        let loader = DefaultImageLoader()
        guard loader.isWithinPixelCountLimit(data) else { return nil }   // [IM-01]
        return try? loader.makeThumbnail(from: data, maxPixelSize: 240)
    }
}
