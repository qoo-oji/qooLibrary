# CLAUDE.md

qooLibrary の実装作業でこのリポジトリを扱う際に、Claude Code が常に踏まえておくべき情報をまとめる。

## 0. 現在の状態

**フェーズ 0（基盤検証）完了。フェーズ 1（ファイルマネージャー）着手済み（1-1〜1-13 完了。1-12 のみ未着手、依存関係上ブロックされていない 1-12b/1-13 を先に着手した）。**

### フェーズ 0（`17_実装ロードマップ.md` §17.2、全項目完了）

- `Package.swift`（`QooKit`/`QooPersistence`/`QooInfrastructure`/`QooApplication` + `CLibarchive` + `QooUnrarBridge` + `QooKitTests`）が存在し、`swift build` / `swift test` がグリーン。`PERMISSIVE_ONLY_BUILD=1 swift build` も動作する。
- `Scripts/build-libarchive.sh` / `Scripts/build-unrar.sh` でそれぞれ libarchive・UnRAR をソースからビルドし、`ThirdParty/{libarchive,unrar}/*.xcframework`（arm64+x86_64 ユニバーサル）を生成する。システムの dylib にはリンクしない [LC-15][B-02][LC-11]。
- UnRAR は Objective-C++ ラッパー `Sources/QooUnrarBridge/QooUnrarBridge.mm` 経由でのみ呼ぶ [B-03]。`PERMISSIVE_ONLY_BUILD` ではこのターゲット自体が `Package.swift` から除外される。
- `Spikes/LibarchiveSpike`・`Spikes/UnrarSpike` で zip・RAR の一覧・展開を確認済み。実 `.rar`/`.cbr`（ユーザー提供、122 件）での T-12 再測定と、実ファイル名（2,957 件）に基づく 0-3 の知見も完了（`Spikes/README.md`、`Spikes/real-data-findings.md`）。**実ファイル名・実データそのものはリポジトリに一切含めない**運用にした（ユーザーの明示的な指示）。
- 静的検査 `Scripts/check-fileops-isolation.swift`（B-10）・`check-layer-dependencies.swift`（B-11）・`check-json-completeness.swift`（B-13, 現状はプレースホルダ）と CI（`.github/workflows/ci.yml`）を用意した。
- **既知の懸念（要フォローアップ）**: libarchive 3.8.9 は特定の壊れた RAR 入力（use-after-free の回帰テストファイル）でクラッシュする（エラーを返さず異常終了）。`SecureExtractor`（09章 §9.3）実装時に対処を検討する必要がある。詳細は `Spikes/README.md` の T-12 節。

### フェーズ 1（`17_実装ロードマップ.md` §17.3、1-1〜1-11・1-12b・1-13 完了・1-12/1-14/1-15 未着手）

- **1-1 プロジェクト基盤が完了。** `qooLibrary.xcodeproj` は `project.yml` から `xcodegen generate` で生成する（**git-ignore 対象、手で pbxproj を編集しない**。ThirdParty の xcframework と同じ「生成物はコミットしない」方針）。ローカルの SwiftPM パッケージ（`QooKit`/`QooPersistence`/`QooInfrastructure`/`QooApplication`）を local package dependency として参照し、実機で起動確認済み。
- App Sandbox entitlement（`Sources/qooLibraryApp/qooLibrary.entitlements`）を付与済み。`codesign -d --entitlements :-` で署名済みバイナリに実際に反映されていることを確認済み [SB-01]。
- デザイントークン: `Resources/DesignTokens.json`（spacing/radius/fontSize/iconSize、単一ソース [UI-01]）を `Sources/qooLibraryApp/DesignSystem/Tokens.swift` が実行時に読み込む。色は `Sources/qooLibraryApp/Assets.xcassets` の Color Set 経由（ライト/ダーク対応、コード中に HEX 直書きしない [DT2-03]）。
- 共通コンポーネント: `ThreePaneWindow`/`TwoPaneWindow`（`PaneWindows.swift`）、`QooDialogFooter`、`QooProgressPresenter` を実装（UI-02〜UI-04, UI-09）。`LabelChip`/`QooErrorView`/`RenamePreviewTable`/`FieldBreakdownView` はドメイン型（`Label`、`FieldSpan`、`UserPresentableError`）が無いため未着手。
- `Sources/CLibarchive/shim.c`: Xcode のビルドシステム（`swift build` と違い）はソースファイルを持たないターゲットで `<Target>.o` を要求してリンクに失敗するため、空の C ファイルを追加して回避した。同種の headers-only ターゲットを追加する際はこのパターンを踏襲する。
- CI に `app-build` ジョブを追加（`brew install xcodegen && xcodegen generate && xcodebuild`）。
- **1-2 Security-Scoped Bookmark 基盤・FS 適合検証が完了。**
  - `Sources/QooInfrastructure/Sandbox/BookmarkResolving.swift` + `SecurityScopedBookmarkResolver.swift`: `BookmarkResolving` プロトコルと既定実装 [SB-02][SB-05]。
  - `Sources/QooInfrastructure/FileOps/VolumeEligibilityChecking.swift` + `VolumeEligibilityChecker.swift`: `VolumeEligibilityChecking`（FS-01〜FS-09、作成→移動→ID 再取得の実測）。**登録前の一回性プローブのため `FileOperationService` を経由しない**という spec 上の意図的な例外があり、そのため本ファイルは（実体は別クラスだが）B-10 の許可ディレクトリである `QooInfrastructure/FileOps/` に置いている（コメントで理由を明記）。
  - `QooInfrastructureTests`（新規テストターゲット）で実際のローカル APFS ボリューム・実際に接続された外部ボリューム（このマシンでは `/Volumes/T7`、`/Volumes/PRO-G40`）に対して `evaluate()` を実行し検証済み。ブックマークの生成・解決・`withAccess` の往復も検証済み（サンドボックス外プロセスのため、権限強制そのものの検証ではない）。
  - `Sources/qooLibraryApp/Debug/SandboxVerificationView.swift`: 実サンドボックス下でのみ検証できること（NSOpenPanel によるユーザー選択、ブックマークのアプリ再起動をまたいだ永続性、`startAccessingSecurityScopedResource` の実効性）を確認する暫定 UI。右ペインに仮置きし、当初は 1-13（フォルダ登録の本実装）で削除する計画だったが、実際には 1-10（右ペイン詳細情報、`InspectorPane`）が同じ右ペインの領域を必要としたためそちらで置き換え・削除した。
  - **実機検証（ユーザーによる手動確認）で完了。** 署名済みアプリを実際に起動し、外部ボリューム上のフォルダを選択 → ブックマーク作成 → FS 適合検証 → セキュリティスコープ内アクセスが成功。**アプリを終了して再起動した後**、フォルダを選び直さずに保存済みブックマークを解決 → 同じフォルダへ再度アクセスできることも確認済み [SB-02 の核心]。
  - この過程で実装バグを発見・修正した: 検証コードが FS 適合検証（一時ファイル作成を伴う）を `withAccess` のセキュリティスコープの**外側**で呼んでいたため、NSOpenPanel 直後の URL（暗黙に書き込み可）でしか動かず、ブックマーク解決のみの経路（再起動後）では `probeSetupFailed` になっていた。`swift test` は非サンドボックスプロセスのため発見できず、**実サンドボックス下での手動検証で初めて見つかった**。教訓: セキュリティスコープを要する操作は必ず `withAccess` のクロージャ内で行うこと。
- **1-3 メインウインドウ 3 ペイン・タブ・複数ウインドウ・状態の 3 分類が完了。**
  - `Sources/qooLibraryApp/State/WindowState.swift`: `WindowState`（`@Observable`、ウインドウ固有状態 [ST-20]）と `SessionState`（セッション一時状態の器のみ）。`labelSelection`/`ratingFilter`/`sort` はラベル・評価ドメイン型がまだ無いため未実装（コメントに明記、フェーズ 2 で追加）。`TabState` がタブ 1 枚分（フォルダ・選択・検索文字列）を保持する。
  - `Sources/qooLibraryApp/MainWindow/`: `MainWindowView`（`@State private var windowState` をウインドウごとに生成）、`TabBarView`（タブ追加・切替・閉じる。ドラッグでの並べ替え・別ウインドウへの移動 [MW-03] は未実装）、`FolderContentView`（実フォルダの内容を `FileManager` で一覧表示する最小実装。1-9 の本実装ではない）。
  - **実機検証（ユーザーによる手動確認）で完了。** 実フォルダをタブで開いて一覧表示・タブ切替で状態が独立して保持されること、⌘N で開いた新規ウインドウが「Data」タブ 1 枚だけの独立した初期状態になり元のウインドウに影響しないことを確認済み [MW-01][MW-02][ST-21]。
  - サンドボックスコンテナ内の仮想ホーム（`homeDirectoryForCurrentUser` はサンドボックス下では実ホームではなくコンテナ内パスを返す）がデフォルトタブとして表示されることを実機で確認。これは正しい挙動（許可なく実ホームには入れない）で、SB-01 の必要性を裏付ける実例になった。
  - 既知の粗さ: サンドボックスコンテナ内の `Desktop`/`Downloads`/`Movies`/`Music`/`Pictures`（実際はシンボリックリンク）がフォルダアイコンではなくファイルアイコンで表示される。`.isDirectoryKey` がシンボリックリンク越しに解決できないための表示上の問題で、機能に影響はない。1-4/1-9 で直す。
- **1-4 フォルダツリー（左ペイン、ボリューム／テンポラリ／ライブラリの 3 グループ）が完了。**
  - `Sources/qooLibraryApp/MainWindow/FolderTreeNode.swift`: `FolderTreeNode`（14章 §14.2 のモデルに準拠）。`mountedVolumes()` で実際にマウント中のボリュームを列挙し、`children(of:)` で実フォルダを遅延列挙する（読み取りのみ、FileOps 隔離検査の対象外）。
  - `Sources/qooLibraryApp/MainWindow/FolderTreePane.swift`: 3 グループとも折りたたみ可能 [LP-07]。ボリュームは実ツリー（`DisclosureGroup` の再帰構造、展開時に子を遅延読み込み）。テンポラリ・ライブラリは見出しの `＋`/歯車のみ用意し、リストは常に空（**フォルダ登録の永続化は 1-13 の担当**、ここで先取りしない）。
  - アクセス権がない領域は「アクセス権がありません」+「システム設定を開く」（`x-apple.systempreferences:…Privacy_AllFiles`）を表示 [SB-04][B-20]。
  - `WindowState.navigateCurrentTab(to:)` を追加し、ツリーのクリックとファイル一覧のダブルクリックの両方がこの共通経路で中央ペインと同期する [LP-06]。選択中フォルダはツリー上でハイライト表示。
  - **実機検証（ユーザーによる手動確認）で完了。** 実ボリューム（Macintosh HD / 外部ボリューム）がツリーに表示され、展開して実フォルダ構造を辿れること、権限のない領域が正しく「アクセス権がありません」になること、クリックで中央ペインと同期し選択がハイライトされることを確認済み。
  - 既知の粗さ: サンドボックスコンテナ内の `Desktop`/`Downloads`/`Movies`/`Music`/`Pictures`（実際はシンボリックリンク）がフォルダアイコンではなくファイルアイコンで表示される（`.isDirectoryKey` がシンボリックリンク越しに解決できない）。機能に影響はなく、1-9 あたりで直す。
  - 右クリックのコンテキストメニューは未実装。ファイル操作系は 1-5、フォルダ登録・削除系は 1-13 など、対応する機能が実装されるタイミングでそれぞれ追加する（LP-01〜08 自体はコンテキストメニューを要求していない）。
- **1-5 基本ファイル操作・衝突処理（`FileOperationService` への集約）が完了。**
  - `Sources/QooKit/Model/FileIdentity.swift`: `FileIdentity`（volumeUUID + inode、Foundation のみに依存する値型 [A-01]）。
  - `Sources/QooInfrastructure/FileOps/FileOperationTypes.swift` + `FileOperationService.swift`: `createDirectory`/`copy`/`move`/`rename`/`trash`/`deletePermanently`/`restoreFromTrash` を実装。`trash`/`restoreFromTrash` は `NSWorkspace.shared.recycle` を使い Finder のゴミ箱と互換にする [FM-04][TR2-01]。衝突時は `.replace`/`.keepBoth`（Finder 流 `name 2.ext` [CF-01]）/`.skip`/`.ask`（`conflictResolver` クロージャに委譲、`NotificationRouter`/`BatchNotificationSession` が無い 1-12b 前の暫定形）に対応 [FM-11〜FM-13]。`CommandStack`/`LockManager` と同じ「アプリ全体で単一」の方針で `FileOperationService.shared` を用意（`ExpectedChangeLedger`・操作履歴・Undo との接続は 2-2/1-11 で行う）。
  - `QooInfrastructureTests/FileOperationServiceTests.swift`: 実テンプディレクトリでの統合テスト 10 件（create/copy/move/rename/delete と衝突方針 4 種）。`trash`/`restoreFromTrash` は実 Finder ゴミ箱に触れるため自動テスト対象外とし、実機検証で確認する方針（後述）。
  - `Sources/qooLibraryApp/MainWindow/FolderContentView.swift` に右クリックメニュー（Finder で表示・パスをコピー・複製・名前を変更・ゴミ箱）と新規フォルダボタンを配線。ファイルを変更する操作はすべて `FileOperationService` 経由。
  - **静的検査の誤検知を発見・修正**: `check-fileops-isolation.swift`（B-10）が `fileOps.createDirectory(...)`（`FileOperationService` への正当な呼び出し）を `FileManager` の変更系 API と誤認識していた。`FileOperationService` が spec 通り `FileManager` と同名のメソッドを公開しているため。該当行に `"FileManager"` という文字列が含まれる場合のみを違反候補とするよう修正（`Scripts/check-fileops-isolation.swift`）。
  - **実機検証（ユーザーによる手動確認）で完了。** サンドボックスコンテナ内に新規フォルダを作成 → 名前変更 → 複製（Finder 流 `名前 2` 命名を確認）→ ゴミ箱に入れる、を実際に操作してもらい、最後は実際の Finder ゴミ箱に移動していることまで確認済み。
