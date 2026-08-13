import AppKit
import QooApplication
import QooInfrastructure
import SwiftUI

/// 環境設定「一般」タブ [15.10 節]。表示言語 [ユーザー要望]、アプリ終了の
/// 挙動、マウス/トラックパッドの戻る・進むジェスチャーに関する設定
/// [ユーザー要望、要件定義書には無い] をまとめる。
///
/// `twoFingerSwipeForNavigation` は既存の `UserDefaults` キーをそのまま
/// `@AppStorage` で参照する。以前は `FolderContentView.swift` の右クリック
/// コンテキストメニューに暫定配置していたが、「トレードオフのある app 全体の
/// 挙動をコンテキストメニューで操作させるべきではない」というユーザー指摘を
/// 受けてここへ移設した。**「フォルダを上にまとめる」[LV-03] は表示に関する
/// 設定のため `DisplayPreferencesTab` へ移設した**（ユーザー指摘）。
///
/// 表示言語は最上部に置く [ユーザー指定]。`AppLanguage`/`.appLanguageOverride()`
/// （`Localization/AppLanguage.swift`）参照。
struct GeneralPreferencesTab: View {
    @Environment(\.locale) private var locale
    @AppStorage("qoo.twoFingerSwipeForNavigation") private var twoFingerSwipeForNavigation = true
    @AppStorage("qoo.backForwardSwipeDirectionInverted") private var swipeDirectionInverted = false
    @AppStorage("qoo.preferences.appLanguage") private var appLanguage = AppLanguage.system.rawValue
    /// [ユーザー要望、要件定義書には無い] 既定は `false`（macOS の一般的な
    /// アプリと同じく、ウインドウを閉じてもアプリは常駐する）。実際の終了判定は
    /// `AppDelegate.applicationShouldTerminateAfterLastWindowClosed(_:)` が
    /// 同じ `UserDefaults` キーを直接読む。
    @AppStorage("qoo.preferences.quitWhenAllWindowsClosed") private var quitWhenAllWindowsClosed = false

    // アプリ起動時に開くフォルダ [ユーザー要望]。「テンポラリフォルダと
    // ライブラリフォルダは、通常のボリューム上のフォルダとは分けて設定
    // できること」という指摘を受け、`StartupFolderKind` の3値
    // （仮想ホーム/登録フォルダ/ボリューム上の任意フォルダ）に加えて、
    // UI 表示専用に「登録フォルダのうちどちらのリストか」も別キーで
    // 覚えておく（`StartupFolderPreference` 型コメント参照）。
    @AppStorage(StartupFolderPreference.kindKey) private var startupFolderKind = StartupFolderKind.virtualHome.rawValue
    @AppStorage(StartupFolderPreference.registeredFolderIDKey) private var startupRegisteredFolderID = ""
    @AppStorage(StartupFolderPreference.registeredFolderCategoryKey) private var startupRegisteredFolderCategory = ""
    @AppStorage(StartupFolderPreference.volumeDisplayNameKey) private var startupVolumeDisplayName = ""
    @State private var temporaryFolders: [RegisteredFolder] = []
    @State private var libraryFolders: [RegisteredFolder] = []

