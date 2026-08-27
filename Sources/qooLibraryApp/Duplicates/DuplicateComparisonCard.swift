//
//  比較ビューの 1 枚 [DU-20][DU-21][DU-23]。
//
//  **カバーを並べて目視で比べられる**こと [DU-23] がこの画面の要なので、
//  表形式ではなくカードにして絵を大きく出す。
//
import QooApplication
import QooKit
import QooInfrastructure
import SwiftUI

struct DuplicateComparisonCard: View {
    let row: DuplicateComparisonRow
    /// ユーザー指定カバーの複製の場所 [IV-02①]。無ければ `nil`。
    let userCoverURL: URL?
    let isKeeper: Bool
    let onChoose: () -> Void
    /// 代表の手動固定を切り替える [DU-08][DG-04]。
    ///
    /// **一覧側からでは代表しか選べない**（畳んだ結果として代表 1 行しか
    /// 描かれないため）ので、**別の 1 件を代表に指名できるのはこの画面だけ**。
    let onTogglePin: () -> Void

    private let coverSize: Double = 96

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.spacing.m) {
            // [DU-24] 残す 1 件を選ぶ。**カード全体を押しても選べる**——
            // 小さな丸を狙わせない。
            Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
                .font(.system(size: Tokens.fontSize.title3))
                .foregroundStyle(isKeeper ? Color.accentColor : Color.secondary)
                .accessibilityLabel(Text("duplicates.keepThisOne"))

            DuplicateCoverThumbnail(url: row.url,
                                    assignment: CoverAssignment(row.file),
                                    userCoverURL: userCoverURL, size: coverSize)

            VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                Text(row.file.filename)
                    .font(.system(size: Tokens.fontSize.body, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)      // 末尾を切ると巻数が消える
                metadataGrid
                if !row.labelNames.isEmpty {
                    Text(row.labelNames.joined(separator: " · "))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button {
                onTogglePin()
            } label: {
                Image(systemName: row.file.isDuplicateRepresentativePinned
                      ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(row.file.isDuplicateRepresentativePinned
                             ? Color.accentColor : Color.secondary)
            .help(Text(row.file.isDuplicateRepresentativePinned
                       ? "folder.unpinDuplicateRepresentative"
                       : "folder.pinDuplicateRepresentative"))
        }
        .padding(Tokens.spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radius.m)
                .fill(isKeeper ? Color.accentColor.opacity(0.10) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radius.m)
                .strokeBorder(isKeeper ? Color.accentColor : Color.secondary.opacity(0.25),
                              lineWidth: isKeeper ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onChoose)
    }

    /// 比較項目 [DU-21]。**まだ数えていないものは「—」ではなく回転**——
    /// 「取れなかった」と取り違えると、中身のあるほうを捨てる材料になる。
    private var metadataGrid: some View {
        HStack(spacing: Tokens.spacing.m) {
            field(Text("duplicates.field.size"),
                  Text(ByteCountFormatter.string(fromByteCount: row.file.fileSize,
                                                 countStyle: .file)))
            field(Text("duplicates.field.format"),
                  Text(verbatim: (row.file.filename as NSString).pathExtension.uppercased()))
            pagesField
            resolutionField
            field(Text("duplicates.field.rating"),
                  Text(verbatim: row.file.rating > 0
                       ? String(repeating: "★", count: row.file.rating) : "—"))
            if !row.folder.isEmpty {
                field(Text("duplicates.field.folder"), Text(verbatim: row.folder))
            }
        }
        .font(.system(size: Tokens.fontSize.caption))
    }

    @ViewBuilder private var pagesField: some View {
        switch row.measurement {
        case .pending:
            field(Text("duplicates.field.pages"), nil)
        case .measured(let pages, _, _):
            field(Text("duplicates.field.pages"), Text(verbatim: "\(pages)"))
        case .unavailable:
            field(Text("duplicates.field.pages"), Text(verbatim: "—"))
        }
    }

    @ViewBuilder private var resolutionField: some View {
        switch row.measurement {
        case .pending:
            field(Text("duplicates.field.resolution"), nil)
        case .measured(_, let w, let h):
            field(Text("duplicates.field.resolution"),
                  Text(verbatim: (w != nil && h != nil) ? "\(w!)×\(h!)" : "—"))
        case .unavailable:
            field(Text("duplicates.field.resolution"), Text(verbatim: "—"))
        }
    }

    /// 値が `nil` なら「算出中」[MD-01]。
    private func field(_ label: Text, _ value: Text?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            label.foregroundStyle(.secondary)
            if let value {
                value.monospacedDigit()
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

/// 比較用のカバー [DU-23]。`ThumbnailService` をそのまま使う——同じファイルを
/// 一覧で見たときのキャッシュを共有する [TH-08]。
struct DuplicateCoverThumbnail: View {
    let url: URL
    let assignment: CoverAssignment
    let userCoverURL: URL?
    let size: Double

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: Tokens.radius.s)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size * 1.4)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
        .task(id: url) {
            // 一覧のセル（`IconGridView`）と同じ経路。①②③の判定は
            // `CoverResolution` が唯一持つ [IV-03]。
            let target = await CoverResolution.resolve(
                url: url, assignment: assignment, userCoverURL: userCoverURL
            ).previewURL(for: url)
            image = await ThumbnailService.shared.thumbnail(
                for: target, maxPixelSize: Int(size * 2))
        }
    }
}