- **1-6 ドラッグ＆ドロップが完了。** DD-01〜DD-03・DD-05 を実装。DD-04（テンポラリ／ライブラリ見出しへのドロップで登録）・DD-06（ライブラリ移動後の自動ラベル付け）・DD-07（ネスト登録の拒否）・DD-08（ロック中の拒否）は、それぞれ 1-13・フェーズ 2・1-13・`LockManager` 未実装のため対象外（該当機能の実装時に追加）。
  - **最小対応 OS を macOS 15.0 → 26.0 に引き上げた**（`project.yml` の `deploymentTarget`/`MACOSX_DEPLOYMENT_TARGET`）。理由は後述の複数選択ドラッグ問題。ユーザーに確認の上での意図的な設計判断。SwiftPM ライブラリ層（`Package.swift` の `.macOS(.v15)`）は SwiftUI を使わないため据え置き。
  - `Sources/qooLibraryApp/MainWindow/DropHandling.swift`: `DropHandling.performDrop(_:into:onComplete:onFailure:)` に D&D の共通処理を集約。Finder と同じ規則 [DD-01]（同一ボリューム内は既定移動・異なるボリューム間は既定コピー、Option キーで反転、`.volumeUUIDStringKey` で判定）。衝突は `.keepBoth`。失敗時は `onFailure` 経由でアラート表示（以前は console print のみで、後述のクロスウインドウの実測時にこの可視化がないと原因追跡できなかった）。
  - `Sources/qooLibraryApp/MainWindow/FolderContentView.swift`: 行に `.draggable(containerItemID:)`（DD-02 実ファイル参照エクスポート）、フォルダ行への `DropIntoFolderModifier`、ペイン全体への `.dropDestination(for: URL.self)`（DD-03 Finder 等からの取り込み）。Cmd/Shift クリックでの複数選択、右クリックメニューは選択に含まれる行なら選択全体を対象にする（Finder 流）。
  - `Sources/qooLibraryApp/MainWindow/FolderTreePane.swift`: ツリー行への `.dropDestination` で移動（DD-05）。
  - `Sources/qooLibraryApp/State/WindowState.swift`: `SessionState.reloadToken`（ファイル操作完了のたびに増分、`FSEventsWatcher` が無い 2-2 前の暫定ポーリング代替）。**ウインドウ単位ではなくセッション全体で 1 つ**（`SessionState.shared`）を共有しており、あるウインドウでの操作が他のウインドウ／ペインの表示にも反映される（後述の実機検証で発見した不具合の修正）。
  - **実機検証（ユーザーによる多数回の手動確認）で完了。** 単一・複数アイテムの D&D、Finder との相互ドラッグ（両方向・同一/異なるボリューム）、複数選択でのコンテキストメニュー操作、Cmd/Shift クリック、複数アイテム同時ドラッグ時のカーソル個数バッジ表示まで確認済み。
  - **実機検証中に見つけて直した実装バグ（`swift test` では発見できなかったもの）**:
    - `List` 行の当たり判定が `Label` の文字幅ぶんしかなく、`.draggable`/`.onDrag` と List 標準のクリック選択が競合して名前クリックが反応しなかった → `.frame(maxWidth: .infinity)` + 明示的な `.onTapGesture` での選択。
    - `.draggable(_:)`（Transferable ベース）は macOS の `List` でドラッグそのものが一切発火しなかった（後述の通り Apple 側の既知の未解決バグ、Feedback FB10128110）。単一アイテムは `.onDrag`（`NSItemProvider` ベース）で当面回避。
    - 同一ボリューム判定に `.volumeURLKey` を使うと、サンドボックス配下のフォルダ一覧経路で解決に失敗し「異なるボリューム」（＝コピー）に誤ってフォールバックしていた → `VolumeEligibilityChecker` と同じ `.volumeUUIDStringKey` に変更。
    - `nextAvailableName`（Finder 流連番）が衝突先の名前（例: `name 2`）をそのまま素のベース名として扱い、次の衝突で `name 2 2` になってしまっていた → 既存の連番サフィックスを剥がしてから採番するよう修正（回帰テスト追加、`FileOperationServiceTests.conflictKeepBothIncrementsExistingSuffixInsteadOfStacking`）。
    - D&D 対応で List 標準のクリック選択を手動処理に置き換えた副作用で、選択したリストにキーボードフォーカスが移らず、選択ハイライトが常に非アクティブ色（グレー）になっていた → `@FocusState` で明示的にフォーカスさせて解消。
    - 右クリックのコンテキストメニュー（複製・ゴミ箱・Finder で表示）が、複数選択中でも右クリックした行 1 つだけを対象にしていた → 選択に含まれる行なら選択全体を対象にするよう修正。
    - D&D 対応で List 標準のクリック選択を手動処理に置き換えた副作用で、Cmd/Shift クリックでの複数選択も失われていた → 手動で Cmd（トグル）・Shift（範囲選択、起点を `selectionAnchor` で保持）を再実装。
    - `WindowState.reloadToken` がウインドウ単位だったため、あるウインドウでの D&D 完了後、別ウインドウで同じフォルダを表示していてもそちらは自動更新されなかった。実機検証中、これが原因で「ウインドウ間で反対方向にドラッグすると何も起きない（実際は移動に成功していたが表示が古かった）→ 同じ行をもう一度ドラッグして実体の無いファイルへのアクセスとなりエラー」という事象が発生し、原因特定に至った → `reloadToken` を `WindowState`（ウインドウ単位）から `SessionState.shared`（セッション全体で 1 つ）に移し、全ウインドウ・全ペインが同じシグナルを見るように変更。
  - **SwiftUI の既知の未解決バグに遭遇し、macOS 26 の新 API で回避した**: `.onDrag`/`.draggable(_:)` は macOS の `List` で複数選択をまとめてドラッグできない（Apple Developer Forums、Feedback FB10128110、2023年7月報告、未修正）。デバッグログで実測したところ、複数選択中でも実際にドラッグされた 1 行分の `.onDrag` しか呼ばれず、SwiftUI が他の選択行を自動的に束ねてはくれないことを確認した。オープンソースの macOS ファイルマネージャー（Nimble Commander・Double Commander・folderium 等）を調査したところ、SwiftUI の `List` を使うもの（folderium）はペイン間の複数ファイル転送を D&D ではなくツールバーボタン（選択全体が対象）で行っており、AppKit 直下のもの（Nimble Commander）は自前の `NSTableView` サブクラス + `pasteboardWriterForRow:` で複数行ドラッグを実現していた。つまり SwiftUI の枠内でこの問題を回避する一般的な方法は無い。最終的に **macOS 26 で追加された `draggable(containerItemID:)` + `dragContainer(for:itemID:in:)` + `dragContainerSelection(_:)`**（`SwiftUI.swiftinterface` で確認、`@available(macOS 26.0, *)`、iOS 側は unavailable）を採用し、最小対応 OS を引き上げることで正攻法で解決した。
- **1-7（圧縮・展開、文字化け対策、展開時のセキュリティ、ライセンス表記一式）が完了。** 文字化け判定のプレビュー UI・手動オーバーライド（EN-01/EN-02）だけは未着手（判定・自動適用は完了）。
  - `Sources/QooKit/Model/AppLimits.swift`: 定数集約の第一号（`AppLimits.Extraction`、EX-21 の既定値）[4章 命名規約]。
  - `Sources/QooKit/Model/Archive/`: `ArchiveFormat`（`cbz`/`cb7`/`cbr` エイリアス込み）、`ArchiveEntry`/`ArchiveListing`（`detectedEncoding` を持つ）、`ExtractOptions`/`ExtractLimits`/`ExtractResult`/`RejectionReason`/`ExtractError`、`ArchiveNameEncodingHeuristic`（§9.2 UTF-8 / CP932 判定ロジック）。
  - `Sources/QooInfrastructure/FileOps/Archive/`: `ArchiveReading` プロトコル、`LibarchiveBackend`（zip/7z/tarGz の読み書き、`PERMISSIVE_ONLY_BUILD` では RAR 読み取りも）、`UnrarBackend`（RAR 読み取り専用、`#if !PERMISSIVE_ONLY_BUILD`）、`ArchiveBackendRegistry`、`EntryPathValidation`（EX-10〜EX-15 の共通パス検証）、`SecureExtractor`（展開の司令塔、EX-01〜EX-24）、`ArchiveCompressor`（圧縮の司令塔、AR-10/AR-11）。**FileOps 隔離検査（B-10）の対象外ディレクトリに意図的に置いている** — ステージング（ユーザー非可視のアプリ内部領域）への書き込みは期待変更台帳・Undo の対象外のため `FileOperationService` を経由しない設計判断（`VolumeEligibilityChecker` と同じ理由・パターン）。ユーザーに見える最終位置への移送・昇格だけは `FileOperationService.promoteFromStaging`／`FileOperationService.move`（`OperationKind.promoteFromStaging` 新設）を必ず経由する。
  - **文字化け対策（AR-02, EN-04）を実際にバックエンドへ統合した。** `LibarchiveBackend.listEntries` がアーカイブを 1 回走査する中で `archive_entry_pathname` の生バイト列を保持し（`String(cString:)` で直接文字列化すると不正な UTF-8 が U+FFFD に化ける — 実機検証で Shift_JIS 名の zip が文字化けした実例で発覚）、全エントリが有効な UTF-8 ならそのまま UTF-8 扱い（EN-04 相当）、そうでなければ `ArchiveNameEncodingHeuristic` で zip/7z のみ判定する（RAR/tar.gz は対象外 [AR-03]）。判定結果は `ArchiveListing.detectedEncoding` として返り、`SecureExtractor` がこれを `extract` の `ExtractOptions.encoding` に引き継ぐため、`extract` 側でアーカイブを再走査する必要が無い。手動でエンコーディングを選び直すプレビュー UI（EN-01/EN-02）は未実装のまま。
  - **libarchive 経由（zip/7z/tarGz）は実バイト数によるリアルタイムの展開爆弾対策ができる**（`archive_read_data` のストリーミングループ内で都度チェック）。**UnRAR 経由（RAR）はできない** — `QooUnrarBridge` の `qoo_unrar_extract_all` がエントリ単位のストリーミング取得やキャンセルに対応しない一括 API のため。RAR は代わりに、①展開前の一覧取得でパス検証し不正なエントリが 1 件でもあればアーカイブ全体を拒否（部分展開はできない）、②展開後にステージング全体の実サイズを検証し超過していれば破棄、という事後チェックにしている。より踏み込んだ対応（UnRAR の `UCM_PROCESSDATA` コールバックを使ったバイト単位の中断）が必要になれば `QooUnrarBridge.mm` の拡張を検討する（自作ラッパーなので改変は問題ない）。
  - **圧縮（AR-10/AR-11）は zip のみ対応。RAR は読み取り専用のため書き込みバックエンドの抽象化（`ArchiveWriting` プロトコル）は導入しなかった** [YAGNI、libarchive 以外の書き込みバックエンドを想定する理由が無いため]。`LibarchiveBackend.compress` がディレクトリを再帰的に zip へ追加し、`ArchiveCompressor` が `SecureExtractor` と同じ「ステージングで作ってから `FileOperationService.move` で最終位置へ」パターンで昇格する。
  - **圧縮エントリ名は書き込み時に NFC 正規化し、読み込み時にも念のため NFC 正規化する（往復とも）[設計判断、9.4 節に追記済み]。** macOS の Foundation API はファイル名を NFD で返すことが多く、そのまま zip に書くと NFC 前提の Windows 側で文字化けする（Mac 製 zip アーカイバでよくある問題）。書き込み時に `.precomposedStringWithCanonicalMapping` を適用しても、libarchive（内部の iconv 実装）が zip を**読み込む際に** HFS+ 互換で NFD へ分解して返すことを実測で確認した（Python の `zipfile` で直接調べると書き込んだバイト列は NFC のままだが、`LibarchiveBackend` で読み直すと NFD になる）。書き込み側だけの正規化では往復一貫性が保てないため、`LibarchiveBackend` の共通デコード関数側でも正規化している。ユーザーに実際の日本語ファイル名で圧縮 → Finder 経由でコピー → 展開しても文字化けしないことを確認済み。
  - **ロケール関連の実装バグを発見・修正した。** `archive_entry_set_pathname_utf8`（UTF-8 明示 API）は内部で「現在のロケール」向けの互換フィールドも導出しようとし、Swift プロセスは C プログラムと違い起動時に自動で `setlocale(LC_ALL, "")` を呼ばないため常に "C"/POSIX ロケールのままで、"Can't translate pathname ... to current locale" エラーになる。`archive_write_set_format_option(writer, "zip", "hdrcharset", "UTF-8")` を試しても同様に失敗した。**`setlocale(LC_ALL, "")` をプロセス全体に対して呼ぶ対処も試したが、これはグローバルな副作用を持つため、他のテスト（並行実行される別スイート）の挙動を変えてしまう回帰を引き起こした**（Swift の協調的スレッドプール下ではどのスレッドで実行されるかも保証されず、根本的に危うい）。最終的に、ロケールに依存しない素の `archive_entry_set_pathname`（生の UTF-8 バイト列をそのまま渡す。Swift の `String` → C 文字列変換は常に UTF-8）に統一し、`setlocale` 系の対処は一切使わない形に決着した。
  - `Sources/qooLibraryApp/MainWindow/FolderContentView.swift`: 右クリックメニューに「ここに圧縮」「圧縮…」[AR-10][AR-11]、対象がアーカイブ形式のときのみ「ここに展開」「（名前）に展開」/「それぞれのフォルダに展開」「展開…」[AR-20〜AR-23] を配線。**圧縮・展開は数秒かかることがあり無表示だとアプリが固まったように見える、という実機検証時のユーザー指摘を受け**、既存の共通コンポーネント `QooProgressPresenter`（1-1 で用意済み、未使用のまま残っていたもの）を使った不定進捗オーバーレイを追加 [UI-09]。バイト単位の進捗（`ProgressReporter`）はまだ無いため、現状は「処理中」の表示のみ。
    - `QooProgressPresenter` 自体の見た目の粗さも実機検証で発覚し修正した: 不定進捗の spinner が `VStack(alignment: .leading)` のせいで左に寄って見えていたため、spinner とタイトル文字列をともに中央寄せにした。
    - 1-6 で D&D 対応のため List 標準のクリック選択を手動の `.onTapGesture(count: 1)` に置き換えていたが、同じ行に `.onTapGesture(count: 2)`（ダブルクリックでフォルダを開く）も付いているため、SwiftUI が「単発クリックかダブルクリックの1回目か」を見極めるためシステムのダブルクリック間隔だけ選択の発火を遅らせていた（Finder に対して選択ハイライトが遅く感じられる、と実機検証で指摘があった）。単発クリックのハンドラを `.onTapGesture(count: 1)` から `.simultaneousGesture(TapGesture(count: 1).onEnded { ... })` に変更し、ダブルクリック判定との排他的な調停グループから外すことで即座に発火するようにした。ダブルクリック・Cmd/Shift 複数選択・ドラッグはいずれも実機で回帰していないことを確認済み。
  - `Sources/qooLibraryApp/About/AboutView.swift` + `qooLibraryApp.swift`: `Window(id: "about")` シーンと「qooLibrary について」メニュー項目を追加し、UnRAR（著作者 Alexander Roshal/RARLAB、RAR 互換アーカイバ開発への使用禁止）と libarchive（BSD-2-Clause）の帰属表示を掲載 [LC-25]。**実機で表示確認済み。**
  - `SecureExtractor.cleanupResidualStaging()` を `qooLibraryApp.init()` から起動時に一度だけ呼ぶ（異常終了後の残存ステージング削除 [RB-07][EX-03]）。`Scene` は `.task` を持てないため `init()` 内の `Task { }` から呼んでいる。
  - `QooKitTests`（12件、`ArchiveNameEncodingHeuristicTests`/`ArchiveFormatTests`）・`QooInfrastructureTests`（新規 28 件、`LibarchiveBackendTests`/`SecureExtractorTests`/`ArchiveCompressorTests`/`FileOperationServiceTests` 追加分）で検証。**`Tests/QooInfrastructureTests/ArchiveFixtureBuilder.swift`** が libarchive の書き込み API で直接 zip フィクスチャを組み立てる（`zip` コマンド経由だとパストラバーサル等の不正なエントリ名が正規化されてしまい再現できないため）。パストラバーサル・絶対パス・シンボリックリンク・エントリ数上限・展開後サイズ上限・圧縮率上限・Shift_JIS ファイル名のデコード・NFC 正規化のいずれも実際に作ったフィクスチャで検証済み。UnRAR 経由（実 RAR ファイル）の自動テストは無し（フェーズ 0 と同じ理由、実 RAR ファイルはユーザー提供のみでリポジトリに含められない。ユーザーによる実機検証では成功を確認済み）。
  - **実装中に見つけて直した実装バグ**: `SecureExtractor.extract()` が成功時にステージングディレクトリを削除しないまま放置していた（`promoteFromStaging` は中身だけを移送し、空になった殻のディレクトリ自体は消さない）。「成功時は削除しない」という早すぎる最適化のフラグ変数が原因で、`extractDoesNotLeaveResidualStagingOnSuccess` テストが実際に空ディレクトリの蓄積を検出して発覚。成功・失敗を問わずステージングを必ず削除するよう修正（テストで実測検証済み）。
  - **最小対応 OS を macOS 26 に上げたことの副産物として** `Window`/`openWindow` などの比較的新しい SwiftUI シーン API が使えるようになり、About ウインドウの実装が単純になった。
