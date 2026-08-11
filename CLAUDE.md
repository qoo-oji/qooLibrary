# CLAUDE.md

qooLibrary の実装作業でこのリポジトリを扱う際に、Claude Code が常に踏まえておくべき情報をまとめる。

## 0. 現在の状態

**フェーズ 0（基盤検証）完了。フェーズ 1（ファイルマネージャー）着手済み（1-1〜1-8 完了）。**

### フェーズ 0（`17_実装ロードマップ.md` §17.2、全項目完了）

- `Package.swift`（`QooKit`/`QooPersistence`/`QooInfrastructure`/`QooApplication` + `CLibarchive` + `QooUnrarBridge` + `QooKitTests`）が存在し、`swift build` / `swift test` がグリーン。`PERMISSIVE_ONLY_BUILD=1 swift build` も動作する。
- `Scripts/build-libarchive.sh` / `Scripts/build-unrar.sh` でそれぞれ libarchive・UnRAR をソースからビルドし、`ThirdParty/{libarchive,unrar}/*.xcframework`（arm64+x86_64 ユニバーサル）を生成する。システムの dylib にはリンクしない [LC-15][B-02][LC-11]。
- UnRAR は Objective-C++ ラッパー `Sources/QooUnrarBridge/QooUnrarBridge.mm` 経由でのみ呼ぶ [B-03]。`PERMISSIVE_ONLY_BUILD` ではこのターゲット自体が `Package.swift` から除外される。
- `Spikes/LibarchiveSpike`・`Spikes/UnrarSpike` で zip・RAR の一覧・展開を確認済み。実 `.rar`/`.cbr`（ユーザー提供、122 件）での T-12 再測定と、実ファイル名（2,957 件）に基づく 0-3 の知見も完了（`Spikes/README.md`、`Spikes/real-data-findings.md`）。**実ファイル名・実データそのものはリポジトリに一切含めない**運用にした（ユーザーの明示的な指示）。
- 静的検査 `Scripts/check-fileops-isolation.swift`（B-10）・`check-layer-dependencies.swift`（B-11）・`check-json-completeness.swift`（B-13, 現状はプレースホルダ）と CI（`.github/workflows/ci.yml`）を用意した。
- **既知の懸念（要フォローアップ）**: libarchive 3.8.9 は特定の壊れた RAR 入力（use-after-free の回帰テストファイル）でクラッシュする（エラーを返さず異常終了）。`SecureExtractor`（09章 §9.3）実装時に対処を検討する必要がある。詳細は `Spikes/README.md` の T-12 節。

### フェーズ 1（`17_実装ロードマップ.md` §17.3、1-1〜1-8 完了・1-9 着手中・1-10 以降未着手）

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
  - `Sources/qooLibraryApp/Debug/SandboxVerificationView.swift`: 実サンドボックス下でのみ検証できること（NSOpenPanel によるユーザー選択、ブックマークのアプリ再起動をまたいだ永続性、`startAccessingSecurityScopedResource` の実効性）を確認する暫定 UI。右ペインに仮置き。**1-13（フォルダ登録の本実装）で削除しフォルダ登録フローに置き換える。**
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
- **1-9（リスト表示・アイコン表示、サムネイル生成）は着手中。リスト表示（LV-01〜LV-03）のみ完了。** サムネイル基盤・アイコン表示（IV-01/08/09、PF-10/11）は未着手。ユーザーとの合意で「リスト表示 → サムネイル基盤 → アイコン表示」の順に実装している。
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
- **未着手**（1-9 以降）: 文字化け判定のプレビュー UI・手動オーバーライド（EN-01/EN-02、1-7 の残り）、Undo 基盤、環境設定（表示密度等の可変設定・キーバインドのカスタマイズ UI・タブバー常時表示トグルを含む）、通知基盤、診断ログ、右ペインの詳細情報（現状 1-2 の検証 UI が仮置き）、ラベルフィルタ（左ペイン下半分、現状プレースホルダ）、フォルダ登録（1-13）等。
- 各 `Sources/{QooKit,QooPersistence,QooApplication}/*.swift` の中身はまだプレースホルダ（モジュール依存関係を検証するための最小限のマーカー型のみ）で、ドメインロジック・SwiftData モデルは一切実装していない。`QooInfrastructure` はサンドボックス／FS 検証のみ実装済み。

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
フェーズ1 ファイルマネージャー  Finder 代替として日常使用できる状態             ← 進行中（1-1〜1-8 完了）
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
| 1-9 | リスト表示・アイコン表示、サムネイル生成 | 着手中（リスト表示 LV-01〜LV-03 のみ完了。サムネイル基盤・アイコン表示は未着手） |
| 1-10〜1-15 | Undo、環境設定、通知基盤 等 | 未着手 |

- フェーズ 1 の 4 制約（DP-01 Undo 基盤 / DP-05 FileOps 集約 / DP-07 mainContext 構成 / DP-08 通知基盤）は機能追加より先に固める。後付けは大規模改修になる。1-1 はこれらより前段の土台（プロジェクト構成・デザイントークン）であり、4 制約自体はまだ手を付けていない。
- フェーズ 2 の最初に `VersionedSchema` を導入する。パーサ（`QooKit`）は永続化と並行実装できるため早期着手を推奨。
- 各フェーズの DoD（完了条件、17 章に記載）を満たさないまま次フェーズへ進まない。

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
