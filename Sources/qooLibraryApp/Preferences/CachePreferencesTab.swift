import QooInfrastructure
import QooKit
import SwiftUI

/// 環境設定「キャッシュ」タブ [15.10 節、IV-09]。サムネイルキャッシュの
/// 現在の合計サイズ表示・上限設定・手動クリアを行う。
///
/// `CoverImageCache.prune(toMaxSize:)`/`clear()`（1-9 で実装済みだが、
/// このタブが実装されるまでどこからも呼ばれていなかった）の最初の呼び出し元。
struct CachePreferencesTab: View {
    private static let defaultMaxSizeBytes = Double(AppLimits.Thumbnail.defaultCacheMaxSize)

    @AppStorage("qoo.preferences.thumbnailCacheMaxSizeBytes") private var maxSizeBytes: Double = defaultMaxSizeBytes
    @State private var currentSize: Int64?
    @State private var isBusy = false

    private let cache: CoverImageCache = DefaultCoverImageCache.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("preferences.cache.currentSize")
                    Spacer()
                    if let currentSize {
                        Text(Self.byteCountString(currentSize))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    Text("preferences.cache.limit")
                    Slider(value: $maxSizeBytes, in: (50 * 1_000_000)...(2_000 * 1_000_000), step: 50 * 1_000_000)
                        .onChange(of: maxSizeBytes) { _, newValue in
                            Task {
                                await cache.prune(toMaxSize: Int64(newValue))
                                await refresh()
                            }
                        }
                    Text(Self.byteCountString(Int64(maxSizeBytes)))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                Button("preferences.cache.clearNow") {
                    Task {
                        isBusy = true
                        await cache.clear()
                        await refresh()
                        isBusy = false
                    }
                }
                .disabled(isBusy)
            } header: {
                Text("preferences.cache.header")
            }

            // スライダーで既定値が分かりにくいため
            // [ユーザー指摘: 調整系の設定には必ず「既定に戻す」を付けること]。
            Section {
                Button("preferences.resetToDefaults") {
                    maxSizeBytes = Self.defaultMaxSizeBytes
                }
            }
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        currentSize = await cache.totalSize()
    }

    /// `ByteCountFormatter` は 0 バイトを既定で「Zero KB」という人間向けの
    /// 特別表記にしてしまう（実機検証でユーザーから指摘）。クリア直後など
    /// 0 バイトのときだけ素直な「0 KB」に置き換える。
    private static func byteCountString(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