- **1-8（キーボードショートカット、KB-01〜KB-05）が完了。** 対応する機能が既に実装済みの操作（開く・上の階層へ・戻る/進む・リネーム・ゴミ箱・新規フォルダ）のみ実際に配線し、他は登録済みだが未配線（下記）。
  - `Sources/QooKit/Model/KeyBinding.swift`: `KeyModifiers`（`OptionSet`）・`KeyCombo`（キー1つ+修飾キー、`QooKit` は Foundation 以外に依存できないため `SwiftUI.KeyboardShortcut` を直接持てない [A-01]）・`ActionID`（`MX-08` の `ManualCommandID` とは別物）・`KeyBinding`・`KeyBindingStore` プロトコル・`DefaultKeyBindings.all`（既定値一覧）。**仕様書（`docs/Specifications/13_UI_共通基盤.md` §13.6）が当初 `KeyBinding.shortcut: KeyboardShortcut?` と `SwiftUI` 型を直接使う設計になっていたため、A-01 に合わせて先に仕様書側を修正してから実装した**（ユーザー確認済み）。
  - `KeyBinding.combos: [KeyCombo]`（**単数の `combo: KeyCombo?` ではなく複数形の配列**）。1つの操作に複数のキーを割り当てられる設計 [KB-01 拡張]。当初は単数で実装したが、実機検証で「戻る」に割り当てた `⌘]` がユーザーの環境で他アプリのショートカットと競合して動作確認ができない事象が見つかり、**Finder 流の `⌘[`/`⌘]` に加えてブラウザ流の `⌘←`/`⌘→` も既定で併用できるようにする**ため、まだコミット前だったこの型を配列に置き換えた（既存のシリアライズ済みデータが無い段階だったため後方互換シムは作らず、素直に型を差し替えた）。
  - `Sources/QooInfrastructure/Preferences/UserDefaultsKeyBindingStore.swift`: `KeyBindingStore` の既定実装。既定値からの差分だけを `UserDefaults` に JSON で保存する。**実装中に見つけて直した不具合**: 当初 `overrides: [ActionID: KeyCombo]`（値が非 Optional）に対して `overrides[action] = combo`（`combo` が `nil` のことがある）という添字代入をしていたが、Swift の `Dictionary` は `nil` の添字代入を「キー削除」と解釈するため、「上書きが無い（既定値を使う）」と「明示的に未割り当てへ上書きした」を区別できなくなっていた（`setBindingToNilUnassignsAction` テストが失敗して発覚）。保存領域を `[ActionID: [KeyCombo]]`（値が配列）に変えたことで、「キーが無い＝上書き無し」と「値が空配列＝明示的に未割り当て」を素直に区別できるようになり、この問題自体が解消された。
  - `Sources/qooLibraryApp/Keyboard/KeyComboConversion.swift`: `KeyCombo` → `SwiftUI.KeyboardShortcut` への変換は View 層でのみ行う [A-01 との整合]。`KeyBindingButtons`（`action` に登録された `combos` の数だけ不可視ボタンを生成する View）が、1つの操作に複数のショートカットを割り当てる実際の配線経路。
  - `Sources/qooLibraryApp/MainWindow/FolderContentView.swift`: 開く（`Enter`、`.onKeyPress`）・上の階層へ（`⌘↑`）・戻る（`⌘[`/`⌘←`）・進む（`⌘]`/`⌘→`）・リネーム（`⌘R`、単一選択時のみ）・ゴミ箱（`⌘⌫`）・新規フォルダ（`⇧⌘N`）を配線。戻る/進むの履歴自体は `WindowState`（タブごとに `backHistory`/`forwardHistory`）が持ち、`navigateCurrentTab(to:)` を経由するすべてのナビゲーション（ツリークリック・ダブルクリック・Enter・上の階層へ）が履歴に積まれる。`goBack()`/`goForward()` 自身は履歴を壊さないよう `navigateCurrentTab` を経由しない。
  - **実機検証で発見・修正したバグ**: 仮想ホーム（サンドボックスコンテナ内 `Data`、`FileManager.homeDirectoryForCurrentUser` の値）で `⌘↑` を押すと、その1つ上（コンテナ本体のルート）へ移動しようとして「permission to view it」エラーになっていた。コンテナルート自体は Unix パーミッション上は読めても、サンドボックスプロファイルは `Data` 配下だけをアプリに開放しており、コンテナルートはアプリの内部実装領域でユーザーにとって意味のある行き先ではない。`FolderContentView` に `canGoToParent`（現在地が仮想ホームと一致したら `false`）を追加し、境界で `⌘↑` を無効化することで解決した。
  - **実機検証（ユーザーによる手動確認）で完了。** 開く・上の階層へ・戻る（`⌘[`/`⌘←` とも）・進む（`⌘→`。`⌘]` はユーザーの環境で他アプリと競合し確認できず）・リネーム・ゴミ箱・新規フォルダのすべてで期待通りの動作を確認済み。
  - `Tests/QooKitTests/KeyBindingTests.swift`（7件）・`Tests/QooInfrastructureTests/UserDefaultsKeyBindingStoreTests.swift`（8件）で、既定値の網羅性・衝突検出（複数キー割り当て時も含む）・既定に戻す・複数ショートカットの永続化を検証。
  - **未配線**（対応する機能が未実装のため）: `quickLook`・`toggleThumbnails`・`copy`/`paste`/`cut`・`focusSearch`・`toggleDisplayMode`・`clearLabelFilter`・`moveToVault`・`undo`/`redo`・`deletePermanently`。いずれも `DefaultKeyBindings.all` には登録済みで、衝突検出・既定に戻すの対象にはなっている。キーバインドのカスタマイズ UI（KB2-02 の「既定に戻す」ボタン等）は 1-12（環境設定）で実装する。
  - **将来検討として記録のみ**（要件定義書に無い、ユーザーからの要望）: マウスのサイドボタン（戻る/進む）・トラックパッドの2本指スワイプでのナビゲーション。詳細と実装方針の見立ては `docs/Specifications/13_UI_共通基盤.md` §13.6「将来検討」参照。実装フェーズ未確定（1-12 候補）。
- **1-9（リスト表示・アイコン表示、サムネイル生成）が完了。** ユーザーとの合意で「リスト表示 → サムネイル基盤 → アイコン表示」の順に実装した。
  - `Sources/qooLibraryApp/MainWindow/FolderContentView.swift`: 中央ペインを `List` から `Table` に置き換えた。名前・更新日・サイズ・種類のカラムを持ち、ヘッダクリックでソート可能 [LV-01]。カラムの表示/非表示は右上の漏斗アイコンのメニューから切り替える [LV-02]。列幅はドラッグで調整可能（`Table` 標準機能）。「フォルダを上にまとめる」トグルも同じメニューにある [LV-03]。
  - **カラム表示/非表示・フォルダまとめ設定は `@AppStorage` で永続化**（アプリ全体で共有、ウインドウ固有ではない）。1-12（環境設定）の本実装が無いため、1-8 のキーバインド上書きと同じ暫定パターン。ソート順自体（`sortOrder`）はタブ/ウインドウをまたいだ永続化はしていない単純な `@State`。
  - `FolderSortComparator`（`SortComparator` 準拠、`enum Key { name, modificationDate, size, kind }` で1つの型に集約）: SwiftUI の `Table` は `sortOrder` を単一のコンパレータ型の配列として要求するため、カラムごとに別のコンパレータ型を使うことができない。名前のソートは `localizedStandardCompare`（Finder 流の自然順、単純な `<` ではない）を使う。
  - `Table` の各カラムは独立したセルのため、`List` のときのように行全体に1回だけ修飾子を付けるのではなく、`rowCell(_:content:)` ヘルパーで選択・ダブルクリック・コンテキストメニュー・D&D の同一の modifier 一式を全カラムのセルへ共通適用している（Finder のようにどの列をクリックしても同じ挙動になるようにするため）。
  - **List→Table の置き換えでも 1-6 で実装した D&D（`draggable(containerItemID:)`/`dragContainer`/`dragContainerSelection`）・複数選択・コンテキストメニュー・キーボードショートカットはすべて無修正で動作した**（実機検証で確認。事前に懸念していた「Table でも同じ macOS 26 API が機能するか」は問題にならなかった）。
  - **実機検証で発見・修正したバグ**: `Label(entry.name, systemImage:)` で "folder" と "doc" の SF Symbol の実測幅が異なるため、フォルダとファイルで名前の先頭位置がずれて見えていた。アイコンを `.frame(width: 16, alignment: .center)` の固定幅に収め、`HStack` で名前と組むことで Finder のように先頭を揃えた。
  - `reload()` が `.fileSizeKey`/`.contentModificationDateKey` も取得するよう拡張。`kindDescription` は `UTType(filenameExtension:)?.localizedDescription` を使う（フォルダは「フォルダ」固定）。
  - **実機検証（ユーザーによる手動確認）で完了。** 各カラムでのソート、カラム表示/非表示、フォルダまとめトグル、D&D（単一・複数選択、Finderとの相互ドラッグ、フォルダへのドロップ）、Cmd/Shift複数選択、右クリックメニュー、ダブルクリック、キーボードショートカットのいずれも回帰なく動作することを確認済み。
  - **リスト表示の実機検証中、ユーザーから「起動直後は3ペインが等幅で中央・右ペインが見切れる」という別件の指摘があり、ペイン幅の保存・復元（`Sources/qooLibraryApp/DesignSystem/PaneWindows.swift`、[UI-02]）をあわせて実装した。** 1-1 時点では構造のみで未実装だった領域（コード中のコメントに明記されていた）。
    - **試行錯誤の末、最終的に AppKit の `NSSplitView.setPosition(_:ofDividerAt:)` を直接呼ぶ方式に落ち着いた。** 過程で分かったこと・捨てた案:
      1. 当初 `NSSplitViewController` + `NSSplitViewItem`（`autosaveName` による自動永続化）への全面置き換えを試したが、実機検証で右ペインが表示されなくなる不具合が発生。原因を視覚的に切り分けられる状況になく、リスクの大きい経路と判断して撤回。
      2. 次に `HSplitView`（SwiftUI）を維持し、`.frame(idealWidth:)` に保存済みの幅を渡す方式を試したが、**`HSplitView` は `idealWidth` を初期レイアウトのヒントとして事実上使わないことが実機検証で判明**（常に等幅で開始する）。これはそもそもの「見切れる」報告の真因でもあった（1-1 の初期実装が元々ハードコードの `idealWidth: 220/280` を指定していたが機能していなかった）。
      3. `minWidth` は確実に尊重される（見切れ防止自体は機能していた）ことを利用し、初回描画だけ `minWidth` を保存済みの幅まで一時的に引き上げてから通常値に戻す方式を試したが、**`minWidth` を戻した瞬間に再レイアウトが走り、しかも戻すたびに違う中途半端な幅（実測: 400→216.5→202.5 のように毎回変動）に収束することが実機検証で判明**。`.frame()` の制約値を動的に変更するアプローチ自体が信頼できないと判断。
      4. 最終的に `.frame()` を一切いじらず、`NSViewRepresentable` でゼロサイズの補助 `NSView` を各ペインの背後に忍ばせ、`superview` を遡って実際の `NSSplitView` を見つけたら `setPosition(_:ofDividerAt:)` を一度だけ呼ぶ方式に変更。右ペイン側は `setPosition` の引数がウインドウ左端からのx座標であり「右ペインの幅」そのものではないため、`splitView.bounds.width - dividerThickness - rightWidth` で逆算している。
    - 幅の観測・保存は `GeometryReader`（`WidthPersistingModifier`）で行い、`UserDefaults`（`@AppStorage`、動的キー `qoo.threePane.\(id).leftWidth` 等）に書き戻す。1-8 のキーバインド上書き・本フェーズのカラム表示設定と同じく、1-12（環境設定）の本実装が無い間の暫定的な永続化先。
    - **実機検証（ユーザーによる複数回の再起動を含む手動確認）で完了。** ペイン幅のドラッグ調整、見切れの解消、アプリ再起動をまたいだ幅の保持のいずれも確認済み。
  - **同じくリスト表示の実機検証の流れで、ユーザーからタブバーの改善要望（「＋」がダイアログを出す・タブ幅が均等でない・閉じるボタンがホバーで出ない）があり、あわせて対応した。**
    - `Sources/qooLibraryApp/MainWindow/TabBarView.swift`: 「＋」はダイアログを出さず `WindowState.openDefaultTab()`（仮想ホームを開く、1-13 でフォルダ登録ができるまでの暫定）を呼ぶ。閉じるボタン（✗）はタブ左端に配置し、ホバー時のみ不透明度を上げて表示（表示/非表示でテキスト位置がずれないよう幅は常に確保）。タブ幅は `HStack` 内の各タブに `.frame(minWidth:100, maxWidth: .infinity)` を与えるだけで均等分割される（2つなら2分割、3つなら3分割）。
    - **タブバーは既定で非表示、タブが2つ以上のときだけ自動表示する**（Safari/Finder 流、`MainWindowView.body` の `if windowState.tabs.count >= 2`）。表示メニューから「常に表示」に切り替えられるようにする案（`@AppStorage` をこの `if` 条件内で読む）も実装したが、**実機検証でアプリ全体がハングする不具合が発生した**（後述）ため撤回し、単純な条件のみにしている。
    - タブバーを既定で隠すと、タブが1枚のときは「＋」ボタンも一緒に消え、2枚目のタブを開く手段が無くなる。これを防ぐため `⌘T`（新規タブ）を追加した。1-8 で作った `ActionID`/`KeyBindingStore` の仕組みに正式に組み込み（`DefaultKeyBindings` に `case newTab` 追加）、`MainWindowView` に他の 1-8 のショートカットと同じ「可視要素を持たない `KeyBindingButtons`」で配線した。**当初は `.commands` + `.focusedValue` で App 側の File メニューに出す実装を試みたが、以下のハング調査でこれも撤回した。**
    - **実機で「ハングアップしているようです」という報告を受け、原因調査を行った。** `ps aux` で確認するとプロセスが継続的に CPU 100% を消費しており（`R` 状態）、デッドロックではなく無限ループだった。`sample` コマンドでスタックを採取したところ `AttributeGraph`/`Hasher`/Unicode 正規化まわりが継続的に呼ばれており、SwiftUI の再描画が止まっていないことを示していた。原因切り分けは以下の手順で行った（各段階でビルド・再起動・`ps aux` によるCPU確認を実施）:
      1. `.focusedValue` にクロージャを渡す実装（`⌘T` を App の `.commands` から呼ぶための橋渡し）を疑い撤去 → 直らず。
      2. `.commands` 内の `Toggle("タブバーを表示", isOn: $alwaysShowTabBar)` を撤去 → 直らず。
      3. `PaneWindows.swift` を直前のコミット（1-8）の内容に戻す → 直らず。
      4. `FolderContentView.swift` も 1-8 の内容に戻す → 直らず。
      5. **作業ツリー全体を `git stash` して直前のコミット（1-8, `eacda7c`）のみをビルド → CPU 0%、正常。** ここで今回の変更のどれかが原因だと確定。
      6. `git stash pop` で変更を復元し、`MainWindowView.body` の `if alwaysShowTabBar || windowState.tabs.count >= 2`（`@AppStorage` を含む条件）を `if windowState.tabs.count >= 2`（`@AppStorage` を使わない条件）に変更 → **CPU 0%、正常に戻った。**
      - **結論: `@AppStorage` で読んだ値をタブバーの表示/非表示を決める `if` 条件の中で使うと、SwiftUI の Observation が無限に再評価を繰り返しハングする**（正確な内部メカニズムまでは特定できていない。`AttributeGraph`/`MainMenuItemHost` 関連のフレームがスタックに出ていたことから、メニューコマンド側の `@AppStorage` 購読と何らかの形で干渉している可能性はあるが未確認）。安全に原因を追い切れる状況ではなかったため、「常に表示」トグル自体を見送るという判断をした。
      - **フォローアップ**: 「常に表示」トグルを実装したい場合は、`@AppStorage` を直接 `if` 条件に使わず、`onChange`/`NotificationCenter` 経由で明示的に同期する別の設計を検討すること。1-12（環境設定）で環境設定 UI 自体を作るタイミングで再検討する。
    - タブ幅について、`GeometryReader` で実測してから `.frame(width:)` を手計算で設定する実装を最初に試みたが、**実機検証でタブバーが新規に挿入される瞬間（1タブ→2タブ）に表示が崩れる**（1つ目のタブが黒く塗りつぶされ、タブ下に黒い余白ができる）不具合が発生した。`GeometryReader` の初回レイアウト時のタイミング競合が疑わしい。`.frame(minWidth:100, maxWidth: .infinity)` を各タブに与えて `HStack` の標準レイアウトに均等分割を任せる方式に変更したところ解消した。**`GeometryReader` は結果的に不要だった**（教訓: 均等分割が欲しいだけなら `GeometryReader` より先に `.frame(maxWidth: .infinity)` を試すべきだった）。
    - **実機検証（ユーザーによる複数回の手動確認）で完了。** 「＋」ボタン・`⌘T` での新規タブ、タブ2枚以降での自動表示・均等幅分割（崩れなし）、ホバーでの閉じるボタン表示・クローズ動作のいずれも確認済み。
  - **コンテキストメニューの拡充。** ユーザーから「中央ペインの右クリックメニューが非常に限定的（新規タブで開く・コピーが無い、空きスペース・タブ・フォルダツリーを右クリックしても何も出ない）」という指摘があり、まず Finder の右クリックメニュー一覧を洗い出し、サンドボックス／本アプリのアーキテクチャ制約で対応不可なものを除外した上で、実装可能なものをすべて実装した（フォルダツリーの右クリックのみ、要件定義書通り 1-13 で対応する計画のまま据え置き）。要件定義書には無い、ユーザー要望ベースの追加。
    - **除外した項目とその理由**: タグ/ラベル付け（xattr 書き込み禁止 [CL-03] という本アプリ独自のアーキテクチャ制約。macOS サンドボックス自体の技術的制約ではない）。復帰（旧バージョンに戻す、汎用ファイル形式には本質的に適用できない）。サービス/クイックアクション（実装コストに見合わないと判断）。
    - **保留にした項目（別途 entitlement が必要、後日検討）**: 「新規ターミナルウインドウで開く」と、Finder 本体の「情報を見る」ウインドウをそのまま呼び出すこと。どちらも `com.apple.security.automation.apple-events` entitlement の追加と、実行時のユーザー許可（TCC プロンプト）が必要（Finder への Apple Events 送信が必要なため）。「情報を見る」自体は自作の簡易シートとして先に実装した。
    - `Sources/QooInfrastructure/FileOps/FileOperationService.swift`: `createAlias(for:in:)`（Finder の「エイリアスを作成」、`URL.bookmarkData(options: .suitableForBookmarkFile)` で本物の Finder エイリアスを作る）と `setLocked(_:locked:)`（Finder の「ロック」/「ロック解除」、`.isUserImmutableKey`）を追加。どちらも実質的なファイルシステム変更を伴うため、既存の他の操作と同じく `FileOperationService` 経由にした [FO-01 の精神]。`OperationKind` に `.createAlias`/`.setLocked` を追加。
    - `Sources/qooLibraryApp/qooLibraryApp.swift`: 「新規ウインドウで開く」に対応するため `WindowGroup { MainWindowView() }` を `WindowGroup(for: URL.self) { $initialFolder in MainWindowView(initialFolder: initialFolder) }` に変更。`openWindow(value: url)` で特定フォルダを初期表示にした新規ウインドウを開ける。⌘N・Dock からの起動など値を指定しない経路は引き続き `nil` → 既定の仮想ホーム。
    - `Sources/qooLibraryApp/MainWindow/FolderContentView.swift`: コピー（⌘C、`NSPasteboard` へファイル URL として書き込み、Finder との相互運用可）・ペースト（⌘V、ペーストボードのファイル URL を現在のフォルダへコピー）・エイリアス作成・共有（`ShareLink`）・ロック/ロック解除・「情報を見る」（自作の簡易シート、`FileInfoSheet`。1-10 の本実装＝カバー画像・ラベル・評価を含む右ペインの詳細情報とは別物）・新規タブ/ウインドウで開く（フォルダのみ）を追加。メニューの並びは「利用頻度が高いと想定される順」にユーザー指摘で並べ替えた（開く／移動系 → 編集系（名前変更・複製・コピー・ゴミ箱）→ 圧縮 → 展開 → 副次的操作（表示・パス・共有・エイリアス）→ 付随情報（ロック・情報）、区切り線もこの単位ごと）。
    - **右クリックした行が現在の選択に含まれない場合の視覚的フィードバック（Finder 流の青い枠線）は、自前の状態管理ではなく `Table` の `.contextMenu(forSelectionType: URL.self) { urls in ... }`（macOS 標準の `NSTableView` 機能を直接使う API）に置き換えることで実現した。** 当初は行ごとに `.contextMenu { ... }` を付ける方式（1-9 のリスト表示実装からの実装）だったが、これだと選択されていない行を右クリックしたときに枠線が出なかった（実機検証で発覚、ユーザーが Finder のスクリーンショットを示して要望）。`forSelectionType` 版は AppKit が対象解決（選択に含まれていればその選択全体、含まれていなければその1行だけ）と枠線描画を両方自動的に行うため、以前手動で書いていた `targetURLs(for:)` ヘルパーも不要になり削除した。空きスペースの右クリック（`urls` が空集合）も同じ API 一本で扱えるようになり、以前は別々だった行用・空きスペース用の `.contextMenu` が統合された。
    - `Sources/qooLibraryApp/MainWindow/TabBarView.swift`: タブの右クリックメニュー（新規タブ・タブを閉じる・他のタブを閉じる）を追加。`WindowState.closeOtherTabs(keeping:)` を新設。
    - **実機検証（ユーザーによる複数回の手動確認）で完了。** 新規タブ/ウインドウで開く・コピー/ペースト・エイリアス作成・共有・ロック・情報を見る・空きスペースメニュー・タブメニューのいずれも動作確認済み。メニューの並び順・区切り線の位置調整、Share の日本語ラベル化、選択されていない行の右クリック時の枠線表示についても、ユーザーからの複数回のフィードバックを反映して修正済み。
  - **右ペインをたたむ（隠す）トグルボタンを追加した**（ユーザー要望、要件定義書には無い）。ウインドウ右上のツールバーに `sidebar.trailing` アイコンのボタンを配置し、`ThreePaneWindow` の `HSplitView` 内で右ペインを `if !isRightPaneCollapsed { ... }` で囲んで表示/非表示を切り替える。中央ペインが空いた分だけ広がり、ウインドウ全体の幅は変わらない。
    - **意図的に `@AppStorage` を使わず、`MainWindowView` の単純な `@State`（再起動をまたいでは保持されない）にしている。** タブバーの表示/非表示を同様の `if` 条件の中で `@AppStorage` を直接読む形にした際、SwiftUI の Observation が無限に再評価を繰り返しアプリがハングする不具合を実機検証で踏んだばかりだったため（本ファイル該当箇所参照）、同じ危険なパターンを避けた。`ThreePaneWindow.isRightPaneCollapsed` は呼び出し側から渡された `Bool` をそのまま使うだけで、永続化の判断自体は一切行わない設計にしている。
    - **実機検証（ユーザーによる手動確認）で完了。** トグルで右ペインの表示/非表示・中央ペインの拡大・幅の記憶（再表示時に元の幅へ戻る）を確認済み。