    /// UI 上の「起動時に開くフォルダ」モード。永続化されている
    /// `startupFolderKind`（3値）とは別に、テンポラリ／ライブラリを
    /// 別々の選択肢として見せるための表示専用の区分。
    ///
    /// [実機検証で発見・修正したバグ] 当初はこれを `startupFolderKind`＋
    /// `startupRegisteredFolderCategory` から都度導出する計算プロパティに
    /// していたが、「テンポラリフォルダ」「ライブラリフォルダ」ラジオボタンを
    /// クリックしても選べなかった。原因は、モード切替の直後は具体的な登録
    /// フォルダがまだ選ばれていない（`startupRegisteredFolderID` が空）ため
    /// `startupFolderKind` を意図的にまだ `registeredFolder` へ書き換えて
    /// いなかったこと — その結果、`Picker` の `get:` が呼ばれるたびに
    /// `startupFolderKind` はまだ `virtualHome` のままなので、モードが
    /// `virtualHome` に巻き戻って見え、ラジオの選択が一切「定着」しなかった
    /// （サブピッカー自体も `switch startupFolderUIMode` の分岐に現れないため
    /// 表示されなかった）。**「どのモードが選ばれているか」を専用の
    /// `@AppStorage` キーとして独立に永続化**し、`startupFolderKind`
    /// （実際に起動時に使う値、`registeredFolder` になるのは具体的なフォルダ
    /// が確定した時点）とは別に管理することで解消した。
    private enum StartupFolderUIMode: String, CaseIterable {
        case virtualHome, temporaryFolder, libraryFolder, volumeFolder
    }

    @AppStorage("qoo.preferences.startupFolder.uiMode") private var startupFolderUIModeRaw = StartupFolderUIMode.virtualHome.rawValue
    private var startupFolderUIMode: StartupFolderUIMode {
        StartupFolderUIMode(rawValue: startupFolderUIModeRaw) ?? .virtualHome
    }

