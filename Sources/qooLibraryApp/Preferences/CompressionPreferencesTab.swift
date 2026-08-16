import QooKit
import SwiftUI

/// 環境設定「圧縮／展開」タブ [ユーザー要望、要件定義書には無い]。既定の
/// 圧縮形式（zip/7z）とその形式で使えるオプション（圧縮レベル/コーデック・
/// 暗号化方式）、展開時の安全上限（`ExtractLimits`）を設定可能にする。
///
/// **暗号化は zip 選択時のみ有効**。libarchive の 7z ライター
/// （`archive_write_set_format_7zip.c`）には暗号化オプション自体が無いことを
/// ソース調査で確認済み（CLAUDE.md 参照）。7z 選択時は暗号化セクション自体を
/// 表示しない（機能しない設定を見せない、という既存原則）。
///
/// **パスワード文字列自体はここに保存しない**。実際のパスワードは圧縮の
/// たびに `ArchivePasswordDialog` で入力させる（`CompressionOptions` の
/// コメント参照、セキュリティ上の設計判断）。
struct CompressionPreferencesTab: View {
    @AppStorage("qoo.preferences.compression.format") private var format: CompressibleFormat = .zip
    @AppStorage("qoo.preferences.compression.zipLevel") private var zipLevel: ZipCompressionLevel = .normal
    @AppStorage("qoo.preferences.compression.sevenZipCodec") private var sevenZipCodec: SevenZipCodec = .ppmd
    @AppStorage("qoo.preferences.compression.encryption") private var encryption: ArchiveEncryptionMethod = .none

    @AppStorage("qoo.preferences.extraction.maxUncompressedGB") private var maxUncompressedGB: Double = Double(AppLimits.Extraction.defaultMaxUncompressedBytes) / 1_000_000_000
    @AppStorage("qoo.preferences.extraction.maxEntries") private var maxEntries: Double = Double(AppLimits.Extraction.defaultMaxEntries)
    @AppStorage("qoo.preferences.extraction.ratioWarn") private var ratioWarn: Double = AppLimits.Extraction.defaultRatioWarn
    @AppStorage("qoo.preferences.extraction.ratioAbort") private var ratioAbort: Double = AppLimits.Extraction.defaultRatioAbort

    var body: some View {
        Form {
            Section {
                Picker("preferences.compression.format", selection: $format) {
                    Text("common.zip").tag(CompressibleFormat.zip)
                    Text("common.sevenZip").tag(CompressibleFormat.sevenZip)
                }

                if format == .zip {
                    Picker("preferences.compression.zipLevel", selection: $zipLevel) {
                        Text("preferences.compression.levelStore").tag(ZipCompressionLevel.store)
                        Text("preferences.compression.levelFast").tag(ZipCompressionLevel.fast)
                        Text("preferences.compression.levelNormal").tag(ZipCompressionLevel.normal)
                        Text("preferences.compression.levelBest").tag(ZipCompressionLevel.best)
                    }
                } else {
                    Picker("preferences.compression.sevenZipCodec", selection: $sevenZipCodec) {
                        Text("preferences.compression.codecPPMd").tag(SevenZipCodec.ppmd)
                        Text("preferences.compression.codecBzip2").tag(SevenZipCodec.bzip2)
                        Text("preferences.compression.codecDeflate").tag(SevenZipCodec.deflate)
                        Text("preferences.compression.codecCopy").tag(SevenZipCodec.copy)
                    }
                }
            } header: {
                Text("preferences.compression.header")
            }

            if format == .zip {
                Section {
                    Picker("preferences.compression.encryptionMethod", selection: $encryption) {
                        Text("preferences.compression.encryptionNone").tag(ArchiveEncryptionMethod.none)
                        Text("preferences.compression.encryptionTraditional").tag(ArchiveEncryptionMethod.zipTraditional)
                        Text("preferences.compression.encryptionAES128").tag(ArchiveEncryptionMethod.aes128)
                        Text("preferences.compression.encryptionAES256").tag(ArchiveEncryptionMethod.aes256)
                    }
                    .pickerStyle(.radioGroup)
                    if encryption == .zipTraditional {
                        Text("preferences.compression.traditionalWarning")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.red)
                    }
                    if encryption != .none {
                        Text("preferences.compression.passwordHint")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("preferences.compression.encryptionHeader")
                }
            }

            Section {
                HStack {
                    Text("preferences.extraction.maxSize")
                    Slider(value: $maxUncompressedGB, in: 1...200, step: 1)
                    Text(String(format: "%.0f GB", maxUncompressedGB))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Text("preferences.extraction.maxEntries")
                    Slider(value: $maxEntries, in: 1_000...500_000, step: 1_000)
                    Text("\(Int(maxEntries))")
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Text("preferences.extraction.ratioWarn")
                    Slider(value: $ratioWarn, in: 10...500, step: 10)
                    Text(String(format: "×%.0f", ratioWarn))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Text("preferences.extraction.ratioAbort")
                    Slider(value: $ratioAbort, in: 100...5_000, step: 100)
                    Text(String(format: "×%.0f", ratioAbort))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            } header: {
                Text("preferences.extraction.header")
            }

            // スライダーで既定値が分かりにくいため
            // [ユーザー指摘: 調整系の設定には必ず「既定に戻す」を付けること]。
            Section {
                Button("preferences.resetToDefaults") {
                    format = .zip
                    zipLevel = .normal
                    sevenZipCodec = .ppmd
                    encryption = .none
                    maxUncompressedGB = Double(AppLimits.Extraction.defaultMaxUncompressedBytes) / 1_000_000_000
                    maxEntries = Double(AppLimits.Extraction.defaultMaxEntries)
                    ratioWarn = AppLimits.Extraction.defaultRatioWarn
                    ratioAbort = AppLimits.Extraction.defaultRatioAbort
                }
            }
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
    }
}