- **サムネイル基盤（IV-01/08/09、PF-11）が完了。まだ UI（アイコン表示）には配線していない、インフラ層のみ。** 実機で目に見える機能が無いため、この段階の検証は自動テストのみで行った（アイコン表示に配線した時点で改めて実機検証する）。
  - 仕様書の `ThumbnailService`/`CoverImageCache` は `fileID: UUID`/`libraryID: UUID`（SwiftData の `Library`/`ManagedFile` 前提）でキー付けする Phase 2 以降の設計だが、フェーズ1にはまだ DB もライブラリ登録も無い。そのため `QooKit` に既にある `FileIdentity`（volumeUUID + inode、DB 抜きでも使える値型）でキー付けする形に落とし込んだ。同じ理由で `resolveCover` の解決順序（①ユーザー指定 → ②サイドカー → ③先頭画像）のうち①②（DB 依存）は実装せず、③（フォルダ/アーカイブの先頭画像）だけを実装している。ユーザー指定カバー画像用の「複製保存」（TH-04、元の拡張子を保つ）も Phase 2 の対象なので、生成したサムネイルは常に PNG で保存する単純化をした。
  - `Sources/QooInfrastructure/FileOps/Thumbnails/`: `ImageLoading.swift`（`DefaultImageLoader`、ヘッダのみでの寸法チェック [IM-01] → `CGImageSourceCreateThumbnailAtIndex` [IM-03] → 失敗時は例外を投げるのみでアプリを落とさない [IM-04]。ピクセル数上限はテストで注入できるようインスタンスプロパティにしている）、`CoverImageCache.swift`（`DefaultCoverImageCache`、`~/Library/Application Support/qooLibrary/covers/` に PNG で保存 [CL-05]、`prune(toMaxSize:)`/`clear()` [IV-09]）、`ThumbnailService.swift`（`actor`、フォルダ/アーカイブの先頭画像を自然順で解決し生成・キャッシュする）。**`FileManager` で直接キャッシュファイルを書き込む（`FileOperationService` を経由しない）ため、B-10 の許可ディレクトリである `QooInfrastructure/FileOps/` 配下に置いている**（`SecureExtractor`/`VolumeEligibilityChecker` と同じ設計判断・同じ理由: アプリ内部のキャッシュで期待変更台帳・Undo の対象外）。
  - **同時実行数の制限 [PF-11] は自前のスロット管理（`actor` 内の `activeCount`/`waiters: [CheckedContinuation]`）で実装した。** `actor` は自分自身の非 async コードを直列にしか実行できないため、スロット確保後の実際の重い処理（デコード）は `Task.detached` で actor 分離の外へ逃がし、そこで初めて `maxConcurrent` 本の真の並列実行になる。デッドロックしないことをテスト（`handlesMoreRequestsThanMaxConcurrentWithoutDeadlock`、`maxConcurrent: 2` に対し6件同時投入）で検証済み。
  - `Sources/QooInfrastructure/FileOps/Archive/ArchiveReading.swift`: `readEntry(_:entry:encoding:maxBytes:)` を追加（1-7 で「次段階で追加」として意図的に未実装のまま残していたもの）。アーカイブ全体を展開せず、カバー画像用の1エントリだけを読む。`encoding` は `listEntries` が返した `ArchiveListing.detectedEncoding` をそのまま渡す必要がある（`entry.pathname` はその encoding でデコード済みの文字列であり、再走査時に同じ encoding で比較しないと一致しないため）。`LibarchiveBackend` は先頭から走査してデコードしながら比較する素直な実装。`UnrarBackend`（実 RAR）は `QooUnrarBridge` に新規追加した `qoo_unrar_extract_one`（1エントリだけを抽出して即座に走査を打ち切る、大きな RAR を丸ごと展開する無駄を避ける）を使い、一時ファイルへ書き出してから読み直す。
  - `Sources/QooUnrarBridge/`: `qoo_unrar_extract_one` を追加（既存の `qoo_unrar_list`/`qoo_unrar_extract_all` と同じ RARDLL の `RARReadHeaderEx`/`RARProcessFileW` を使うが、目的のエントリが見つかった時点でループを打ち切る点が異なる）。`ThirdParty/unrar/` 配下の UnRAR 本体には一切手を入れていない（自作ラッパーである `QooUnrarBridge.mm`/`.h` のみの変更、ビルド済み xcframework の再生成は不要）。
  - `Sources/QooKit/Model/AppLimits.swift`: `AppLimits.Thumbnail`（ピクセル数上限 1億 [IM-01]、1エントリ読み込み上限 512MB [IM-02]、同時実行数 4 [PF-11]、キャッシュ上限 500MB [IV-09]）を追加。
  - **テスト作成中に実機ではなく `swift build` で見つけた実装バグ**: `guard let X = <複数行にまたがる`.filter{}.sorted(by:){}.first`チェーン> else { ... }` という書き方をしたところ、Swift の型検査が `X` の型を `Array.filter` メソッド自体の型（未呼び出しの関数値）だと誤推論し、無関係な箇所にまで波及するコンパイルエラーになった。中間変数に分けて1行ずつの代入にしたところ解消した（`ThumbnailService.firstImageDataInFolder`/`firstImageDataInArchive`）。原因のコンパイラの挙動自体は特定できていないが、同種の複数行チェーン + `guard let` は避けたほうが安全という教訓として記録しておく。
  - `Tests/QooInfrastructureTests/TestImageFixture.swift`: `CoreGraphics`/`ImageIO` だけで実画像データ（PNG）をその場で生成するヘルパー。バイナリのテストフィクスチャをリポジトリに含めずに済む。
  - `ImageLoadingTests`（6件）・`CoverImageCacheTests`（6件）・`ThumbnailServiceTests`（6件、後述の直接画像ファイル対応で+1）・`LibarchiveBackendTests` に `readEntry` 系3件を追加。**RAR 経由（`UnrarBackend.readEntry`、実 RAR ファイル）の自動テストは無し**（フェーズ0以来一貫した理由: 実 RAR ファイルはユーザー提供のみでリポジトリに含められない）。
  - `ThumbnailService.resolveFirstImageData` に、フォルダ・アーカイブに加えて**画像ファイル自身を直接プレビューする分岐**を追加した（IV-01 の自然な拡張、`.task(id: entry.url)` のコメント参照）。`ThumbnailServiceTests.resolvesThumbnailForAPlainImageFileDirectly` で検証。