    var body: some View {
        Form {
            Section {
                Picker("preferences.general.language", selection: $appLanguage) {
                    Text("preferences.general.languageSystem").tag(AppLanguage.system.rawValue)
                    Text("preferences.general.languageJapanese").tag(AppLanguage.japanese.rawValue)
                    Text("preferences.general.languageEnglish").tag(AppLanguage.english.rawValue)
                }
            }

            Section {
                Toggle("preferences.general.quitWhenAllWindowsClosed", isOn: $quitWhenAllWindowsClosed)
            }

            Section {
                Picker("preferences.general.twoFingerSwipe", selection: $twoFingerSwipeForNavigation) {
                    Text("preferences.general.twoFingerSwipeNavigation").tag(true)
                    Text("preferences.general.twoFingerSwipeScroll").tag(false)
                }
                .pickerStyle(.radioGroup)
                if !twoFingerSwipeForNavigation {
                    Text("preferences.general.threeFingerHint")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
                Toggle("preferences.general.invertSwipeDirection", isOn: $swipeDirectionInverted)
            } header: {
                Text("preferences.general.backForwardHeader")
            }

            Section {
                Picker("preferences.general.startupFolder", selection: Binding(
                    get: { startupFolderUIMode },
                    set: { setStartupFolderMode($0) }
                )) {
                    Text("preferences.general.startupFolderVirtualHome").tag(StartupFolderUIMode.virtualHome)
                    Text("preferences.general.startupFolderTemporary").tag(StartupFolderUIMode.temporaryFolder)
                    Text("preferences.general.startupFolderLibrary").tag(StartupFolderUIMode.libraryFolder)
                    Text("preferences.general.startupFolderVolume").tag(StartupFolderUIMode.volumeFolder)
                }
                .pickerStyle(.radioGroup)

                switch startupFolderUIMode {
                case .virtualHome:
                    EmptyView()
                case .temporaryFolder:
                    registeredFolderSubPicker(temporaryFolders, category: .temporary)
                case .libraryFolder:
                    registeredFolderSubPicker(libraryFolders, category: .library)
                case .volumeFolder:
                    HStack {
                        Text(startupVolumeDisplayName.isEmpty ? String(localized: "preferences.general.startupFolderNoneChosen", locale: locale) : startupVolumeDisplayName)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("preferences.general.startupFolderChooseEllipsis") { chooseVolumeFolder() }
                    }
                }
            } header: {
                Text("preferences.general.startupFolderHeader")
            }
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
        .task {
            temporaryFolders = await RegisteredFolderStore.shared.folders(kind: .temporary)
            libraryFolders = await RegisteredFolderStore.shared.folders(kind: .library)
        }
    }

    /// 1件以上登録されていれば、まだ何も選んでいない状態でも一番上のフォルダを
    /// 既定として選択しておく [ユーザー要望]。
    private func currentRegisteredSelection(_ folders: [RegisteredFolder], category: RegisteredFolderKind) -> String {
        if startupRegisteredFolderCategory == category.rawValue,
           folders.contains(where: { $0.id.uuidString == startupRegisteredFolderID }) {
            return startupRegisteredFolderID
        }
        return folders.first?.id.uuidString ?? ""
    }

    /// 表示上の既定選択（一番上のフォルダ）を、実際に起動時に使う値としても
    /// 確定させる。ユーザーが一度も触らなくても既定が有効になるようにする
    /// ため、サブピッカーが現れた時点で永続化する。
    private func ensureDefaultRegisteredSelection(_ folders: [RegisteredFolder], category: RegisteredFolderKind) {
        guard let first = folders.first else { return }
        let hasValidSelection = startupRegisteredFolderCategory == category.rawValue
            && folders.contains(where: { $0.id.uuidString == startupRegisteredFolderID })
        guard !hasValidSelection else { return }
        startupFolderKind = StartupFolderKind.registeredFolder.rawValue
        startupRegisteredFolderID = first.id.uuidString
        startupRegisteredFolderCategory = category.rawValue
    }

    @ViewBuilder
    private func registeredFolderSubPicker(_ folders: [RegisteredFolder], category: RegisteredFolderKind) -> some View {
        if folders.isEmpty {
            Text("preferences.general.startupFolderNoneRegistered")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
        } else {
            Picker("preferences.general.startupFolder", selection: Binding(
                get: { currentRegisteredSelection(folders, category: category) },
                set: { newID in
                    guard !newID.isEmpty else { return }
                    startupFolderKind = StartupFolderKind.registeredFolder.rawValue
                    startupRegisteredFolderID = newID
                    startupRegisteredFolderCategory = category.rawValue
                }
            )) {
                ForEach(folders) { folder in
                    Text(folder.displayName).tag(folder.id.uuidString)
                }
            }
            .labelsHidden()
            .onAppear { ensureDefaultRegisteredSelection(folders, category: category) }
        }
    }

    private func setStartupFolderMode(_ mode: StartupFolderUIMode) {
        startupFolderUIModeRaw = mode.rawValue // ラジオの選択状態はこれで確定・定着する
        switch mode {
        case .virtualHome:
            startupFolderKind = StartupFolderKind.virtualHome.rawValue
        case .volumeFolder:
            startupFolderKind = StartupFolderKind.volumeFolder.rawValue
        case .temporaryFolder, .libraryFolder:
            let category: RegisteredFolderKind = mode == .libraryFolder ? .library : .temporary
            startupRegisteredFolderCategory = category.rawValue
            // 具体的なフォルダが既に選ばれている（カテゴリ切替のみ）場合だけ
            // `startupFolderKind` も確定させる。まだ何も選んでいなければ、
            // サブピッカーで選択した時点で初めて確定する
            // （`registeredFolderSubPicker` の `set` 参照）。
            if !startupRegisteredFolderID.isEmpty {
                startupFolderKind = StartupFolderKind.registeredFolder.rawValue
            }
        }
    }

    /// [ユーザー要望] 通常のボリューム上の任意フォルダを、登録フォルダとは
    /// 別の専用ブックマークで選ぶ。
    private func chooseVolumeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "preferences.general.startupFolderChoosePrompt", locale: locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmarkData = try SecurityScopedBookmarkResolver().makeBookmark(for: url)
            UserDefaults.standard.set(bookmarkData, forKey: StartupFolderPreference.volumeBookmarkKey)
            startupVolumeDisplayName = FileManager.default.displayName(atPath: url.path)
            startupFolderKind = StartupFolderKind.volumeFolder.rawValue
        } catch {
            Task {
                await NotificationRouter.shared.presentError(error, whatHappened: String(localized: "error.operationFailed", locale: locale))
            }
        }
    }
}