- **アイコン表示（IV-01/08/09 の UI 側、PF-10）が完了し、1-9 全体が完了した。**
  - `Sources/qooLibraryApp/MainWindow/IconGridView.swift`（新規）: `LazyVGrid`（可視範囲のみ描画 [PF-10]）+ `ScrollView`。`Table`/`List` と違い選択・D&D・コンテキストメニューまわりの AppKit 標準機能が一切無いため、このファイルで手動再現している。実際の選択・ダブルクリック・コンテキストメニューの中身は `FolderContentView` 側の既存 `private` メソッド（`handleSingleClick`/`contextMenuContent(for:)`/`reloadAndBroadcast` 等）をクロージャとして受け取るだけで、二重実装していない（`FolderEntry`/`DropIntoFolderModifier` の2つの型だけ `private` を外してモジュール内可視にした）。`IconGridView<MenuContent: View>` はコンテキストメニューの内容の型についてジェネリックにし、`AnyView` を避けている。
  - **既知の制限**: `.contextMenu(forSelectionType:)`（`Table` が使う、非選択項目を右クリックしたときに Finder 流の青い枠線を自動描画してくれる AppKit 標準 API）は `List`/`Table` 専用で `LazyVGrid` には使えないため、アイコン表示では各セルへ個別に `.contextMenu` を付ける旧来方式に戻しており、非選択項目を右クリックしたときの枠線表示は無い。
  - `Sources/qooLibraryApp/MainWindow/FolderContentView.swift`: ツールバーにリスト/アイコン切替の `Picker`（`.pickerStyle(.segmented)`、SF Symbol）とアイコンサイズの `Slider`（アイコン表示時のみ表示、`Tokens.iconSize` の範囲を使用）を追加。`WindowState.listStyle`/`iconSize` を `@Binding` で受け取る。
  - `Sources/qooLibraryApp/State/WindowState.swift`: `listStyle` の既定値を `.icon` から `.list` に変更した。1-9 でアイコン表示を実装するまで `.icon` はどこからも参照されておらず実質的な既定表示はずっとリストだったため、配線して初めて意味を持つ値になるこのタイミングで、見た目が急に変わらないよう明示的に `.list` にした [設計判断、ユーザー要望ではなく既存ユーザー体験を壊さないための予防的判断]。
  - **実機検証で発見・修正したバグ（3件）**:
    1. **アイコン表示で Enter キーが効かない・フォルダに入れない。** `IconGridView` のルート（`ScrollView`）が既定では `.focusable()` でなかったため、`.focused($isListFocused)` が何にも結びつかず `.onKeyPress` が発火しなかった。`.focusable()` を追加して解消。
    2. **`⌘↑` で1階層のつもりが2階層上がってしまう。** `Data/Documents/Dummy` にいる状態で ⌘↑ を押すと `Documents` を素通りして仮想ホーム（`Data`）まで戻ってしまう、という実機検証での指摘。当初「OS のキーリピートで `.keyboardShortcut` が二重発火している」という仮説で 300ms のデバウンスガードを実装したが**効果が無く**（症状不変）、仮説が誤りだと判明。両方の関数に一時的なログ（`FileHandle.standardError.write`。`NSLog`/`os_log` は非 Apple 署名プロセスだと内容が `<private>` に伏字化されて実機で読めなかった。実行ファイルを直接ターミナルから起動し標準エラー出力をファイルへリダイレクトして採取）を仕込んで実機検証したところ、**`goToParent()` が呼ばれた瞬間の `folder` の値が実際には1段階古い値になっている**ことが判明した（`WindowState.tabs[index].folder` は正しく最新値を指していたが、`FolderContentView`（値型の View）が自身のプロパティとして保持する `folder` を読む非表示ボタンのクロージャが、フォルダを連続でナビゲートした直後は1世代古い View インスタンスを参照してしまっていた）。「1回の入力で2回移動した」のではなく「1回の移動を、1段階古い位置から行った」が真相だった。同じ非表示ボタンパターンを使う `戻る`/`進む`（`WindowState` というクラス側のメソッドとして最初から実装されており、`@Observable` 経由で常に最新状態を読むため同種の問題が出ていなかった）に合わせ、`goToParent()` を `FolderContentView` から `WindowState.goToParent()`（`navigateCurrentTab(to:)` を内部で使う、`goBack`/`goForward` と同じ構造）に移設して解消した。300ms デバウンスは誤った仮説に基づく対処だったため撤去した。
    3. **⌘↑ 等キーボード操作でのナビゲーション後、選択行がグレー（非フォーカス）表示になり矢印キーがビープするだけになる。** クリック以外の経路（⌘↑・戻る・進む・ツリークリック等）でナビゲートした場合に一覧がキーボードフォーカスを失ったままになっていた。`folder` が実際に変わったとき（`.task(id: folder)` 内）に `isListFocused = true` を設定して解消（`reloadToken` 経由の再読み込みでは他ウインドウ・他ペインのフォーカスを奪わないよう、そちらには適用していない）。
  - **ユーザー要望で追加（要件定義書には無い）**: 中央ペインで何も選択していない状態で↓キーを押すと先頭の項目、↑キーを押すと末尾の項目を選択する（Finder と同じ挙動）。リスト・アイコン両表示に `selectFirstOrLastIfNoneSelected(first:)` を共通で配線。既に何か選択済みの場合は何もせず `.ignored` を返し、リスト表示では `Table` 標準の行選択移動（AppKit の既定キーハンドリング）に処理を譲る。
  - **実機検証（ユーザーによる複数回の手動確認）で完了。** サムネイル表示（フォルダ・アーカイブ・画像ファイル）、選択・複数選択・D&D・コンテキストメニュー、Enter キーでの展開、⌘↑ の1階層ナビゲーション、キーボードナビゲーション後のフォーカス、↓/↑キーでの先頭/末尾選択のいずれも確認済み。
- **未着手**（1-10 以降）: 文字化け判定のプレビュー UI・手動オーバーライド（EN-01/EN-02、1-7 の残り）、Undo 基盤、環境設定（表示密度等の可変設定・キーバインドのカスタマイズ UI・タブバー常時表示トグル・右ペイン折りたたみ状態の永続化・サムネイルキャッシュの上限設定/手動クリア UI [IV-09] を含む）、通知基盤、診断ログ、右ペインの詳細情報（現状 1-2 の検証 UI が仮置き。「情報を見る」の自作シートはこの本実装で置き換える）、ラベルフィルタ（左ペイン下半分、現状プレースホルダ）、フォルダ登録（1-13、フォルダツリーの右クリックメニューもここで追加）、Apple Events 自動化（新規ターミナルで開く・Finder の「情報を見る」を直接呼ぶ、要 entitlement 追加）等。
- **将来検討として記録のみ（要件定義書には無い、ユーザーからの要望）**: **qooLibrary 自身を Finder の「このアプリケーションで開く」の対象にする**（フォルダを右クリック → このアプリケーションで開く → qooLibrary、を選べるようにする）。VSCode 等は自身をフォルダのオープナーとして登録しているが、qooLibrary はまだ登録していないため Finder からフォルダを qooLibrary へ直接渡せない、という実用上の不便から出た要望。
  - 実装の見立て: `Info.plist` の `CFBundleDocumentTypes` に `LSItemContentTypes: ["public.folder"]` を追加して Finder の候補に出るようにし（`project.yml` 側で設定を追加、`xcodegen generate` で反映）、渡された URL を受け取る経路（SwiftUI の `WindowGroup(for: URL.self)` は `onOpenURL`/`application(_:open:)` 経由で自動的に処理される）は 1-9 で「新規ウインドウで開く」用に実装済みの `openWindow(value: url)` と同じ仕組み（`MainWindowView(initialFolder:)`）をそのまま使えると見込んでいる。
  - `AS-01〜AS-07`（`docs/Specifications/12_アプリ層_ユースケース.md` §12.9、1-12 環境設定で実装予定）とは向きが逆（あちらは qooLibrary が「どのファイルをどのアプリで開くか」を管理する側）であり、別の要件として扱う。要件定義書・仕様書のどこにも記載が無いため、実装時に要件 ID を新設するか、13/14 章（UI 共通基盤／メインウインドウ）あたりに追記するかも含めて検討が必要。
  - **ユーザーの意向: ファイルに対する同様の機能と同時に実装したい。** フォルダ単体を先行実装せず、ファイル版の設計とあわせて着手する方針。
  - 実装フェーズ未確定（1-12 の前後、あるいは独立したタスクとして後日着手）。
- **フォルダツリー・リスト表示・アイコン表示すべてで、既定アイコンを Finder と同じものにする改善が完了した**（要件定義書には無い、ユーザーからの要望: SF Symbol の代用アイコンでは視認性が良くないという指摘）。
  - `Sources/qooLibraryApp/MainWindow/FileIconProvider.swift`（新規）: `@MainActor` の単純なパスキー付きメモリキャッシュ + `NSWorkspace.shared.icon(forFile:)`。公開 API で App Sandbox 下でも追加の entitlement 無しに動作する（Launch Services への問い合わせのみで、ファイル内容の読み取りを伴わない）ことを確認済み。カスタムフォルダアイコン・拡張子別のアイコン・アプリバンドルのアイコンいずれも Finder と同一のものが得られる。ディスクへの永続化はしない（サムネイルと違いデコードコストが無く、プロセス起動のたびに再取得すれば十分軽い）。
  - `FolderTreePane.swift`・`FolderContentView.swift`（リスト表示のセル）・`IconGridView.swift`（サムネイル未生成時のプレースホルダ）の3箇所で SF Symbol（`"folder"`/`"doc"`/`"folder.fill"`/`"doc.zipper"`/`"doc.fill"`/`"arrow.turn.up.right"`）を `FileIconProvider.shared.icon(for:)` に置き換えた。シンボリックリンク専用の代用アイコンだった `"arrow.turn.up.right"` は、`NSWorkspace` が対象種別のアイコンに Finder と同じエイリアス矢印バッジを重ねて返すため不要になり削除した。
  - **実機検証（ユーザーによる手動確認）で完了。**
- **将来検討として記録のみ（要件定義書には無い、ユーザーからの要望）**: **フォルダツリーに「ホーム」グループを追加し、実ホームの `アプリケーション`/`デスクトップ`/`書類`/`ダウンロード`/`ムービー`/`ミュージック`/`ピクチャ` を展開できるようにする。** 表示名・アイコンは Finder 準拠（アイコンは `FileIconProvider` で追加コスト無し）。
  - フルディスクアクセスが付与済みなら（`C-04`/`SB-03`/`SB-04`、要件定義書§3.1で確定済みの前提）、これらのフォルダは専用 entitlement もユーザーによるフォルダ選択（Security-Scoped Bookmark）も無しにアクセスできる。サンドボックスのカーネルレベルの制限自体がフルディスクアクセスの許可を見て緩和されるため（1-4 のボリュームツリーの実機検証で実際に確認済みの前提と同じ）。未付与の場合は既存の「アクセス権がありません」フォールバック（`FolderTreePane`）にそのまま乗る。
  - **ユーザーの意向: フルディスクアクセス付与の導線（`SB-03`、初回セットアップウィザード）を実装するタイミングで良い。** その導線自体は `17_実装ロードマップ.md` の **2-17（初回セットアップウィザード、OB-01〜OB-10）** で、フェーズ2の対象。現状は 1-2 で作った `AccessDeniedRow` の「システム設定を開く」ボタンが暫定的にこの役割を担っている。
- **1-10（右ペイン詳細情報表示、DT-01〜DT-07/DT-10）が完了した。**
  - `Sources/qooLibraryApp/MainWindow/InspectorPane.swift`（新規）: 常設のインスペクタ。単一選択時はすべての情報（サムネイル/Finderアイコン [DT-04 相当の視覚表現]、種類 [DT-04]、サイズ [DT-03]、作成日 [DT-01]、変更日 [DT-02]、フォルダ/アーカイブなら含まれるファイル数・サブフォルダ数・合計サイズ [DT-05][DT-06]、場所、フルパス [DT-10]）、複数選択時は共通情報のみ（項目数・合計サイズ）[RP-02]、未選択時は現在のフォルダ自身の情報を表示する（Finder には無い挙動だが、常設インスペクタとして常に何か表示されている方が有用と判断した設計判断）。
  - **DT-05/DT-06（含まれるファイル数・サブフォルダ数）は仕様書が前提とする DB キャッシュ（§9.8）が Phase 1 にはまだ無いため、選択のたびに非同期で再計算する**（`.task(id: url)` が選択変更のたびに前のタスクを自動キャンセルするため、大きいフォルダを選んだ直後に別の項目へ切り替えても古い集計は残らない）。フォルダは `Task.detached` + `FileManager.enumerator` を使い、列挙ループ内で定期的に `Task.isCancelled` を確認して早期終了できるようにした（C-07: 1 ライブラリ 1万〜5万ファイル規模を想定）。アーカイブは 1-9 で実装済みの `ArchiveReading.listEntries` をそのまま使う。キャッシュ自体はフェーズ2（DB 導入時）の課題として残す。
  - **DT-07（アプリの関連付け）・DT-08/DT-09/DT-11（タイトル・シリーズ名巻数・アーカイブ状態）・RP-10〜12（タイトル編集）・RL-01〜09（ラベル）・RA-01〜08（評価）・CV2-02〜08（カバー画像の差し替え）は未実装。** いずれも `AppAssociationService`（1-12）または SwiftData の `Library`/`ManagedFile`（フェーズ2）が前提のドメイン機能のため、1-10 のスコープ外（ロードマップの要件 ID 一覧 `DT-01〜DT-07 / DT-10` 通り）。カバー画像の「表示」のみ（CV2-01 相当）は 1-9 の `ThumbnailService`/`FileIconProvider` を再利用して実装済み。
  - `Sources/qooLibraryApp/Debug/SandboxVerificationView.swift` を削除し、右ペインを `InspectorPane` に置き換えた（前項参照）。
  - **`FolderContentView.swift` から「情報を見る」の簡易シート（`FileInfoSheet`、1-9 までの暫定実装）と関連state（`infoTargets`）を削除した。** 常設インスペクタに機能が統合されたため冗長になったコンテキストメニュー項目も削除。右ペインを折りたたんでいる状態だと詳細情報を見る手段が無くなる点は既知のトレードオフ（折りたたみトグルを解除すればよいだけのため許容）。
  - `MainWindowView.swift`: 右ペインへ `InspectorPane(folder:selection:)` を配線。`selection` は既存の `WindowState.tabs[index].selection`（`FolderContentView` の選択と共有）をそのまま渡すだけで、選択状態を二重管理していない。
  - **実機検証（ユーザーによる手動確認）で完了。** 単一選択・複数選択・未選択それぞれの表示を確認済み。大きなフォルダでのファイル数カウントの検証は、サンドボックス外（フルディスクアクセス付与後）で実際に大きなフォルダにアクセスできるようになってから改めて行う予定（現時点ではサンドボックスコンテナ内に検証に足る規模のフォルダが無いため）。
- **1-11（Undo 基盤、ファイル操作のみ、UD-01〜UD-11/HS-01〜HS-04）が完了した。**
  - `Sources/QooApplication/Command.swift`: `Command` プロトコル・`CommandResult`/`UndoResult`/`FailedItem`・`CompositeCommand`（複数コマンドを1つの Undo 単位にまとめる [UD-04]、`undo()` は children を逆順に実行し失敗した子は部分取り消しとして集約 [UD-07]）。**仕様書は `Command: Sendable` としているが、`@MainActor` プロトコルにする設計判断をした**（実際に扱うのは `CommandStack` とそれを呼ぶ SwiftUI 層のみで、複数 actor をまたぐ必要が無いため。可変な捕捉状態を持つ参照型コマンドを `Sendable` にする複雑さを避けられる）。仕様書の `CommandContext`（`fileOps`/`repositories`/`history`/`notifications`/`progress` を束ねる）も、フェーズ1には `fileOps` 以外の実体（`RepositoryBundle`/`NotificationRouter`/`ProgressReporter`）が無いため導入せず、各コマンドが `init` で `FileOperationService`（既定 `.shared`）を直接受け取る、このコードベース全体で既に使われている DI パターンに合わせた。`affectedFolderIDs`（`LockManager` 用、LK-10）も未実装（`LockManager` 自体がフェーズ1のロードマップに含まれていない。登録フォルダ〈SwiftData の `Library`/`TemporaryFolder`〉が前提のため）。
  - `Sources/QooApplication/CommandStack.swift`: `@Observable @MainActor final class`（仕様書の `ObservableObject`/`@Published` ではなく、既存の `WindowState`/`SessionState` と同じ `@Observable` に統一 [設計判断]）。`.shared` シングルトンだが `FileOperationService`/`SecureExtractor` と同じ理由で `public init()` を残しテスト側で独立インスタンスを作れるようにしている。`run`/`undo`/`redo`、`depth`（既定50 [UD-05]、超過時は最古のコマンドを捨てる [CS-01]）、`undoTitle`/`redoTitle` [UD-06]。新しい `run` で redo スタックを破棄する（一般的な Undo/Redo の規則）。
  - **HS-01〜04（操作履歴）は DB（`OperationLogRecord`、07章）が無い Phase 1 では簡易版に縮小した。** `CommandStack.operationHistory`（メモリのみ、上限500件、アプリ終了で消える）に `run`/`undo`/`redo` のたびに記録する（CS-05 の構造的な要件は満たすが、CSV エクスポート・保持期間設定・専用の操作履歴ウインドウ〈OH-01〜05〉はフェーズ2〈DB導入時〉の対象、まだ表示 UI は無い）。
  - `Sources/QooApplication/FileCommands.swift` + `ArchiveCommands.swift`: `MoveFilesCommand`/`CopyFilesCommand`/`RenameCommand`/`TrashCommand`/`CreateFolderCommand`/`CompressCommand`/`ExtractCommand`（仕様書の11章コマンド一覧のうちフェーズ1のファイル操作に該当するもの）に加え、`CreateAliasCommand`/`SetLockedCommand`（仕様書のコマンド一覧には無いが、1-9 で追加した UI から呼ばれる変更操作を Undo 対象から漏らさないための追加 [設計判断]）。Undo の実装方針: 複製・新規フォルダ・エイリアス作成・圧縮・展開の取り消しは（誤って生成物を失わないよう）完全削除ではなく **Trash へ送る**。移動の取り消しは元の親フォルダへ `.keepBoth` で戻す（元の場所が変化していれば部分取り消し [UD-07]）。すべてのコマンドで `redo()` は `execute()` の再実行と同じにできる（`undo()` が完全に元の状態へ戻すことを前提にできるため、`Command` プロトコルの既定実装として提供）。
  - **`ExtractCommand` の Undo のために `SecureExtractor`/`ExtractResult` を拡張した。** `ExtractResult` に `createdURLs: [URL] = []`（最終位置に実際に作られたトップレベル項目）を追加し、`SecureExtractor.extract()` が `promoteFromStaging` の返り値からこれを埋めて返すようにした。「ここに展開」は既存フォルダへ他のファイルと混在して書き込まれるため、フォルダ丸ごと削除ではなく `createdURLs` だけを Trash へ送ることで、展開前から存在していた無関係なファイルを巻き込まない。
  - **UI 側の全ファイル変更操作を `CommandStack.shared.run(...)` 経由に置き換えた**（`FolderContentView.swift`: ペースト・エイリアス作成・ロック/ロック解除・名前変更・複製・ゴミ箱・新規フォルダ・展開・圧縮、`DropHandling.swift`: D&D のコピー・移動）。1回の操作に複数のコマンドが属する場合（D&D でコピーと移動が混在する場合、新規フォルダ作成込みの展開）は `CompositeCommand` で1つの Undo 単位にまとめている。`DropHandling` は `Command`（`@MainActor` プロトコル）を構築する必要があるため `enum` 自体を `@MainActor` にした（呼び出し元はすべて SwiftUI の View クロージャで元々 MainActor 上だったため実質的な変更は無い）。
  - `Sources/qooLibraryApp/MainWindow/MainWindowView.swift`: `⌘Z`/`⇧⌘Z` を配線（1-8 で登録済みだった `ActionID.undo`/`.redo` を実際に使用。`CommandStack` はウインドウ単位ではなくアプリ全体で単一のため、特定のタブ/フォルダに依存せずウインドウ直下の隠しボタンとして配線）。`Sources/qooLibraryApp/qooLibraryApp.swift`: Edit メニューにも Undo/Redo の項目を追加（動的なタイトル表示 [UD-06]）。**実際のキーボードショートカットはここでは付けていない** — `KeyBindingButtons`/`DefaultKeyBindings` をアプリの唯一の配線経路にするため（1-8 以来の他のショートカットと同じ仕組みに揃える設計判断、メニューの `.keyboardShortcut` と二重に登録すると SwiftUI の挙動が読みにくくなることを避けた）。
  - **実機検証で発見・修正したバグ**: Undo/Redo 自体は成功していたが、他のファイル操作系の経路（`reloadAndBroadcast()`）と違い `SessionState.shared.reloadToken` を伝える処理を入れ忘れており、画面が古いまま更新されなかった（実際には正しく取り消されていたが、フォルダを移動して戻ってくるまで気づけなかった）。`MainWindowView`/`qooLibraryApp.swift` の Undo/Redo アクションに `SessionState.shared.reloadToken += 1` を追加して解消。
  - `Tests/QooApplicationTests`（新規テストターゲット、21件）: `CommandStackTests`（run/undo/redo、深さ超過時の破棄 [CS-01]、redo スタックのクリア、操作履歴の記録）、`FileCommandsTests`、`CompositeCommandTests`（`FakeCommand`/`CallRecorder` を使い実行順序・部分失敗の集約を検証）。**Trash を経由する Undo（`copy`/`createFolder`/`createAlias`/`compress`/`extract`/`trash` コマンドの取り消し）は実 Finder ゴミ箱に触れるため自動テスト対象外**（`FileOperationServiceTests`/`ArchiveCompressorTests` と同じ方針）。それらは `execute()` の結果までを検証し、`undo()` 自体は実機検証で確認した。`move`/`rename`/`setLocked` は実 Trash に触れないため Undo まで含めて自動テストしている。
  - **実機検証（ユーザーによる複数回の手動確認）で完了。** 新規フォルダ・移動・複製・名前変更・ゴミ箱・圧縮・展開・D&D（コピー/移動）のそれぞれで実行→⌘Z（取り消し）→⇧⌘Z（やり直し）、Edit メニューの動的タイトル表示のいずれも確認済み。
- **⌘N で開いた新規ウインドウのサイズを既存ウインドウに揃え、アプリ再起動後も復元する機能を追加した**（要件定義書には無い、ユーザーからの要望。UI-08 相当）。
  - `Sources/qooLibraryApp/DesignSystem/WindowFrameAutosave.swift`（新規）: 当初 AppKit 標準の `NSWindow.setFrameAutosaveName(_:)`（1回呼ぶだけで復元・以後の自動保存の両方をやってくれるはずの API）を使ったが、実機検証でウインドウ幅が揃わないことが判明した（リサイズ後に ⌘N しても新規ウインドウに反映されない）。原因を深追いするより、`PaneWindows.swift` のペイン幅永続化で実績のある方式（`NSWindowDidResize` 通知を自分で監視して `UserDefaults` へ明示的に書き込み、新規ウインドウでは明示的に読み込んで1回だけ適用する）に統一した方が確実と判断し、そちらへ切り替えた。適用は `PaneWindows.swift` の `SplitPositionApplierView` と同じ理由で `DispatchQueue.main.async` により1サイクル遅らせている（SwiftUI 自身のウインドウサイズ決定ロジックが直後に走り即座の適用を上書きすることがあるため）。
  - **位置（origin）は意図的に対象外にした。** 当初は位置も含めて復元していたところ、⌘N で開いた新規ウインドウが既存ウインドウとまったく同じ位置・サイズになって完全に重なり、見た目上「消えた」（実際は閉じておらず背後に重なっていただけ）というユーザー報告があった。サイズだけを保存・復元し、位置は AppKit 標準のカスケード配置に任せる方式に修正した。
  - **ゾンビウインドウ対策として `.restorationBehavior(.disabled)` を予防的に追加した。** 姉妹プロジェクト qooViewer（同じユーザーが開発）のソースコードを参照したところ、SwiftUI の `WindowGroup` 標準の状態復元が、閉じたはずの古い `NSWindow` を再利用してしまい中身が正しく描画されない・`onAppear` が意図せず再発火するなどの実機バグが実際に報告・修正されていた。qooLibrary のウインドウ位置・サイズの記憶は上記の自前の `UserDefaults` ベースの仕組みで行っており標準の状態復元には依存していないため、無効化しても既存機能に影響しない。`.windowResizability(.automatic)` + `.defaultSize(width: 900, height: 560)` も合わせて設定した（qooViewer のコメントで、`.contentSize` のままだと SwiftUI がコンテンツサイズからフレームを再計算しようとして自前の復元と競合すると報告されていたため）。
  - **既にペイン幅（左右の分割位置）は全ウインドウで共有・永続化されていた**ことも今回わかった（`ThreePaneWindow` の内部 ID が全ウインドウで同じ `"main"` のため、`@AppStorage` キーが元々共通だった）。追加対応は不要だった。
  - **右ペインの折りたたみ状態も、新規ウインドウへの反映と再起動をまたいだ保持の両方に対応した。** `MainWindowView.isRightPaneCollapsed` の `if` 条件では引き続き素の `@State` だけを見る（タブバー表示/非表示のハング不具合を踏まえた既存方針を維持、`ThreePaneWindow` のコメント参照）。その代わり、初期値だけ `init` で `UserDefaults` から素の値として読み込み（リアクティブな購読ではない）、トグル時に明示的に書き戻す一方向同期にすることで、`@AppStorage` を `if` 条件内で直接読む危険なパターンを踏まずに両方の要望を満たした。
- **Finder 流のインライン名前編集を実装した**（要件定義書には無い、ユーザーからの要望: リネームは別ウインドウ/アラートではなく中央ペインのその場で行いたい）。
  - `FolderContentView.handleSingleClick`: 既に選択済みの1件だけをもう一度クリックすると、少し待って（400ms、ダブルクリックとの区別のため）からリネームを開始する。クリックのたびに増分する `pendingRenameGeneration` を使い、その間に別のクリック（ダブルクリックの2回目・他項目の選択・修飾キー付きクリック等）が起きたら自動的にキャンセルされる。
  - リスト表示（`Table` の名前セル）・アイコン表示（`IconGridView` のラベル）とも、名前を `Text` から `TextField` へ切り替えるインライン編集にした（旧: `.alert` によるモーダルダイアログ、`FileInfoSheet` と同様に削除）。編集中の行/セルは選択・ダブルクリック・D&D 用のジェスチャをすべて外し、`TextField` 自身のクリックが誤って再トリガーされないようにしている。Enter で確定・Esc で取り消し・他の項目のクリックやフォーカス喪失でも確定する。名前が変わっていなければ何もしない（Undo スタックを無意味に汚さない）。
  - `Sources/qooLibraryApp/MainWindow/InlineRenameSupport.swift`（新規、リスト・アイコン両方で共有）: リネーム開始時、Finder と同じく拡張子を除いたファイル名部分だけを選択状態にする。SwiftUI の `TextField` は選択範囲操作を公開していないため、AppKit のフィールドエディタ（`NSApp.keyWindow?.firstResponder as? NSText`）へ直接アクセスする。フォーカスが実際に割り当てられた後でないと機能しないため `DispatchQueue.main.async` で1サイクル遅らせて呼ぶ。
  - **将来検討として記録のみ**: 「拡張子を含めて選択」に切り替えられる環境設定（ユーザーからの要望、1-12 で実装予定）。現状は上記の Finder 流の既定動作のみで、切り替え UI 自体はまだ無い。
- **フォルダツリー・アイコン表示の選択ハイライト色を AppKit のシステム標準色に変更した**（要件定義書には無い、ユーザーからの要望: 独自の半透明アクセントカラーだと Finder のような青にならないという指摘）。
  - `FolderTreePane.swift`: `Color(nsColor: .selectedContentBackgroundColor)` に変更（このツリーはフォーカスの概念を持たない表示専用の選択のため常に強調表示）。選択時の文字色も `.alternateSelectedControlTextColor`（白）にして濃い青背景でのコントラストを確保。
  - `IconGridView.swift`: `Table` と同じくフォーカスの有無で `selectedContentBackgroundColor`（濃い青）と `unemphasizedSelectedContentBackgroundColor`（灰色）を切り替えるようにした（`FolderContentView.isListFocused` を新しい `isFocused` パラメータとして受け取る）。選択時の文字色もフォーカスありのときだけ白にする。
- **1-13（ライブラリ／テンポラリフォルダの登録・削除、RG-01〜RG-08）が完了した。** 1-12/1-12b より依存関係上先に着手できたため、ロードマップの番号順を飛ばして先に実装した（1-13 の依存は 1-2/1-4 のみ）。
  - **ロードマップの注記通り「エイリアス相当」に留めた。** SwiftData（`Library`/`TemporaryFolder` モデル）がまだ無いため、`Sources/QooInfrastructure/FileOps/RegisteredFolderStore.swift`（新規）は実フォルダへの参照（Security-Scoped Bookmark）と表示名だけを持つ軽量なレコードを JSON（`Application Support/qooLibrary/registeredFolders.json`）で永続化する `actor`。8章 §8.7 疑似コードの①〜④（シンボリックリンク解決 [SL-07]、入れ子禁止 [RG-03][RG-04]、FS 適合検証 [RG-08]、ブックマーク生成 [RG-07]）は実装したが、⑤（テンプレート適用・初回フルスキャン）はラベル・スキャンドメインが無い Phase 1 のスコープ外。RG-06（登録解除時のラベル保持選択）もラベル自体が無いため意味を持たず、単純に削除するのみにした。
  - **Security-Scoped Bookmark は「登録されている間はアプリ終了までアクセスを開始したまま保持する」方針にした**（個々の読み取り操作のたびに `startAccessing`/`stopAccessing` するのではない）[1-2 の実機検証で確認済みのパターンの応用]。これにより `FolderTreeNode.children(of:)`/`FolderContentView.reload()` など、既存の素の `FileManager` 呼び出し（読み取り専用、FileOps 隔離検査の対象外）を一切変更せずに登録フォルダにも対応できた。
  - **すべての公開メソッドの先頭で `ensureLoaded()`（初回だけ JSON 読み込み＋ブックマークのアクセス開始）を呼ぶ設計にした。** 当初はアプリ起動時に明示的に1回だけ `loadAndActivateAll()` を呼ぶだけの設計だったが、`FolderTreePane` 側の `.task` も独立して起動時に同じストアへアクセスするため、どちらが先に実行されるか保証できないレースコンディションになると気づき、呼び出し順序に依存しない設計に直した。
  - `Sources/qooLibraryApp/MainWindow/FolderTreePane.swift`: 「テンポラリフォルダ」「ライブラリフォルダ」見出しの「+」ボタンで `NSOpenPanel` を開いて登録する（DD-04 のドロップ登録は今回のスコープ外、後日検討）。登録済みフォルダは解決した URL から `FolderTreeNode` を構築し、既存の `FolderTreeRow`（ボリューム行と共通）でそのまま表示・展開・D&D できる。登録ルート行にだけ右クリックメニュー（「表示名を変更…」[RG-05]・「登録解除」）を出す（`registeredFolder`/`onRename`/`onUnregister` を再帰呼び出しでは `nil` のままにすることで、実フォルダの深い階層に誤ってメニューが出ないようにしている）。ブックマーク解決に失敗した場合（ボリューム未接続等 [SB-05]）は専用のグレーアウト行（`OfflineRegisteredFolderRow`）を表示し、そこからも登録解除だけはできる。
  - `Sources/qooLibraryApp/qooLibraryApp.swift`: 起動時に `RegisteredFolderStore.shared.loadAndActivateAll()` を呼ぶ（`SecureExtractor.cleanupResidualStaging()` と同じ `init()` 内の `Task`）。
  - `Tests/QooInfrastructureTests/RegisteredFolderStoreTests.swift`（新規8件）: 登録・種別ごとの一覧取得・入れ子禁止（祖先・子孫の両方向）・登録解除・表示名変更・別インスタンス間での永続化・FS 非対応時の拒否（フェイクの `VolumeEligibilityChecking` で模擬）を検証。実際の Security-Scoped Bookmark 生成・解決は非サンドボックスの `swift test` プロセスでも成功する（サンドボックス外ではスコープ強制自体が無効なだけで API 自体は動く、既存の `SecurityScopedBookmarkResolverTests` と同じ前提）ため、フェイクを使わず実装をそのままテストしている。
  - **実機検証（ユーザーによる手動確認）で完了。** 「+」ボタンでのライブラリ／テンポラリ登録、登録フォルダのツリー表示・展開、登録解除、表示名変更のいずれも確認済み。
- **1-12b（エラー処理と通知の共通基盤、ER-01〜ER-34）が、DB に依存しない範囲で完了した。** ロードマップの依存関係上 1-13 より先に着手できたが、実際には 1-13 の後に実装した（1-11 完了時点でのユーザーとの相談で 1-13 を先に選んだため）。
  - `Sources/QooKit/Model/Notification.swift`（新規）: `NotificationSeverity`（強度1〜5）・`UserPresentableError` プロトコル・`RecoveryAction`・`NotificationItem`。仕様書の `RecoveryAction.Kind` には `.openWindow(WindowRoute)`/`.runCommand(ManualCommandID)` もあるが、`WindowRoute`（ウインドウルーティング基盤）も `ManualCommandID`（11章 §11.6）もまだ無いフェーズ1では組み込めないため、`.retry`/`.openSystemSettings(String)`/`.dismiss` の3種類のみに絞った。
  - `Sources/QooInfrastructure/Log.swift`（新規）: OSLog カテゴリの集約（`Log.ui`/`Log.fileOps` 等）[MT-05]。
  - `Sources/QooApplication/NotificationRouter.swift`（新規）: `@MainActor @Observable` の `CommandStack` と同じ方針。**severity に応じてどう見せるかを判断する部分（`QooApplication`、AppKit/SwiftUI 非依存）と、実際にどう描画するか（`qooLibraryApp`）を分離した**。専用の「一時通知（トースト）」UI がまだ無いため、フェーズ1では `.appModal`/`.sheet`/`.inline` の3段階すべてを同じアラートで表示する（データモデル上は区別を保持済み、UI が揃い次第描き分けられる）。`.transient`/`.logOnly` は OSLog のみで UI には出さない。`UserPresentableError` に未準拠の素の `Error` から最小限の `NotificationItem` を組み立てる `presentError(_:whatHappened:)` を用意し、既存のエラー型（`FileOperationError` 等）を ER-03 の三要素文言（何が/なぜ/次に何ができるか）に完全準拠させる作業は別途の課題として残した。
  - **[CB-11] 強度4以上（一時通知／ログのみ）だけをメモリ内の簡易履歴に記録する。** アプリモーダル・シート・インラインはその場でユーザーが直接見ているため、別途の履歴を必要としないという仕様書の判断軸に従った。DB（`NotificationHistoryStore`、07章）がまだ無いフェーズ1では、1-11 の `CommandStack.operationHistory` と同じ「メモリのみ・上限あり・閲覧UIなし」の簡易版。
  - **`Sources/qooLibraryApp/DesignSystem/NotificationRouterPresenter.swift`（新規）は、当初 SwiftUI の `.alert(isPresented:)` を `MainWindowView` に適用する設計だったが、実機検証で2つの問題が見つかり、AppKit の `NSAlert` を直接使う命令的な方式に作り直した。**
    1. `NotificationRouter.shared` はアプリ全体で単一（`CommandStack` と同じ方針 [UD-02]）のため、複数ウインドウを開いていると、それぞれのウインドウが同じ `currentModalItem` を見て**両方に同じエラーダイアログが表示された**。
    2. `@Environment(\.controlActiveState)` でキーウインドウかどうかを判定してこれを1つに絞ろうとしたところ、今度は**アラート自体がまったく表示されなくなった**（この深いビュー階層＋複数の `NSViewRepresentable` 橋渡しの組み合わせでの信頼性を安全に検証できる状況ではなかった）。
    - 最終的に、`NotificationRouterPresenterController`（`@MainActor` のシングルトン）が `withObservationTracking` で `NotificationRouter.currentModalItem` を監視し、変化のたびに `NSApp.keyWindow` をその場で問い合わせて `NSAlert.beginSheetModal` を1回だけ呼ぶ方式にした。「表示する瞬間に一度だけ、命令的にどのウインドウに出すか決める」ことで、複数ウインドウでの重複や宣言的バインディングのタイミング問題を構造的に回避している。`QooLibraryApp.init()` から `NotificationRouterPresenterController.shared.start()` を一度だけ呼ぶ。
  - **既存の各画面が独自に持っていたエラーアラート（ER-01 が禁じる「機能ごとに独自の提示方法」）をすべて `NotificationRouter` 経由に置き換えた。** `FolderContentView.swift`（`actionError` 状態と専用 `.alert` を削除、10箇所の `catch` 節と D&D 失敗コールバックを移行）・`FolderTreePane.swift`（`dropError`/`registrationError` を削除）・`DropHandling.swift`（`onFailure` の既定値が以前は `print` でコンソールに出すだけ＝**ユーザーには一切見えていなかった**バグを修正）。
  - **実機検証でさらに2件の実装バグを発見・修正した**（1-12b の作業そのものではなく、通知経路を通してテストした結果見つかった既存コードのバグ）:
    1. 上記の「複数ウインドウで重複表示される」問題（`NotificationRouterPresenterController` 参照）。
    2. **同名フォルダを重複作成してもエラーが出なかった。** `FileOperationService.createDirectory` が `FileManager.createDirectory(at:withIntermediateDirectories: true)` を使っており、これは対象がすでに存在していてもエラーを投げない Foundation の標準動作だった（`options: OpOptions` パラメータ自体も無視されており、衝突判定が一切無かった）。Finder と同じく既存項目との衝突をエラー扱いする事前チェックを追加した。
  - **未実装（スコープ外、CLAUDE.md に記録のみ）**: `BatchNotificationSession`（ER-10〜16、「以降すべてに適用」・結果サマリ）は、現時点でこれを必要とする一括処理フロー自体が無い（既存の一括処理は単純な「最初の失敗で中断」のみ）ため、具体的な呼び出し元の無いまま作る投機的な実装になってしまうと判断し見送った。`NotificationHistoryStore`（SwiftData 版）・通知履歴ウインドウ（NW-01〜08）・`SystemNotificationGate`（ER-30〜34、システム通知）もフェーズ2以降。既存のエラー型を `UserPresentableError` に完全準拠させる作業（ER-03 の三要素文言）も未着手。
  - `Tests/QooApplicationTests/NotificationRouterTests.swift`（新規7件）: モーダル severity での表示・`resolve` によるアクション返却・`.transient`/`.logOnly` が UI を出さないこと・[CB-11] の履歴記録範囲・複数アイテムのキューイング・`presentError` の橋渡し（`UserPresentableError` 準拠時とそうでない場合の両方）を検証。
  - **実機検証（ユーザーによる複数回の手動確認）で完了。** D&D 失敗・重複フォルダ作成のいずれもエラーダイアログが表示されること、複数ウインドウでの重複表示が解消されたことを確認済み。
- `QooApplication` は 1-11 で `Command`/`CommandStack`（ファイル操作の Undo 基盤）が実装され、プレースホルダの段階を脱した。`QooKit`/`QooPersistence` の中身はまだプレースホルダ（モジュール依存関係を検証するための最小限のマーカー型のみ）で、ドメインロジック・SwiftData モデルは一切実装していない。`QooInfrastructure` はサンドボックス／FS 検証・ファイル操作・アーカイブ・サムネイルを実装済み（DB 依存部分のみ未実装）。
- **メインウインドウのツールバーを刷新し、`ThreePaneWindow`（`HSplitView` ベース）から `NavigationSplitView` + `.inspector()` へ移行した**（要件定義書には無い、ユーザー要望: 戻る/進む/上の階層へ・表示切替・新規フォルダ・右ペイン折りたたみを Finder 風の実ウインドウツールバーに配置したい）。
  - **[CP-01 の例外]** `MainWindowView` だけは共通コンポーネント `ThreePaneWindow`（`PaneWindows.swift`）を使わない。理由: 戻る/進む/上の階層へのツールバー項目を「サイドバーとの境界線（分割線）を追跡してセンター（detail）ペインの左端に揃える」には、AppKit の `NSTrackingSeparatorToolbarItem` に対応する SwiftUI の `NavigationSplitView`（`.navigation` 配置のみ対応）が必須で、`ThreePaneWindow`（プレーンな `HSplitView`）ではこの自動追従が得られない。`ThreePaneWindow`/`TwoPaneWindow` 自体は他画面向けにそのまま残しており、CP-01 の原則自体は変えていない。
  - `PaneWindows.swift` の `SplitPositionApplierView`（`NSSplitView.setPosition` を使う自前ブリッジ、1-9 で苦労して実装したもの）はもう使わない。`NavigationSplitView`/`.inspector()` は `ideal:` パラメータ（`.navigationSplitViewColumnWidth(min:ideal:max:)`/`.inspectorColumnWidth(min:ideal:max:)`）を実際に尊重してくれる（`HSplitView` の `.frame(idealWidth:)` は無視されていた、1-9 の実機検証参照）ため、単に永続化した幅を `ideal:` に渡すだけで済むようになった。幅の観測・保存（`GeometryReader` + `@AppStorage`）は同じキー文字列（`qoo.threePane.main.leftWidth`/`rightWidth`）のまま `MainWindowView.swift` 内の `PaneWidthPersisting` に複製し、既存の保存値をそのまま引き継いでいる。
  - **戻る・進む・上の階層へは `ToolbarItemGroup(placement: .navigation)` の素の `Button` 3つ**にしている。`ControlGroup`（丸皮グループ化）を併用すると、実機検証で `ControlGroup` の中身だけが `.navigation`（先頭側）ではなく末尾側に配置されてしまう現象が起きた（`Button` 単体は正しく先頭に来る）。`ControlGroup` をやめても macOS 側が `.navigation` 内の連続ボタン列を自動的に丸皮風の見た目にまとめてくれるため、視覚的なグループ化は失われない。実機検証で、この3つが常にサイドバーとの境界線（＝中央ペインの左端）にきちんと揃うことを確認済み。
  - **右ペイン（インスペクタ）を表示すると、`.navigation` 以外の配置のツールバー項目はすべてインスペクタ側の境界線を追従してインスペクタの上へ移動してしまう**ことが実機検証で判明した（中央ペインの範囲内に留めることはできない）。既定配置（`.automatic`）・明示的な `.primaryAction`・`.toolbar` の付け替え（`NavigationSplitView` 側 / `.inspector` の中身側）のいずれを試しても同じ結果で、Apple Developer Forums でも同種の報告があり macOS バージョンをまたいで挙動が変わる SwiftUI 側の未整備な領域と判断した。「表示切替（リスト/アイコン）」「新規フォルダ」ボタンは、この制約を承知の上でユーザーの判断により実ツールバー（`.primaryAction`）に置いている（インスペクタを開くと中央ペイン範囲外に出るが許容）。
  - **隣接する単独アイコンボタン2つ（「新規フォルダ」と「右ペイン折りたたみ」）を視覚的に別グループへ分離することは、5通りの方法を試したが実現できなかった**（既知の限界、macOS 26 の新しいツールバー描画〈Liquid Glass〉側の挙動と考えられる）: ① `ToolbarSpacer(.fixed, placement: .primaryAction)` を挟む、② `ToolbarSpacer(.flexible, ...)`、③ 片方の `placement` を `.secondaryAction` に変更（分離はされたがツールバー中央〈タイトル付近〉という全く別の場所に移動してしまった）、④ 一方を `ToolbarItemGroup` でまとめる、⑤ 両方を個別の `ToolbarItemGroup` にする。隣接する2つの単独アイコンボタンは常に1つの角丸グループへ自動的に吸収されてしまい、`ToolbarItemPlacement`/`ToolbarSpacer` の公開 API では制御できなかった。ユーザーに確認の上、この制限を受け入れている。
  - **ウインドウタイトルをカレントフォルダ名にした**（`.navigationTitle(currentFolderTitle)`、以前はアプリ名「qooLibrary」固定だった）。`FileManager.default.displayName(atPath:)` を使い `PathBarView`/`FileIconProvider` と同じ Finder 準拠のローカライズされた表示名にしている。
  - **右ペインを開くとウインドウ全体の幅が自動的に広がり（実測 1221pt → 1562pt 程度）、閉じても元の幅には戻らない**という `ThreePaneWindow` 時代には無かった副作用が実機検証で見つかった（`ThreePaneWindow`/`HSplitView` は右ペイン表示時に中央ペインを縮めるだけでウインドウ全体の幅は不変だったが、`NavigationSplitView`/`.inspector()` はインスペクタの `ideal` 幅を確保するためウインドウ自体を広げようとする）。実害は無い（許容範囲）と判断したが、気になる場合は 1-12 以降で `.inspector` 表示時のウインドウ幅制御を再検討する余地がある。
  - **不可解な事象は先に `WebSearch`/`WebFetch` で調べる**という上記ルールを本タスクで初めて実践し、`NSTrackingSeparatorToolbarItem`・`.inspector()` のトラッキング挙動・`ToolbarSpacer` の存在をいずれも実装前後の検索で特定できた（特に `ToolbarSpacer` は macOS 26 の新 API で、知らなければ存在に気づけなかった）。ただし検索で見つかった「移動すれば直る」という情報（Apple Developer Forums のワークアラウンド）が実機では効果が無かった例（インスペクタの境界追従問題）もあり、**検索結果は仮説として実機検証で必ず裏取りする**という運用を継続している。

作業を始める際は、対象領域の仕様書（下記 §2 の一覧）を該当箇所だけ `Read` してから着手する。仕様書は合計 18 ファイルあり、全部を毎回読み込む必要はない。要件定義書本体は `docs/Requirements/qooLibrary_要件定義書_v2.8.md` にある（約 2,900 行）。矛盾したときの優先順位は §1 参照。

## 1. アプリ概要

qooLibrary は macOS 用の**マンガ・同人誌ライブラリ管理アプリ**（Swift / SwiftUI / SwiftData）。3 つの役割を段階的に提供する。

1. **ファイルマネージャー** — Finder の代替として日常使用できる
2. **ライブラリマネージャー** — ファイル名・フォルダ構成からラベルを自動抽出し、フィルタ・検索・評価・カバー画像などで管理する
3. **テンポラリフォルダ** — 取り込んだファイルを自動リネーム・変換リネーム・一括リネームで整形し、ライブラリへ投入するワークフロー

対応する要件定義書は「qooLibrary 要件定義書 v2.8」（約 1,053 要件 ID、`docs/Requirements/qooLibrary_要件定義書_v2.8.md`）。実装仕様書 `docs/Specifications/` はこれを実装に落とし込んだもので、要件 ID を `[XX-00]` の形式で併記している。両者が矛盾した場合は要件定義書が最上位だが、実務上は日常的には `docs/Specifications/` の記述に従い、矛盾を見つけたら仕様書側を直す（無断でコードだけ仕様と異なる実装にしない）。要件定義書は分量が大きいため、要件 ID の一次情報や仕様書に説明のない詳細を確認したいときだけ該当セクションを開く。

## 2. ドキュメント地図（`docs/Specifications/`）

| # | ファイル | 内容 |
|---|---|---|
| 00 | `00_概要とドキュメント構成.md` | 全体像・モジュール地図・命名規約・並行性モデル |
| 01 | `01_プロジェクト構成とビルド.md` | リポジトリ構成、SwiftPM ターゲット、entitlement、FS 適合検証 |
| 02 | `02_共通基盤_定数エラーログ.md` | `AppLimits`、`UserPresentableError`、`NotificationRouter`、ログ |
| 03 | `03_ドメイン層_正規化と値型.md` | 文字列正規化、`NormalizedString`、値オブジェクト |
| 04 | `04_ドメイン層_フォーマットパーサ.md` | ファイル名フォーマットの字句解析・構文木・マッチャ（中核） |
| 05 | `05_ドメイン層_シリーズ巻数.md` | 巻数フォーマット、シリーズ抽出、出力書式 |
| 06 | `06_ドメイン層_リネームエンジン.md` | 自動リネーム・一括リネーム・変換リネーム（純粋関数） |
| 07 | `07_永続化_スキーマとリポジトリ.md` | SwiftData モデル、`VersionedSchema`、Repository、`LabelIndex` |
| 08 | `08_インフラ_ファイル操作.md` | `FileOperationService`、期待変更台帳、衝突、ゴミ箱、アーカイブ |
| 09 | `09_インフラ_アーカイブと画像.md` | libarchive / UnRAR、文字化け対策、展開セキュリティ、サムネイル |
| 10 | `10_インフラ_監視とスキャン.md` | FSEvents、ボリューム着脱、`ScanEngine`、`IdentityResolver` |
| 11 | `11_アプリ層_コマンドとロック.md` | `Command`/`CommandStack`、`LockManager`、状態の 3 分類 |
| 12 | `12_アプリ層_ユースケース.md` | 自動ラベル付与、ライブラリ移動、重複ファイル、ウィザード等 |
| 13 | `13_UI_共通基盤.md` | デザイントークン、共通コンポーネント、エラー提示、キーバインド |
| 14 | `14_UI_メインウインドウ.md` | 3 ペイン、ツールバー、表示モード、フィルタ、検索 |
| 15 | `15_UI_専用ウインドウ.md` | 設定／ラベルグループ／保管庫／ペンディング等の専用ウインドウ |
| 16 | `16_テスト戦略.md` | ゴールデンテスト、単体・統合・性能テスト、技術検証(T-xx)計画 |
| 17 | `17_実装ロードマップ.md` | フェーズ 0〜3 の分割、DoD、依存関係 |
| 18 | `18_要件トレーサビリティ.md` | 要件 ID → 実装成果物の対照表 |

各要件は `[XX-00]` の形式で要件 ID を持つ。設計判断は `[設計判断]` と付され、選定理由が書かれている。**理由ごとコードやレビューコメントに引用してよい。**

要件定義書本体（`docs/Requirements/qooLibrary_要件定義書_v2.8.md`）はこれらの一次情報。仕様書に説明のない詳細や、要件 ID そのものの文言を確認したいときに開く。

## 3. 絶対に破ってはいけないアーキテクチャ制約

これらは CI の静的検査（`Scripts/check-fileops-isolation.swift` 等）で強制される、または後戻りが極めて困難な設計判断。実装中に「近道」で回避しない。

### 3.1 モジュール依存方向 [A-01][A-02]

```
qooLibraryApp → QooApplication → QooPersistence ─┐
                      ↓                          ├→ QooKit
                QooInfrastructure ───────────────┘
```

- `QooKit` は `Foundation` 以外に依存しない。`SwiftData` / `AppKit` / `SwiftUI` を import してはならない。パーサ・正規化・リネームエンジンはすべて**純粋関数**として実装し、実ファイルには一切触れない。
- `QooPersistence` と `QooInfrastructure` は相互依存しない。協調が必要なら `QooApplication` を経由する。
- Repository は `Sendable` な値型のみを返す。`@Model` オブジェクトや `Predicate` を API に露出させない（GRDB 等への差し替えを想定）[RP2-02][RP2-03]。

### 3.2 ファイル操作の一元化 [FO-01][FO-02]

**`QooInfrastructure/FileOps/FileOperationService` 以外から `FileManager` の変更系 API（`moveItem`/`copyItem`/`removeItem`/`createDirectory`/`trashItem`/`createFile`/`linkItem`/`replaceItem`）を呼んではならない。** これは CI で機械的に検査される最重要制約。理由: 自己変更識別（期待変更台帳）と Undo がここに集約されて初めて成立するため。

### 3.3 自己変更識別は 4 層構造 [5.4 節]

FSEvents の `IgnoreSelf` フラグだけに頼らない。① FSEvents フラグ（一次フィルタのみ）② 期待変更台帳（主たる識別手段）③ 一括操作中の監視停止 ④ リネームの冪等性検証（最終防衛線）。冪等性検証で `.diverges` と判定されたルールは**保存を拒否**する [FO-22]。

### 3.4 Command パターンと単一 Undo スタック [A-03][UD-02]

すべての変更操作は `Command` として実装し、`CommandStack.shared`（アプリ全体で単一、ウインドウ単位に分けない）を経由して実行する。`FileOperationService` が返す `OpReceipt` を Command が保持して `undo()` を実装する。

### 3.5 エラー・通知は `NotificationRouter` に一本化 [ER-01]

機能ごとに独自の提示方法（アラート・トースト等）を作らない。提示強度（1: アプリモーダル 〜 5: ログのみ）に応じた提示手段の選択は `NotificationRouter` の中だけで行う。

### 3.6 排他制御は `LockManager` 単一インスタンス [LK-11]

ファイルシステムを変更する一括処理（一括リネーム・変換リネーム・ライブラリへの一括移動・JSON インポート等）のみ排他。取得順序は UUID 昇順固定でデッドロックを防ぐ [LK-12][LK-13]。待機・キューイングはせず、取得できなければ即座に失敗する [LK-14]。

### 3.7 状態の 3 分類 [ST-20〜ST-27]

- **永続状態** → SwiftData（ライブラリ設定、ラベル、フォーマット、ペンディング等）
- **ウインドウ固有状態** → `WindowState`（ラベルフィルタ選択、表示モード、ソート順など。DB に保存しない）
- **セッション一時状態** → `SessionState`（実行中処理、ロック状態。メモリのみ）

例外: ラベルグループの表示順とピン留めはライブラリ単位の永続設定として全ウインドウ共有 [ST-23]。

### 3.8 正規化は 1 箇所にしか実装しない [3 章]

文字列の NFC 化・全角半角統一・空白畳み込みは `TextNormalizer` のみが行う。`CFStringTransform(.fullwidthHalfwidth)` は使わない（長音・半角カナを壊すため、変換表を自前で持つ）[NM-01]。

### 3.9 パーサは正規表現の連結で実装しない [FF-12]

ファイル名フォーマットは 字句解析 → 構文木 → 両端アンカー+バックトラッキング+メモ化 の 3 段構成で実装する（04 章）。

### 3.10 SwiftData は v1 から `VersionedSchema` を使う [MG-01][DP-06]

移行対象が何もなくても `SchemaV1` と空の `MigrationPlan` をファイルとして用意する。後付けはリスクが大きすぎるため。

### 3.11 再生成可能／不可能データの区別 [MG-20〜MG-23]

`@Regenerable` でマークされたデータ（サムネイル、`fileCount`、自動ラベル等）とマークされないデータ（手動ラベル、評価、手動編集タイトル等）を区別する。JSON エクスポートは再生成不可能データを漏れなく含む必要があり、CI で網羅性を検証する。

### 3.12 サンドボックス配下を汚さない [CL-01〜CL-05]

ライブラリ／テンポラリフォルダ配下にアプリ由来のファイルを作らない（例外: `.qooarchive`）。xattr へのメタデータ書き込みは行わない。`FileOperationService` に xattr 書き込み API を持たせない。

### 3.13 ネットワーク通信を実装しない [SC-01][LG2-08]

ログの送信機構、外部メタデータ連携、クラウド同期のいずれも実装しない。

## 4. 命名規約 [00 章 §0.4]

| 対象 | 規約 | 例 |
|---|---|---|
| プロトコル | 能力は `-ing`/`-able`、役割は接尾辞なし | `ArchiveExtracting`, `LibraryRepository` |
| SwiftData モデル | 名詞、`@Model final class` | `ManagedFile` |
| 値型 | 名詞、`struct` | `VolumeValue`, `ParseResult` |
| ユースケース | `<動詞><対象>UseCase` | `ApplyAutoLabelsUseCase` |
| コマンド | `<動詞><対象>Command` | `MoveFilesCommand` |
| SwiftUI View | `<対象>View`/`<対象>Pane`/`<対象>Window` | `LabelFilterPane` |
| エラー | `<領域>Error` | `FormatCompileError` |
| 定数 | `AppLimits`/`AppDefaults` に集約。マジックナンバー直書き禁止 | `AppLimits.maxLabelGroups` |

- コード中のコメントに要件 ID を残す。特に制約系（`FO-01`, `MG-01`, `LK-13` 等）は該当箇所に `// [FO-01]` を付す。
- 型名・変数名は英語。コメント・ログメッセージは日本語可。ユーザー向け文字列は String Catalog（`Resources/Localizable.xcstrings`）へ。

## 5. 並行性モデル [00 章 §0.5]

Swift 6 言語モード、`StrictConcurrency` 有効。

| 領域 | コンテキスト |
|---|---|
| SwiftUI View / ViewModel、`mainContext` を触る処理 | `@MainActor` |
| スキャン・サムネイル生成・一括処理・JSON 入出力 | `@ModelActor` の専用アクター |
| `FileOperationService` / `ExpectedChangeLedger` / `LockManager` | `actor`（直列化） |
| FSEvents コールバック | 専用 `DispatchQueue` → `AsyncStream` |

コンテキストをまたぐ受け渡しは `PersistentIdentifier` のみ。`@Model` オブジェクトを `Sendable` として渡さない。

## 6. 実装の進め方

`17_実装ロードマップ.md` に従い、フェーズを飛ばさない。現時点ではフェーズ 1（ファイルマネージャー）の途中（§0 参照）。

```
フェーズ0 基盤検証        T-13/T-12 の技術検証、ゴールデンサンプル収集開始、プロジェクト骨格 ← 完了
フェーズ1 ファイルマネージャー  Finder 代替として日常使用できる状態             ← 進行中（1-1〜1-11・1-12b・1-13 完了）
フェーズ2 ライブラリマネージャー ラベル管理が実用レベル
フェーズ3 テンポラリフォルダ   取り込み〜投入のワークフロー完結
```

フェーズ 1（`17_実装ロードマップ.md` §17.3）:

| # | 内容 | 状態 |
|---|---|---|
| 1-1 | プロジェクト基盤（レイヤ構成、デザイントークン、共通コンポーネント） | 完了 |
| 1-2 | サンドボックス + Security-Scoped Bookmark 基盤、FS 適合検証 | 完了 |
| 1-3 | メインウインドウ 3 ペイン、タブ・複数ウインドウ、状態の 3 分類 | 完了 |
| 1-4 | フォルダツリー（ボリューム／テンポラリ／ライブラリの 3 グループ） | 完了 |
| 1-5 | 基本ファイル操作・衝突処理。`FileOperationService` への集約 | 完了 |
| 1-6 | ドラッグ＆ドロップ（DD-01〜DD-03, DD-05） | 完了 |
| 1-7 | 圧縮・展開、文字化け対策、展開時のセキュリティ、ライセンス表記一式 | 完了（文字化け判定のプレビューUI・手動オーバーライド EN-01/EN-02 のみ未着手） |
| 1-8 | キーボードショートカット（KB-01〜KB-05） | 完了（実装済み機能のみ実配線。他は登録済み・未配線） |
| 1-9 | リスト表示・アイコン表示、サムネイル生成 | 完了 |
| 1-10 | 右ペイン（詳細情報表示、DT-01〜DT-07/DT-10） | 完了 |
| 1-11 | Undo 基盤（ファイル操作のみ、UD-01〜UD-11/HS-01〜HS-04） | 完了 |
| 1-13 | ライブラリ／テンポラリフォルダの登録・削除（エイリアス相当、RG-01〜RG-08） | 完了 |
| 1-12b | エラー処理と通知の共通基盤（ER-01〜ER-34 の実装可能な範囲） | 完了 |
| 1-12/1-14/1-15 | 環境設定、Quick Look 等、診断ログ | 未着手 |

- フェーズ 1 の 4 制約（DP-01 Undo 基盤 / DP-05 FileOps 集約 / DP-07 mainContext 構成 / DP-08 通知基盤）は機能追加より先に固める。後付けは大規模改修になる。DP-05（FileOps 集約）は 1-5 で、DP-01（Undo 基盤）は 1-11 でそれぞれ完了済み。DP-07（mainContext 構成）は SwiftData 導入（フェーズ2）まで対象外、DP-08（通知基盤）は 1-12b が対象。
- フェーズ 2 の最初に `VersionedSchema` を導入する。パーサ（`QooKit`）は永続化と並行実装できるため早期着手を推奨。
- 各フェーズの DoD（完了条件、17 章に記載）を満たさないまま次フェーズへ進まない。
- **不可解な事象（原因不明のクラッシュ・ハング・意図しない挙動）に遭遇したら、`sample`/`git stash` によるバイセクトなど重い実機調査に入る前に、まず `WebSearch`/`WebFetch` で既知の問題でないか調べる**（時間・トークンの節約 [ユーザー指示]）。特に Apple のフレームワーク（Foundation/SwiftUI/AppKit）は、ドキュメントに明記された既知の挙動やコミュニティで既知のバグであることが少なくない。実例: パスバー実装（下記参照）で `URL.deletingLastPathComponent()` がルート `/` に対して `/` 自身ではなく `/..` を返すこと（Apple 公式ドキュメントに明記）を知らずに書いた終了判定が無限ループし、「ウインドウが表示されない」を SwiftUI 側のハングバグと誤って決めつけ、`sample` でのスタック採取や `git stash` によるバイセクトに時間を費やした後になって判明した。検索で手がかりが無かった場合に初めて、実機再現・バイセクト・スタックトレース採取などの重い調査に進む。

## 7. テスト方針 [16 章]

- `QooKit`（純粋関数）はカバレッジ 80% 以上必須。特に `TextNormalizer.normalize` は 100% カバレッジ必須 [NM-04]。
- **ゴールデンテスト**（`Tests/GoldenDataset/`）がパーサ・シリーズ抽出・巻数正規化・保護文字列・変換リネームの正しさを担保する主手段。プリセット 8 種それぞれに正例・負例 20 件以上。
- 実運用で誤判定が見つかったら、**そのファイル名を必ずデータセットへ追加してから修正する** [MT-25]。
- 実在の作品名・著者名を含むサンプルは `Tests/GoldenDataset/private/` に置き `.gitignore` する。CI は `public/` のみ実行。
- パーサに変更を加えたら `Tests/GoldenDataset/public` 全件を実行し、差分が出たら「期待値を直す」か「実装を直す」かを明示的に判断する。

## 8. CI 静的検査（実装後に必ず通す）

| 検査 | 内容 |
|---|---|
| FileOps 隔離 [FO-02] | `FileOps/` 以外での `FileManager` 変更系 API 呼び出しを検出したらビルド失敗 |
| 層の依存 [A-01] | `QooKit` 配下の `import SwiftData`/`AppKit`/`SwiftUI` を検出したら失敗 |
| 定数の集約 [MT-03] | マジックナンバー直書きの検出 |
| JSON 網羅性 [MG-23] | `@Regenerable` 未付与の非再生成属性が JSON DTO に存在するか検証 |
| ゴールデンテスト [MT-24] | `Tests/GoldenDataset/public` 全件 |

## 9. やってはいけないこと（明示的な禁止事項）

- `FileOperationService` を経由しないファイルシステム変更（§3.2）
- `QooKit` からの `SwiftData`/`AppKit`/`SwiftUI` の import
- ファイル名パーサを正規表現の連結で実装すること [FF-12]
- `CFStringTransform(.fullwidthHalfwidth)` による全角半角変換 [NM-01]
- xattr へのメタデータ書き込み、サイドカーファイルを作る API [CL-03][FS2-03]
- ライブラリ／テンポラリフォルダ配下への `.qooarchive` 以外のアプリ由来ファイル作成
- ログ・使用状況等のネットワーク送信機構
- 排他処理でのブロッキング待機・暗黙のキューイング（即座に失敗させる）[LK-14]
- 機能ごとに独自のエラー表示・通知 UI を作ること
- ウインドウ固有状態（表示モード、ソート順、フィルタ選択）の DB 保存
- 冪等性検証で `.diverges` と判定された自動リネームルールの保存許可
- `RarBackendName` を無視した UnRAR 由来コードの流用（「RAR 互換アーカイバの開発に使用してはならない」旨を必ず先頭コメントに記す）[LC-26]

## 10. 依存ライブラリとライセンス [01 章 §1.7]

- 自作コード（`Sources/`）は MIT。
- **libarchive（BSD-2-Clause）は組み込み済み。** `Scripts/build-libarchive.sh` がソースからビルドし `ThirdParty/libarchive/libarchive.xcframework`（gitignore 対象、要再生成）を生成する。システムの `libarchive.dylib` にはリンクしない [LC-15][B-02]。ビルド前に一度このスクリプトを実行する必要がある（README 参照）。configure の機能検出はホスト環境依存になりやすい（liblzma の有無で CI と開発機の挙動が分かれた実例あり、`Spikes/README.md` 参照）ため、使わない機能は `--without-*` で明示的に無効化する方針。
- **UnRAR（専用ライセンス、MIT ではない）は組み込み済み。** `Scripts/build-unrar.sh` がソースからビルドし `ThirdParty/unrar/libunrar.xcframework`（gitignore 対象、要再生成）を生成する。呼び出しは Objective-C++ ラッパー `Sources/QooUnrarBridge/QooUnrarBridge.mm` 1 ファイルに閉じ込め、先頭コメントに「RAR 互換アーカイバの開発に使用してはならない」旨を記している [LC-26][B-03][B-04]。Swift から見えるのは `Sources/QooUnrarBridge/include/QooUnrarBridge.h` の素の C API のみで、UnRAR 自身のヘッダ（`raros.hpp`/`dll.hpp`、`Sources/QooUnrarBridge/` 直下に private として同梱）を直接 import しない。
- 依存追加時は `THIRD-PARTY-NOTICES.md` の更新を必須とする(CI の `license` ジョブが `ThirdParty/` の変更を検出して強制する)。
- `PERMISSIVE_ONLY_BUILD=1 swift build` は `Package.swift` から `QooUnrarBridge`/`unrarBinary` ターゲット自体を除外し、libarchive の RAR リーダーを使う構成になる。`Scripts/build-unrar.sh` を実行していなくてもこの構成はビルドできる。既定ビルドとの機能差は `Spikes/README.md`（T-12、libarchive 同梱の RAR テスト corpus による暫定比較）を参照。実アプリのアバウト画面での明示は [B-01] としてフェーズ 1 以降の課題。
