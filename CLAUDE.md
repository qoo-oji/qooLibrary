# CLAUDE.md

qooLibrary の実装作業でこのリポジトリを扱う際に、Claude Code が常に踏まえておくべき情報をまとめる。

## 設計の大原則（最優先・厳守）

**人間が機械に合わせるのではなく、機械が人間に合わせる。** ユーザーの自然な操作・個人差・癖を「正しい使い方をしていない」とみなして矯正を求めるのではなく、それを吸収できるように機能側を作る（固定値を強制するのではなく調整可能にする、既定値を実測に基づいて選ぶ、等）。

- 実例（マウス・トラックパッドでの戻る/進むジェスチャー実装、要件定義書には無い機能）: 実装当初は固定のしきい値を使い、ユーザーの実際のスワイプがそれに届かないと「もっとはっきり大きくスワイプしてください」と操作の変更を求めていた。ユーザーから「人間が機械に合わせるのはあるべき姿ではない」との明確な指摘を受け、3段階のプリセット・広範囲調整可能なスライダーと段階的に対応したが、最終的に判明した真因は感度の問題ではなく実装のバグ（中央ペイン `Table` が横スクロールとして信号の大半を横取りしてしまっていたこと）だった。バグを直したところしきい値調整 UI 自体が不要になり削除した。教訓: 「調整可能にする」は最初の一手として正しいが、それ自体がゴールではない。動かない報告の背後に測定不能なほど小さい・矛盾した実測値があるなら、感度不足ではなく実装の構造的な欠陥を疑うべきだった（詳細は 1-8 節「マウス・トラックパッドでの戻る/進む」参照）。
- 「動作しない／使いにくい」という報告に対して、まず疑うべきは実装（固定の前提・しきい値・想定する操作パターンの狭さ）であり、ユーザーの操作方法ではない。ユーザーに操作を変えるよう繰り返し求める前に、調整可能にする・自動で適応させる・実測データに基づいて既定値を選び直す、といった手段を優先して検討する。

## 0. 現在の状態

**フェーズ 0（基盤検証）完了。フェーズ 1（ファイルマネージャー）はほぼ完了（1-1〜1-16 完了、1-12 は実装可能な範囲を実装済み。残るは 1-17〈登録フォルダの縮退状態、設計のみ完了〉のみ）。**

### フェーズ 0（`17_実装ロードマップ.md` §17.2、全項目完了）

- `Package.swift`（`QooKit`/`QooPersistence`/`QooInfrastructure`/`QooApplication` + `CLibarchive` + `QooUnrarBridge` + `QooKitTests`）が存在し、`swift build` / `swift test` がグリーン。`PERMISSIVE_ONLY_BUILD=1 swift build` も動作する。
- `Scripts/build-libarchive.sh` / `Scripts/build-unrar.sh` でそれぞれ libarchive・UnRAR をソースからビルドし、`ThirdParty/{libarchive,unrar}/*.xcframework`（arm64+x86_64 ユニバーサル）を生成する。システムの dylib にはリンクしない [LC-15][B-02][LC-11]。
- UnRAR は Objective-C++ ラッパー `Sources/QooUnrarBridge/QooUnrarBridge.mm` 経由でのみ呼ぶ [B-03]。`PERMISSIVE_ONLY_BUILD` ではこのターゲット自体が `Package.swift` から除外される。
- `Spikes/LibarchiveSpike`・`Spikes/UnrarSpike` で zip・RAR の一覧・展開を確認済み。実 `.rar`/`.cbr`（ユーザー提供、122 件）での T-12 再測定と、実ファイル名（2,957 件）に基づく 0-3 の知見も完了（`Spikes/README.md`、`Spikes/real-data-findings.md`）。**実ファイル名・実データそのものはリポジトリに一切含めない**運用にした（ユーザーの明示的な指示）。
- 静的検査 `Scripts/check-fileops-isolation.swift`（B-10）・`check-layer-dependencies.swift`（B-11）・`check-json-completeness.swift`（B-13, 現状はプレースホルダ）と CI（`.github/workflows/ci.yml`）を用意した。
- **既知の懸念（要フォローアップ）**: libarchive 3.8.9 は特定の壊れた RAR 入力（use-after-free の回帰テストファイル）でクラッシュする（エラーを返さず異常終了）。`SecureExtractor`（09章 §9.3）実装時に対処を検討する必要がある。詳細は `Spikes/README.md` の T-12 節。

### フェーズ 1（`17_実装ロードマップ.md` §17.3、1-1〜1-16 完了（1-12 は実装可能な範囲のみ）・1-17 は設計のみ）

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
  - `Sources/qooLibraryApp/State/WindowState.swift`: `SessionState.reloadToken`（当時はファイル操作完了のたびに増分する、変更検知が無い間の代替）。**ウインドウ単位ではなくセッション全体で 1 つ**（`SessionState.shared`）を共有しており、あるウインドウでの操作が他のウインドウ／ペインの表示にも反映される（後述の実機検証で発見した不具合の修正）。**[その後の変更] ファイルの追加・削除・改名・書き換えはこの信号を使わなくなった** — `DirectoryChangeHub` が影響を受けるフォルダを表示している場所だけへ届ける（本 §0 末尾の「表示中のフォルダの状態一貫性」節参照）。`reloadToken` に残っているのはファイルの中身以外の理由（アクセス権・ボリュームの取り出し・登録フォルダの増減）だけ。
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
  - **マウスのサイドボタン・トラックパッドのスワイプによる戻る/進むを実装した**（要件定義書には無い、ユーザーからの要望。§13.6「将来検討」に記録していたものをここで実装）。
    - `Sources/qooLibraryApp/MainWindow/BackForwardGestureSupport.swift`（新規）: `NSEvent.addLocalMonitorForEvents` によるウインドウ単位のローカルモニタ（`Info.plist`/entitlement 追加や Accessibility 権限が不要）で `.otherMouseDown`（マウスのサイドボタン、ボタン3/4）・`.scrollWheel`（トラックパッド2本指、「ページ間をスワイプ」が2本指設定のとき）・`.swipe`（3本指設定のとき）を検出する。`MainWindowView` に1回だけ適用する（タブごとに再生成される `FolderContentView` に付けるとジェスチャー途中でモニタが再設置されイベントストリームが途切れることを実機検証で確認した）。
    - **`NSEvent.Phase` は `OptionSet`** のため `switch` の厳密一致ではなく `.contains()`/`.isEmpty` で判定する必要がある（姉妹プロジェクト qooViewer の実装を参照して発見）。1回の物理的なジェスチャーで `.began`/`.mayBegin` が複数回届くこと、非常に軽いタッチだと `.ended`/`.cancelled` が一度も届かないことも実機検証で判明し、それぞれ「ジェスチャー中フラグでリセットを1回に限定」「最後のイベントから200ms新しいイベントが無ければ強制確定するタイマー」で対処した。指を離した後の慣性スクロール（`momentumPhase`）中の移動量も積算に含める（Chrome/Safari 相当のスワイプナビゲーションは慣性分も含めた総移動量で判定していると推測したため）。
    - **根本原因の発見と解決**: 当初は `scrollingDeltaX` を自前で積算し固定ピクセルしきい値と比較する方式で実装したが、ユーザーの軽いスワイプでは合計移動量が実測 1〜14px 程度しか記録されず、しきい値をどれだけ下げても検出できなかった。3段階プリセット→広範囲スライダーへと調整可能にする方向で対応したが、ユーザーから「トラックパッド幅の70%を動かしているのに3pxはおかしい、中央ペインが実際に横スクロールしようとしている」という指摘があり、**中央ペインの `Table`（`NSScrollView` 内包）が横スクロールとして信号の大半を消費してしまっており、モニタに残っていたのは消費されなかったわずかな余りだった**ことが判明した。`NSTouch`（生のマルチタッチ座標、`touchesBegan` 等）で `scrollingDeltaX` を経由しない生データを取ろうとも試みたが、`hitTest` を強制しても `window.contentView` へ直接追加しても一度も届かず（「2本指で左右にスクロール」が OS 側で既にジェスチャーとして専有されているため）撤回。`NSEvent.trackSwipeEvent`（Safari 相当の正規化スワイプ API）も、正規化された振れ幅がウインドウ幅に対して相対的で必要移動量が安定しないため不採用。**最終的に、ローカルモニタのハンドラで横方向優位の `.scrollWheel` イベントに対して `nil` を返す（＝ `Table` を含め以降どの view にも配送しない）ことで解決した。** `Table` の内部スクロールビュー（実体は private な `ListCoreScrollView`）を isa 差し替え等で直接いじる方式も試したが、`.background()` で配置したヘルパービューは `Table` の内部スクロールビューの子孫ではなく共通の祖先を持つ「兄弟」だったため `enclosingScrollView`（祖先方向のみ探索）では見つからず、また private な内部実装への依存はリスクが大きいため、イベント配送そのものを止める方式に一本化した。修正後は同じ操作で実測 500〜700px 規模の正しい移動量が積算されるようになり、固定しきい値（60px）で安定して動作することを確認した。**調整可能にすることが目的化しないよう注意する教訓**（CLAUDE.md 冒頭「設計の大原則」参照）。
    - **この修正の副作用として、ウインドウ内のどのペインでも2本指の横スワイプが常に戻る/進む専用になり、通常の横スクロールが一切効かなくなる。** ユーザー指摘「トレードオフがあるなら原則としてユーザーに選択を委ねるべき」を受け、`twoFingerSwipeForNavigation`（`@AppStorage("qoo.twoFingerSwipeForNavigation")`、既定 `true`）を追加。`false` にすると2本指の横スワイプは通常の横スクロールとして扱われ、戻る/進むは3本指スワイプ（`.swipe` イベント、OS 側で「ページ間をスワイプ」を3本指に設定する必要がある）のみが手段になる。空きスペースの右クリックメニュー「2本指の横スワイプ」で切り替え、`false` 選択時は3本指設定への案内文を表示する。
    - **マウスのサイドボタン（Logi Options+ 使用時）の根本原因と解決**: 当初は「Logitech Options+ 等のユーティリティがサイドボタンを横取りしており、生の `otherMouseDown` が一切届かないため、ユーティリティ側の設定でキーボードショートカットへ再割り当てしてもらう必要がある」という結論で一旦記録していたが、**ユーザーから「Finder や Chrome は Logi Options+ の既定設定のまま戻る/進むが機能している、そちらが合わせるべきだ」との指摘を受け**、この結論を覆して再調査した（CLAUDE.md 冒頭「設計の大原則」参照）。`.systemDefined`・`otherMouseUp`・全ボタン番号を含む広いイベントマスクで実機計測したところ、**Logi Options+ の既定設定ではサイドボタン押下が `otherMouseDown` ではなく `.swipe`（3本指スワイプと同じイベント種別）として届く**ことが判明した。さらに、1回のボタン押下で `deltaX=0.0`（予備動作）→数ミリ秒後に `deltaX=±1.0`（実際の方向）という2つの `.swipe` イベントが連続して発生するにもかかわらず、`handleSwipe` のクールダウン判定が `deltaX=0.0` の予備イベントでもクールダウンを消費してしまい、直後に届く本来のイベントを握りつぶしていたバグを発見した。`deltaX != 0` のイベントのみをクールダウン判定・消費の対象にする修正で解消し、**ユーティリティ側の設定変更を一切求めることなく**マウスのサイドボタンでの戻る/進むが機能するようになった。教訓: 「他のアプリで動いている」という事実は、その環境がアプリ側の実装だけでは制御不能という結論を覆す強い反証になる。決めつける前に、まず実機で広く生イベントを計測すべきだった。
    - **フォローアップ（1-12 環境設定で対応すること）**: ①「2本指の横スワイプ」の切替設定は本来コンテキストメニューではなく環境設定 UI に置くべき、との指摘を受けた。現状は 1-12 の本実装が無いための暫定配置（他の `@AppStorage` 直接永続化と同じパターン）であり、1-12 実装時に必ず環境設定へ移すこと。②あわせて、戻る/進むの左右（どちらのスワイプ方向が戻る/進むになるか）を入れ替えられる設定も環境設定に追加すること（ユーザーからの要望、まだ未実装）。
    - **実機検証（ユーザーによる複数回の手動確認）で完了。** マウスのサイドボタン（接続環境によっては前述のユーティリティ制約あり）、トラックパッドの2本指スワイプ（軽いスワイプ・大きいスワイプとも）、3本指スワイプ、通常の縦スクロール・横スクロール設定への切り替えのいずれも確認済み。
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
    - **保留にした項目（entitlement の追加とユーザー同意を要する。実装不能ではなく判断事項）**: Finder 本体の「情報を見る」ウインドウをそのまま呼び出すこと（`com.apple.security.automation.apple-events` entitlement の追加と、実行時のユーザー許可〈TCC プロンプト〉が必要）。「情報を見る」自体は自作の簡易シートとして先に実装した。
      - **[訂正] 「新規ターミナルウインドウで開く」も同じ理由で保留にしていたが、これは誤りだった** — 下記「ターミナルで開く」節の通り、Apple Events を使わずに実装でき、entitlement も不要だった。
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
- **未着手**（1-10 以降）: 文字化け判定のプレビュー UI・手動オーバーライド（EN-01/EN-02、1-7 の残り）、Undo 基盤、環境設定（表示密度等の可変設定・キーバインドのカスタマイズ UI・タブバー常時表示トグル・右ペイン折りたたみ状態の永続化・サムネイルキャッシュの上限設定/手動クリア UI [IV-09] を含む）、通知基盤、診断ログ、右ペインの詳細情報（現状 1-2 の検証 UI が仮置き。「情報を見る」の自作シートはこの本実装で置き換える）、ラベルフィルタ（左ペイン下半分、現状プレースホルダ）、フォルダ登録（1-13、フォルダツリーの右クリックメニューもここで追加）、Apple Events 自動化（Finder の「情報を見る」を直接呼ぶ、要 entitlement 追加。「新規ターミナルで開く」は Apple Events 不要と判明し実装済み）等。
- **アプリ関連付け（環境設定「関連付け」タブ、「アプリケーションで開く」サブメニュー、Finder への qooLibrary 登録）を1セットで実装した**（ユーザー指示: 「まず、「関連付け」タブの実装と、「開く」の対象アプリ選択、ファイルおよびフォルダのコンテキストメニューに「このアプリケーションで開く」を追加、を1セットで進めてください」。3番目は上記「将来検討」として記録していた項目〈フォルダを右クリック → このアプリケーションで開く → qooLibrary〉を、当時のユーザー意向どおりファイル版とあわせて実装したもの）。
  - **当初「`AppAssociationService` は SwiftData 前提のため Phase 1 では対象外」と記録していたが、実際には `RegisteredFolderStore`（JSON 永続化の `actor`、SwiftData 抜きで Phase 1 の間に合わせを実現した既存パターン）と同じ手法で実装可能と判明し、この節で実装した。**
  - **ドメイン層**（`QooKit`）: `Sources/QooKit/Model/AppAssociation.swift`（新規）— `AppCandidate`（`bundleID`/`name`/`url`）、`AppAssociationService` プロトコル（`candidates(for:)`/`primary(for:)`/`setPrimary(_:for:)`/`open(_:with:)`）。**`setPrimary`/`primary` は qooLibrary 内部だけの「既定アプリ」上書きであり、macOS システム全体の既定関連付け（Finder や他アプリにも影響するもの）は一切変更しない**［設計判断、仕様の AS2-01「設定のない拡張子はシステムの関連付けに従う」を、システム既定の上に乗る内部設定と解釈した］。仕様の `setSecondary`（副次アプリの固定リスト、AS-06）は対象外にした — 「アプリケーションで開く」サブメニューが `candidates(for:)` を毎回動的に列挙するため、別途「副次アプリ」を保存・管理する意味が薄いと判断［設計判断、`RegisteredFolderStore` 等と同じ「実装可能な範囲に絞る」方針を踏襲］。
  - **インフラ層**（`QooInfrastructure`）: `Sources/QooInfrastructure/FileOps/AppAssociationStore.swift`（新規、`RegisteredFolderStore.swift` と同じ配置理由・同じ actor パターン）— `[拡張子: bundleID]` を `Application Support/qooLibrary/appAssociations.json` に永続化。候補アプリの列挙は `NSWorkspace.shared.urlsForApplications(toOpen:)`（`UTType(filenameExtension:)` で拡張子から変換）、開く処理は `NSWorkspace.shared.open(_:withApplicationAt:configuration:)`（特定アプリ指定時）/`open(_:)`（システム既定へのフォールバック）。`primary(for:)` は保存済みの bundleID が実際にインストールされているアプリに解決できない場合（アンインストール等）`nil` を返すため、**AS2-05「設定アプリが削除済みなら…システム関連付けへフォールバック」を追加コード無しで自然に満たす**副次効果があった。
  - **UI**（`qooLibraryApp`）:
    - `Sources/qooLibraryApp/Preferences/AssociationPreferencesTab.swift`（新規）: qooLibrary が実際に読めるアーカイブ拡張子（zip/cbz・7z/cb7・rar/cbr）ごとに候補アプリの `Picker`（アイコン付き、「システムの既定」を含む）。`tar.gz` は複合拡張子で `UTType(filenameExtension:)` に単純に渡せないため対象から除外した［設計判断］。`PreferencesView` に `.associations` カテゴリを追加。
    - `FolderContentView.swift` の右クリックメニューに `OpenWithMenu`（新規、単一選択・非ディレクトリのファイルのみ対象）を追加。`AppAssociationService.candidates(for:)` を `.task(id: url)` で読み込み、末尾に「その他…」（`NSOpenPanel` で任意の `.app` を選択）を配置。フォルダは拡張子を持たないため対象外にした。
    - **実機検証で発見・修正した2段階のバグ: 環境設定「関連付け」タブで既定アプリを設定しても、ダブルクリックで反映されなかった。**
      1. まず `openEntries(_:)`（1-3/1-8 時点からある既存のファイルオープン処理、`Enter`/`⌘↓`/コンテキストメニューの「開く」が経由する）が `NSWorkspace.shared.open(url)` を直に呼んでおり、`AppAssociationService` を一切経由していなかった。`appAssociationService.open([url], with: nil)`（`nil` を渡すと内部で qooLibrary の関連付け設定 → システムの既定アプリの順にフォールバックする、`AppAssociationStore.open(_:with:)` 参照）に置き換えた。
      2. **しかしユーザーによる再検証で「ダブルクリックでは依然として起動しない」と判明した。** エラーを黙って握りつぶさないよう `presentError` 経由に変更してもエラーダイアログすら出ないことから、`openEntries` 自体が呼ばれていないと判断し、ダブルクリックのジェスチャハンドラを直接調べたところ、`FolderContentView.swift`（`Table` 行）と `IconGridView.swift`（アイコンセル）の両方で `.onTapGesture(count: 2) { if entry.isDirectory { onNavigate(entry.url) } }` という**フォルダのときしか何もしない**実装になっていた（ファイルのダブルクリックはそもそも 1-3 の実装当初から一貫して無反応だった、`Enter` キーだけが動く経路として存在していた）。`openEntries([entry])`（`IconGridView` 側は新設した `onOpenEntry: (FolderEntry) -> Void` クロージャ経由、`onNavigate` を再利用せず専用のクロージャに分離した — `onNavigate` は「フォルダへ移動」専用の意味を持つ既存のプロパティで、ファイルを開く動作を混ぜると意味が曖昧になるため）に置き換えて解消した。
      - **教訓**: 「関連付けタブ」「アプリケーションで開くサブメニュー」の実装時に `openEntries`（キーボード経路）だけを見て「開く」経路を把握したつもりになっていたが、実際にはダブルクリックという、日常的にはより頻繁に使われる経路が完全に別実装として存在し、そちらは検討対象から漏れていた。UI の同じに見える操作でも、複数の独立した実装経路が存在し得ることを踏まえ、既存機能を拡張する際は「その機能に到達できる経路をすべて洗い出す」ことを徹底する。
  - **関連付けタブに任意の拡張子を追加できるようにした**（ユーザー要望: 「任意の拡張子を追加できるようにしてほしい。本アプリはメインはコミックライブラリ管理だが、きちんと設定すれば動画ライブラリとしても利用できる想定。そのため、任意の動画形式を関連付けできるようにしておきたい」）。組み込みの6形式（zip/cbz/7z/cb7/rar/cbr）は従来通り常時表示・削除不可のまま、その下に「カスタム拡張子」セクションを新設し、テキストフィールドへの入力＋「追加」ボタンで任意の拡張子（例: mp4/mkv/avi 等の動画形式）を追加できる。追加した拡張子にも組み込み形式と全く同じ「開くアプリ」の `Picker`（候補列挙・システムの既定）が使え、行の「−」ボタンで削除できる。
    - **`AppAssociationService`（`QooKit`）に `customExtensions()`/`addCustomExtension(_:)`/`removeCustomExtension(_:)` を追加した。** `AppAssociationStore`（`QooInfrastructure`）の永続化スキーマを、これまでの `[拡張子: bundleID]` 単体の JSON から `{ associations: [拡張子: bundleID], customExtensions: [拡張子] }` という構造体（`StorageDTO`）に拡張した。**既存ユーザーが持つ旧形式（`[String: String]` 単体）の `appAssociations.json` も引き続き読めるよう、`ensureLoaded()` で新形式のデコードに失敗したら旧形式へフォールバックするようにしている**（`loadsLegacyPlainDictionaryFormat` テストで検証）。`removeCustomExtension` は一覧からの除外だけでなく、その拡張子に設定済みの `primary`（開くアプリ）もあわせて削除する（削除後に再度追加したとき、意図しない古い設定が残らないようにするため）。
    - **入力の正規化・検証**（`AssociationPreferencesTab.swift`）: 前後の空白除去・小文字化・先頭の `.` 除去のうえ、英数字のみを許可する（それ以外の文字が残る場合は「英数字のみで有効な拡張子を入力してください」エラー）。組み込み形式・追加済みのカスタム拡張子との重複も拒否する（「この拡張子は既に追加されています」）。**拡張子の追加は「開くアプリ」の設定対象を増やすだけで、qooLibrary が実際に読める・表示できる形式が増えるわけではない**（動画のプレビュー・サムネイル生成等は本節の対象外、将来別途実装が必要になる）ことをコメントに明記した。
    - **実機検証で「カスタム拡張子に関連付けしても、システムで関連付けされているアプリが起動する」という報告があり、原因を切り分けた。** まず `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`/`open(_:withApplicationAt:configuration:)` を単独の非サンドボックス Swift スクリプトで検証したところ、mp4 → Infuse.app の解決・起動は成功した（サンドボックス起因の制約ではないと判明）。次に `AppAssociationStore.open(_:with:)` に一時的な診断ログ（`FileHandle.standardError.write`、1-9 の `⌘↑` バグ調査以来のパターン）を仕込み、実機で再現してもらったところ、**再現に使われたファイルは `.mkv` だったが、関連付けタブのカスタム拡張子には `mp4` のみが追加されており `mkv` は未登録だった**ことが判明した（ログ: `resolvedBundleID=nil` → システム既定へフォールバック、これは実装の意図通りの正しい挙動）。`mkv` をカスタム拡張子として追加してから再テストしたところ正しく Infuse が起動することを確認済み（ログ: `resolvedBundleID=com.firecore.infuse` → `SUCCEEDED`）。**実装のバグではなく、対象拡張子が未登録だっただけ**という結論になり、診断ログは調査後に削除した。教訓としては軽微だが、「関連付け対象の拡張子ごとに個別に追加が必要」という UI の性質上、似た拡張子（mp4 と mkv 等）を一括りに扱えると誤解されやすい可能性がある — 深刻な混乱が再発するようなら、動画形式のよくある拡張子をまとめて追加できるプリセットボタンの追加を検討してもよい。
  - **Finder への登録**（`project.yml`）: `GENERATE_INFOPLIST_FILE: YES` + `INFOPLIST_KEY_*`（ビルド設定からの自動生成、スカラー値しか表現できない）を、XcodeGen の `info: { path:, properties: }` ブロック（実ファイルとして Info.plist を書き出し `INFOPLIST_FILE` を自動設定する仕組み）に切り替え、既存3キー（コピーライト表記／アプリカテゴリ／プリンシパルクラス）もこちらへ移した。**XcodeGen 自身が `CFBundleIdentifier`/`CFBundleExecutable`/`CFBundlePackageType`/`CFBundleInfoDictionaryVersion`/`CFBundleName` 等の必須キーを自動的に補う**ことを `InfoPlistGenerator.swift`（XcodeGen 本体のソース）と実際に生成された Info.plist の両方で確認済み — `CFBundleShortVersionString`/`CFBundleVersion` はプレースホルダ（`"1.0"`/`"1"`）で上書きされるリスクがあったため、`"$(MARKETING_VERSION)"`/`"$(CURRENT_PROJECT_VERSION)"` を明示的に指定して既存のビルド設定を確実に反映させた。生成される `Sources/qooLibraryApp/Info-Generated.plist` は `qooLibrary.xcodeproj/` と同じ理由（再生成可能な成果物）で `.gitignore` に追加した。
    - `CFBundleDocumentTypes`（`public.folder` 用と、zip/cbz・7z/cb7・rar/cbr 用、各 `LSHandlerRank: Alternate`〈既定アプリを奪わず候補として追加されるだけ〉）+ `UTExportedTypeDeclarations`（`.cbz`/`.7z`/`.cb7`/`.rar`/`.cbr` は macOS 標準の UTI を持たないため独自 UTI を宣言、`public.zip-archive`/`public.archive` に conform）を追加。
    - **`lsregister -dump` で実際に登録されたことを確認したが、実機検証で Finder の「このアプリケーションで開く」に qooLibrary が候補として出ない不具合が見つかった。** 原因は独自 UTI（`com.qoolibrary.cbz`/`com.qoolibrary.sevenzip`/`com.qoolibrary.cb7`/`com.qoolibrary.rar`/`com.qoolibrary.cbr`）を宣言していたが、これらは実際のファイルには使われていなかったこと。`mdls -name kMDItemContentType` で実ファイル（`.cbz`/`.cbr`/`.cb7`/`.7z`/`.rar`）を調べたところ、**macOS は独自 UTI ではなく標準搭載の `public.cbz-archive`/`public.cbr-archive`/`public.cb7-archive`/`org.7-zip.7-zip-archive`/`com.rarlab.rar-archive` にファイルを解決している**ことが判明した（`public.zip-archive` 以外はいずれも把握していなかった標準 UTI）。`UTExportedTypeDeclarations` を全廃し、`LSItemContentTypes` をこれら実際の標準 UTI（`public.folder`/`public.zip-archive`/`public.cbz-archive`/`org.7-zip.7-zip-archive`/`public.cb7-archive`/`com.rarlab.rar-archive`/`public.cbr-archive`）に置き換えて解消した。**教訓: 独自 UTI を宣言する前に、対象拡張子が macOS に既に標準搭載されていないか `mdls -name kMDItemContentType <実ファイル>` で先に確認すべきだった。**
    - **Finder の右クリックメニューに実際に候補として表示され、選択して qooLibrary が正しく開くところまでの検証は、この節の記述時点で保留にしている**［ユーザー指摘: 現在 Xcode でビルドしたパッケージをアプリケーションとして登録していない（`/Applications` への配置・正式な署名等を経ていない）ため検証できない。最終フェーズ（配布用ビルド・インストール手順が整った段階）へ回す］。開かれたときの受け口は既存の `WindowGroup(for: URL.self)`（1-9 で「新規ウインドウで開く」用に実装済み）をそのまま使う想定だが、これも含めて後日の実機検証で確認する。それまでの間、環境設定「関連付け」タブとコンテキストメニューの「アプリケーションで開く」サブメニュー（qooLibrary 自身の内部機能、DerivedData のビルドでも検証可能）はユーザーによる実機確認を依頼中。
  - `Tests/QooInfrastructureTests/AppAssociationStoreTests.swift`（新規6件）: 未設定時に `nil`、設定・取得の往復、拡張子の大文字小文字非依存、`nil` 設定でシステム既定へ戻ること、設定済みアプリが存在しない場合に `nil`〈AS2-05〉、別インスタンス間での永続化を検証。`primary`/`setPrimary` の往復テストは macOS に常時同梱される `com.apple.TextEdit`（数十年変わっていない安定した bundle ID）を使い、実際の `NSWorkspace` 解決に依存する形で検証している。
- **フォルダツリー・リスト表示・アイコン表示すべてで、既定アイコンを Finder と同じものにする改善が完了した**（要件定義書には無い、ユーザーからの要望: SF Symbol の代用アイコンでは視認性が良くないという指摘）。
  - `Sources/qooLibraryApp/MainWindow/FileIconProvider.swift`（新規）: `@MainActor` の単純なパスキー付きメモリキャッシュ + `NSWorkspace.shared.icon(forFile:)`。公開 API で App Sandbox 下でも追加の entitlement 無しに動作する（Launch Services への問い合わせのみで、ファイル内容の読み取りを伴わない）ことを確認済み。カスタムフォルダアイコン・拡張子別のアイコン・アプリバンドルのアイコンいずれも Finder と同一のものが得られる。ディスクへの永続化はしない（サムネイルと違いデコードコストが無く、プロセス起動のたびに再取得すれば十分軽い）。
  - `FolderTreePane.swift`・`FolderContentView.swift`（リスト表示のセル）・`IconGridView.swift`（サムネイル未生成時のプレースホルダ）の3箇所で SF Symbol（`"folder"`/`"doc"`/`"folder.fill"`/`"doc.zipper"`/`"doc.fill"`/`"arrow.turn.up.right"`）を `FileIconProvider.shared.icon(for:)` に置き換えた。シンボリックリンク専用の代用アイコンだった `"arrow.turn.up.right"` は、`NSWorkspace` が対象種別のアイコンに Finder と同じエイリアス矢印バッジを重ねて返すため不要になり削除した。
  - **実機検証（ユーザーによる手動確認）で完了。**
- **将来検討として記録のみ（要件定義書には無い、ユーザーからの要望）**: **フォルダツリーに「ホーム」グループを追加し、実ホームの `アプリケーション`/`デスクトップ`/`書類`/`ダウンロード`/`ムービー`/`ミュージック`/`ピクチャ` を展開できるようにする。** 表示名・アイコンは Finder 準拠（アイコンは `FileIconProvider` で追加コスト無し）。
  - **[訂正] 「フルディスクアクセスが付与済みならサンドボックスのカーネルレベルの制限自体が緩和される」という以前の前提は誤りだったと実機で確認した**（動画サムネイル調査の過程で `/Applications` に配置したビルドへ実際にフルディスクアクセスを付与し、トグルの OFF→ON まで行って再検証した結果、`/Users`/`/Volumes/<外部ボリューム>` への素の `FileManager.contentsOfDirectory` 呼び出しは一貫して権限エラーのままだった）。フルディスクアクセス（TCC）と App Sandbox（カーネルレベルの Seatbelt 制限）は別々の強制レイヤーであり、qooLibrary の entitlements（`app-sandbox`/`files.bookmarks.app-scope`/`files.user-selected.read-write`/`get-task-allow` のみ、広範なファイルアクセスを許可する entitlement は無し）では、フルディスクアクセスを付与してもサンドボックスの基本的なファイル読み取り制限は回避されない。**この機能を実装する際は、フルディスクアクセスだけでは不十分という前提で設計し直す必要がある**（広範アクセス用の entitlement 追加、または結局ユーザーによるフォルダ選択〈Security-Scoped Bookmark〉を要求する設計に倒すか、実装着手時に改めて検証すること）。未付与／未対応の場合は既存の「アクセス権がありません」フォールバック（`FolderTreePane`）にそのまま乗る点は変わらない。
  - **[更新] フルディスクアクセスは使えないと判明したため、導線自体は `SB-03` ではなく、後述の環境設定「アクセス権」タブ（`VolumeAccessStore`/`AccessPreferencesTab`、1-12 で実装済み）が担う。** ユーザーの意向: この導線を初回セットアップウィザードに組み込むタイミングで良い。ウィザード自体は `17_実装ロードマップ.md` の **2-17（初回セットアップウィザード、OB-01〜OB-10）** で、フェーズ2の対象。現状は `FolderTreePane` の `AccessDeniedRow`「アクセスを許可…」ボタン（環境設定「アクセス権」タブへ遷移する）が暫定的にこの役割を担っている。**2-17 実装時の導線順序について明確な指示あり: 初回セットアップウィザードでは、まずアクセス権（ボリューム許可）の設定を行い、その後にライブラリ／テンポラリフォルダの登録に進む順序にすること**（アクセス権が先に済んでいないと、外部ボリューム上のフォルダをライブラリ／テンポラリとして登録しようとした際に選択自体ができない、という依存関係のため合理的な順序）。
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
  - **位置（origin）は当初意図的に対象外にした。** 当初は位置も含めて復元していたところ、⌘N で開いた新規ウインドウが既存ウインドウとまったく同じ位置・サイズになって完全に重なり、見た目上「消えた」（実際は閉じておらず背後に重なっていただけ）というユーザー報告があった。サイズだけを保存・復元し、位置は AppKit 標準のカスケード配置に任せる方式に修正した。
  - **その後、「アプリを再起動するたびにウインドウ位置がずれる」という別のユーザー指摘を受け、「起動直後の最初の1本にだけ位置も復元する」折衷案に変更した**（`Sources/qooLibraryApp/DesignSystem/WindowFrameAutosave.swift`）。セッション中に ⌘N で追加されるウインドウは従来どおり位置復元の対象外（カスケード配置のまま）なので、前述の「新規ウインドウが完全に重なって消えたように見える」問題は再発しない。`WindowFrameAutosaveView` にプロセス全体で共有する `nonisolated(unsafe) private static var hasRestoredPositionThisLaunch` フラグを追加し、「このプロセスで最初に `viewDidMoveToWindow` が呼ばれたウインドウかどうか」を判定する。位置の監視・保存はサイズと同じパターン（`NSWindowDidResize` に加えて `NSWindowDidMoveNotification` も監視）で行う。
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
- **1-12（環境設定）を、現在のアーキテクチャで実装可能な範囲に絞って実装した。** `docs/Specifications/15_UI_専用ウインドウ.md` §15.10 が定義する8タブ（一般/表示/キーボード/関連付け/スキャン/キャッシュ/データ/通知/詳細）のうち、関連付け・スキャン・データ・通知・詳細の大半は `AppAssociationService`/`ScanEngine`/SwiftData/`NotificationHistoryStore`/診断ログ基盤（いずれも未実装）に依存するため対象外にし、**一般・表示・キーボード・キャッシュ**の4カテゴリのみを実装した［設計判断］。
  - `Sources/qooLibraryApp/Preferences/`（新規ディレクトリ）: `PreferencesView`（ルート）・`GeneralPreferencesTab`・`DisplayPreferencesTab`・`KeyboardPreferencesTab`・`CachePreferencesTab`・`ResetPreferencesTab`（プレースホルダ、後述）・`KeyComboRecorder`（新規コンポーネント、次に別記）。
  - **一般タブ**: フォルダを上にまとめる［LV-03、`FolderContentView.swift` の右クリックメニューから移設］、2本指の横スワイプの用途・戻る/進むのスワイプ方向反転［前述のマウス/トラックパッド機能の設定、同じく移設・新規追加］、**表示言語**（後述）を最上部に配置。
  - **表示タブ**: 新規ウインドウ/タブの既定表示モード・アイコンサイズ既定値（新規、`WindowState.init()` が `UserDefaults` から読む）、リスト表示のカラム表示/非表示［LV-02。既存の中央ペイン漏斗アイコンメニューと同じ `UserDefaults` キーを共有し、両方から変更できる。漏斗アイコンメニューは Finder の「表示オプション」相当の頻用操作として維持]。**Finder に合わせて「作成日」「追加日」列を追加した**［ユーザー要望「現在表示できる情報だけでは少ない」。`FolderEntry` に `creationDate`/`addedDate`（`.creationDateKey`/`.addedToDirectoryDateKey`）を追加し、`FolderSortComparator.Key` にも追加、テーブル列・漏斗アイコンメニュー・並び替えメニュー・表示タブの4箇所すべてに配線。既存3列と違い新規ユーザーの表示が急に増えないよう既定は非表示]。
  - **キーボードタブ**（KB2-01〜03）: `ActionID.allCases`（20件）を一覧表示、`UserDefaultsKeyBindingStore.shared`（1-8 で実装済み）をそのまま使い新規の永続化コードは書いていない。**`KeyComboRecorder`（新規）が `KeyPress → KeyCombo` の逆変換を初めて実装した**（`KeyComboConversion.swift` に追加。既存は `KeyCombo → SwiftUI.KeyboardShortcut` の一方向のみだった）。`.onKeyPress(phases: .down)` で次のキー入力を捕捉する、既存コードに前例のないコンポーネント。衝突検出（`KeyBindingStore.conflicts(of:)`）・「既定に戻す」ボタンも実装。
  - **キャッシュタブ**（IV-09）: `CoverImageCache.prune(toMaxSize:)`/`clear()`（1-9 で実装済みだがどこからも呼ばれていなかった）の最初の呼び出し元になった。**`ByteCountFormatter` は 0 バイトを既定で「Zero KB」という表記にする**ことが実機検証で判明し（ユーザー指摘）、0 バイトのときだけ「0 KB」に置き換える処理を追加した。
  - **表示タブ・キャッシュタブに「既定に戻す」ボタンを追加した**［ユーザー指摘: 「スライダー調整があるタブは、既定値が分かりにくいため必ず『既定に戻す』を付けること」という一般原則。今後スライダー等の調整系設定を追加する際はこの原則に従うこと]。
  - **「リセット」タブを一番下に追加した**（`ResetPreferencesTab.swift`、プレースホルダのみ）［ユーザー要望: 将来ここにアプリ内データベースを一括削除するボタンを置く予定。**ただし、データベース（SwiftData、Phase 2）自体がまだ存在せず、かつ `Phase 2` でデータベースを導入する際は、一括削除ボタンより先に必ずエクスポート/インポート機能を実装しなければならない**（ユーザーからの明示的な制約。後戻りできない一括削除を、バックアップ手段が無いまま提供してはならない）。Phase 2 でデータベースを実装する担当者は、この制約を踏まえてから「リセット」タブへ実際の削除ボタンを追加すること]。
  - **ウインドウ構成は `NavigationSplitView` による左サイドバー＋右詳細ペインの2ペイン構成にした**（`TabView` のタブバー方式ではなく）［ユーザー要望: 最近の macOS システム設定と同じ構成にしたい。「タブ方式だと気軽に増やしにくい」との指摘。`MainWindowView` と同じ `NavigationSplitView` を再利用]。
    - **サイドバーの折りたたみトグルボタンを消すには、`NavigationSplitView` 自体ではなくサイドバー側の `List` に `.toolbar(removing: .sidebarToggle)` を付ける必要がある**（`NavigationSplitView` 直下に付けても効かないことを実機検証で確認）。`columnVisibility: .constant(.all)` と組み合わせて常に両カラム表示に固定している。
    - **カテゴリ名タイトルをウインドウ中央に表示しようとして 3 段階の試行錯誤をした。** ①`.navigationTitle` はサイドバー境界に追従して左寄りになる（`NSTrackingSeparatorToolbarItem` 相当、上記ツールバーの戻る/進むボタンと同種の挙動）。②ウインドウ中央に来る `.principal` 配置のツールバー項目に変更したところ、macOS 26 の `NavigationSplitView` では `.principal` 項目が「現在のタブ」を示すピル（カプセル）状の背景付きで自動描画されることが判明した。当初 `Settings` シーン特有の挙動かと思い、環境設定ウインドウ自体を `Settings { }` から `About` と同じ `Window(id:)` へ切り替えて検証したが（`⌘,`・メニュー項目は `CommandGroup(replacing: .appSettings)` で手動配線するよう変更）、**`Settings` 固有ではなく `NavigationSplitView` 自体の挙動**だと判明した。③SwiftUI の公開 API でこのピルを取り除く方法が見つからず、**最終的にユーザー判断で「タイトルが左に寄る程度は許容し、ピルが出ない `.navigationTitle` に戻す」ことで決着した**。副産物として、環境設定ウインドウは `Settings` シーンではなく `Window(id: "preferences")` のままになっている。
  - **表示言語をアプリ内で切り替えられるようにした**（環境設定「一般」タブ最上部、「システムに従う」「日本語」「英語」の3択）［ユーザー要望: 「手遅れになる前に」日本語/英語の両対応をしておきたい。以降のローカライズ対応もこの方針を踏襲すること]。
    - **String Catalog（`Resources/Localizable.xcstrings`）を導入し、`Sources/qooLibraryApp/` 配下の全17ファイル・約214箇所（重複除いて157キー）の直書き日本語文字列を、英語キー＋カタログ経由に移行した**［ユーザー指示: 「ソースコード中の Key は英語とし、日本語はローカライズで対応すること」。`project.yml` に `Resources/Localizable.xcstrings` をリソースとして追加、`xcodegen generate` で反映]。キーは `preferences.general.groupFoldersAtTop` のようなドット区切りの英語識別子（Xcode の自動抽出に頼らず手作業で1つの JSON へまとめて生成）。`Command.displayName`（`QooApplication` 側、"移動"/"コピー" 等）は今回のスコープ外で日本語のまま残っている（フォローアップ）。
    - **`AppLanguage`（`Sources/qooLibraryApp/Localization/AppLanguage.swift`、新規）**: `.environment(\.locale:)` を各シーンのルート（メインウインドウ・環境設定・アバウト）へ適用する `.appLanguageOverride()` を用意した。`AppleLanguages`（`UserDefaults`）を書き換える伝統的な方式は次回起動まで反映されないため採用せず、`.environment(\.locale:)` なら設定変更の瞬間に再描画される（再起動不要）。
    - **重要な区別: `Text(_:)` の `LocalizedStringKey` 解決（文字列リテラルをそのまま渡した場合）だけが `.environment(\.locale)` を自動的に見る。`String(localized:)`・`ByteCountFormatter`・`DateFormatter`・`NSOpenPanel`/`NSSavePanel` の `prompt`/`message`・`NotificationItem`（`NSAlert` 経由で表示、SwiftUI の外）は自動的には見ないため、`@Environment(\.locale)` を明示的に読んで `locale:` 引数へ渡す必要がある。** View の外（`static func`・`enum` 等、`@Environment` を持てない場所）からは `AppLanguage.effectiveLocale`（`UserDefaults` を直接読むヘルパー）を使う。**動的な値を1つ埋め込む文字列**（`"Version \(appVersion)"` 等）は `Text` の interpolation-based `LocalizedStringKey` に任せてよいが、**値を複数埋め込む場合**は Xcode の自動抽出が生成する実際のプレースホルダ表記（`%1$@`/`%2$@` 等）を手作業で正確に再現するのは事故りやすいため、`%@` テンプレートの `String(format:)` 方式（`KeyboardPreferencesTab.swift`/`AboutView.swift` 参照）を使うこと。**今後もこの方針をすべての表示言語対応に適用すること**［ユーザー指示］。
    - **英語表現を一度レビューし、それに日本語を合わせて修正した**［ユーザー指示: 「一度、現在のUIの英語表現が一般的なものか見直すこと。その上で、英語表現にあわせて日本語表現を見直してほしい」]。見つけて直した問題: ①内部の実装フェーズ番号（「1-13」「2-8」）がそのままユーザー向けテキストに漏れていた（バグ。ロードマップの内部管理番号を UI 文字列に埋め込んでいた）。②エラーメッセージの英語表現に文法的な不統一があった（"Creating the alias failed" 系のジェランド形と "Compression failed" 系の名詞形が混在→名詞形に統一）。③「更新日」（Date Modified の直訳）ではなく、実際の Finder の日本語ローカライズで使われている「変更日」に修正。④重複していた意味上同一のキー（`common.change`→`action.rename` へ統合、`menu.undo`/`redo`→`action.undo`/`redo` へ統合、`inspector.modificationDate`→`column.modificationDate` へ統合）を整理。
  - **実機検証（ユーザーによる複数回の手動確認）で完了。** 4カテゴリそれぞれの設定変更・表示言語の即時切り替え（再起動不要）・サイドバートグル非表示・タイトル表示のいずれも確認済み。
- **File/Edit メニューバー・コンテキストメニューの Finder 対比監査を行い、実装可能なものをすべて追加した**（要件定義書には無い、ユーザー指摘: 「ファイルメニューにほとんど項目がない。Finder のファイルメニューに表示される項目を調査し、対応可能なものは追加すること。編集メニューも同様」。続けて「対応不能と判断したものは、なぜ対応できないのか（サンドボックスだから根本的に不可能なものと、実装可能なのにしていないものを区別すること）を明確化すること」「これは各コンテキストメニューについても同様」という追加指示があり、下記に**理由付きの対照表**として残す）。
  - **`FolderMenuActions`（`Sources/qooLibraryApp/MainWindow/FolderMenuActions.swift`、新規）**: メニューバーの `.commands` はシーン構築時に評価され、個々のウインドウ・タブが持つ状態（現在のフォルダ・選択）を直接参照できない。`@FocusedValue`/`.focusedSceneValue` という SwiftUI 標準機構でこれを橋渡しする新しい仕組みを導入した（`CommandStack` の Undo/Redo のようなアプリ全体で単一のシングルトンには不要だった仕組み。フォルダ・選択はウインドウ／タブごとに異なるため必要になった）。`.focusedValue`（キーボードフォーカスを持つ特定のコントロールのみに見える）ではなく `.focusedSceneValue`（そのウインドウのシーン全体で見える）を採用: ツールバーのボタン操作直後などフォーカスが一覧から外れている場面でも File/Edit メニューが機能する必要があるため。`FolderContentView` が `currentFolderMenuActions`（計算プロパティ）を組み立てて `.focusedSceneValue(\.folderMenuActions, ...)` で公開し、`qooLibraryApp.swift` の `FileMenuCommands`/`EditMenuCommands`（新規 View）が `@FocusedValue(\.folderMenuActions)` で読んで各項目の有効/無効・実行を行う。
  - **実際のキーボードショートカットはメニュー項目自体には付けていない**（`UndoRedoMenuCommands` 以来の既存方針を踏襲。`KeyBindingButtons`/`DefaultKeyBindings` をアプリの唯一の配線経路にするため、メニューの `.keyboardShortcut` と二重登録するとSwiftUI の挙動が読みにくくなることを避ける）。メニュー項目はクリックでの実行と有効/無効表示の役割のみを持つ。
  - **新規に実装した機能**（メニューバー整備の過程で「実装可能なのに未実装だった」と判明したもの）:
    - **カット（⌘X）を実機能として実装した。** `SessionState.cutURLs`（1-6 の実装時点から型としては存在していたが、どこからも書き込まれない死んだプロパティだった）を実際に使うようにした。`cutSelectionToPasteboard` がペーストボードへ書き込みつつ `cutURLs` に対象を記録し、`pasteFromPasteboard` がペーストボードの内容が直前の `cutURLs` と一致していれば `CopyFilesCommand` ではなく `MoveFilesCommand` を実行する。素の「コピー」（⌘C）は `cutURLs` をクリアする（さもないと直前のカットが後続の無関係なペーストで誤って移動として処理される）。Finder 自身のカット判定はプライベート API 頼りで他アプリと相互運用できないため、この独自実装はアプリ内で完結する（Finder との間で「カット」状態そのものは伝搬しないが、コピーは標準の `NSPasteboard` ファイル URL 経由で相互運用できる）。カット済み項目をアイコンで淡色表示する視覚フィードバック（Finder にある挙動）は今回未実装（将来のポリッシュ、機能的な影響はない）。
    - **実機検証で発見・修正したバグ: `⌘X` → `⌘V` が「移動する場合としない場合がある」不具合。** 原因は `SessionState.cutURLs` を `Set<URL>` として持ち、ペースト時に `NSPasteboard.readObjects` で読み戻した `URL` と生の `==` で比較していたこと。ペーストボードを経由して読み戻した `URL` はカット時に書き込んだ元の `URL` と（末尾スラッシュの有無等）表現が異なることがあり、一致しないと黙って `CopyFilesCommand`（コピー）にフォールバックしてしまっていた（エラーにはならず、単に「カットしたのに複製された」ように見える）。`cutURLs` の型を `Set<URL>` から `Set<String>`（`standardizedFileURL.path`）に変更し、`FolderTreeRow.isSelected` と同じ「パス文字列で比較する」パターンに揃えて解消した。
    - **実機検証で発見・修正した2件目のバグ: フォルダを移動した直後に `⌘V` すると、移動前のフォルダにペーストされることがある。** 具体例: Documents で `⌘X` → Documents/Dummy へ移動 → `⌘V` すると、Documents/Dummy ではなく Documents にペーストされてしまう。原因は `pasteFromPasteboard()`（値型の `FolderContentView` が保持する `let folder: URL?` を直接読む）が、1-9 の「⌘↑ で1階層のつもりが2階層上がってしまう」バグと同じ根本原因（`goToParent()` の旧実装のコメント参照）だった: ナビゲーション直後にキー入力すると、SwiftUI が古い世代の `FolderContentView` インスタンス（＝古い `folder` の値）をまだ保持していることがあり、`KeyBindingButtons` の非表示ボタンがその古いインスタンスのクロージャを実行してしまう。`goToParent()`/`goBack()`/`goForward()` は既にこの問題を踏まえて `WindowState`（クラス、参照型）側のメソッドとして実装されていたため無事だったが、`pasteFromPasteboard()`（1-9）や `duplicate`/`createAliases`/`compressHere`/`compressWithDialog`/`createNewFolder`/`newFolderWithSelection`/`extractInPlace`/`extractToNamedFolders`（1-7・1-9・本節の File/Edit メニュー整備）はこの教訓が反映されないまま、`FolderContentView` 自身の `folder` を直接読んでいた。`FolderContentView` に `let currentFolder: () -> URL?`（`MainWindowView` から `{ windowState.tabs[index].folder }` として配線、`windowState` はクラスなので呼び出し時点で必ず最新値を返す）を追加し、これらの関数すべてで `folder`（構造体に保持された値）ではなく `currentFolder()`（呼び出し時点の最新値）を読むように統一して解消した。**教訓: `KeyBindingButtons` の非表示ボタンから呼ばれる関数が `FolderContentView` 自身の `let` プロパティを直接読んではならない、という制約は `goToParent` 実装時のコメントに残っていたが、後続の機能追加（1-6 の File/Edit メニュー整備）で同じ注意が払われなかった。今後この種の非表示ボタン経由のアクションを追加する際は、既存の `currentFolder()` を使うこと。**
    - **実機検証で発見・修正した3件目のバグ: ファイルをゴミ箱に入れても、右ペインのインスペクタ（`InspectorPane`）が削除前の詳細情報を表示し続ける。** 原因は `moveToTrash(_:)` が成功後に `reloadAndBroadcast()`（一覧の再読み込み）を呼ぶだけで、`selection`（`@Binding`、`WindowState.tabs[index].selection` と共有）から削除済みの URL を取り除いていなかったこと。`InspectorPane.SingleItemInspector` は `.task(id: url)`（`id` は選択中の URL 自体）で詳細情報を読み込むため、選択中の URL が変わらない限り再読み込みが走らず、ファイルが物理的に消えた後もキャッシュ済みの情報を表示し続けていた。`reload()` の最後で `selection.formIntersection(Set(entries.map(\.url)))`（一覧に実在する項目だけに selection を絞り込む）を追加して解消した。選択が空になった場合、`InspectorPane` は既存の設計どおり現在のフォルダ自身の情報表示にフォールバックする。`reload()` はゴミ箱以外の経路（移動・D&D 等、他ウインドウでの操作による `SessionState.reloadToken` 経由の再読み込みも含む）でも呼ばれるため、この修正は同種の「操作対象が一覧から消えたのに選択だけ残る」不具合全般を一括して解消する。
  - **「ここに圧縮」後、作成した圧縮ファイルを選択状態にするようにした**（ユーザー要望）。`CompressCommand.resultURL`（実行後に作成されたアーカイブの URL）を `private` から `public private(set)` に変更し、`runCompress` が `CommandStack.shared.run(command)` の実行後に同じ `CompressCommand` インスタンス（`final class` のため参照が保たれる）から `resultURL` を読んで `selection` に設定する。
  - **コンテキストメニューの圧縮・展開関連の項目を「圧縮／展開」サブメニューにまとめた**（ユーザー要望）。以前はフラットに「ここに圧縮」「圧縮…」「ここに展開」「（名前）に展開」「展開…」が並び、区切り線で挟まれていただけだったが、`Menu("folder.compressExtractSubmenu")` で1つにまとめ、対応可能なアーカイブが選択されている場合のみ展開系の項目をサブメニュー内に表示する（`isExtractable` の判定は従来通り）。
  - **選択がプログラム的に変わったとき、中央ペインをその項目までスクロールするようにした**（ユーザー要望: 「ここに圧縮」で選択は変わるがスクロールしないと見えないことがある）。`body` 全体を `ScrollViewReader` で包み（`Table`/`IconGridView` どちらのスクロール領域にも作用する）、`scrollProxy.scrollTo(target, anchor: .center)` する。`FolderEntry`/`IconGridView` の `ForEach` はどちらも `url` を `Identifiable` の id として使っているため、同じ `URL` でスクロール先を指定できる。
    - **実機検証で発見・修正したバグ: ユーザー自身のクリックで選択しただけでも中央ペインが中央寄せにスクロール（ジャンプ）してしまっていた。** 当初は `.onChange(of: selection)`（あらゆる選択変更で発火）を使っており、「ユーザー自身のクリックによる選択でも同じ経路を通るが、その項目は既に表示範囲内にあるため実害はない」と判断していたが、これは誤りだった — 既に見えている項目をクリックしただけでも `anchor: .center` により画面が強制的に再センタリングされ、ユーザー指摘の通り毎回スクロールしてしまっていた。**「プログラム的な選択変更のときだけスクロールし、ユーザーのクリックによる選択ではスクロールしない」という区別が必要**と判明し、`@State private var pendingScrollTarget: URL?`（既定 `nil`）を新設。`.onChange(of: selection)` を `.onChange(of: pendingScrollTarget)` に置き換え、スクロールが必要な呼び出し元（`runCompress`）だけが明示的に `pendingScrollTarget = resultURL` を設定する形にした（発火後は `nil` に戻す）。ユーザーのクリックによる選択は `selection` だけを変更し `pendingScrollTarget` には触れないため、スクロールが発生しない。
- **環境設定「表示」タブに「現在開いているフォルダまでフォルダツリーを展開」を追加した**（要件定義書には無い、ユーザー要望: 中央ペインでフォルダを移動していったとき、フォルダツリーが自動的に展開・スクロールして現在地〈ハイライト中のフォルダ〉を表示してほしい）。既定 `true`。
  - `FolderTreePane.swift`: `selectedURL`（中央ペインの現在のフォルダ、既存プロパティ）の変更を `.onChange` で監視し、`ancestorPaths(of:)`（`selectedURL` からファイルシステムルートまで `.deletingLastPathComponent()` を辿って祖先パスを列挙する新設ヘルパー）の結果を `expandedNodeIDs`（`FolderTreeRow` の `DisclosureGroup` が参照する既存の展開状態集合、`FolderTreeNode.id` と同じ「正規化パス文字列」形式）へ `formUnion` するだけで、対象がボリューム配下・登録フォルダ配下のどちらであっても正しい枝が展開される（`FolderTreeRow` は遅延読み込みの再帰構造のため、祖先の展開状態を集合に加えるだけで、各行が自分の子を読み込む既存の反応的な仕組みがそのままカスケードする）。あわせて、対象が登録フォルダ（ライブラリ／テンポラリ）配下か判定して該当グループの `Expanded` フラグも開く（`RegisteredFolderEntry.node.url` を祖先関係で判定）。
  - `body` を `ScrollViewReader` で包み、`scrollProxy.scrollTo(selectedURL.standardizedFileURL.path, anchor: .center)` で現在地までスクロールする。**遅延読み込みで子行が生成されるまでに数フレームかかるため、スクロールは `DispatchQueue.main.asyncAfter(deadline: .now() + 0.3)` で遅らせて呼んでいる**［設計判断、`PaneWindows.swift`/`WindowFrameAutosave.swift` と同じ「SwiftUI 自身のレイアウト確定を待ってから適用する」パターンの応用だが、多階層のカスケード展開を待つ必要があるため経験的に余裕を持たせた固定時間にしている。理想的にはすべての祖先行の子読み込み完了を検知してから呼びたいが、`FolderTreeRow` の `children` は各行のプライベートな `@State` のため外部から完了を観測できず、この節の実装では簡易な固定遅延に留めた］。
  - `Sources/qooLibraryApp/Preferences/DisplayPreferencesTab.swift`: `autoExpandTreeToCurrentFolder`（`FolderTreePane` と同じ `UserDefaults` キーを共有）の `Toggle` を追加、「既定に戻す」の対象にも含めた。
  - **実機検証で CPU 100% のハングを発見・修正した。** 原因は新設した `ancestorPaths(of:)` の終了判定（`parent.path == current.path` になったら止める）が `URL.deletingLastPathComponent()` の既知の挙動と噛み合っていなかったこと — **これは 1-8 のパスバー実装時に一度踏んで CLAUDE.md 冒頭「不可解な事象は先に WebSearch で調べる」の実例として既に記録していたのと全く同じ罠**（`deletingLastPathComponent()` はルート `/` に対して呼んでも `/` 自身を返すとは限らない）に、今回また気づかずに引っかかった。`current` がルートに達した後も `deletingLastPathComponent()` を呼び続けてしまい、CPU を専有し続けるハングになっていた（`sample` でスタックを採取し `FolderTreePane.ancestorPaths(of:)` に張り付いていることを確認）。ループの先頭で `current.path == "/"` を確認し、ルートに達した時点で `deletingLastPathComponent()` を一切呼ばずに抜けるよう修正し、孤立した Swift スクリプトでルート・深い階層とも正常に終了することを確認してから実機へ反映した。**教訓: 過去に一度記録した教訓であっても、実装のたびに再度意識しないと同じ罠に落ちる。`URL.deletingLastPathComponent()` を使ったパス走査ループを書くときは、この既知の挙動を毎回思い出すこと。**
- **`NavigationRoot`（現在のタブがボリューム経由／登録フォルダ経由のどちらから来たかを表す状態）を新設した**（ユーザー指摘: 「現在開いているフォルダまでフォルダツリーを展開」実装直後の実機検証で、ライブラリフォルダにアクセスすると Macintosh HD・外部ボリューム両方のツリーまで開いてしまう不具合が見つかった。逆にボリューム経由でアクセスした場合もテンポラリ／ライブラリのツリーが反応してはならない、という指摘もあり、双方向で厳密に分離した）。
  - **当初は `selectedURL` のパスが登録フォルダの配下かどうかを都度判定する方式で実装していたが、これは根本的に誤りだった。** 実体として同じ物理フォルダでも、フォルダツリーでライブラリ／テンポラリ行をクリックして到達した場合と、ボリューム側のツリーを手で辿って（同じ場所へ）到達した場合とで、パスだけでは区別がつかない。**ユーザーから「実体としては同じであっても、ボリューム経由かライブラリ／テンポラリ経由かで処理を分離してほしい」と明確な指摘があり**、URL からの逆算をやめ、「どちらの入口から来たか」を明示的な状態として持ち回る設計に変更した。
  - `Sources/qooLibraryApp/State/WindowState.swift`: `NavigationRoot`（`.volume` / `.registeredFolder(id:rootURL:)`）を新設し、`TabState.navigationRoot` として保持する。`navigateCurrentTab(to:root:)` に `root` パラメータを追加（既定 `nil` は「現在のタブの文脈を引き継ぐ」の意味）。フォルダツリーのボリューム行／登録フォルダ行のクリックだけが明示的に `root` を指定し、中央ペインでのダブルクリック・Enter・「1階層上へ」など、ツリーを経由しない移動はすべて `nil`（継承）を使う。`backHistory`/`forwardHistory` も `URL` だけでなく `TabHistoryEntry(url:navigationRoot:)` を積むように変更し、戻る／進むで当時の文脈も正しく復元されるようにした。
  - **「1階層上へ」も同じ仕組みで解決した**（ユーザー要望: テンポラリ／ライブラリフォルダ経由でアクセスした場合、その登録フォルダが最上位として扱われ「1階層上へ」で外に出られないようにしてほしい）。`canGoToParent` に、`navigationRoot` が `.registeredFolder` かつ現在のフォルダがちょうどその登録ルートと一致する場合は `false` を返す分岐を追加した（既存の仮想ホーム境界チェックと同じパターン）。ボリューム経由で実体として同じ場所に来た場合はこの制限を適用しない — `navigationRoot` で入口を区別しているため、同じ URL でも挙動が変わる、意図した設計。
  - `Sources/qooLibraryApp/MainWindow/FolderTreePane.swift`: `FolderTreeRow` に `rowNavigationRoot: NavigationRoot` を追加し、`registeredFolder`/`onRename`/`onUnregister`（登録ルート行だけに渡す）と違い**子孫の行にもそのまま伝播させる**（再帰呼び出しで渡し続ける）ことで、ツリーのどの行をクリックしても、それがどちらの枝に属するかを常に正しく `onSelect(url, navigationRoot)` へ伝えられるようにした。`revealSelectionIfNeeded` も `selectedURL` のパスから逆算するのをやめ、`navigationRoot` を直接 `switch` して反応するグループを1つに絞り、`ancestorPaths(of:downTo:)` に登録フォルダの根で打ち切る `floor` 引数を追加した（ボリューム経由のときだけファイルシステムルートまで遡る）。
  - **この `NavigationRoot` は今回の2機能（ツリー自動展開・「1階層上へ」の境界）専用ではなく、将来のラベルフィルタ（ライブラリ経由のときだけ適用）・テンポラリフォルダ専用の一括処理（テンポラリ経由のときだけ適用）のための基盤として設計した**［ユーザー指摘: 「これは重要で」と明示的に強調された要件。フェーズ2でラベルフィルタを実装する際、フェーズ3でテンポラリフォルダの一括処理を実装する際は、`currentTab.navigationRoot` を直接参照してスコープを判定すること。新たに URL ベースの逆算ロジックを作らないこと]。
  - **実機検証で発見・修正した2件目のバグ: 登録フォルダの根（サブフォルダではなく登録フォルダ自身）を直接開くと、ボリューム側のツリーまで反応してしまっていた。** `ancestorPaths(of:downTo:)` の `floor` 一致判定を「`parent` を計算した後」にしか行っていなかったことが原因— `parent` は常に `current` の1つ上を指すため、`url` が `floor` そのものだった場合に `floor` 自身が一度も `parent` として現れる機会が無く、判定に一切引っかからないままファイルシステムルートまで遡ってしまっていた（登録フォルダの1つ下のサブフォルダを開いたときは正しく動いていたため、「サブフォルダは大丈夫だが根そのものだけ壊れる」という非対称なバグとして発覚）。ループの先頭で「`current` が既に `floor` そのものか」を確認し、その時点で `parent` を計算せずに抜けるよう修正。孤立スクリプトで根そのもの・1階層下・2階層下のいずれも正しい結果になることを確認してから実機へ反映した。
- **環境設定「一般」タブに「起動時に開くフォルダ」を追加した**（ユーザー要望）。**「テンポラリフォルダとライブラリフォルダは、通常のボリューム上のフォルダとは分けて設定できること」という明示的な指摘**があり、UI 上は仮想ホーム／テンポラリフォルダ／ライブラリフォルダ／ボリューム上のその他のフォルダの4択（テンポラリ・ライブラリを選ぶとさらに具体的な登録フォルダを選ぶサブピッカーが出る）にしている。
  - `Sources/qooLibraryApp/Preferences/StartupFolderPreference.swift`（新規）: `StartupFolderKind`（`virtualHome`/`registeredFolder`/`volumeFolder` の3値、永続化の実体）と、実際に開くフォルダを解決する `resolve() async -> (url:navigationRoot:)`。`registeredFolder` は ID で参照する（表示名を後から変更しても追従する）ため `RegisteredFolderStore` の解決を要し非同期。`volumeFolder` は `RegisteredFolderStore` とは**別の、この設定専用の** Security-Scoped Bookmark（`SecurityScopedBookmarkResolver` を直接使う、`RegisteredFolderStore` と同じ「登録されている間はアプリ終了までアクセスを開始したまま保持する」方針）で参照し、同期的に解決できる。解決結果には `NavigationRoot`（前節参照）も含め、登録フォルダ起点で開いた場合は正しく「1階層上へ」の境界・フォルダツリーの自動展開スコープにも反映される。
  - `Sources/qooLibraryApp/MainWindow/MainWindowView.swift`: `wasLaunchedWithoutExplicitFolder`（`initialFolder == nil` かどうか）と `hasAppliedStartupFolderThisLaunch`（`WindowFrameAutosaveView` と同じ「プロセスで最初の1本にだけ適用する」`nonisolated(unsafe) static` フラグ）を組み合わせ、**アプリ起動直後の最初のウインドウにだけ**適用する。⌘N で追加するウインドウや「新規ウインドウで開く」から開いたウインドウは対象外（後者は既に `initialFolder` が明示されているため元々対象外、前者は起動時フォルダへ戻ってしまうと逆に不便なため意図的に除外）。既定（仮想ホーム）のときは非同期処理自体を行わない（無駄なチラつき・待ち時間を避ける）。
  - `Sources/qooLibraryApp/Preferences/GeneralPreferencesTab.swift`: 永続化される3値の `StartupFolderKind` とは別に、UI 表示専用の4値 `StartupFolderUIMode`（`virtualHome`/`temporaryFolder`/`libraryFolder`/`volumeFolder`）を導入し、「テンポラリフォルダ」「ライブラリフォルダ」を独立した選択肢として見せている。どちらの登録フォルダリストに属する選択かを判定するため、選択時に `RegisteredFolderKind`（`library`/`temporary`）を追加の `UserDefaults` キーへ保存し、`temporaryFolders`/`libraryFolders`（`RegisteredFolderStore` から `.task` で非同期読み込み）の完了を待たずに UI の初期表示モードを同期的に決定できるようにしている。ボリューム上の任意フォルダは `NSOpenPanel` で選び、選択直後に `SecurityScopedBookmarkResolver().makeBookmark(for:)` でブックマーク化して保存する。
  - **既知のリスク（実機検証で要確認）**: `startupFolderUIMode`（`@AppStorage` 由来の値から導出する計算プロパティ）を `switch` で分岐してビュー構造（サブピッカー／ボタンの出し分け）を決めている。これは 1-9 で発見した「`@AppStorage` の値をビュー構造を決める `if` 条件の中で直接使うと SwiftUI の Observation が無限に再評価を繰り返しハングする」不具合と**構造的に同じパターン**であり、`ancestorPaths` の無限ループとは別種の潜在的リスクとして認識している。
  - **実機検証で発見・修正したバグ: 「テンポラリフォルダ」「ライブラリフォルダ」のラジオボタンを選べなかった。** 原因はハングとは別の、単純なロジックバグだった。当初 `startupFolderUIMode` は `startupFolderKind`＋`startupRegisteredFolderCategory` から都度導出する計算プロパティにしていたが、モード切替の直後はまだ具体的な登録フォルダが選ばれていない（`startupRegisteredFolderID` が空）ため `startupFolderKind` を意図的にまだ書き換えないようにしていた。結果、`Picker` の `get:` が呼ばれるたびに `startupFolderKind` は `virtualHome` のままなので毎回そちらへ巻き戻って見え、ラジオの選択が一切「定着」しなかった（サブピッカー自体も `switch startupFolderUIMode` の分岐に現れないため表示されなかった）。**「どのモードが選ばれているか」を専用の `@AppStorage`（`qoo.preferences.startupFolder.uiMode`）として独立に永続化**し、実際に起動時に使う `startupFolderKind`（具体的なフォルダが確定した時点で初めて `registeredFolder` になる）とは別に管理することで解消した。**この不具合が「選べない」という形で（ハングではなく）確定的に再現したこと自体が、この画面で Observation の無限ループは起きていないことの状況証拠**になっている — ただし念のため実機での最終確認は引き続き依頼する。
  - **登録フォルダが1件以上あれば、何も選んでいない状態でも一番上のフォルダを既定として選択しておくようにした**（ユーザー指摘: 選択できるようになったが既定が空だった）。`registeredFolderSubPicker` の `Picker` の `get:` を「有効な選択が無ければ先頭のフォルダを返す」形にして表示上の空白を無くし、`.onAppear`（サブピッカーが実際に画面へ現れた時点）で同じ先頭フォルダを `startupFolderKind`/`startupRegisteredFolderID`/`startupRegisteredFolderCategory` へ実際に永続化する（`ensureDefaultRegisteredSelection`）。表示上の既定と実際に起動時に使われる値の両方を一致させるため、片方だけの対応（見た目だけ選択済みに見えて実際は未確定、等）にならないようにしている。
  - **「仮想ホーム」という表記をやめ「ホーム」にした**（ユーザー指摘: 実体はサンドボックスの仮想ホームであっても、ユーザーに見せる表記としては実装詳細を出すべきではない）。`preferences.general.startupFolderVirtualHome` の日本語訳のみ変更（内部の型名・コード中のコメントは実装の正確な説明として引き続き「仮想ホーム」を使う）。
  - **文言修正が実機に反映されずハマった: `xcodebuild` の増分ビルドが `Resources/Localizable.xcstrings` の変更をコンパイル済み `Localizable.strings` へ反映しないことがあった。** 上記「ホーム」表記修正後、`xcodebuild`（成功表示）→ 再起動しても画面上は「仮想ホーム」のままだった。ビルド成果物の `Contents/Resources/ja.lproj/Localizable.strings` を `plutil -p` で直接確認したところ、コンパイル済みの値がソース編集より古いタイムスタンプのまま（＝再コンパイルされていない）と判明。`xcodegen generate` からやり直して再ビルドしたところ正しく反映された。**教訓: 文字列カタログ（`.xcstrings`）だけを変更したときも、`xcodebuild` の成功表示だけで反映を信じず、疑わしければ `Contents/Resources/<lang>.lproj/Localizable.strings` を `plutil -p` で直接確認すること。**
  - **実機検証（ユーザーによる手動確認）で完了。** ライブラリ／テンポラリフォルダの既定選択（1件以上登録時に先頭が既定になる）、「ホーム」表記、起動時フォルダ設定のいずれも確認済み。
    - **すべて選択（⌘A）を新規実装した。** `selectAllInCurrentFolder()`（現在のフォルダの `entries` 全件を `selection` にする）。Edit メニューと、空きスペースの右クリックメニュー（Finder に合わせて）の両方に配線。
    - **「選択項目で新規フォルダを作成」（Finder の File メニュー相当機能）を新規実装した。** `newFolderWithSelection(_:)` が新規フォルダの作成と選択項目の移動を `CompositeCommand` で1つの Undo 単位にまとめる（`extractArchives` 等、既存の複合コマンドパターンを踏襲）。衝突時にコマンド自体が失敗しないよう、事前に空いているフォルダ名（「新規フォルダ（選択項目）」「新規フォルダ（選択項目） 2」…）を探してから実行する。File メニューとコンテキストメニュー（選択項目がある場合）の両方に配線。既定のキーバインドは割り当てていない（Finder 自身も既定は ⌃⌘N だが、本アプリでは File メニューから呼べれば十分と判断）。
    - **複製（⌘D）・エイリアスを作成（⌘L）・圧縮（既定キー無し）を、右クリックだけでなく実際のキーボードショートカット・メニューバー経由でも呼べるようにした。** 3つとも 1-7/1-9 で機能自体は実装済みだったが、`ActionID`/`KeyBindingButtons` 経由の配線が無く、コンテキストメニューをマウスで開かない限り呼べなかった。`ActionID` に `.duplicate`/`.makeAlias`/`.compress`/`.selectAll`/`.newFolderWithSelection` を追加（`DefaultKeyBindings` にも追加、キーボードタブの一覧・衝突検出・既定に戻すの対象になる）。
    - **既定キーの衝突を1件発見・解消した。** Finder 標準の「エイリアスを作成」は ⌘L だが、本アプリは 1-8 の時点で未実装だった `toggleDisplayMode`（表示モード切替）に ⌘L を仮に割り当てていた。`toggleDisplayMode` は本 CLAUDE.md 記述時点でもどこからも呼ばれていない未実装機能であり、かつ Finder 自身「トグル」という概念を持たない（⌘1〜⌘4 で個々の表示モードを直接指定する）ため援用すべき Finder 標準キーが無いと判断し、`toggleDisplayMode` の既定キーを空にして ⌘L を `makeAlias` に譲った。
  - **File メニュー**: `CommandGroup(after: .newItem)`（既定の「新規ウインドウ」の直後）に追加。
  - **Edit メニュー**: `CommandGroup(replacing: .pasteboard)` で標準のプレースホルダ（Cut/Copy/Paste/Delete/すべて選択。テキスト編集ビューが無いためクリックしても何も起きない非活性項目のまま放置されていた）を丸ごと置き換えた。SwiftUI の `.pasteboard` プレースメントに Cut/Copy/Paste/Delete/Select All が一括りで含まれることは WebSearch で確認済み（`CommandGroup(after: .pasteboard)` で追加のみだと重複した「すべて選択」等が残るリスクがあったため、`replacing` を選んだ）。Undo/Redo は従来通り別グループ（`.undoRedo`）のまま（`CommandStack` が単一シングルトンのため `FocusedValue` を経由する必要が無い）。
  - **Finder との対照表（File メニュー）** — 実装したものは上記参照。以下は追加しなかった項目とその理由（**A = サンドボックス／アーキテクチャ上の理由で現状不可能、B = 技術的には実装できるが未着手**）:
    - 開く／情報を見る／複製／エイリアスを作成／ゴミ箱に入れる／圧縮／すべて選択／カット・コピー・ペースト → **実装済み**（上記参照）。
    - **「開く」の対象アプリ選択（Open With サブメニュー）**: **[この後 1-12 のタイミングで実装済み]** `OpenWithMenu`（`FolderContentView.swift`）として実装済み、詳細は「アプリ関連付け」節参照。当初はここで B 判定として見送っていたが、`AppAssociationService`（関連付けタブ）の実装時にまとめて対応した。
    - **印刷**: B（技術的な可否は未検証）。汎用ファイル形式（マンガ・アーカイブ主体）を「印刷」する需要がほぼ無く、実装コストに見合わないと判断し優先度を下げているだけで、サンドボックスによる制約は確認していない。
    - **情報を見るを Finder 本体のウインドウで開く**: ~~A~~ → **[2026-08 再調査で分類を訂正] 「実装不能」ではなく「entitlement の追加とユーザー同意を要する判断事項」**。SDK のヘッダを全文検索して、Finder の情報ウインドウを開く**公開 API は存在しない**ことを確認した（`NSWorkspace.getInfoForFile:` は非推奨のメタデータ取得でウインドウとは無関係）。したがって経路は Apple Events のみだが、`com.apple.security.automation.apple-events` は**追加できる** entitlement で、本プロジェクトの禁止事項（§9）にも含まれない。実装するかどうかはユーザーの判断であって、技術的な不能ではない。優先度は低いまま——自前の常設インスペクタ（`InspectorPane`）が同等の情報を出しており、Finder の Get Info にしか無い要素（Spotlight コメント・タグ）はそもそも本アプリが xattr を書かない方針 [CL-03] と相容れない。
    - **クイックルック（スペースキーでのプレビュー）**: B。サンドボックス起因ではなく、`QLPreviewPanel`/QuickLook Framework 統合そのものが未着手（ロードマップ 1-14「Quick Look 等」として既に切り出し済みの独立タスク）。`ActionID.quickLook`（既定キー: スペース）は 1-8 の時点で登録済みだが呼び出し先の機能が無いため未配線のまま。
    - **検索（Find）**: B。サンドボックス起因ではなく、検索 UI・インデックス機構そのものが未着手（`ActionID.focusSearch` は登録済みだが同様に呼び出し先が無い）。フェーズ2以降のラベル・検索機能とあわせて実装するのが自然、独立フェーズはまだ割り当てていない。
    - **タグ／カラーラベル**: B、ただし理由はサンドボックスではなくドメインモデル。ラベルドメイン型（`Label`）自体が Phase 2 対象で未実装のため、対応するメニュー項目を今追加しても意味を持たない。
    - **サイドバーに追加**: 該当機能なし（B寄りだが正確には「代替済み」）。Finder のサイドバーに相当する概念は本アプリでは 1-13 で実装済みの「ライブラリ／テンポラリフォルダとして登録」（`RegisteredFolderStore`）であり、フォルダツリーの「+」ボタンから既に行える。Finder と同じ名前の項目を重ねて追加する意味が無いため対象外。
    - **新規スマートフォルダ**: 該当機能なし。保存済み検索（スマートフォルダ）という概念自体が本アプリのどのフェーズの要件にも存在しない。サンドボックスではなく、機能そのものが設計上スコープ外。
    - **新規ターミナルで開く**: ~~A（既出）~~ → **[訂正] 実装可能だった。** 下記「ターミナルで開く」節参照。Apple Events は不要で、LaunchServices 経由で足りる。
    - **サービス（Services）／クイックアクション**: B、ただし通常の「未実装」より実装コストが高い区分。macOS の `NSServices`（Info.plist 宣言＋ Services メニュー統合）自体はサンドボックスで禁止されていないが、公開する側（Service Provider として他アプリから呼ばれる）・利用する側（他アプリの Service を呼ぶ）のどちらも、Info.plist 宣言や別ターゲット（App Extension）を要することがあり、実装・保守コストが今回のスコープに見合わないと判断した。以前の CLAUDE.md 記述（1-9）は「実装コストに見合わない」とだけ書いていたが、サンドボックス起因という誤解を避けるためここで理由を明確化した。
    - **イジェクト（取り出し）**: B、ただしサンドボックス下での実際の可否は**未検証**。`NSWorkspace.unmountAndEjectDevice(at:)` 自体は公開 API だが、サンドボックス下でユーザー未選択の外部ボリュームに対して追加の entitlement 無しに動作するかは WebSearch でも確証を得られなかった。VolumeEligibilityChecker 等が既に外部ボリュームを扱っている実績はあるが、イジェクト操作自体の検証はしていないため、実装は将来のタスクとして保留する（検証してから着手すべき、のケース）。
    - **ディスクに書き込む（Burn to Disc）**: 該当機能なし。光学ドライブ搭載 Mac が実質的に存在しない現在、価値がほぼ無い機能と判断し対象外にした。サンドボックスとは無関係。
    - **項目を Dock に追加**: B、優先度低。実装コストに対する価値が低いと判断し見送った。
  - **Finder との対照表（Edit メニュー）**: Undo/Redo/カット/コピー/ペースト/すべて選択 → **実装済み**（上記参照）。「クリップボードを表示」「音声入力を開始」「絵文字と記号」は macOS 標準機能（`.pasteboard` を置き換えても影響を受けない別グループ）のため対象外。
  - **[1-16 のスコープ定義、要件定義書には無い、ユーザー要望]**: 「フェーズ1のアイテムに、Finder が持つ機能で実装を見送ったものを可能な範囲で実装する、を加えておいてください」との指示を受け、上記の File メニュー対照表・下記のコンテキストメニュー対照表で **B 判定**（技術的には実装できるが未着手）とした項目群をロードマップ番号 **1-16** としてまとめて記録する。棚卸し時点での対象候補: 印刷、クイックルック（既に 1-14 として独立タスク化済みのためそちらで対応）、検索（Find、フェーズ2のラベル機能と合わせて検討）、サービス／クイックアクション、イジェクト（サンドボックス下での実際の可否が未検証のため着手前に要検証）、Dock への項目追加、フォルダツリーの通常フォルダ行への右クリックメニュー追加（後述、配線工数のみの問題）。**A 判定**（サンドボックス／アーキテクチャ上不可能）の項目はこの対象に含めない。着手時は、この節と直後のコンテキストメニュー対照表を読んでから、各項目について現時点でも B 判定が妥当か（依存する機能が実装されて A→実装可能や既に別タスクで実装済みになっていないか）を再確認すること。
    - **[2026-08 の再棚卸し] 上記の候補一覧を実装状況の調査に基づいて更新した。着手時は以下の更新後の表を正とすること**（上の初期棚卸しの列挙は履歴として残す）。

      | 項目 | 更新後の判定 | 根拠 |
      |---|---|---|
      | クイックルック | **完了・対象外** | 1-14 で実装済み（Space・コンテキストメニュー・File メニュー） |
      | フォルダツリーの通常フォルダ行への右クリックメニュー | **完了・対象外** | `FolderTreeContextMenu.swift` で実装済み（グループ別の拡張スロット付き） |
      | イジェクト | **B（実装可能と確定）** | **サンドボックス下での可否を実測で確定させた**（下記） |
      | Dock への項目追加 | **A へ再分類** | 公開 API が無く、Dock の永続項目一覧は `~/Library/Preferences/com.apple.dock.plist`（他アプリの設定ドメイン）。サンドボックスからは書き込めない |
      | 検索（Find） | **B（範囲を絞る）** | 現在のフォルダ内の名前フィルタ（⌘F）はフェーズ2の依存なしに実装できる。`ActionID.focusSearch`（既定 ⌘F）と `TabState.searchText` は登録済み・未配線のまま残っている。ライブラリ横断検索・ラベル検索はフェーズ2のまま |
      | 印刷 | **対象外と決定** | 実装自体は可能だが、マンガ・アーカイブ主体の本アプリで価値がほぼ無い［ユーザー判断、2026-08。1-16 の候補から正式に外す。将来必要になったら改めて起票すること］ |
      | サービス／クイックアクション | **1-16 では見送り（B のまま）** | AppKit のレスポンダ（`validRequestor(forSendType:returnType:)` + `writeSelection(to:types:)` + `NSApp.servicesMenu`）で実装可能。macOS の Quick Action も Services メニュー経由で同じ仕組みに乗る。ただし SwiftUI 主体の本アプリに AppKit レスポンダを 1 つ持ち込む構造変更を伴うため、他項目を片付けてから必要性を見て判断する［ユーザー判断、2026-08］ |

    - **[1-16 の確定スコープ、2026-08]** 上記の再棚卸しとユーザー判断を反映した、実際に着手する対象は次の 4 つ:
      1. **イジェクト** — 実測で可否を確定済み（下記）。1-17 と相互に検証しやすい。
      2. **検索（⌘F）** — 現在のフォルダ内の名前フィルタに範囲を絞る。横断検索・ラベル検索はフェーズ2のまま。
      3. **表示メニュー** — 既存機能（表示モード・並び替え・アイコンサイズ・パスバー等）のメニューバーへの配線 ＋ **ステータスバー（項目数・空き容量、⌘/ で表示切替）を新規実装する**［ユーザー判断、2026-08］。
      4. **移動メニュー** — 戻る/進む/上の階層への配線 ＋ **「フォルダへ移動…（⇧⌘G）」** ＋ 最近使ったフォルダ。「サーバへ接続」はネットワーク通信を実装しない方針 [SC-01] のため対象外。

    - **[イジェクトの実測、2026-08]** サンドボックス下での可否が唯一の未検証項目だったため、使い捨てのプローブで確定させた。`hdiutil` のスパースイメージをマウントし、`app-sandbox`/`files.user-selected.read-write`/`files.bookmarks.app-scope`（実アプリと同一の entitlement）でアドホック署名した最小アプリから実行した結果:
      - プロセスが実際にサンドボックス下であることを確認（ホームが `~/Library/Containers/…/Data`、対象ボリュームの `contentsOfDirectory` は `NSPOSIXErrorDomain Code=1 Operation not permitted` で失敗）。
      - **その状態でも `NSWorkspace.unmountAndEjectDevice(at:)` は成功し、実際にアンマウントされた**（`stillMounted=false`）。**追加の entitlement は不要。**
      - `volumeIsEjectableKey`/`volumeIsRemovableKey` は**読み取り権限が無いボリュームでも取得できる**（メニュー項目の出し分けに使える）。
      - つまり**ファイルアクセス権とイジェクト権限は別のレイヤ**で、アクセスを許可していないボリュームも取り出せる。1-17（登録フォルダの縮退状態）はイジェクトを主要な引き金として設計しているため、**1-17 と近い時期に実装すると相互に検証しやすい**。
    - **[新たに判明したスコープの穴] 初期の Finder 対比監査は File メニュー・Edit メニュー・コンテキストメニューだけを対象にしており、Finder の「表示」メニュー・「移動」メニューは一度も監査していない。** `Finder.app` の `MenuBar.nib` を実際にインスタンス化して確認したところ（この手法自体は本 CLAUDE.md「Finder の ⌥ 代替項目」節に記録済み）、qooLibrary には**そもそも「表示」メニュー・「移動」メニューが存在しない**（`CommandMenu` を 1 つも定義していない）。機能自体は多くが既に実装済みで、メニューからの導線だけが無い状態のため、配線中心の作業になる。**この 2 メニューは 1-16 に含める**［ユーザー判断、2026-08 の再棚卸し時に確認済み］。
      - **表示メニュー**（Finder: ⌘1/⌘2 の表示モード直接指定・並び替え・パスバー/サイドバー/インスペクタ/タブバーの表示切替・アイコンサイズ ⌘+/⌘-・表示オプション ⌘J・ステータスバー ⌘/）。qooLibrary の対応状況: 表示モード切替・並び替え・アイコンサイズ・カラム表示は**ツールバー／漏斗アイコンメニュー／環境設定にのみ存在**しメニューバーからは呼べない。`ActionID.toggleDisplayMode` は既定キー空のまま（Finder は「トグル」ではなく ⌘1/⌘2 の直接指定なので、**ActionID の設計自体を見直す必要がある**）。パスバーは常時表示で切替が無い。**ステータスバー（項目数・空き容量）は未実装。**
      - **移動メニュー**（Finder: 戻る/進む/上の階層へ・Recents/書類/デスクトップ/ダウンロード/ホーム/アプリケーション等へのジャンプ・最近使ったフォルダ・フォルダへ移動… ⇧⌘G・サーバへ接続 ⌘K）。qooLibrary の対応状況: 戻る/進む/上の階層へは実装済みだがメニューバーには無い。ホーム等へのジャンプは既存の「ホーム」グループ構想（アクセス権の付与が前提、本 CLAUDE.md の 1-4「将来検討」節参照）と同じ話。**「フォルダへ移動…（⇧⌘G）」は依存が無く単独で実装でき、実用価値が高い。** 最近使ったフォルダは未実装。サーバへ接続はネットワーク通信を実装しない方針 [SC-01] のため対象外。
  - **コンテキストメニューの Finder 対比監査**（`FolderContentView.contextMenuContent(for:)`／`FolderTreePane`）:
    - 上記で新規実装したカット・すべて選択・選択項目で新規フォルダの3つは、コンテキストメニューにも同時に配線済み（前述）。
    - **[実装済み] フォルダツリー（左ペイン）の通常フォルダ行に右クリックメニューが無い**（登録ルート行だけ「表示名を変更」「登録解除」を持つ）。B → 本 §0 末尾の「フォルダツリー（左ペイン）の全行にコンテキストメニューを追加し…」の節で実装済み。以下は当時の判断の記録。Finder のサイドバー相当ではあるが、Finder のサイドバー項目自体のコンテキストメニューも「新規タブで開く」「新規ウインドウで開く」「Finder の情報を見る」程度に限定的で、本アプリの中央ペインの豊富な右クリックメニューほどの価値は無い。`onOpenInNewTab`/`onOpenInNewWindow` コールバックは現状 `FolderTreePane` まで届いておらず（`MainWindowView → FolderContentView` にのみ渡している）、実装するにはプロパティのバケツリレーが必要。優先度が低いと判断し今回は見送ったが、サンドボックスや設計上の制約ではなく単純に配線工数の問題であり、実装可能。
    - **Get Info を Finder と同じ独立ウインドウで表示すること**: 上記 File メニューの「情報を見る」項目と同じ理由（A、Apple Events entitlement）。1-10 で常設インスペクタに代替済み（アーキテクチャ上の設計判断であり、サンドボックスの制約でこの形になったわけではない点に注意 — 常設インスペクタ自体はより優れたUXという判断で選んだもので、Get Info ウインドウが技術的に作れないわけではない。作れないのはあくまで「Finder 自身の」Get Info ウインドウを呼び出すことだけ）。
  - **ビルド・テスト・静的検査**: `xcodebuild`（Debug）成功、`swift test`（125件）全通過、`check-fileops-isolation.swift`/`check-layer-dependencies.swift` 両方 OK。
- **環境設定「一般」タブに「すべてのウインドウが閉じたら終了」を追加した**（要件定義書には無い、ユーザー要望）。既定は `false`（macOS の一般的なアプリと同じく、ウインドウを閉じてもアプリは常駐し続ける）。
  - `Sources/qooLibraryApp/AppDelegate.swift`（新規）: SwiftUI の `App`/`Scene` には `applicationShouldTerminateAfterLastWindowClosed` に相当する宣言的 API が無いため、`NSApplicationDelegateAdaptor` で最小限の `NSApplicationDelegate` を導入した。同じメソッドを実装するだけの単機能クラスで、`UserDefaults` の該当キー（`GeneralPreferencesTab` の `@AppStorage` と共有）を直接読む。
  - `Sources/qooLibraryApp/qooLibraryApp.swift`: `@NSApplicationDelegateAdaptor(AppDelegate.self)` を `QooLibraryApp` に追加。
- **環境設定「圧縮／展開」タブを新規追加し、7z 書き込み対応・zip/7z の圧縮レベル調整・zip のパスワード保護（暗号化）・展開時の安全上限調整を実装した**（要件定義書には無い、ユーザー要望: 「既定の圧縮形式と、その形式で利用可能なオプションを設定可能に」「7zが良いという人もいるかもしれない」「圧縮率等の設定を変更したい」「パスワード付きで圧縮したい」「展開についても設定可能なオプションがあれば追加すること」）。
  - **調査の結果、当初の判断を覆す発見があった。** 圧縮（書き込み）は 1-7 時点では zip のみで、`Scripts/build-libarchive.sh` は `--without-lzma --without-openssl --without-nettle` を明示的に指定してビルドしている。この指定だけを見て「本格的な 7z 圧縮（LZMA）や AES 暗号化には liblzma・OpenSSL/nettle の新規ベンダリングが必須」と判断し、ユーザーに確認して「本格対応（新規ベンダリング）」の回答を得ていた。**しかしその後、libarchive のソース（`archive_write_set_format_7zip.c`）と、ビルド済みの `ThirdParty/libarchive/libarchive.xcframework` の静的ライブラリを `nm`/`strings` で直接調査したところ、この判断は誤りだったと判明した**:
    1. **7z の PPMd コーデックは外部依存ゼロで既にビルド済みバイナリに含まれていた**（`archive_ppmd7.o`/`archive_ppmd8.o` が実際にリンクされている、`archive_write_set_format_7zip.c` 上も `ppmd`/`copy` オプションには `#ifdef` ガードが無い＝常時利用可能）。bzip2/deflate コーデックも、最終リンクコマンドに元々 `-lbz2 -lz` が含まれておりシステムライブラリとして既にリンクされていた（`nm` で `BZ2_bzCompress`/`deflate` の undefined symbol を確認）。**LZMA（liblzma）だけが無いだけで、7z 自体は PPMd 既定で十分実用的な圧縮が可能** — liblzma の新規ベンダリングは不要だった。
    2. **AES 暗号化についても、`archive_cryptor.o` に Apple CommonCrypto（`CCCryptorCreateWithMode` 等）への undefined symbol 参照と `archive_commoncrypto_version` シンボルが既に存在していた。** `archive_write_set_passphrase.c`/`archive_read_add_passphrase.c` もビルド済みバイナリに含まれていた（デバッグ文字列で確認）。CommonCrypto は macOS システム標準（新規ベンダリング不要）のため、OpenSSL/nettle も不要だった。
    3. 静的解析だけでは「実際にリンク・実行時に動くか」までは確定できないため、実装前に `CompressionCapabilityProbeTests`（zip AES256 round-trip・7z PPMd round-trip、`CLibarchive` の生 API を直接叩く）を書いて実行し、両方 green で通過することを実機（テスト実行環境）で確認してから本実装に入った。この一時的な検証テストは、後により網羅的な `LibarchiveBackendTests` の正式テストで置き換えて削除した。
    4. **libarchive の 7z ライターにはそもそも暗号化オプションが存在しない**ことも判明した（`archive_write_set_format_7zip.c` の `_7z_options()` が扱うのは `compression`/`compression-level`/`threads` のみ）。そのため暗号化は zip 選択時のみ提供し、7z 選択時は暗号化 UI 自体を表示しない（機能しない設定を見せない、という既存原則）。
    - **教訓**: `--without-*` のビルドフラグを見て「機能が無い」と早合点せず、実際にビルド済みバイナリの記号表・文字列を調べれば「本当に使えないのか」を数分で確定できる場合がある。ユーザーに新規依存追加の可否を確認する前に、この程度の裏取りを先に済ませておくべきだった。
  - **ドメイン層**（`QooKit`）: `Sources/QooKit/Model/Archive/CompressionOptions.swift`（新規）— `CompressibleFormat`（zip/sevenZip、書き込み可能な2形式のみに絞った専用列挙。`ArchiveFormat` は読み取り専用の rar/tarGz も含む4種のため、無効な組み合わせを型で排除する目的で分離）、`SevenZipCodec`（ppmd 既定/bzip2/deflate/copy）、`ZipCompressionLevel`（store/fast/normal/best、libarchive の `zip:compression-level` にそのまま渡す）、`ArchiveEncryptionMethod`（none/zipTraditional/aes128/aes256）、`CompressionOptions`。**パスワード文字列自体はこの型に含めない** — `UserDefaults` への平文保存はセキュリティ上望ましくないため、実際のパスワードは圧縮のたびに `ArchivePasswordSheet` で入力させる設計にしている（環境設定が持つのは「暗号化するか、その方式」だけ）。`ExtractError` に `.passwordProtected`（既存、フェーズ0以来未使用のまま残っていたプレースホルダを実際に使うようにした）と `.incorrectPassphrase`（新規）を追加。
  - **インフラ層**（`QooInfrastructure`）: `LibarchiveBackend.compress` を `CompressionOptions`/`passphrase` を受け取る形に拡張し、format に応じて `archive_write_set_format_zip`/`archive_write_set_format_7zip` を切替え、`archive_write_set_options` で圧縮レベル/コーデックを設定、zip で暗号化が有効なら `archive_write_set_passphrase` も設定する。`ExtractOptions` に `passphrase: String?` を追加（`nil` なら zip の暗号化エントリ遭遇時に `ExtractError.passwordProtected` を投げる設計、`archive_read_add_passphrase` へブリッジ）。パスフレーズ関連のエラー判定は libarchive の実際のエラー文言（WebSearch で確認: "Passphrase required for this entry"/"Incorrect passphrase"）を部分一致で判別する `passphraseError(from:)` ヘルパーを追加。`ArchiveCompressor.compress` も同様に拡張し、拡張子を `options.format` に応じて `.zip`/`.7z` で出し分ける。
  - **アプリ層**（`QooApplication`）: `CompressCommand`/`ExtractCommand` に `options`/`passphrase`（または `limits`/`passphrase`）を追加。
  - **UI**（`qooLibraryApp`）: `Sources/qooLibraryApp/Preferences/CompressionPreferencesTab.swift`（新規、`PreferencesView` の `.compression` カテゴリとして表示/キーボードの並びに追加）— 圧縮セクション（形式・レベル/コーデック）、暗号化セクション（zip 選択時のみ表示、Traditional 選択時は弱い暗号化である旨の警告文、パスワードはここに保存しない旨のヒント文）、展開セクション（`ExtractLimits` の最大サイズ・最大エントリ数・警告/中断の圧縮率しきい値をスライダーで調整、既定に戻すボタン付き）。`Sources/qooLibraryApp/MainWindow/ArchivePasswordSheet.swift`（新規）: 圧縮時のパスワード設定（確認欄付き）と、展開時のパスワード入力・誤りパスワードでの再試行を兼ねる共通シート。
    - **QooDialogFooter に `confirmDisabled` パラメータを追加した**（1-1 で用意されて以来どこからも使われていなかった共通コンポーネントの、実質的な最初の利用箇所）。パスワード未入力・確認欄不一致の間は決定ボタンだけを無効化し、キャンセルは常に押せるようにする必要があったため。
    - **展開時のパスワード対話的再試行は、単一アーカイブ展開時のみ提供する**［設計判断、スコープを絞った理由を明記］。複数選択の一括展開（`CompositeCommand` でまとめて1つの Undo 単位にする既存パターン）中にパスワード保護されたアーカイブに遭遇した場合、どれが原因か・途中まで成功した分をどう扱うかの UX が複雑になるため、対話的な再試行は行わず通常のエラー表示に留める。
    - `FolderContentView.swift` の `compressHere`/`compressWithDialog` を環境設定の `CompressionOptions` を読むように変更し、暗号化が有効なときは `ArchivePasswordSheet(mode: .setPassword)` を挟んでから実行する。`extractArchives`（`extractInPlace`/`extractToNamedFolders`/`extractToChosenDestination` の共通実装）は環境設定の `ExtractLimits` を常に使い、単一アーカイブ展開で `ExtractError.passwordProtected`/`.incorrectPassphrase` を検知したら `ArchivePasswordSheet(mode: .unlock)` を表示して再試行する。
  - **テスト**: `Tests/QooInfrastructureTests/LibarchiveBackendTests.swift` に、zip の全圧縮レベルでの書き込み確認、7z の全コーデック（ppmd/bzip2/deflate/copy）での round-trip、zip の全暗号化方式（Traditional/AES128/AES256）でのパスワード無し失敗・誤りパスワード失敗・正しいパスワードでの round-trip、パスワード未指定での圧縮失敗、7z への暗号化オプション指定が無視されることを追加（計8件、パラメタライズドテスト込み）。
  - **RAR（`UnrarBackend`）のパスワード対応は対象外**。UnRAR 側にパスワード関連の実装が現状皆無で（`RAROpenArchiveEx` にパスワードコールバックを渡していない）、対応するには別途 `QooUnrarBridge.mm` の拡張が必要になるため。RAR はそもそも読み取り専用でこのタブの「圧縮」対象にはならない。
  - **実機検証（ユーザーによる手動確認）を依頼予定。**
- **動画ファイルのサムネイル表示に対応した**（要件定義書には無い、ユーザー要望: 「一般的な動画形式のサムネイル表示に対応するにはどうすればいいですか？」から始まった調査の帰結。関連付けタブへの任意拡張子追加〈直前の節〉と同じ「動画ライブラリとしても使える想定」という文脈）。
  - **技術調査の経緯**: `QLThumbnailGenerator`（QuickLookThumbnailing framework）が有力候補と判断したが、macOS 標準では mp4/mov 等 QuickTime 互換コンテナのみが対象で、**mkv はコンテナ自体が非対応**（コーデックが H.264/H.265/AV1 のいずれでも無関係）と実機で確認した。`qlmanage -m`（登録済み QuickLook ジェネレータ一覧）に mkv 用の項目が無く、`qlmanage -t` でのサムネイル生成が実際にタイムアウトするまで応答しなかった（2分以上）ことで実証済み。
  - **ユーザーが実際に `QuickLook Video`（QLVideo, github.com/Marginal/QuickLookVideo, GPL）をインストールして検証に協力してくれた。** 当初「IINA をインストールすればサムネイル表示できるか」という仮説を立てたが、これは**誤りだった**（`IINA.app` の `PlugIns/` を実際に調べたところ `OpenInIINA.appex` は Safari 拡張のみで QuickLook 拡張は同梱していないことが判明、訂正済み）。QLVideo は正しく mkv/webm/avi 等の QuickLook 対応を追加する（`QLVideo Formats.appex`/`QLVideo Codecs.appex`、`com.apple.mediaextension.formatreader` という**新しい Media Extensions の仕組み**〈従来の `.qlgenerator`/QuickLook 専用 App Extension とは別物〉を使う）。
  - **有効化だけでは終わらなかった、地道な切り分けの記録**: インストール直後は `pluginkit -m` に登録されて見えるのに、実際には `AVAssetImageGenerator`/`QLThumbnailGenerator` のどちらで試しても "-11828 このメディアフォーマットには対応していません" で失敗し続けた。`qlmanage -r`（quicklookd リセット）でも変化なし。ユーザーに **macOS を再起動**してもらってもなお同じ結果で、続けて**メディア拡張の設定自体を明示的に変更**してもらってようやく状況が動いた——ただし直後の再検証でもまだ `AVAssetImageGenerator`/`QLThumbnailGenerator` は失敗し、`log stream` で監視しても QLVideo 側のログが一切出ないという、原因不明のまま行き詰まった局面があった。
  - **ユーザーからの「Finder 上ではサムネイルが表示されるようになった」という報告が決定打になった。** Finder が実際にサムネイルを表示し、Quick Look（スペースキー）で映像が実際に再生され、同じフォルダの他の mkv ファイルもすべてサムネイル表示されている、という申告を受け、**「正式にパッケージして `/Applications` に登録しないと利用できない可能性はありますか」というユーザーの指摘**を受けて実際に試したところ、決定的な違いが見つかった: `/Applications` にコピーして起動し直すと、エラー内容が `-11828 対応していません`（コーデック非対応）から **`NSCocoaErrorDomain 257`/サンドボックス拡張の発行失敗（`Operation not permitted`）** へと明確に変化した。これは「QLVideo 自体は機能しており、コーデック非対応ではなく単なるファイルアクセス権限の問題」であることを示す決定的な証拠だった。診断コード（`URL(fileURLWithPath:)` を直接構築するだけで正規のセキュリティスコープを経由していなかった）の不備であり、`registeredFolders.json` を確認したところ対象ファイルの親フォルダは実際には既にライブラリフォルダとして登録済みだった。**結論: 技術的な障害は解消されており、`ThumbnailService` が既に持つ正規のセキュリティスコープ経由でアクセスすれば動作するはず**という判断で実装に進んだ。
  - **教訓**: 「サンドボックス化されたアプリとして正式に動作するか」を疑うべきタイミングを、ユーザーの一言（過去に Finder 登録〈AS-07 節〉で一度出ていた注意点）が的確に思い出させてくれた。即席の診断コードは、たとえ動いているように見えても、アプリ本体が使う正規のアクセス経路（セキュリティスコープ・登録フォルダ）を経由しているとは限らないため、その場しのぎの検証結果を早計に「本体でも同じ結果になるはず」と判断しないよう注意する必要がある。
  - **実装**（`QooKit`/`QooInfrastructure`）: `AppLimits.Thumbnail.defaultVideoThumbnailTimeoutSeconds`（既定8秒）を追加。`Sources/QooInfrastructure/FileOps/Thumbnails/VideoThumbnailLoading.swift`（新規）: `VideoThumbnailLoading` プロトコル（`ImageLoading`/`CoverImageCache` と同じ「プロトコル + 既定実装」パターン）と `QLVideoThumbnailLoader`（`QLThumbnailGenerator` を使う既定実装）。**`QLThumbnailGenerator.Request` が `Sendable` 非準拠のため、タイムアウト用の並行タスクと生成用の並行タスクの両方に渡そうとすると Swift 6 の厳格な並行性検査に引っかかった** — 実際に可変な状態を共有しない（`cancel(_:)` の識別子として渡すだけ）ことを承知した上で `@unchecked Sendable` の `RequestBox` に包んで解決した。**タイムアウトは `withTaskGroup` で生成タスクとスリープタスクを競合させ、スリープが先に完了したら `QLThumbnailGenerator.shared.cancel(request)` を明示的に呼ぶ**設計にした——`qlmanage -t` が実機で実際に無限ハングした事例があるため、`PF-11` の同時実行スロットが1件のハングに専有され続けないための防御。`cancel(_:)` を呼ばずに `group` を抜けようとすると、構造化並行性の性質上まだ完了していない子タスクを暗黙に待ち続けてしまいハングが再現するため、ここは省略できない。
  - `Sources/QooInfrastructure/FileOps/Thumbnails/ThumbnailService.swift`: `thumbnail(for:maxPixelSize:)` に、対象が動画ファイル自身（`UTType.movie` に準拠、`isVideoFilename` で判定）の場合は `VideoThumbnailLoading` 経由に分岐する処理を追加した。画像ファイル自身のプレビュー（1-9 で追加済み）と対をなす自然な拡張。**フォルダ／アーカイブ内の「先頭の動画」をカバーとして使う対応は対象外**（IV-01 が要求する「先頭画像」の範囲を超えるため、必要になれば別途検討する）にとどめ、スコープを絞った。`ThumbnailService.init` に `videoThumbnailLoader` パラメータを追加（既定 `QLVideoThumbnailLoader()`）。UI 側（`IconGridView`/`InspectorPane`）は既に `ThumbnailService.shared.thumbnail(for:maxPixelSize:)` を汎用的に呼んでいるため、**変更は一切不要**で動画サムネイルが自動的に反映される。
  - **テスト**: `Tests/QooInfrastructureTests/ThumbnailServiceTests.swift` に3件追加（`FakeVideoThumbnailLoader` を注入し、動画拡張子のファイルだけが `VideoThumbnailLoading` 経由になること・失敗時に `nil` へフォールバックすること・非動画ファイルでは使われないことを検証）。`TestImageFixture` に `makeCGImage`（PNG エンコードを経由しない直接の `CGImage` 生成）を追加。**`QLVideoThumbnailLoader` 自体（実際の `QLThumbnailGenerator` 呼び出し）の自動テストは無し** — サードパーティ QuickLook 拡張の有無という環境依存の結果になるため、UnRAR 経由のテストと同じ理由でスコープ外。
  - **実機検証で完了。mp4 は動作確認済み。mkv は現状 QLVideo 側の制約により動作しないことを、複数の独立した経路で確定させた。**
    - キャッシュ有無の質問（ユーザー: 「このサムネイルはキャッシュされますか？」）には、`ThumbnailService.thumbnail(for:)` が生成前に `CoverImageCache` を確認し生成後に必ず保存する既存の共通ロジックにそのまま乗るため「される」と回答した（動画専用の特別扱いは無い）。
    - mp4 は実機で「順次生成されているようです」と確認が取れたが、**同じフォルダの mkv だけサムネイルが出ない**という報告を受け、`QLVideoThumbnailLoader` に一時的な診断ログを仕込んで原因を特定した。実際のログ: `Error Domain=QLThumbnailErrorDomain Code=0 "Could not generate a thumbnail" ... Code=102`。UTType 判定（`org.matroska.mkv` が `public.movie` に正しく準拠していること）は問題ないことを別途確認済み。
    - **`QLThumbnailGenerator.Request.RepresentationTypes` を個別に試したところ、`.thumbnail`/`.lowQualityThumbnail` は一貫して失敗し、`.icon` のみ成功することが判明した。** さらにこの失敗は**完全に非サンドボックスの素の `swift` スクリプトからの直接呼び出しでも再現した**ため、qooLibrary 側のサンドボックス・アクセス権の問題ではないと確定した（`/Applications` へコピーした際に見えた「サンドボックス拡張の発行失敗」は、あくまで即席の診断コードが正規のセキュリティスコープを経由していなかったことが原因で、本質的な問題ではなかったと判明）。
    - **`.icon` 表現型は成功するが、`NSWorkspace.icon(forFile:)` と同様に「ファイルによらず同一の汎用アイコン」であることも実測で確認した**（2つの異なる mkv ファイルに対してそれぞれ `NSWorkspace.icon(forFile:)` の PNG 書き出しを行い、**MD5 が完全に一致**することを確認、`.icon` も同種の汎用結果と判断）。`qlmanage -t`（レガシー CLI）も終始無反応でハングし続け、こちらも使い物にならなかった。
    - **一方でユーザーに確認したところ、Finder が実際に表示している mkv のサムネイルは「ファイルごとに絵柄が違う」（本物のコンテンツベースのサムネイル）ことが確定した。** つまり Finder は、qooLibrary が試したどの公開 API（`QLThumbnailGenerator` の `.thumbnail`/`.icon`、`NSWorkspace.icon(forFile:)`、`qlmanage`）とも異なる経路でサムネイルを取得している。
    - **[根本原因を特定、確定] QLVideo のソース（`github.com/Marginal/QuickLookVideo`、GPLv2）を実際にクローンして `BUILDING.md` を確認したところ、原因が明記されていた。** QLVideo は `formatreader`/`videodecoder`（Media Extensions、AVFoundation 自体にコンテナ・コーデック理解を追加する仕組み。Spotlight メタデータ抽出や Quick Look 再生には効く）に加えて、**サムネイル生成専用の古い QuickLook 拡張点（`thumbnailer`）と、非対応形式のプレビュー用拡張点（`previewer`）も本来は存在するが、`BUILDING.md` に "Not included in v3 of the app" と明記されている**——つまり現在配布されているバージョン（インストール済みの 3.11 も該当、`pluginkit -m` で確認しても `videodecoder`/`formatreader` の2つしか登録されていない）は、開発者の設計判断として**意図的に**サムネイル専用拡張を同梱していない。`QLThumbnailGenerator` の `.thumbnail` はこの（存在しない）拡張点を必要とするため失敗し、`.icon` は LaunchServices の汎用 UTI→アイコン解決（QuickLook 拡張と無関係）のため成功する、という整合的な説明になる。Finder が見せている本物のサムネイルは、この古い拡張点とは別の、Finder 自身が持つ内部的な Media Extensions 統合（公開 API の外側）から来ていると考えられる。**これは推測ではなく開発者自身が明記した設計方針のため、qooLibrary 側で対応できる余地は無いと確定した。**
    - **[最終決着] mkv のサムネイル表示は、QLVideo とは別のサードパーティ拡張（QLMedia、開発者 Sergey Dikov、Mac App Store）で実際に解決した。** ユーザーからの重要な指摘「QLVideoができない＝サムネイル表示できないわけではない。拡張機能はQLVideoだけではない」を受けて調査を継続し、以下の経緯で解決に至った。
      1. **`Oil3/Mkv-Quicklook`（`QLCodec-mkv` ビルド、GitHub Releases、"with-icons-thumbnailer" と明記されたバージョン）を試したところ、`com.apple.quicklook.thumbnail`（廃止されていない現行のサムネイル専用拡張点）を正しく実装しており、これ単体なら動作する可能性があった。** しかし実際にはすぐには成功せず、原因を切り分けたところ **QLVideo（Marginal 版）が同じ UTI（`org.matroska.mkv` 等）を先に掴んでおり、`quicklookd` がリクエストを QLCodec-mkv 側の拡張へ一切ルーティングしていなかった**ことが `log stream` での監視（サムネイル拡張のプロセスが一度も起動されていないこと）で判明した。**`lsregister -u` で QLVideo を正式に登録解除**してからようやく QLCodec-mkv の拡張が呼ばれ、サムネイル生成に成功した（`pluginkit -r` だけでは登録が残り続け不十分だったため `lsregister -u` を使う必要があった）。
      2. **ただし QLCodec-mkv 自体に実装バグが2つ見つかった。** ①**同時に複数のサムネイルリクエストを投げると結果が入れ替わる**（`QLSupportsConcurrentRequests: true` を宣言しているにもかかわらず）。実際に4ファイルを並行リクエストしたところ2件が取り違えられたことを、生成された PNG を目視比較して実証した（「作品A」のリクエストに対し「作品B」用に保存したはずの画像が実際には「作品C」の画像と一致する、という事例を確認）。②**画像が上下反転して返る。** どちらも qooLibrary 側のコードの問題ではなく拡張機能自体の実装バグと判断し、採用を見送った。
      3. **代替として Mac App Store の `QLMedia`（開発者 Sergey Dikov、QLVideo・Oil3 系とは無関係の独立実装、バージョン履歴に "Thumbnailer fix for Sequoia" の記載あり）をユーザーがインストールしたところ、同時リクエスト5件・すべて正しい対応関係・上下反転無しで成功した。** qooLibrary の実アプリでも、ローカルキャッシュ（`~/Library/Containers/com.qoolibrary.app/Data/Library/Application Support/qooLibrary/covers/`。以前 QLCodec-mkv の誤ったサムネイルが `FileIdentity` キーでキャッシュされてしまっていたため一度削除が必要だった）をクリアした上で、正しいサムネイルが表示されることを実機で確認済み。
      4. **qooLibrary 側のコードは一切変更していない。** `QLVideoThumbnailLoader`/`ThumbnailService` は元々「動作する QuickLook サムネイル拡張があれば動く、無ければ既定アイコンにフォールバックする」設計だったため、ユーザーの環境に QLMedia をインストールしただけで自動的に動くようになった——実装時に見込んでいた設計意図（「将来 QLVideo 側が対応すれば」と書いていたが、実際には別の拡張が対応したことで実現した）通りの結果になった。
      5. **結論**: mp4/mov 等ネイティブ対応形式に加え、mkv も**ユーザーが QLMedia（または同等の正しく動作するサムネイル拡張）をインストールすれば**動作する。qooLibrary はどの拡張が入っているか関知せず、公開 API 経由で得られるものをそのまま使うだけの設計を維持する。QLVideo・QLCodec-mkv はどちらも試した上で不採用と判断した記録として残す（QLVideo は起動には有効だが今回のセッションで最終的に削除済み、QLCodec-mkv も同様に削除済み）。
      6. **[追加修正] QLMedia が返すサムネイルは常に正方形で、動画の実際のアスペクト比を無視してスクイーズする癖があることが実機検証で判明した**（ユーザー指摘: 「アスペクト比がおかしい気がします」）。`Sources/QooInfrastructure/FileOps/Thumbnails/MatroskaDimensionReader.swift`（新規）を実装して対応した——mkv（Matroska/EBML）コンテナのヘッダだけを軽量にパースし（`Segment > Tracks > TrackEntry > Video > PixelWidth/PixelHeight` の経路のみを理解する最小限の EBML VINT パーサ、**動画本体は一切デコードしない**）、`QLThumbnailGenerator.Request` に渡すリクエストサイズ自体を実際のアスペクト比に合わせて事前に補正する（`QLVideoThumbnailLoader.requestSize(for:maxPixelSize:)`）。この対応は特定の拡張の不具合を回避するための qooLibrary 側の防御的な補正であり、`MatroskaDimensionReader` 自体はどのサムネイル拡張が入っているかに関知しない独立したコンポーネント。`Tests/QooInfrastructureTests/MatroskaDimensionReaderTests.swift`（新規5件）で、手作業で組み立てた最小限の EBML フィクスチャによる寸法読み取り・非 mkv ファイルでの `nil`・破損ファイルでの `nil`（クラッシュしないこと）・音声トラックのみの場合の `nil` を検証。実際の mkv 3本（1920x1080、1920x808、1920x1040）でも正しく寸法を読めることを一時的な診断テストで確認済み（確認後に削除、恒久的なテストはフィクスチャベースのもののみ残した）。**実機検証（ユーザーによる手動確認）で完了** — 正しいアスペクト比で表示されることを確認済み。
    - **フルディスクアクセスでも改善しないかの追加検証を行った副産物として、2つの学びを得た。** ①ユーザーの提案で `/Applications` へ実際に配置しフルディスクアクセスを付与して再検証したが、結果は変わらず同じ `code 102` で失敗した——この経路でも改善しないことが確定し、mkv サムネイル非対応は qooLibrary からは解決不能という結論を補強した。②その過程で、**アドホック署名の開発ビルドは再ビルド・再配置のたびにコード上のアイデンティティが変わり、以前作成した Security-Scoped Bookmark（登録フォルダ）へのアクセスや、フルディスクアクセスの許可が新しいバイナリに引き継がれない**ことを実機で確認した（`/Applications` の登録済みライブラリフォルダへのアクセスが、再ビルド前は成功していたのに再ビルド後は失敗するようになった）。さらにこの副産物の検証から、**フルディスクアクセスがそもそもサンドボックスのカーネルレベル制限を回避しない**ことも判明した（詳細は 1-4 節「将来検討」の訂正箇所参照）。
- **環境設定に「アクセス権」タブを新設し、フルディスクアクセスに代わるボリューム／フォルダへのアクセス許可手段を実装した**（要件定義書には無い、ユーザー要望: 「qooViewerのように、環境設定にアクセス権を設定する項目を追加し、そこからユーザーがボリュームへのアクセス権を付与するようにしたらどうでしょう？」。直前の動画サムネイル調査で「フルディスクアクセスは App Sandbox のカーネルレベルの制限を回避しない」と判明したことを受けた直接の対応）。
  - **`Sources/QooInfrastructure/FileOps/VolumeAccessStore.swift`（新規）**: `GrantedVolumeAccess`（`id`/`displayName`/`bookmarkData`）を JSON 永続化する `actor`。`RegisteredFolderStore` と全く同じ配置理由・同じパターン（起動時に `loadAndActivateAll()` で全ブックマークのセキュリティスコープを開始したままにする、`ensureLoaded()` を全公開メソッドの先頭で呼ぶ）だが、ライブラリ／テンポラリの種別や入れ子禁止といったドメイン制約は無い、より単純な「許可したボリューム／フォルダの一覧」だけを扱う軽量版。`qooLibraryApp.init()` に `VolumeAccessStore.shared.loadAndActivateAll()` の起動時呼び出しを追加。
  - **`Sources/qooLibraryApp/Preferences/AccessPreferencesTab.swift`（新規）**: 許可済み一覧（`NSWorkspace` 準拠ではなくシンプルな行表示）＋「追加…」ボタン（`NSOpenPanel` でボリューム/フォルダを選択）＋各行の「−」で取り消し。`PreferencesView`/`PreferencesCategory` に `.access` を追加（圧縮／展開タブの次、キャッシュタブの前）。
  - **`FolderTreePane.swift` の `AccessDeniedRow` を刷新した。** 旧実装（`x-apple.systempreferences:...Privacy_AllFiles` を開く「システム設定を開く」ボタン）は、フルディスクアクセスが実効性を持たないと判明した以上ミスリーディングなため撤去し、**その場で `NSOpenPanel` を開いて直接アクセスを許可できる「アクセスを許可…」ボタン**に置き換えた。`panel.directoryURL` にアクセス失敗したノードの URL を渡すことで、パネルがその場所から開くようにしている（`node.url` を `AccessDeniedRow` に渡す形に変更）。許可後は `onGranted` コールバックで `accessDenied = false` にして `loadChildren()` を再試行し、即座にツリーへ反映される。環境設定「アクセス権」タブは、こうして個別に許可したものを後から一覧・取り消しできる場所という位置づけ（qooViewer に前例のある構成、とのユーザー言及）。
  - **`Localizable.xcstrings`**: `folderTree.openSystemSettings` を削除し `folderTree.grantAccessEllipsis`（「アクセスを許可…」）に置き換え。`preferences.tab.access`・`preferences.access.header`/`.empty`/`.addEllipsis`/`.footer`/`.panelMessage` を追加。
  - **テスト**: `Tests/QooInfrastructureTests/VolumeAccessStoreTests.swift`（新規6件）— 許可の追加・表示名の既定値／明示指定・URL 解決・取り消し・表示名でのソート・別インスタンス間での永続化を検証（`RegisteredFolderStoreTests` と同型のテスト構成）。
  - **[訂正・確定] Macintosh HD（起動ボリューム `/`）を1件許可するだけで、マウント中の外部ボリュームも含めてアクセス可能になることを実機で確定させた。** 当初「Security-Scoped Bookmark は一般にマウントポイントの境界を越えない」という理解をユーザーに回答したが、これは誤りだった。ユーザーが実際に Macintosh HD だけを許可したところ外部ボリュームにもアクセスできるようになったため、フルディスクアクセスが（別ビルドに対して）たまたま効いていた可能性を疑い、**Macintosh HD の許可だけを取り消してもらったが、同一プロセス内ではまだアクセスできる状態が続いた**——これは「取り消し操作をしても、フォルダツリーが既に読み込み済みの子要素をキャッシュしたままだった」という別のバグ（後述）による見せかけだったと判明した。**アプリを再起動（再ビルドはせず同一バイナリのまま）してもらったところ、外部ボリュームへのアクセスは正しく失われた**——これによりフルディスクアクセスは無関係で、Macintosh HD の Security-Scoped Bookmark が実際に外部ボリュームまでカバーしていたことが確定した。ユーザーには基本的に **Macintosh HD を1回許可するだけで十分**という結果になったため、`AccessPreferencesTab.addAccess()` の `NSOpenPanel` は既定でルート（`/`）を指した状態で開くようにした［ユーザー要望: 「追加」ボタンで既定選択にできないか］。
  - **[実機検証で発見・修正したバグ] 環境設定でアクセスを取り消しても（または追加しても）、既に読み込み済みのフォルダツリーの行は再起動するまでキャッシュされたままだった。** `FolderTreeRow` に `SessionState.shared.reloadToken` の変更を監視する `.onChange` を追加し、`children != nil || accessDenied` の行（＝一度でも読み込みを試みた行）だけを `accessDenied` をリセットしてから再読み込みするようにした（他ウインドウ／ペインをまたいだ変更の反映と同じ既存の仕組みを再利用）。`AccessPreferencesTab` の `addAccess()`/`revoke()` の両方から `SessionState.shared.reloadToken += 1` を呼ぶようにし、許可・取り消しのどちらの方向でもツリーが即座に反映されるようにした。`loadChildren()` の失敗時に `children = nil` も追加し（アクセスが後から失われた場合に古い一覧が残り続けないように）。
  - **Macintosh HD 許可 → 外部ボリュームも含めてアクセス可能になることは実機で確認済み。** キャッシュ再読み込みの修正（`reloadToken` 経由）・「追加」ボタンの既定選択（ルート）・`AccessDeniedRow` から環境設定への遷移も含め、**実機検証（ユーザーによる手動確認）で完了。** 「アクセスを許可…」ボタンが期待通り動作し、各ボリュームへアクセスできる状態になったことを確認済み。
  - **フォルダツリーの「アクセスを許可…」ボタンを、その場で `NSOpenPanel` を開く実装から、環境設定「アクセス権」タブへ遷移する実装に置き換えた**（ユーザー要望: 「ボリュームの『アクセスを許可』ボタンをクリックしたら、環境設定のアクセス権タブが開くようにできますか？」。許可 UI が複数箇所に分散するより一箇所に集約する方が分かりやすいという判断）。`PreferencesNavigation`（新規、`@Observable` の `@MainActor` シングルトン、`PreferencesView.swift` に配置）が `pendingCategory: PreferencesCategory?` を保持し、`AccessDeniedRow` は `PreferencesNavigation.shared.pendingCategory = .access` をセットしてから `openWindow(id: "preferences")` を呼ぶだけになった（`NSOpenPanel`/`VolumeAccessStore` 呼び出しは `AccessPreferencesTab` 側だけに一本化、`AccessDeniedRow` から `url`/`onGranted` パラメータを削除）。`PreferencesView` は `.task`（初回表示）と `.onChange(of: PreferencesNavigation.shared.pendingCategory)`（既に開いているウインドウが前面に来ただけのケース、`Window` シーンは同一 id で再度 `openWindow` してもビューを作り直さないため）の両方で `pendingCategory` を監視し、検出したら `selection` に反映してクリアする。`PreferencesCategory` は `AccessDeniedRow`（別ファイル）から参照できるよう `private` を外した。許可されればフォルダツリー側は既存の `SessionState.reloadToken` 監視で自動的に反映される（前項の修正がそのまま効く）ため、`AccessDeniedRow` 側で明示的なコールバックを持つ必要が無くなった。
- **フェーズ1完了前の先行リソースリーク・ファイル安全性監査を実施した**（§6 に記録した恒常的プロセスの内容に沿って実施したもの。**[訂正] 実施時点でフェーズ1はまだ完了しておらず（1-14/1-15/1-16 が未着手のまま残っていた）、ユーザーからも「フェーズ１は完了していません。この作業を、フェーズ１完了時に実施してほしい、というリクエストでした」と明確な訂正を受けた。** §6 の恒常的プロセス自体（「各フェーズの完了時に必ず実施する」）の理解は正しかったが、実行するタイミングを誤り、フェーズ1が実際に完了する前に前倒しで実施してしまった。見つけて直した不具合自体（下記）は独立して価値のある修正のため取り消してはいないが、**これは正式な「フェーズ1完了時点の監査」の代替にはならない** — 1-14/1-15/1-16 を実装し終えてフェーズ1が実際に完了した時点で、それらを含めて本節の監査を改めて実施すること。元のユーザー指示: 「最後にリファクタリングを実施したいです。特にリソースリークがないか、潜在的にその危険性がないか、予防策がないか。カット＆ペースト等で、ファイル消失を引き起こす危険性は本当にないか、壊れたファイルで健康なファイルを書き潰してしまうおそれはないか。丁寧に、徹底的に、監査にかける時間に上限を設けずに調査する工程を設けてください」）。`code-review` スキルを最高深度（`max`）で `QooInfrastructure/FileOps`・`QooApplication`・D&D／中央ペイン／状態管理／アクセス権関連の `qooLibraryApp` ファイル一式に対して実行し、さらに独立した検証用サブエージェントと、既知の指摘を伏せた「フレッシュな目」での再走査用サブエージェントを並行させて突き合わせた（3系統の指摘が同一の根本原因に複数回独立して収束したものは信頼度が高いと判断）。
  - **修正した項目（実際にコードを変更したもの）**:
    1. **[最重要・データ消失] `.replace`（上書き）方針が宛先ファイルを書き込み前に即座に削除していた。** `FileOperationService.resolveDestination`/`transfer` を変更し、宛先ファイルを即座に削除せず同一ディレクトリへ一時退避してから書き込み、失敗時は退避先から元へ戻す（`withReplaceBackupCleanup`）よう修正した。唯一の到達経路は「圧縮…」ダイアログで既存アーカイブに上書き保存する場合（`ArchiveCompressor` 経由、`conflictPolicy: .replace`）で、外部/ネットワークボリュームへの書き込み中に失敗すると旧アーカイブと新アーカイブの両方を失う実害のある経路だった。`rename`/`createAlias`/`copy`/`move`/`promoteFromStaging` すべてに共通で効く。回帰テスト `conflictReplaceRestoresOriginalDestinationIfWriteFails` を追加。
    2. **[リソースリーク] `ThumbnailService.acquireSlot()`（PF-11 の同時実行数制限）が、キャンセルされたリクエストの継続を観測せず `waiters` に永久に迷子にしていた。** アイコン表示を高速スクロールした際、スロット待ちの間にセルが画面外へ出て `.task(id:)` がキャンセルされても、継続はそのまま残り続けていた。`withTaskCancellationHandler` でキャンセルを検知し、まだ順番待ちであれば即座に解放するよう修正（`resumeWaiterIfStillWaiting`）。スロット取得直後にも `Task.isCancelled` を確認し、キャンセル済みなら重いデコード処理へ進まないようにした。
    3. **[リソースリーク] `VolumeAccessStore` が同じ場所への重複許可を防いでおらず、`Set<URL>` の集計が2つの `startAccessingSecurityScopedResource` 呼び出しを1件として扱っていた。** 片方を取り消すともう片方の `stop` が対応づかないまま残る構造だった。`grantAccess` に重複防止（パス文字列比較、`RegisteredFolderStore.checkNotNested` と同じ方式）を追加し、内部の集計も `[URL: Int]` による参照カウントに変更した。回帰テスト `grantAccessToTheSamePathTwiceReturnsTheExistingGrant` を追加。
    4. **[退行バグ] `LibarchiveBackend.nextAvailableName`（EX-15、大文字小文字のみ異なるエントリの衝突時の連番付与）が、`FileOperationService` 側では既に修正済みだった「既存の連番サフィックスを剥がしてから採番する」対策を欠いており、`photo 2.txt` の衝突が `photo 2 2.txt` に積み重なる同種のバグが再発していた。** 同じ対策を移植し、回帰テスト `extractRenumbersInsteadOfStackingWhenColliderAlreadyHasACopyNumberSuffix` を追加。
    5. **[設定消失リスク] `RegisteredFolderStore`/`VolumeAccessStore` の `load()` が JSON デコード失敗を `try?` で握りつぶし、`folders`/`grants` を空のまま処理を続けていた。** この状態で1件でも登録・許可・取り消し操作をすると、次の `save()` が壊れた元ファイルごと上書きし、以前登録していたライブラリ／テンポラリフォルダやボリュームアクセスの記録が全て復元不能になる経路があった。デコードに失敗した場合は元ファイルを `<元のファイル名>.corrupt-<UUID>` として隣へ退避してから空の状態で続行するよう修正し、少なくとも手動での調査・復旧の余地を残した。両ストアに回帰テスト `corruptStorageFileIsPreservedAsABackupInsteadOfBeingOverwritten` を追加。
    6. **[低確度だが安全側で修正] `FolderContentView` の空きスペースへの `.dropDestination`（Finder 等からの取り込み、DD-03）が、構造体に保持された `let folder: URL?` を直接読んでいた。** ⌘↑ 実装（1-9）・ペースト実装（1-6 の File/Edit メニュー整備）で過去に踏まれた「高速なナビゲーション直後は SwiftUI がまだ1世代古い `FolderContentView` インスタンスを保持していることがある」という既知の罠と同じパターンで、他の全操作は `currentFolder()` 経由に移行済みだったのにこの1箇所だけ移行が漏れていた。`currentFolder()` を読むよう修正。
  - **見つかったが、今回は修正せず理由とともに記録するに留めた項目**（いずれも「壊れたファイルで健康なファイルを書き潰す」「ファイルが消える」の水準には該当しないと判断したもの、または UI 層への機能追加を要し監査の場で即座に安全に実装しきれる範囲を超えるもの）:
    - **`FileOperationService.transfer()`（copy/move/promoteFromStaging の共通実装）が、バッチ処理の途中の項目で例外が発生すると、既に成功していた項目分の `OpReceipt` を丸ごと破棄する。** 結果として、実際にはファイルが移動/コピーされているのに Undo 履歴にも操作履歴にも一切残らない（ファイル自体は消えないが、取り消せない状態になる）。`trash()` も `NSWorkspace.recycle` がドキュメント上許容している「一部成功・一部失敗」の部分結果を、エラーが非 nil なら丸ごと破棄する同種の欠陥を持つ。`CommandResult.partial`/`FailedItem` という型自体は既に用意されているが、`Sources/qooLibraryApp` のどこからも参照されておらず、`CommandStack.undo()`/`redo()` も `.partial`/`.impossible` な結果を `NotificationRouter` へ一切routeしていない（内部の `operationHistory` ログにのみ記録され、閲覧 UI が無い）。**この一連の問題を正しく直すには「部分失敗をどう UI に見せるか」という設計判断を伴う機能追加が必要**であり、監査の場での場当たり的な修正は避けるべきと判断した。フェーズ2で `NotificationHistoryStore`/通知履歴ウインドウ（NW-01〜08）を実装するタイミングで、`CommandResult`/`UndoResult` の可視化とあわせて対応すること。
    - **`SecureExtractor.extract()`/`ArchiveCompressor.compress()` の `defer` が、ステージングディレクトリを成功・失敗を問わず必ず削除する（EX-24 で意図的に定めた挙動）。** アーカイブの多くの項目のうち一部だけ最終位置への移送（`promoteFromStaging`）に失敗した場合、まだステージングに残っている未移送分がこの `defer` で失われる。ただし、展開元のアーカイブ自体・圧縮対象の元ファイル自体はどちらも一切変更されないため、失敗時に再試行すればやり直せる——「壊れたファイルが健康なファイルを道連れにする」水準の被害ではなく、「失敗した処理は結果を持ち越さない」という EX-24 の元々の設計意図の範囲内と判断し、変更しなかった（`.replace` の安全化［上記1.］により、少なくとも「置き換え対象の既存ファイルを失う」経路は別途塞がれている）。
    - **`CompositeCommand.execute()` に部分成功の集計が無く、`newFolderWithSelection`（選択項目で新規フォルダ作成）や password-protected アーカイブの展開でユーザーが再試行をキャンセルした場合に、`CreateFolderCommand` だけ成功した空フォルダが Undo にも操作履歴にも載らない孤児として残ることがある。** データは失われないが、Undo で片付けられない残骸が残る。`transfer()` の部分失敗と同根の設計課題のため、まとめてフェーズ2で対応する。
    - **`RenameCommand`/`CreateAliasCommand` が既定 `OpOptions()`（`.ask`、`conflictResolver` 未設定）のまま使われており、名前衝突時に `FileOperationError.conflictResolutionRequired`（`UserPresentableError` 未準拠）がそのまま `NotificationRouter.presentError` の技術的なフォールバック文言で表示される。** データ損失はないが UX が粗い。低優先度のため今回は見送り。
    - **`VolumeAccessStore`/`RegisteredFolderStore` の `save()` 失敗（ディスク容量不足等）が `try?` で握りつぶされている呼び出し元がある。** 保存に失敗しても UI 上は成功したように見えるため、次回起動時に変更が消えていることに気づける手段が無い。低確率かつ低優先度と判断し見送った。
    - **`CommandStack.undo()` が `.partial` を返した Undo でも、そのままアクティブなアプリの `redoStack` に積んでしまう。** 部分的にしか元に戻っていない状態を Redo すると、元の `items` 配列を使って `execute()` を再実行するため「移動元が既に存在しない」といったエラーになり得る。`transfer()` の部分失敗と同根のため、まとめてフェーズ2で対応する。
    - **登録フォルダ（ライブラリ／テンポラリ）配下のサブフォルダを「新規タブ/ウインドウで開く」と、開いた先の `NavigationRoot` が既定の `.volume` に戻り、「登録フォルダの外へ ⌘↑ で出られない」という意図した境界が新しいタブ/ウインドウでは効かなくなる。** データ損失はなく、1-12 で明示的に設計した境界機能の抜け穴という UX 上の課題。`WindowState.openTab(for:)`/`openWindow(value:)` に `NavigationRoot` を配線する作業が必要なため、低優先度の別タスクとして記録する。
    - **`FileOperationService.setLocked`（ロック/ロック解除の一括処理）も `transfer()` と同根の「途中の項目で失敗すると、それまでの成功分の `OpReceipt` を丸ごと破棄する」問題を持つ。** ロック状態自体はファイルに実際に適用されているため消えるものではないが、Undo 履歴に載らない。
  - **検証**: `swift build`/`swift test`（160件、全通過。新規回帰テスト5件を含む）、`Scripts/check-fileops-isolation.swift`/`check-layer-dependencies.swift`（両方 OK）、`xcodegen generate && xcodebuild`（Debug、成功）。
  - **実機検証（ユーザーによる手動確認）**: 「圧縮…で既存アーカイブを上書き」は `NSSavePanel` 標準の上書き確認ダイアログ（本監査より前から存在、`compressWithDialog` のコメント参照）を経て正常に上書きできることを確認済み——**この確認ダイアログ自体は今回の修正で新たに追加したものではない**（`.replace` の安全化は内部の退避・復元ロジックのみで、書き込みが正常に成功する通常経路の見え方は変わらない）。「アクセス権タブで Macintosh HD を重複登録」は、ダイアログ等の警告は表示されない（これは意図した設計——`grantAccess` は重複を検知すると既存の許可をそのまま返すだけで、エラーや確認は出さない）。**一覧が重複せず1行のままであることをユーザーに確認していただき、重複防止が正しく効いていることを確認済み。**
- **PDF・EPUB のサムネイル生成に対応し、環境設定「ビューア」タブ（旧「関連付け」）の組み込み対象にも追加した**（要件定義書には無い、ユーザー指摘・要望: 「関連付けタブについて、既定で関連付け対象に含めたい拡張子としてpdfとepubが抜けています」「qooLibraryはqooViewerのフロントエンドとして設計しているので、qooViewerが対応しているファイル形式は網羅する必要がある」。実装にあたっては、姉妹プロジェクト qooViewer（同じユーザーが開発、ページ単位のビューアアプリ）のソースコードを実際に参照するよう明示的な指示があった）。
  - **[訂正] 「関連付けタブの組み込み/カスタムの区別＝qooLibraryが実際に中身を読める形式かどうか」という当初の説明は誤りだった。** ユーザーから「関連付けタブはまさにダブルクリックやエンターからファイルを開くときの既定のアプリケーションを指定するためだけの設定です。この設定とは無関係に、zip/cbz/rar/cbr/7z/cb7/pdf/epubについては内部を参照することが期待です」と明確な訂正を受けた。組み込み/カスタムの区別は「qooLibraryがコミック・電子書籍ライブラリアプリとして常に対象とする中核形式か、それ以外の任意追加形式か」という、このタブ自体の UX 上の区別に過ぎず、`ThumbnailService` の内部読み取り対応（サムネイル生成）とは独立した別の関心事——`AssociationPreferencesTab.swift` のコメントをこの理解に基づいて訂正した。
  - **タブの表示名を「関連付け」から「ビューア」に変更した**（ユーザー提案: 「関連付けという名前が誤解を招きやすいなら、ビューアと名前を変えてもよいです。まさに、対応するビューアを設定したいだけです」）。`Localizable.xcstrings` の `preferences.tab.associations`（EN: Associations→Viewer、JA: 関連付け→ビューア）・`preferences.associations.header`（EN: File Associations→Supported Formats、JA: ファイルの関連付け→対応形式）・`preferences.associations.footer`（「アーカイブ形式」という表現を「ダブルクリックまたは Enter で開く」という実際の意味に修正、PDF/EPUB はアーカイブではないため）を変更。Swift 側の型名（`AssociationPreferencesTab`）・`PreferencesCategory.associations` ケース名・アイコン（`app.badge`）は内部識別子のため変更していない。
  - **PDF サムネイル**: `Sources/QooInfrastructure/FileOps/Thumbnails/PDFThumbnailLoading.swift`（新規）— `PDFThumbnailLoading` プロトコル + `CoreGraphicsPDFThumbnailLoader`（既定実装）。qooViewer の `Services/PageLoader.swift` `renderPDFPage(pdfURL:pageIndex:maxPixelSize:)` と全く同じアルゴリズム（`CGPDFDocument`/`CGPDFPage.getBoxRect(.mediaBox)` から実寸を読み、`maxPixelSize` に収まるようアスペクト比を保ったまま `CGContext` へ直接描画。白背景で塗りつぶし、mediaBox の原点オフセットを補正）を1ページ目のサムネイル生成用に移植した。動画（`VideoThumbnailLoading`/`QLThumbnailGenerator`）と異なりサードパーティ拡張に一切依存せず、macOS 標準の CoreGraphics だけで完結する。
  - **EPUB サムネイル**: `Sources/QooInfrastructure/FileOps/Thumbnails/EpubCoverResolver.swift`（新規）— qooViewer の `Services/EpubStructureResolver.swift`（container.xml → package document(OPF) → spine → 各項目の画像解決）と同じアルゴリズムを、**サムネイル1枚分（spine の先頭ページ）にスコープを絞って移植**したもの。qooViewer 版が持つページ全体の読み順管理・目次（nav.xhtml）・見開きヒント・読み方向は qooLibrary には不要なため持たない。EPUB 自体は zip コンテナのため、読み取りは既存の `ArchiveReading`（既定 `LibarchiveBackend.shared`）をそのまま使うが、**`ArchiveFormat`/`ArchiveBackendRegistry` による拡張子判定は経由せず直接呼ぶ**——EPUB を「展開・圧縮できるアーカイブ」として中央ペインの「展開」メニュー等に一般公開すると意味が変わってしまう（EPUB はユーザーが個別ファイルへばらして展開する対象ではない）ため、あくまでサムネイル生成専用の内部利用に限定した［設計判断］。libarchive のアーカイブ読み取り自体は拡張子ではなく実際のバイト列（zip シグネチャ）で判定するため、`.epub` のまま渡しても正しく zip として読める。
  - `Sources/QooInfrastructure/FileOps/Thumbnails/ThumbnailService.swift`: `thumbnail(for:maxPixelSize:)` に PDF（`isPDFFilename`、`UTType.pdf` 準拠で判定）・EPUB（`isEpubFilename`、拡張子直接比較——EPUB は `.pdf`/`.movie` と違い `UTType` に共通の静的定数が標準搭載されていないため）の分岐を追加。EPUB は「アーカイブ内の自然順で先頭の画像」ではなく spine（読み順）の先頭ページを取る必要があるため、汎用アーカイブ向けの `firstImageDataInArchive`（自然順ソート）とは別の専用経路（`EpubCoverResolver`）にしている。
  - **Finder 登録**（`project.yml`）: 既存の Folder/Archive 2種の `CFBundleDocumentTypes` に加え、`CFBundleTypeName: Document`（`LSItemContentTypes: [com.adobe.pdf, org.idpf.epub-container]`、`LSHandlerRank: Alternate`）を追加。どちらも macOS 標準搭載の UTI（既存のアーカイブ群を追加した際と同じ調査方法、独自 UTI 宣言は不要）。ビルド後に生成された Info.plist を `plutil -p` で確認し、意図通り反映されていることを確認済み。
  - **テスト**: `Tests/QooInfrastructureTests/PDFThumbnailLoadingTests.swift`（新規2件、`CGContext` の PDF コンテキスト API でその場に組み立てた実際に開ける最小限の1ページ PDF を使い、アスペクト比を保ったサイズで描画されること・PDF でないファイルで `nil` を返すことを検証）、`Tests/QooInfrastructureTests/EpubCoverResolverTests.swift`（新規4件、`ArchiveFixtureBuilder` で組み立てた最小限の EPUB フィクスチャを使い、spine 先頭が画像直接参照のケース・XHTML 経由で `<img>` を辿るケース・container.xml が無いケース・画像が1枚も見つからないケースを検証）、`ThumbnailServiceTests.swift` に4件追加（PDF はフェイクの `PDFThumbnailLoading` でルーティングの確認、EPUB は実装（`EpubCoverResolver`）を使った end-to-end 確認）。
  - **検証**: `swift build`/`swift test`（169件、全通過）、静的検査2件（OK）、`xcodegen generate && xcodebuild`（Debug、成功、生成された Info.plist の `CFBundleDocumentTypes` を確認）。**実機での Finder 登録（「このアプリケーションで開く」候補への表示）は、既存のアーカイブ形式と同じく配布用ビルドが無いと検証できないため保留**（既存のアーカイブ6形式と同じ既知の制約、CLAUDE.md「アプリ関連付け」節参照）。
  - **[追加対応] 画像ベースのページのみサムネイル対象にするよう PDF/EPUB の基準を揃えた**（ユーザー確認・要望: 「pdfおよびepubは画像ベースではない、通常のドキュメントの場合はサムネイル表示の対象外にする処理ということでいいですか？」「画像ベースかどうかで揃えてください」）。実装当初、EPUB（`EpubCoverResolver`）は仕組み上つねに実際の画像データが見つかった場合しか値を返さなかった（テキストから合成したサムネイルを作ることが構造的に無い）が、PDF（`CoreGraphicsPDFThumbnailLoader`）にはこの判定が無く、テキスト主体の通常ドキュメントでも1ページ目をそのまま描画していた——結果自体は画像だが、元がテキストレイアウトを描画しただけという点で EPUB 側の基準と揃っていなかった。
    - `PDFThumbnailLoading.swift` に `isImageBasedPage(_:)` を追加。ページのコンテンツストリームを `CGPDFContentStreamCreateWithPage`/`CGPDFScanner` で走査し、テキスト描画命令（`Tj`/`TJ`/`'`/`"`）が1つも無く、かつ Image XObject の描画（`Do`）が1つ以上あるページだけを「画像ベース」と判定してレンダリングする。それ以外（テキスト主体のドキュメント、テキストも画像も無いベクター描画のみのページ）は `nil` を返し、呼び出し側の既定アイコンへのフォールバックに委ねる（`IM-04` と同じ方針）。
    - **既知の限界（コード中に明記）**: OCR 済みスキャン（見えない文字レイヤーを持つ画像ページ）はテキスト命令を検出するため対象外になる。Form XObject 内部への再帰は行わない（単純なスキャン PDF の多くは Image XObject を直接描画するため実用上は十分だが、Form XObject 経由で画像を描画する PDF は判定できない）。
    - **実装中に発見したバグ**: `Do` 演算子のコールバックで、リソース辞書から引いた XObject の実体を `CGPDFObjectGetValue(xObject, .dictionary, &dict)` で直接辞書として取り出そうとすると常に失敗していた。単体のデバッグスクリプトで `doCalls` は発火するのに `hasImage` が常に `false` のままになる現象を再現し、原因を切り分けた——**Image XObject は PDF の「stream オブジェクト」**（辞書と実際の画像データを両方持つ、`<< /Type /XObject /Subtype /Image ... >> stream ... endstream`）であり、`CGPDFObjectType` には `.dictionary` とは別に `.stream` があることに気づいて解決した。正しくは `.stream`（`CGPDFStreamRef`）として取り出し、`CGPDFStreamGetDictionary` でその辞書を得る必要がある。
    - `Tests/QooInfrastructureTests/PDFThumbnailLoadingTests.swift` を全面的に書き直し、画像ベース（`context.draw` でページ全面に実画像を描画、Image XObject + `Do` として書き出される）・テキストベース（CoreText で実テキストを描画、`Tj`/`TJ` として書き出される）・どちらでもない（ベクター塗りつぶしのみ）の3パターンで判定を検証する回帰テストに置き換えた。**当初は10×10の小さい画像で画像ベースのテストを書いたが、CoreGraphics が小さい画像をインライン画像（`BI`/`ID`/`EI`、XObject を経由しない別の PDF 書き出し形式）として書き出すことがあり、意図せず「画像ベースではない」と判定されてテストが落ちた**——ページ寸法に合わせた十分な大きさの画像に変更して解消した（実際のスキャン PDF はページ全面の大きな画像を使うため、この点はむしろ実運用に近い形になった）。
    - `xcodegen generate && xcodebuild`（Debug、成功）、`swift test`（171件、全通過）で再検証済み。
- **環境設定「ビューア」タブの「組み込み」「カスタム」2セクション構成を単一の一覧に統合した**（ユーザー指摘: 「もう既定の拡張子とカスタム拡張子を分離する意味はない」。直前の節で「組み込み＝qooLibraryが読める形式」という説明が誤りだったと訂正した流れを受けた、論理的な帰結）。
  - **統合前に、将来のバージョンアップで既定拡張子が増えた場合にユーザーの追加済みカスタム拡張子と競合する実害が無いかをユーザー自身に確認された。** 確認した設計: 既定値の投入（seeding）は「永続化ファイルが1つも存在しない初回起動時」「`customExtensions` という概念が無かった旧形式ファイルの読み込み時」の2パターンに限定し、**一度でも `customExtensions` を持つ永続化ファイルが存在すれば、以後この既定値は一切参照しない**。そのため、ユーザーが拡張子を削除・追加した後に将来のバージョンで既定拡張子が増えても、上書き・マージによる巻き込みは発生しない（代わりに、新しく増えた既定拡張子は既存ユーザーには自動反映されない——Finder のお気に入りサイドバーが新しい既定項目を既存ユーザーへ遡って追加しないのと同じ、カスタマイズ可能な一覧として一般的で無害な挙動）。実害が無いと判断できたため統合を実施した。
  - **`AppAssociationService`（`QooKit`）のメソッドを改名した**: `customExtensions()`→`extensions()`、`addCustomExtension(_:)`→`addExtension(_:)`、`removeCustomExtension(_:)`→`removeExtension(_:)`。「カスタム」という呼称自体が、組み込み/カスタムの区別が無くなった以上ふさわしくなくなったため。
  - **`AppAssociationStore`（`QooInfrastructure`）**: `defaultExtensions`（旧「組み込み」の8形式、zip/cbz・7z/cb7・rar/cbr・pdf/epub）を、`ensureLoaded()` が初回起動時（永続化ファイルなし）・旧形式ファイル読み込み時にだけ `extensionSet` へ投入するようにした。
  - **[実装中に発見した実データとの不整合、実際に修正が必要だった]** 開発機の実際の永続化ファイル（`appAssociations.json`、このセッション中に mp4/mkv の関連付けを実機テストした際に作られたもの）を確認したところ、`customExtensions` には `["mkv","mp4"]` のみが入っており、当時「組み込み」として UI 側の定数（`AssociationPreferencesTab.builtInExtensions`）にハードコードされていた zip/cbz/7z/cb7/rar/cbr は一度もこの永続化配列に含まれていなかった——つまり素朴に「ファイルが既に存在するなら何もしない」という初回起動判定だけでは、**この開発機を含む「組み込み/カスタム分離時代に一度でも使ったことがある」ケース全般で、統合後に組み込みだった6形式がタブから消えてしまう**ことが判明した。`StorageDTO` に `hasUnifiedDefaults: Bool?`（Optional なので旧形式 JSON にキー自体が無くても decode エラーにならず `nil` になる）を追加し、`ensureLoaded()` で `nil`/`false` の場合は `defaultExtensions` を1回だけ `formUnion` してから即座に保存（`hasUnifiedDefaults: true` を含めて）することで、統合前のファイルでも組み込みだった形式を失わずに移行できるようにした。回帰テスト `migratesPreUnificationFileByUnioningInDefaultExtensions`（実際の開発機のファイルと同じ形の JSON を使い、移行で消えないこと・移行後は1回きりで再度合流しないことの両方を検証）を追加。**教訓: 「ファイルが存在するかどうか」だけで初回起動を判定する設計は、スキーマ自体が途中で変わるケース（新しいフィールドの意味が追加される）を見落とす。スキーマ変更を伴う既定値投入は専用の移行フラグを持つべき。**
  - `Sources/qooLibraryApp/Preferences/AssociationPreferencesTab.swift`: 2つの `Section`（組み込み・カスタム）を1つに統合。`builtInExtensions` 定数を削除し、`extensions`（`@State`、`service.extensions()` から読み込む）のみを表示・追加・削除の対象にした。既定で入っている拡張子も他の項目と全く同じ「−」ボタンで削除できる。
  - `Resources/Localizable.xcstrings`: `preferences.associations.customHeader`/`customFooter` を削除し、`preferences.associations.footer` に「拡張子を追加できる」旨を統合した文言へ変更。
  - **検証**: `swift build`/`swift test`（174件、全通過。新規回帰テスト含む）、静的検査2件（OK）、`xcodegen generate && xcodebuild`（Debug、成功）。**実機での確認は依頼予定** — 特に、この開発機の既存の関連付け設定（mp4/mkv → Movist、zip/cbz/7z/cb7/rar/cbr → qooViewer）が統合後も一覧に残っており、削除・追加が単一の一覧として自由に行えることの2点。
  - **実機検証（ユーザーによる手動確認）で完了。** 既存の関連付け設定が消えずに一覧へ残ること、単一の一覧としての削除・追加のいずれも確認済み。あわせて「拡張子を追加」の `TextField` に枠線が無く入力欄の位置が分かりにくいとの指摘を受け、`.textFieldStyle(.roundedBorder)` を追加して解消した（実機で解消を確認済み）。
- **[CI障害の調査・修正] `main` への複数回の push で GitHub Actions の `unit`（`swift test`）ジョブが継続して失敗していた（メールでの通知をユーザーから指摘され気づいた）。** `gh run list`/`gh run view --log` で調査したところ、失敗は動画サムネイル対応（「動画ファイルのサムネイル表示に対応した」節）を追加したコミット以降、**すべての `unit` ジョブに共通する単一の原因**（`build`/`static-checks`/`app-build`/`license` の各ジョブは一貫して成功）と判明した: `ThumbnailServiceTests.resolvesThumbnailForAVideoFileViaVideoThumbnailLoader()` が `clip.mkv` という拡張子でテストしており、`ThumbnailService.isVideoFilename` は `UTType(filenameExtension:).conforms(to: .movie)` で判定する——**`org.matroska.mkv` が `public.movie` に準拠するかどうかは、mkv 対応のメディアアプリ／QuickLook 拡張（Infuse・IINA・QLMedia 等）がシステムに登録されているかに依存する**（動画サムネイル対応の節で判明した知見と同根）。この開発機には動画サムネイル調査の過程でそれらが複数インストール済みのためローカルでは常に通過していたが、そうしたアプリが一切入っていない CI ランナーでは `isVideoFilename("clip.mkv")` が `false` になり、動画分岐へルーティングされずテストが失敗していた。`mp4`（macOS 標準搭載、`public.movie` 準拠が OS 自体に組み込まれている）に変更して解消——同じ関数の別テスト（`returnsNilWhenVideoThumbnailLoaderFails`）は元々 `mp4` を使っており CI でも一貫して成功していたことからも、原因の特定に確信が持てた。**教訓: サムネイル・関連付け対応状況を検証するテストで `mkv` のような「対応が環境（インストール済みアプリ）に依存する」拡張子を使うと、開発機では入っている拡張機能のおかげで気づかずに通過し、まっさらな CI 環境で初めて失敗することがある。ルーティングロジック自体の検証が目的なら、`mp4`/`mov` のような OS 標準搭載で環境に依存しない拡張子を使うこと。**
- **「このアプリケーションで開く」サブメニューが「その他…」しか表示しない不具合を修正し、フォルダにも対応させた**（ユーザー報告: 「「このアプリケーションで開く」が「その他」としか表示されないままです」）。
  - **[実機検証で発見・修正したバグ] `candidates(for:)` は正しい候補を返していたが、画面には反映されなかった。** 一時的な診断ログ（`FileHandle.standardError.write`）を仕込み、ユーザーに複数のファイル（cbz/mkv/mp4）で「このアプリケーションで開く」にホバーしてもらったところ、`candidates(for:)` 自体は Movist/Infuse/IINA/QuickTime Player 等の実在する候補を正しく返していることが確認できた——つまり原因はデータ取得ではなく描画側だった。`OpenWithMenu`（`FolderContentView.swift`）は候補一覧を `.task(id: url)` で非同期に読み込み `@State` へ格納していたが、SwiftUI の `Menu`/`.contextMenu` は AppKit の `NSMenu` へブリッジされる際に一度構築されると、`.task` の完了後に `@State` を更新しても既に表示（または表示準備）済みのサブメニューの中身が再構築されない。`candidates(for:)` の実体は `NSWorkspace.urlsForApplications(toOpen:)`（元々同期 API）への問い合わせのみで実際の非同期処理を伴わないため、`AppAssociationService` プロトコルの `candidates(for:)` から `async` を撤去し、`AppAssociationStore` 側は `associations`/`extensionSet`/`storageURL` のいずれにも触れない（actor 隔離不要な）ことを確認した上で `nonisolated` にした。`OpenWithMenu.body` の評価時（＝コンテキストメニューが実際に構築される時点）に同期的に確定させることで解消。呼び出し側（`AssociationPreferencesTab.swift` の2箇所）も `await` を外して追随。診断ログは調査後に削除した。
  - **フォルダにも対応させた**（ユーザー指摘: 「フォルダについては...「このアプリケーションで開く」がありません」）。当初はフォルダを対象外にしていた（`candidates(for:)` が拡張子ベースのため、拡張子を持たないフォルダには使えない）。`AppAssociationService` に `candidatesForFolders() -> [AppCandidate]`（`public.folder` 準拠のアプリを列挙）を追加し、`AppAssociationStore` 内部で `candidates(for:)`/`candidatesForFolders()` が共通の UTType ベースのプライベートヘルパーに委譲するようリファクタリング。`OpenWithMenu` に `isDirectory` を渡し、フォルダならこちらを使うよう切り替えた。`contextMenuContent(for:)` 側の `!only.isDirectory` 除外条件も撤去。`IconGridView` は `FolderContentView.contextMenuContent(for:)` を共有しているため追加の変更は不要だった。
  - **検証**: `swift build`/`swift test`（174件、全通過）、静的検査2件（OK）、`xcodegen generate && xcodebuild`（Debug、成功）。**実機検証（ユーザーによる手動確認）で完了。** ファイル・フォルダともに実在する候補アプリが表示され、実際に選んで開けることを確認済み。
- **フォルダツリー（左ペイン）の全行にコンテキストメニューを追加し、あわせてグループ（ボリューム／テンポラリ／ライブラリ）ごとに項目を切り替えられる仕組みを構築した**（ユーザー要望: 「中央ペインでフォルダを右クリックした場合のコンテキストメニューに原則あわせてください」「ライブラリグループとテンポラリグループのフォルダに対しては独自の項目追加が今後あるので、ボリューム、テンポラリ、ライブラリのいずれに属しているフォルダなのかでコンテキストメニューを切り替えられる仕組みを構築してください」。1-16 のスコープ定義で「B（技術的には実装できるが未着手）」として記録していた「フォルダツリーの通常フォルダ行への右クリックメニュー追加」の実装にあたる）。
  - **`Sources/qooLibraryApp/MainWindow/FolderOperations.swift`（新規）: 中央ペインとフォルダツリーが共有するファイル操作レイヤ。** 複製・コピー／カット・ペースト・ゴミ箱・名前変更・新規フォルダ・エイリアス・ロック・圧縮・展開を、対象 URL と書き込み先フォルダを引数で受け取る形で 1 箇所に集約した（「中央ペインは現在のフォルダ、ツリーは右クリックした行の親フォルダ」という違いは呼び出し側の引数だけで吸収される）。**`FolderContentView` 側も新規実装ではなくこのレイヤへ委譲するよう移行した** — 同じ操作を 2 箇所に実装すると片方だけ直したときに静かにずれるため。`busyMessage`（不定進捗 [UI-09]）・圧縮／展開のパスワードシートもこのオブジェクトが状態を持ち、描画は `.folderOperationsHost(_:)`（新設の `ViewModifier`）が担う。
    - `@Observable` のクラスのため `@AppStorage`/`@Environment(\.locale)` を使えない。圧縮・展開の環境設定は `UserDefaults` を直接読み（`FolderOperations.PreferenceKeys` にキーを集約して `CompressionPreferencesTab` との取り違えを防ぐ）、表示言語は `AppLanguage.effectiveLocale` を使う（`WindowState.loadDefaultListStyle()` と同じ既存パターン）。設定値は操作を実行する瞬間に読むため、リアクティブな購読が無くても常に最新になる。
    - 成功時は必ず `SessionState.reloadToken` を増分する。加えて `onSuccess` クロージャを受け取る——`reloadToken` 経由の反映は次の Observation サイクルになるため、直後に選択・スクロールを操作する経路（「ここに圧縮」後に作成物を選択してスクロールする等）ではタイミングが問題になり得る。中央ペインは従来の `reloadAndBroadcast()` と同じ順序（同期 `reload()` → 増分）を保つためここで `{ reload() }` を渡している。
  - **`Sources/qooLibraryApp/MainWindow/FolderTreeContextMenu.swift`（新規）: グループ・役割による出し分けの仕組み。**
    - `FolderTreeBranch`（`.volume` / `.temporary(id:rootURL:)` / `.library(id:rootURL:)`）を新設し、`FolderTreeRow` の再帰で子孫へそのまま伝播させる。**以前の `rowNavigationRoot: NavigationRoot` を置き換えた** — `NavigationRoot`（`.volume`/`.registeredFolder`）だけではテンポラリとライブラリを区別できず、`FolderTreeNode.kind` にも同じ情報が分かれて入っていたため、判断基準を 1 つに集約した。`FolderTreeBranch` から `FolderTreeGroup`（メニューの出し分け）と `NavigationRoot`（タブの入口）の両方を導出する。
    - `FolderTreeRowRole`（`.volumeRoot` / `.registeredRoot` / `.plainFolder`）と `FolderTreeRowContext`（`node`＋`branch`＋`role`＋`registeredFolder`）を新設。メニューの条件分岐は `FolderTreeRowContext.allowsStructuralOperations`／`allowsItemOperations` の 2 つの名前付きプロパティに集約し、View 側に条件を書き散らさない。
    - **`FolderTreeContextMenu.groupSpecificSection` が将来の拡張スロット**［ユーザー要望の中核］。`switch context.group` で `.volume`/`.temporary`/`.library` それぞれの枠が既に用意してあり、現状はすべて `EmptyView()`。フェーズ2でライブラリ固有のラベル操作を、フェーズ3でテンポラリ固有の一括処理を追加する際は、この `switch` に項目を書き `FolderTreeContextMenuActions` に対応するクロージャを足して `FolderTreePane` から配線する（`context.role` で「登録ルート自身か配下のフォルダか」もさらに絞り込める）。
  - **中央ペインとの差分と、ユーザーとの事前合意**（実装前に `AskUserQuestion` で 4 点確認した）:
    - **名前を変更はアラート方式**［ユーザー判断］。中央ペインは Finder 流のインライン編集だが、ツリー行は `DisclosureGroup` のラベル＋タップでナビゲートという構造でインライン編集の基盤が無く、新規実装は実装量・リグレッションのリスクが大きい。既存の「表示名を変更…」と同じ体裁に揃えた。
    - **登録ルート行（ライブラリ／テンポラリの最上位）では破壊的・構造変更系（名前を変更・複製・カット・ゴミ箱・圧縮）を出さない**［ユーザー判断］。ルートを消す・動かす・改名すると Security-Scoped Bookmark が解決不能になり登録が壊れるため、片付けは明示的な「登録解除」に一本化する。エイリアス作成・ロックも同じ扱いにした（前者は書き込み先が親フォルダで、登録で得たスコープの外のため必ず権限エラーになる。後者はロックすると qooLibrary 自身の操作を阻害するため）。
    - **ボリュームのルート行（Macintosh HD・外部ボリューム等）はナビゲーション＋ユーティリティのみ**［ユーザー判断］。複製・圧縮がボリューム全体の走査を始めるため。
    - **「新規フォルダ（この中に作成）」「ペースト（この中へ）」を追加**［ユーザー判断］。中央ペインでは空きスペースの右クリックに相当する項目で、どちらも「この行のフォルダの中へ」作用する。ツリーへの D&D は既に対応済み（[DD-05]）なので整合する。「選択項目で新規フォルダを作成」は、ツリーに複数選択の概念が無く用途が限定的なため見送った。
    - 展開系は自然に対象外（ツリーはフォルダしか表示しないため、アーカイブを右クリックする場面が存在しない）。「圧縮／展開」サブメニューではなく圧縮だけの「圧縮」サブメニュー（新規キー `folder.compressSubmenu`）にしている。
  - **`.contextMenu` を全行に付けても描画コストがゼロであることを実測で確認した。** 当初、`OpenWithMenu` が呼ぶ `NSWorkspace.urlsForApplications(toOpen:)` を実測したところ 0.19ms/回で、もし可視行ぶん毎レンダリング構築されるなら（可視 30 行として）1 パスあたり ~6ms と無視できない懸念があった。`FolderTreeContextMenu.body`・`OpenWithMenu.body`・`FolderTreeRow.body` の 3 箇所に一時的な診断ログ（`FileHandle.standardError.write`、1-9 の ⌘↑ バグ調査以来のパターン）を仕込み、ビルド済みバイナリを直接起動して標準エラー出力を採取した結果、**行本体は 44 回（9 行分）評価されたのに対し、メニュー本体・`OpenWithMenu` 本体はいずれも 0 回**だった——SwiftUI は `.contextMenu` の内容を右クリック時にのみ遅延構築する。診断ログは確認後に削除した。**教訓: `OpenWithMenu` の既知バグ（`.task` の完了後にサブメニューが再構築されない）の記述から「メニュー内容は body 評価時に構築される」と読めるが、これは「メニューが実際に構築される時点で `body` が評価される」の意味であり、「毎レンダリングで評価される」ではない。性能を理由に設計を変える前に実測すること。**
  - **`FolderTreeNode` に `isLocked` を追加した。** コンテキストメニューで「ロック」/「ロック解除」のどちらを出すか判定するため。**メニューを組み立てるたびに 1 行ずつ `resourceValues` を呼ぶのではなく、`children(of:)` が子の一覧を作るついでに `.isUserImmutableKey` をまとめて読む**（中央ペインが `FolderEntry.isLocked` を `reload()` で一括取得しているのと同じ考え方。既に子ごとに 1 回 `resourceValues` を呼んでいるため追加コストは実質ゼロ）。
  - **`FolderTreePane` の入力ダイアログを単一の `.alert` に統合した。** 表示名の変更・実フォルダ名の変更・新規フォルダの 3 種類になったが、**同じビューに複数の `.alert` を重ねると表示が不安定になる**ため、`FolderTreePrompt`（`enum`）1 つの状態で切り替える方式にした［設計判断］。「新規フォルダ」は作成成功後に作成先の行を `expandedNodeIDs` へ入れて開く——折りたたんだ行に対して実行した場合、開かないと「何も起きなかった」ように見えるため。
  - **`WindowState.openTab(for:root:)` に `NavigationRoot` を渡せるようにした。** ツリーの「新規タブで開く」がライブラリ／テンポラリ配下の入口を引き継ぐため。**あわせて、フェーズ1完了前監査で「登録フォルダ配下のサブフォルダを新規タブで開くと `NavigationRoot` が `.volume` に戻る」として記録していた中央ペイン側の抜け穴も塞いだ**（`MainWindowView` の `onOpenInNewTab` が現在のタブの `navigationRoot` を引き継ぐ）。**「新規ウインドウで開く」は引き続き引き継げない**（`WindowGroup(for: URL.self)` の値型が `URL` 固定のため）——既知の制限として残す。
  - **`code-review`（high）の指摘を受けて 1 件修正した: 表示中のフォルダが消えるとタブが行き止まりになる問題。** 表示中のフォルダをゴミ箱に入れる・名前を変更する経路がツリーから直接届くようになったことで顕在化した（他ウインドウでの操作・Finder 側での削除でも同じことが起きる、部分的には既存の問題）。**発生源ごとに手当てするのではなく、実際に読み込みに失敗した `FolderContentView.reload()` の 1 箇所から `WindowState.relocateCurrentTabIfFolderVanished()` を呼ぶ**ことで、経路（ツリー／中央ペイン／D&D／別ウインドウ／アプリ外）に関わらず自己修復する形にした。存在する直近の祖先へ静かに移動し（履歴には積まない）、既に積まれている履歴のうち実体を失ったものも取り除く。名前変更時に Finder のようにウインドウを新しい名前へ追従させるには変更前後を同一視するファイル ID の追跡（2-2 の `FSEventsWatcher`/`IdentityResolver`）が要るため、フェーズ1では「親フォルダへ退避する」安全側の単純な挙動に留めた［設計判断］。 **[その後の変更] この自己修復は `DirectoryChangeHub` が変更を届けるようになったことで実際に働くようになった** — 以前は「表示中のフォルダが外部で消えても、何かのきっかけで `reload()` が走るまで気づかない」状態だった（本 §0 末尾の「表示中のフォルダの状態一貫性」節参照）。
    - **祖先の探索は `URL.deletingLastPathComponent()` を繰り返さず `pathComponents` から積み上げる**（ルート `/` に対して `/..` を返し得る Apple の既知挙動。本プロジェクトでは 1-8 のパスバーと `FolderTreePane.ancestorPaths` で 2 度、無限ループとして踏んでいる）。孤立した Swift スクリプトで、削除された末端・2 階層まとめて削除・ルート直下・ルート自身・500 階層の存在しないパス（6.6ms で終了、無限ループしない）を検証してから実機へ反映した。
    - **`code-review` のもう 1 件（同じ実フォルダにボリュームの枝から到達すると `role` が `.plainFolder` になり、登録ルートでも破壊的操作が出る）は修正せず、`allowsStructuralOperations` のコメントに既知の限界として明記した。** 中央ペインでも同じフォルダをそのままゴミ箱へ入れられる（1-13 以来の既存の挙動）ため、ツリーの一方の枝だけを塞いでも一貫性が無く、Finder のサイドバー（登録項目でも実体は普通に削除できる）とも食い違う。登録フォルダの実体が失われた場合はブックマークの解決に失敗し `OfflineRegisteredFolderRow`（グレーアウト＋登録解除）へ自動的にフォールバックする [SB-05] ため復旧不能にはならない。
  - **検証**: `xcodegen generate && xcodebuild`（Debug、成功、新規追加分の警告なし）、`swift test`（174件、全通過）、静的検査2件（OK）。**実機検証（ユーザーによる手動確認）を依頼予定。**
- **1-14 のうち完全削除（FM-14〜FM-18、8章 §8.5 PD-01〜06）が完了した。**（サムネイル表示制御 DS-01〜07 は後日の別作業で完了。本 §0 末尾の「サムネイル表示制御」節を参照）
  - **【後日訂正・下記「Finder の ⌥ 代替項目」節を参照】この節が記録している「`⌥` による項目の入れ替えは SwiftUI では実装不能」という結論は誤りだった。** `View.modifierKeyAlternate(_:_:)`（macOS 15.0+）で実装可能で、後日そちらへ全面的に置き換え済み。以下は当時の調査記録として残す（実測した挙動自体は正しく、誤っていたのは「メニュー内容を作り直せなければ実現できない」という前提のほう）。
  - **`⌥` による項目の入れ替えが SwiftUI では実装不能であることを実測で確定させ、仕様書側を訂正した。** ユーザーは当初「Finder 流の ⌥ 入れ替え」（⌥ 押下中だけ「ゴミ箱に入れる」→「すぐに削除…」に差し替わる）を選択した。`WebSearch` で `NSMenuItem.isAlternate` に相当する SwiftUI API が無く、Apple Developer Forums でも未解決として挙がっていること、`NSEvent.modifierFlags` をメニューの条件分岐で読む方法も「確実には評価されない」と報告されていることを確認したうえで、**検索結果は仮説として実機検証で裏取りする**という本プロジェクトの運用に従い最小の検証アプリを作って計測した。判明したこと:
    1. `.contextMenu { ... }` の**クロージャ自体**はアプリ起動時に先行評価される（`NSEvent.modifierFlags` は常に空）。
    2. その中に置いた**別の View 構造体の `body`**（実アプリの `FolderTreeContextMenu` と同じ構造）は、**初回の右クリック時に**評価される。ここまでは 1-9 の実測記録（「メニュー本体は右クリック時に遅延構築される」）と一致する。
    3. **しかし 2 回目以降の右クリックでは body が再評価されない。** ⌥ あり／なしで右クリックを繰り返しても評価は 1 回だけで、ログにも 1 行しか残らなかった。つまり SwiftUI はメニュー内容を初回表示時に構築して**キャッシュ**しており、修飾キーを見に行く機会自体が存在しない。
    4. メニューバー（`.commands`）側は**アプリ起動時に一度評価されるだけ**で、メニューを開いても再評価されない。
    - **1-9 の記録は「遅延構築される」までで止まっており、「初回だけで以後キャッシュされる」ことまでは分かっていなかった**ため、この機会に正確化した（`FolderTreeContextMenu` に全行分の `.contextMenu` を付けても描画コストがゼロだという 1-9 の結論自体は変わらない）。
    - 途中、合成イベント（`CGEvent`）でこれを自動計測しようとしたが、検証アプリの前面化とフォーカスが安定せず結果が実行ごとにぶれた。**バンドルを持たない `swiftc` 直生成の実行ファイルは既定で前面アプリにならない**（`NSApplication.setActivationPolicy(.regular)` が要る）こと、`Text` に `.background()` を付けただけでは**当たり判定が文字幅ぶんしかない**（1-6 で `List` 行について踏んだのと同じ罠、`.contentShape(Rectangle())` が要る）ことの 2 点が原因だった。最終的に自動化を捨て、メニュー項目自体に判定結果を表示させてユーザーに目視してもらう形に切り替えて確定させた。**教訓: 合成イベントによる UI 自動計測は、前面化・フォーカス・当たり判定という別種の不確実性を持ち込む。結論が実行ごとにぶれ始めたら、計測手段そのものを疑って単純な目視検証に切り替えるほうが速い。**
    - 代替として、**「パスをコピー」と「完全削除…」をまとめて「その他」サブメニューへ退避した**［ユーザー判断］。Finder ではこの 2 つはどちらも ⌥ 押下時にだけ現れる項目であり、同じ性格のものを 1 箇所に集めることでトップレベルの誤クリックを遠ざける。中央ペイン・フォルダツリー・File メニューの 3 箇所すべてで同じ構成にしている。
  - **ドメイン／インフラ層**: `FileOperationService.deletePermanently` を、単純な `[OpReceipt]` を返す実装から `DeletionOutcome`（成功・失敗・スキップを個別に持つ）を返す実装に作り直した [ER-13]。**他の一括操作（`transfer` 等）が「最初の失敗で例外を投げ、それまでの `OpReceipt` を丸ごと捨てる」形（フェーズ1完了前監査で記録済みの既知の課題）なのに対し、完全削除だけは最初からこの形にした** — 完全削除で中断すると「実際にはファイルが消えているのに操作は失敗扱いで記録も残らない」項目が生まれ、それが復元不能な事故に直結するため。`DeletePermanentlyOptions.lockedItemResolver`（ロック済み項目の判断を呼び出し側へ委ねるクロージャ、`OpOptions.conflictResolver` と同じパターン）と `.unattended`（ユーザー非可視のステージング後始末用、尋ねずに削除）も追加した。
  - **[PD-06 の具体化]** ER-11 は「都度尋ねる対象はユーザーの選択によって結果が変わるものに限る」と定めており、完全削除でこれに該当するのは**ロック済み項目**だけ（Finder も同じくロック項目のみ個別に確認する）と判断した［ユーザー判断］。「以降すべてに適用」の状態は UI 側（`FolderOperations.lockedItemBlanketDecision`）が resolver クロージャに閉じ込めて保持しており、`BatchNotificationSession`（ER-10〜16 の汎用機構、依然未実装）を待たずに ER-11 を満たしている。**確認は操作対象 1 件ごとに行い、フォルダ配下の個々のロック項目ごとには行わない** — ただしフォルダ自身がロックされていなくても配下にロック項目を含めば尋ねる（`FileManager.removeItem` はロック済みの子に当たった時点で失敗し、そこまでに消した子だけが失われた中途半端な状態を残すため、先に確認を取ってからまとめてロックを解除する）。
  - **[ユーザー要望] 完全削除で実体を失うライブラリ／テンポラリ登録は強制的に登録解除する。** `RegisteredFolderStore.registrationsInvalidated(byDeleting:)` / `unregisterAll(ids:)` を追加。**照合は削除の「前」、解除は削除の「後」でなければならない** — 照合は Security-Scoped Bookmark の解決に依存するため実体が消えた後では判定できず、逆に先に解除するとアクセススコープが閉じて削除自体が権限エラーになる。この順序制約は実装中に気づいて設計を組み直した（当初は「削除後にまとめて照合・解除する」API にしていた）。確認シートにも登録が解除される旨を明示する。
  - **UI**: `PermanentDeleteConfirmationSheet`（新規、`QooDialogFooter` を使った専用シート［ユーザー判断: ネイティブ `.alert` ではなく］）。**件数は即座に、合計サイズは計算完了後に出す** — フォルダの合計サイズは再帰列挙を要し大きなフォルダでは数秒かかるため、シートを開くのを待たせない。`.alert` を選ばなかった理由はもう 1 つあり、`.alert` の中身は `NSAlert` へブリッジされる際に一度構築されると更新されず、非同期に確定する値を後から差し込めない（`OpenWithMenu` で実際に踏んだ、メニュー／アラート系ブリッジ共通の制約）。`LockedItemDecisionSheet`（新規、PD-06 の個別確認＋「以降すべてに適用」）。**この 2 つは 1 つの `@State`（`PermanentDeletionStep` enum）で切り替える** — 確認シートを閉じた直後に次のシートを出す連続遷移になるため、別々の `.sheet` 修飾子を重ねると表示が不安定になりやすい（`FolderTreePane.FolderTreePrompt` が `.alert` で同じ理由の対処をしている）。
  - **`DeletePermanentlyCommand`（`QooApplication`）はこのコードベースで唯一 `isUndoable == false` のコマンド** [UD-10][PD-05]。`CommandStack` は Undo スタックへ積まないが、`run` 経由で実行することで操作履歴 [HS-01] には残る（「取り消せない」ことと「記録が残らない」ことは別）。`Command` プロトコルの `isUndoable` は 1-11 の時点から用意されていた（「完全削除等、Undo 不可能な操作用」とコメントされていた）が、実際に `false` を返す実装が現れたのはここが初めて。
  - **`code-review`（high）で 7 件の指摘を受け、すべて修正した。** 破壊的操作の経路のため特に丁寧に潰した:
    1. **[リソースリーク] 完全削除した登録フォルダの Security-Scoped Bookmark のスコープが閉じられないまま残る。** `RegisteredFolderStore.unregister` が `activeAccessURLs`（`Set<URL>`）から対象を引くのにブックマークの再解決を使っていたため、実体が消えた後は解決に失敗し `stopAccessingSecurityScopedResource()` が呼ばれず、集合にも古いエントリが残り続けていた。保持を `[UUID: URL]`（登録 ID キー）に変え、実体の有無に依存せず必ず閉じられるようにした。
    2. **[破壊的操作の確認不足] 集計完了前に「削除」ボタンを押せてしまう。** 合計サイズだけでなく、ロック済み項目の予告と「登録が解除される」警告も集計完了後に現れるため、取り消せない操作をそれらを見ないまま確定できる状態だった。`confirmDisabled: !preflight.isComplete` で塞いだ（キャンセルは常に押せる）。
    3. **[退行] リンク切れのシンボリックリンクが削除できない。** 新しく足した存在チェックに `FileManager.fileExists(atPath:)`（リンクを**辿る**）を使ったため「項目が見つかりません」と誤判定していた。素の `removeItem` だけだった以前は問題が無かった、チェックを足したことによる退行。`attributesOfItem(atPath:)`（辿らない）に変更し回帰テストを追加。
    4. **[データ喪失] 削除に失敗してもロックが外れたまま残る／シンボリックリンクの先のロックまで外す。** 前者は「消えてもいないのにロックだけ解除された」状態になるため、外した URL を記録して失敗時に戻すようにした。後者は `.isDirectoryKey` がリンクを辿るため「ディレクトリへのシンボリックリンク」でリンク先を列挙してしまうもので（`removeItem` はリンク自体しか消さないので、削除対象ですらないファイルのロックを外すことになる）、`.isSymbolicLinkKey` を先に見て打ち切るようにした。
    5. **[ハング] ロック確認シートが表示されないとアプリが操作不能になる。** 確認シートを閉じた直後に次のシートを要求するため、SwiftUI が「閉じながら開く」要求を取りこぼすとシートが一度も現れず、`.onDisappear` の安全網も働かない。そうなると `CheckedContinuation` が永久に再開されず、「削除しています…」の表示のまま削除処理の途中で固まる。`PendingLockedItem.didAppear`（`.onAppear` で立てる印）と 2 秒の見張りを追加し、**シートが現れなかった場合に限り**安全側の `.skip` で再開するようにした（ユーザーが長考しても誤発動しない）。
    6. **[死んだキャンセル処理] `Task.detached` は呼び出し元のキャンセルを引き継がない。** 集計中の `Task.isCancelled` が永久に `false` のままで、シートを閉じても 5 万件規模の走査が最後まで走り続けていた（コメントには「打ち切られる」と書いてあり実態と食い違っていた）。`nonisolated` な async 関数の直接呼び出しに変え、**孤立した検証スクリプトで「メインスレッドを外れること」と「同期ヘルパー内の `Task.isCancelled` がキャンセルを拾うこと」の両方を実測してから**反映した（`onMainThread=false` / 20 億回ループの 610 万回目でキャンセル検知）。なお `InspectorPane.computeFolderCounts` にも同じ `Task.detached` の問題が残っている（本節のスコープ外、既知として記録）。
    7. **[案内と実装の食い違い] ロック済み項目の予告件数が実際の確認回数と一致しない。** 配下のロック項目を再帰的に数えていたが、実際の確認は操作対象 1 件ごとに行われるため「N 件を 1 件ずつ確認します」という案内が嘘になっていた（1 回の操作で N 件すべてが黙って消える）。数える単位を操作対象に合わせ、文言も「うち N 件はロックされているか、ロックされた項目を含みます」に直した。
    - なお `NSDirectoryEnumerator` の `for-in` は async コンテキストで使えない（`makeIterator` が unavailable）ため、6 の修正では走査を同期関数へ切り出している（`Task.isCancelled` は同期コードからでも呼び出し元タスクの状態を返すためキャンセルの伝搬は保たれる。これも上記の実測で確認済み）。
  - **キーバインドは既定で未割り当てのまま** [FM-16]。`ActionID.deletePermanently` は 1-8 の時点で `combos: []`・`isDestructive: true` として登録済みだったものを、ここで初めて実際に配線した。`KeyBindingButtons` は `combos` が空だとボタンを 1 つも生成しないため、既定では何も起きず、環境設定「キーボード」タブでユーザーが自分で割り当てたときにだけ効く（割り当てても確認シートは必ず経由する）。
  - **テスト**: `FileOperationServiceTests` に 7 件（ER-13 の継続動作、resolver 未指定時のスキップ、resolver 承認時の削除、配下にロック項目を含むフォルダで尋ねること、`.unattended`、リンク切れシンボリックリンク、削除失敗時のロック復元）、`RegisteredFolderStoreTests` に 4 件（登録フォルダ自身・祖先削除・名前が前方一致するだけの別フォルダを巻き込まないこと・`unregisterAll`）、`FileCommandsTests` に 5 件（`isUndoable == false`、Undo スタックへ積まれないこと、`.partial` の返却、強制登録解除、削除失敗時は登録を残すこと）を追加。合計 211 件が通過。
  - **実機検証で発見・修正したバグ: 中央ペインから登録フォルダを完全削除しても、左ペインから登録が消えない。**
    - **登録解除自体は成功しており、左ペインが読み直していなかっただけ**だった。切り分けの根拠は 3 つ: ①`registeredFolders.json` の更新時刻がテスト実行中の時刻になっていた（＝ストアへの書き込みは起きている）、②残っている登録のブックマークを孤立スクリプトで解決したところ**すべて実体が存在した**（＝消えたはずの 1 件だけが正しく取り除かれた後の状態）、③`reloadRegisteredFolders()` の呼び出し元がツリー自身の操作（＋ボタンでの登録・登録解除・表示名変更）しか無かった。**UI の見た目ではなく永続化ファイルを直接確かめたことで、「ロジックの失敗」と「表示の未更新」を確実に切り分けられた。**
    - 原因は `FolderTreePane` の構造的な穴で、既存のコメント自体がそれを言い当てていた（「ツリー自身の表示更新は各行が `SessionState.reloadToken` を監視して行う。**登録ルート行だけはこのペインが直接保持しているため、こちらは明示的に読み直す**」）。各行は共通シグナルを見ているのに、**登録ルート行の一覧だけはこのペインの `@State` が抱えたコピー**で、ペイン外からの変更では誰も読み直さない。これまで登録が消える経路がツリー自身の「登録解除」しか無かったため表面化しておらず、中央ペインからの完全削除という新経路ができて初めて露出した。
    - `FolderTreePane` に `.onChange(of: SessionState.shared.reloadToken)` を追加して解消（同じファイルの `FolderTreeRow` が既に使っている既存パターンに合わせた）。**発生源ごとに手当てするのではなく共通シグナルに乗せた**ため、今後登録を変える経路が増えても自動的に追従する。
    - **教訓: ペインが `@State` に抱えた一覧は、そのペイン自身の操作以外では更新されない。** 他の経路がその一覧の元データを変え得るようになった時点で、`SessionState.reloadToken` の監視を足す必要がある。同種の `@State` 一覧を持つ箇所を追加する際は、最初からこのシグナルに乗せること。
  - **あわせて潜在的な不具合を 1 件修正した**（今回の症状の原因ではない）: `DeletePermanentlyCommand` が削除**後**にパスを正規化していたため、`resolvingSymlinksInPath()` が実体の無いパスを途中までしか解決できず、削除**前**に解決した登録側のパスと文字列が食い違う可能性があった（シンボリックリンク経由のフォルダで起こり得た）。正規化を削除前に済ませるようにした。
  - **実機検証（ユーザーによる手動確認）で完了。** 「その他」サブメニュー（中央ペイン・フォルダツリー・File メニューの 3 箇所）、確認ダイアログ（件数の即時表示・合計サイズの遅延表示・集計中は決定ボタンが押せないこと・取り消せない旨の明示）、ロック済み項目の個別確認と「以降すべてに適用」[PD-06]、登録フォルダの強制解除（警告表示と左ペインからの消失）、⌘Z で取り消されないこと [PD-05] のいずれも確認済み。
  - **仕様書の実装方式が実際の API と食い違っていたため、仕様書側を訂正してから実装した**（CLAUDE.md §1 の「矛盾を見つけたら仕様書側を直す」に従う。1-8 の `KeyBinding.shortcut` と同じ扱い）。仕様書 9.7 節 QL2-08 は「`QLPreviewPanel` の `previewItem` に独自ビューを持つ `NSViewController` を返す方式」としていたが、**`QLPreviewPanel` に項目ごとの独自ビューを差し込む API は存在しない**（SDK の `QLPreviewPanel.h` を直接読んで確認。データ源は `QLPreviewItem` のみで、その実体は `previewItemURL` ＝ファイル URL）。App Extension を使わないという QL2-08 の設計判断自体は維持し、独自プレビューは「**中の先頭画像を実ファイルとして書き出し、その URL を渡す**」方式に置き換えた。
  - **独自プレビューの対象範囲を要件 QL-03 より広げた**［ユーザー判断］。要件は `.cbz`/`.cbr`/`.cb7` のみを挙げるが、本アプリは `.zip` と `.cbz` を `ArchiveFormat` の同一値として扱い、アイコン表示のサムネイルも同じ経路で生成しているため、拡張子だけで Quick Look の挙動が変わるとアプリ内で説明のつかない不整合になる。**「アイコン表示でサムネイルを生成できるが、標準 Quick Look では中身を見せられないもの」＝対応アーカイブ全般＋フォルダ**を対象にした（フォルダを含めることで QL-08 のブックフォルダも、フェーズ 2 の概念導入を待たずに満たせる）。pdf/epub/画像/動画は QL-02 通り標準 Quick Look に委ねる。
  - **`ThumbnailService` の private ヘルパーを 2 つの共有型へ切り出した**（Quick Look と 2 箇所に同じ判定・解決を持つと片方だけ直される事故が起きるため）。`Sources/QooInfrastructure/FileOps/Thumbnails/PreviewableFileKind.swift`（フォルダ／画像／動画／PDF／EPUB／アーカイブ／その他の分類と、`needsCustomCoverPreview`）・`CoverImageSourceResolver.swift`（「中の先頭画像 1 枚」の解決）。`ThumbnailService` はこの 2 つへ委譲するだけになった（挙動は不変、既存テストで確認）。
  - `Sources/QooInfrastructure/FileOps/Thumbnails/QuickLookCoverStore.swift`（新規、`actor`）: カバー画像を `Application Support/qooLibrary/quicklook/` へ書き出す。**再エンコードせず原画像のバイト列そのものを書く**（サムネイルキャッシュの縮小 PNG を流用すると Quick Look の大きな表示でぼやけるため）。拡張子は**エントリ名ではなく実データの UTI** から決める（アーカイブ内のエントリ名は実体と食い違うことがあり、Quick Look は拡張子で描画方法を選ぶため）。キーは `volumeUUID-inode-mtime`。**セッション限りのキャッシュ**とし、アプリ起動時に `purgeAll()` で丸ごと捨てる（`SecureExtractor.cleanupResidualStaging()` と同じ、異常終了しても次回起動で必ず片付く方式）。1 セッション中の肥大を防ぐため合計サイズ上限（既定 200MB、`AppLimits.QuickLook`）を設け、古いものから削除する——**ただし今書き出したばかりのファイルは削除対象から外す**（上限が 1 件ぶんも無い場合に、これから渡す当のファイルを消して実体の無い URL を返してしまうため）。`FileManager` の変更系 API を使うため B-10 の許可ディレクトリ配下に置いている（`SecureExtractor`/`CoverImageCache` と同じ設計判断）。
  - `Sources/qooLibraryApp/QuickLook/`（新規）: `QuickLookPreviewItem`（`sourceURL` と実際に渡す `previewURL` を分けて持ち、タイトルは常に元のファイル名）、`QuickLookController`（`QLPreviewPanelDataSource`/`Delegate`、ウインドウごとに 1 つ）、`QuickLookPanelInstaller`（レスポンダ差し込み）。
  - **レスポンダチェーンへの差し込み位置を実測で決めた。** `QLPreviewPanel` は「レスポンダチェーンをたどり最初に `acceptsPreviewPanelControl:` へ `true` を返したオブジェクト」を制御者に選ぶが、SwiftUI にはそこへ置ける自前のレスポンダが無い（`.background { NSViewRepresentable }` で置いた `NSView` は中央ペインの `Table` にとって「兄弟」であって祖先ではないため一度も尋ねられない——`TableHorizontalScrollDisabler` で確認済みの構造的制約と同じ）。**最小の AppKit アプリを組んで、①ファーストレスポンダのビュー自身／②`window.nextResponder` への差し込み／③ウインドウデリゲート／④アプリデリゲート の 4 箇所に同時に実装して計測した結果**: パネルを前面に出した時点で探索が走る（`updateController()` を明示的に呼んでもパネルが非表示なら何も起きない）、①が `true` を返すとそこで止まる、**①が `false` なら②が尋ねられ制御権が渡る**（`currentController` も②になる）、③④はどちらの場合も一度も尋ねられない、と判明した。②を採用している。念のため、制御権が渡ってこなかった場合はデータソースを直接設定する保険と警告ログも入れてある。
  - **QL-07（矢印キーで選択移動）は `previewPanel(_:handle:)` で受ける。** 一覧の表示順（`FolderContentView` が `publishQuickLookOrder()` で押し込む）に沿って選択を隣へ動かし、`pendingRevealURL` 経由で中央ペインもその項目までスクロールさせる。複数選択中は ← → をパネル自身が「選択内の前後」に使うためここには届かない（＝ ↑ ↓ だけが一覧の選択移動になる）——Finder と同じ挙動。**delegate メソッドは optional 要件のため Swift 名を間違えてもコンパイルが通り黙って呼ばれなくなる**ので、`class_getInstanceMethod` で 4 つの selector（`previewPanel:handleEvent:` 等）が実際に生えていることを実行時に確認してから進めた。
  - **QL-09（未生成時のプレースホルダ）は「差し替え前は元のファイル URL をそのまま渡す」ことで実現**した。標準 Quick Look がアーカイブ／フォルダのアイコンを出し、カバーが用意できた時点で `refreshCurrentPreviewItem()` により差し替わる。解決は `previewPanel(_:previewItemAt:)` が呼ばれた項目だけを対象にする遅延方式（選択が 100 件あってもユーザーが見た分しか読み込まない）。
  - **QL-06（タイトル・シリーズ名・巻数・評価・ラベル・ファイルサイズの併記）は未実装**。上記の方式ではパネルへメタデータを重ねられず、フェーズ 1 に存在するのはファイル名（パネルのタイトルに出る）とファイルサイズ（常設インスペクタに出る）だけのため実害は無い。**フェーズ 2 でラベル・評価が入った時点で「カバー＋メタデータを 1 枚の画像／PDF に合成して渡す」か「独自パネルへ移行する」かの判断が必要になる**［フォローアップ］。
  - `[QL-10][IM-05]` Quick Look 用の読み込みにも画像の安全上限を適用する。上限超過は縮小せず**諦めて `nil`**（IM-01 の「超過は生成をスキップ」と同じ方針）→ 呼び出し側は元の URL のまま標準 Quick Look に委ねる。上限の判定は `ImageLoading` に追加した `isWithinPixelCountLimit(_:)` に集約し、`QuickLookCoverStore` が上限値を自前で持ち直さないようにした。
  - **配線**: 中央ペインのリスト／アイコン両表示に Space（`ActionID.quickLook`、1-8 で登録済みだったものを初めて実配線）、コンテキストメニュー「クイックルック」、File メニュー「クイックルック」。**コンテキストメニューだけは `toggle()` ではなく `show()` を呼ぶ**（対象を明示して選んだのに、既に開いていると閉じてしまうため）。
  - **`KeyBindingPress`（`KeyComboConversion.swift`）を新設し、`.open` の配線もこれに移した。** `Enter`/`Space` のような修飾キー無しのキーは `KeyBindingButtons`（不可視ボタン＋`.keyboardShortcut`）では扱えず `.onKeyPress` が必要だが、従来の `.onKeyPress(binding.combos.first?.swiftUIKeyEquivalent ?? .return)` には ①未割り当てにしても既定キーが効き続ける ②修飾キーを見ないため ⌘Y に再割り当てすると素の `y` でも発火する、の 2 つの穴があった。`.onKeyPress(keys:phases:)`（キーでの絞り込みは SwiftUI に任せたまま、修飾キーだけ自分で照合する）に置き換えて両方を塞いだ。
  - **`code-review`（high）の指摘 5 件をすべて修正した**: ①ウインドウ間で制御権が移ったとき `currentPreviewItemIndex` が範囲外のまま残り何も表示されない、②上記の `KeyBindingPress` の修飾キー無視、③レスポンダの取り外しがチェーンの尾を切る／再差し込みで輪ができ得る（前任者を探して繋ぎ直す方式に変更、走査長も区切った）、④フォルダのキャッシュキーの限界がコメントと食い違う（コメントを実態に合わせて訂正）、⑤`reload()` の `folder == nil` 早期 return で表示順の押し込みが漏れる。
  - **実機検証で発見・修正した最重要のバグ: Space キーでプレビューを開いた瞬間に `EXC_BREAKPOINT` で即死した。** クラッシュログのフォルティングスレッドは**メインスレッドではなく `NSOperationQueue` のワーカー**で、呼び出し元は `-[QLPreviewView shouldUseAsyncLoading]` → `-[QLPreviewDocument startLoadingWithForcedDisplayBundleID:hints:]` → `NSFileCoordinator` の調整アクセスブロック → `@objc QuickLookPreviewItem.previewItemURL.getter` → `_checkExpectedExecutor` だった。**QuickLook は `previewItemURL` を非同期ロードの判定のためバックグラウンドから読む**のに、`QuickLookPreviewItem` を `@MainActor`（＋隔離付き適合）で書いていたためアクター隔離チェックがトラップしていた。この型を `nonisolated`（`@unchecked Sendable` + `NSLock` で可変な `previewURL` だけを保護）に直して解消。**同じ前提に依存する箇所を残さないため、データ源も `QuickLookItemSource`（ロック保護、メインアクター非隔離）へ切り出し、`sourceFrameOnScreenFor` も `nonisolated` にした**（`QLPreviewPanelDelegate` のうちキーイベント・`windowWillClose` は本質的に UI イベントなので `@MainActor` のまま）。修正の前後を使い捨てのプローブで確認済み（旧設計はバックグラウンド読み出しで SIGTRAP／新設計は正しく読める）。**教訓: AppKit / QuickLook のコールバックが常にメインスレッドで来るとは限らない。`delegate`（UI イベント）と違い、データ源として渡すオブジェクトは任意のスレッドから読まれ得ると考えること。**
  - **同じ検証中に踏んだビルド運用の罠: リポジトリ直下の `build/Debug/qooLibrary.app` は古い成果物で、`xcodebuild` の実際の出力先は DerivedData だった。** `xcodebuild` は毎回 BUILD SUCCEEDED と表示していたが、`open build/Debug/qooLibrary.app` で起動していたのは修正前のバイナリで、修正後も同じクラッシュが再現し「直っていない」と誤認した（バイナリの mtime がソース編集より 15 分以上古いことに気づいて発覚）。**起動前に `xcodebuild -showBuildSettings | grep BUILT_PRODUCTS_DIR` で出力先を確認し、バイナリの mtime がソース編集より新しいことを必ず確かめること**（`.xcstrings` の反映漏れで一度記録した「BUILD SUCCEEDED を信じない」と同根の罠）。紛らわしい `build/` は削除し、`.gitignore` に追加した。
  - **テスト**: `PreviewableFileKindTests`（新規 7 件）・`CoverImageSourceResolverTests`（新規 5 件）・`QuickLookCoverStoreTests`（新規 8 件）。`QLPreviewPanel` 自体を要する部分（パネルの表示・矢印キー・レスポンダ探索）は自動テストの対象外で、上記の通り使い捨ての最小 AppKit アプリでの実測と実機検証で担保する。
  - **実機検証で完了。** まず `System Events` によるスクリプト操作で、File メニューの「クイックルック」・Space キーのどちらでもパネルが開き、Escape / Space で閉じて再度開けること、クラッシュしないことを確認した（パネルが実際に開くこと自体が、レスポンダチェーン差し込みが実アプリでも機能している裏付けになる——制御権が渡らなければパネルは何も表示しない）。続いて**ユーザーによる手動確認**で、①アーカイブ／画像入りフォルダでカバーが大きく表示されタイトルが元のファイル名になること、②pdf/画像/動画が標準 Quick Look に委ねられること、③プレビュー表示中の矢印キーで選択が移動し中央ペインも追従すること、④`.open` の配線を `KeyBindingPress` へ差し替えたことによる Enter キーの回帰が無いこと、をいずれも確認済み。
  - **検証**: `swift build`/`swift test`（195 件、全通過）、静的検査 2 件（OK）、`xcodegen generate && xcodebuild`（Debug、成功、新規追加分の警告なし）、実機検証（上記の通り完了）。

- **1-15（診断ログ、LG2-01〜LG2-08）が完了した。**
  - **`OSLog` に加えてファイルへ出力する** [LG2-01]。`Log.fileOps.info("…")` という呼び出しの書き方は 1-15 以前と同じまま、各チャンネル（`LogChannel`）が `OSLog` とファイルログの**両方**へ同時に流すようになった。`OSLog` へは `privacy: .public` で渡す [設計判断] — 既定の `.private` だと Apple 署名でないビルドで内容が `<private>` に伏字化されて読めない（1-9 の `⌘↑` バグ調査で実際に踏んだ）。パスの秘匿は書き出し時の匿名化 [LG2-06] という別の仕組みで担保する。
  - `Sources/QooKit/Model/LogLevel.swift`（新規）: `LogLevel`（`error`/`warning`/`info`/`debug`、`rawValue` が小さいほど重大）。`AppLimits.Logging` が既定値としてこの型を持つため `QooKit` に置いた（`Foundation` のみに依存する純粋な値型なので [A-01] に反しない）。`AppLimits.Logging`（既定レベル・1ファイル 10MB・5 世代・バッファ上限・匿名化トークン桁数）も追加。
  - `Sources/QooInfrastructure/FileOps/Logging/`（新規5ファイル）。**`FileManager` の変更系 API を使うため `FileOps/` 配下に置いている** [B-10]（`SecureExtractor`/`CoverImageCache`/`RegisteredFolderStore` と同じ設計判断）。加えて**`FileOperationService` を経由してはならない**構造的な理由がある — 経由すると、その中のログ出力がログライターを呼び、それがまた `FileOperationService` を呼ぶ再帰になる。
    - `DiagnosticLogging.swift`: `LogCategory`（仕様書 §2.6 の 8 種に `App`/`Sandbox`/`Image` の 3 種を追加 [設計判断]。既存カテゴリへ寄せると意味が濁るため）、`LogRecord`、`DiagnosticLogging` プロトコル、`DiagnosticLogPreferences`（`UserDefaults` キーの集約）、`LogChannel`。
    - `DiagnosticLog.swift`: 既定実装。**`AsyncStream`（FIFO 保証）に載せて消費側のバックグラウンドタスクが書く** [CB-21]。**1 レコードごとに `Task { await writer.append(…) }` を起こす方式は採らなかった** — `Task` の実行順序は投入順と一致せず、ログ行が入れ替わって時系列を追えなくなる。**まとめてから書く方式にもしない** — バッファリングするとクラッシュ直前の、診断上もっとも重要な数行が失われる。`flush()` は「番兵レコードを流し、消費側がそこへ到達したら再開する」方式（ストリームが FIFO であることを利用して「これより前は書き終わった」を表現する）。バッファ溢れは黙って捨てず、捨てた件数を後続の行へ警告として書く。
    - `LogFileWriter.swift`: 実際の書き込みとローテーション。**ローテーションは書き込みの「前」に判定する** — 後に判定すると、上限を超えた瞬間に現行ファイル（`qoo-0.log`）を退避したまま次の書き込みまで存在しない状態になり、「最新のログがどこにあるか分からない」「書き出しに最新の世代が含まれない」ことになる（実装当初これを間違えており、`rotatesWhenTheCurrentFileExceedsTheLimit` テストが `qoo-0.log` の不在を検出して発覚）。
    - `PathAnonymizer.swift`: 書き出し時のパス匿名化 [LG2-06]（後述）。
    - `DiagnosticsReport.swift` / `DiagnosticExport.swift`: `diagnostics.json` [CB-22] と zip バンドルの書き出し [LG2-05]。zip 化と最終位置への昇格は `ArchiveCompressor` を再利用する（衝突処理・`.replace` の退避と復元がそのまま効く）。**ネットワーク送信は一切しない** [LG2-08][SC-01][CB-24]。
  - **匿名化 [LG2-06][CB-23] の対象を仕様書から広げた**［ユーザー判断、仕様書 §2.6 も更新済み］。元の記述は「ホームディレクトリ以下を `~/…/<sha256 先頭 8 桁>` に置換」だったが、**サンドボックスアプリである qooLibrary が実際に扱うパスの大半はホーム外**（外部ボリューム上のライブラリ／テンポラリフォルダ）であり、ホーム配下だけでは目的をほとんど果たさない。**すべての絶対パス**を対象にし、**パス全体を 1 つのトークンに畳まず成分ごとに**置換する（階層の深さと最終成分の拡張子は残す）。`/Volumes/PRO-G40/Comics/作品A/第01巻.cbz` → `/Volumes/3f2a9c11/8b41d0e7/c9a7f215/1e6b04dd.cbz`。こうすると「同じフォルダにある別のファイル」「移動元と移動先が同じ親を持つ」といった関係がログ上で追えるままになる。トークンは**その成分までのパス接頭辞**から導くため、別の場所にある同名フォルダが同じトークンになって誤った関連付けを生むこともない。インストールごとに一度だけ生成するソルトを混ぜる（書き出したバンドルには含めない。`/Users/<よくある名前>` のような推測しやすいパスの逆引きを防ぐ）。
  - **計装の作法（今後ログを足すときの約束事）**: `error`=ユーザーに提示する失敗、`warning`=回復した失敗、`info`=1 回のユーザー操作＝1 行、`debug`=項目単位の詳細（既定では出ない）。**ファイル名ではなく絶対パス（`url.path`）を書く** — 匿名化の対象になるのは絶対パスだけで、`lastPathComponent` だけを書くとそのまま残る。絶対パスが手元に無いユーザー由来の名前（解決できない登録フォルダの表示名、アーカイブ内のエントリ名）は **`Log.redactable(_:)`** で包む（`⟨名前⟩` の形になり、匿名化時は `⟨<hash8>⟩` に置換される。匿名化しなければそのまま読める）[CB-26]。**パスは行末か区切り記号（`→`・`—`・`,`・括弧）の直前に置く** — 走査は空白で打ち切らない（後述）ため、パスの直後に素の散文を続けると巻き込まれる。
  - **[実機確認で匿名化の取りこぼしを 3 件見つけて修正し、方式そのものを改めた。]** 1-15 を「完了」としてユーザーへ引き渡した直後、**「ファイル名やフォルダ名が匿名化されないのは意図的？」というユーザーの指摘**で発覚した。いずれも「部品単位のテストは通るのに、実際に出力される 1 行では漏れる」種類の不具合だった。
    1. **`Command.displayName` 経由でファイル名が素通しだった。** `displayName`（`「作品A 第01巻.cbz」を展開` のように `lastPathComponent` を素で埋め込む、Undo メニュー用の文言）を `CommandStack` がそのまま診断ログへ書いていた。**全操作が通る経路**なので影響が最も大きい。`Command` プロトコルに **`logDescription`**（対象を必ず**絶対パス**で表す。既定実装は `displayName`）を追加し、全 10 コマンドで実装、`CommandStack.record()` は操作履歴に `displayName`・診断ログに `logDescription` を使い分けるようにした。匿名化されるようになるだけでなく、「どこのファイルか」が分かってログ自体の診断価値も上がった（同名ファイルが複数の場所にあるライブラリでは名前だけでは再現できない）。`CompositeCommand` は呼び出し側から渡された任意の `displayName` を持つため、子の `logDescription` を並べる形にした。
    2. **空白を含むパスが途中までしか匿名化されていなかった。** 走査が空白を終端としていたため、`/Volumes/PRO-G40/My Sample/成年コミック/作品.cbz` が `/Volumes/<hash>/My Sample/成年コミック/作品.cbz` になっていた——**取りこぼしより質が悪い**（匿名化したつもりで実際は素通し）。macOS のパスに空白は普通に含まれるので、空白を終端から外し、代わりにログ本文で実際に区切りとして使っている記号（`→`・`—`・括弧類・引用符）と、`/ `／`, `（箇条・列挙の区切り。`削除 1 件 / 失敗 1 件` を誤ってパスと見なさないため）を終端にした。
    3. **括弧で始まるファイル名がまるごと素通しだった。** 2 の修正で `( ) [ ] （ ）` などを走査の終端に加えたところ、`(成年コミック) [98765架空社] …` という**この分野ではもっとも普通の**ファイル名が、括弧で走査が止まるため一切匿名化されなくなった——**自分の修正が生んだ退行**である。ユーザーが実際に書き出したログで発覚した。
    - **ここで方式そのものを改めた**［ユーザー指摘: 「macがファイル名もしくはフォルダ名への使用を許可しているあらゆる文字・記号を考慮してください」］。macOS のファイル名には **`/` と NUL 以外のあらゆる文字**が入る——空白も括弧も引用符も矢印もタブも合法。つまり**「この文字が来たらパスの終わり」という区切り文字は原理的に存在せず、自由文からパスを推測する方式は根本的に誤り**だった。1 と 2 を個別に潰していたのは、対症療法を重ねていたにすぎない。
      - **`Log.path(url)` が書き込み時にパスを `⟪…⟫` で囲み、匿名化は範囲を推測せずその印だけを信じて置換する**方式に変更した（全 40 箇所超の計装を移行）。ファイル名に印そのものが含まれていても書き込み時に二重化してエスケープするため曖昧さは残らない。印は書き出し時に取り除くので、読む人には見えない。
      - 推測に頼るのは**こちらが書式を決められないテキスト**（`Foundation` の `localizedDescription` が埋め込むパス）だけに限定し、そこでは「余分に伏せる」側へ倒す。
      - あわせて**ログの書式側も曖昧さの無い形に揃えた**: パスの直後に注釈を続けない（`展開開始（zip / 201 エントリ）: <パス> → <パス>` のように注釈を前へ置く）。**今後パスを含むログを追加するときもこの形にすること。**
    - あわせて**自由文への安全網**を入れた [CB-27、ユーザー判断]。`error.localizedDescription`（Foundation が `“foo.txt” couldn’t be moved…` の形で名前を埋め込む）や `NotificationItem` の本文は構造化できないため、匿名化時に**引用符・鉤括弧の中身**（`「」`『』“” ‘’）も置換する。名前でない固定文言も伏せられるが、匿名化は共有時の opt-in 設定なので取りこぼすより安全側に倒す。**新しく計装するときはこの安全網に頼らず、絶対パスか `Log.redactable(_:)` を使うこと**（安全網は伏せる範囲を選べない）。
    - **回帰テスト `PathAnonymizerRealFormatsTests` を新設した。** コードベースに実在するログ行の書式を並べ、匿名化後にユーザー由来の断片が 1 つも残らないことを検証する。**計装を追加・変更したらその書式をここへ追加すること。**
      - **標本は必ず「実際に扱うファイル名の形」にすること。** 3 の退行を検出できなかったのは、それ以前のテストが `作品タイトル.cbz` という**現実には存在しない綺麗な名前**を標本にしていたためだった。現在は `(成年コミック) [98765架空社] …` や `【C99】作品名 → 続編、その2「完全版」 (1:2).cbz`（区切り記号・鉤括弧・読点・`:` を含む）を使い、タブ・引用符・縦棒・印そのものを含む名前の専用テストも置いている。なお `/` だけはファイル名に入らない（Finder で入力した `/` は POSIX 層では `:` として保存される）。
    - 検証は**書き出し機能そのもの**（`exportBundle` → zip 生成 → zip 内のログを読み戻す）を開発機の実際のログ 230 行に対して実行し、実データの断片 17 種（ボリューム名・ライブラリ名・作品名・ユーザー名・印）が 1 つも残らないこと、かつ「展開元と展開先が同じ親」といった診断に必要な構造は保たれることを機械的に確認した（確認用の一時テストは調査後に削除）。
    - **教訓（今後の計装すべてに効く）**: ①自由文からの構造の推測は、入力の自由度が高い領域では必ず破綻する。**書く側に構造を持たせる**ほうが確実で、しかも安上がりだった。②テストの標本を「きれいな例」にすると、その分野で最も普通の入力を取りこぼす。**実データの形をそのまま標本にすること。**
  - **計装した箇所**: 起動セッション情報（バージョン/OS/ビルド構成/RAR バックエンド/サンドボックスか）、`FileOperationService` の全変更操作（`transfer` は**どの項目で止まったか**と**何件成功後だったか**を残す — 一括処理の途中で失敗すると成功分の `OpReceipt` が破棄されて Undo にも操作履歴にも残らない既知の課題があるため、せめてログには残す）、`CommandStack`（`record()` という単一の choke point で実行/取り消し/やり直しをまとめて記録。`FO-03` と同じ「記録漏れを構造的に防ぐ」考え方）、展開・圧縮（拒否したエントリの理由を含む）、Security-Scoped Bookmark の解決失敗（1-17 の縮退状態の診断に直結）、永続化ファイルの破損検知、`NotificationRouter`、サムネイル生成失敗。
  - **環境設定「詳細」タブ**（`AdvancedPreferencesTab`、仕様書 §15.10 の 8 タブ定義どおりの名前で新設）: ログレベル [LG2-03]・現在のログサイズ・ログフォルダを Finder で表示・パス匿名化の有無 [LG2-06]・診断情報の書き出し [LG2-05]・既定に戻す。**ヘルプメニュー**（従来アプリに存在しなかった）を `CommandGroup(replacing: .help)` で新設し「診断ログを書き出す…」を配置 [13章 §13.5]。実処理は `DiagnosticExportAction` として両者で共有する — 同じに見える操作に独立した実装経路が複数あると片方だけ直して取り残される（1-12 のアプリ関連付けで実際に起きた）ため。
  - **アプリ終了時の書き出しは「構造化並行性の外」で上限時間を持つ** [`AppDelegate`]。`applicationWillTerminate` でセマフォを使うとメインスレッドを止めるため、AppKit の `.terminateLater` + `reply(toApplicationShouldTerminate:)` を使う。**`withTaskGroup` で `flush()` と 2 秒のスリープを競争させる書き方は誤り** — 本体が返ってもグループは全子タスクの完了を暗黙に待つため、`flush()` が返ってこない状況（ディスクが固まった等）では結局終了できず、しかも `flush()` は `withCheckedContinuation` で待つ構造上キャンセルにも反応しないので `cancelAll()` も効かない（`code-review` の指摘で発覚）。独立した 2 本の非構造化タスクを走らせ、先に着いた方が 1 回だけ返答する形にした。
  - **`swift test` 中はログ出力先を一時ディレクトリへ振り替える**（`code-review` の指摘）。`Log.*` の呼び出しは `FileOperationService` など広範囲に埋め込まれているため、これが無いとテストを回すたびに開発機の実際のログがテストのノイズで埋まり、ローテーションで本物の履歴が押し流される。判定は環境変数・プロセス名・`XCTestCase` クラスの有無の 3 つを併用する（SwiftPM の Swift Testing は `swiftpm-testing-helper` という名前で走り、`XCTestConfigurationFilePath` も `XCTestCase` も持たないことを実測で確認済み）。
  - **`FileHandle.write(contentsOf:)` が原因の `EXC_BAD_ACCESS` を切り分けて解消した。** 実装当初はファイル書き込みに `FileHandle` を使っていたが、テストスイート全体を走らせると `EXC_BAD_ACCESS`（メインキューが Swift Concurrency のジョブを実行中にクラッシュ）が **3 回中 3 回、直列実行でも**再現した。クラッシュするテストは実行のたびに変わり、原因の見当がつかなかったため以下の手順で機械的に切り分けた: ①作業ツリーを丸ごと `git stash` して HEAD だけで実行 → 正常（＝今回の変更が原因と確定）、②`LogChannel.emit` を即 `return` → 正常、③レコードは作るが `AsyncStream` へ流さない → 正常、④消費側が受け取るが何もしない → 正常、⑤整形だけして書かない → 正常、⑥アクター境界だけ越えて書かない → 正常、⑦記述子を開くが書かない → 正常、⑧**同じ所要時間の `usleep` に置き換える → 正常**（＝タイミングの問題ではない）、⑨`FileHandle.write(contentsOf:)` を呼ぶ → **クラッシュ**。生の `open`/`write(2)`（`O_APPEND`）に置き換えて解消し、リリースビルドを含め 246 件が安定して通るようになった。副次的に、追記が原子的になり `lseek` も不要になった。**教訓: 症状が「実行のたびに別の場所で落ちる」ときこそ、推測を重ねずに 1 段ずつ機械的に潰す方が速い。`lldb` はこの環境では attach できず（`Not allowed to attach`）、クラッシュレポートの最上位フレームも解決不能だったため、二分探索が唯一の実用的な手段だった。**
  - **`PathAnonymizer` の性能を実測して 6 倍改善した。** 10MB のログ 1 本の匿名化に当初 3.2 秒かかっており（書き出しは最大 10MB × 5 世代を一度に処理する）、まず「パス以外の部分を 1 文字ずつ `append` している」ことを疑って一括転記に直したが**まったく改善しなかった**（3.5 秒）。実際の支配要因は ①`String(format: "%02x")` によるトークンの 16 進化（内部でロケール解決を伴い桁違いに遅い）②同じフォルダが何千行にも現れるのに毎回 SHA256 を計算し直していたこと、の 2 つだった。16 進テーブル引きへの置き換えと、1 回の走査内で使い回す接頭辞→トークンのキャッシュで、デバッグビルド 1.18 秒・**リリースビルド 0.53 秒**になった。**教訓: 「文字列を 1 文字ずつ触っているから遅いはず」という直感は外れることがある。直す前に測る。**
  - `Tests/QooInfrastructureTests/`（新規4ファイル）・`Tests/QooApplicationTests/CommandLogDescriptionTests.swift`（新規、全コマンドの `logDescription` が素のファイル名を漏らさないこと・パスフレーズを書かないこと）: `DiagnosticLogTests`（レベルのしきい値、`@autoclosure` が実際に遅延評価されていること、**500 件を連続記録しても順序が入れ替わらないこと**、複数行メッセージが 1 行に畳まれること、ローテーションの世代管理と取りこぼしの無さ、バッファ溢れの注記、テスト中の出力先振り替え）、`PathAnonymizerTests`（決定性、兄弟ファイルが親トークンを共有すること、別の場所の同名フォルダが別トークンになること、拡張子の保持、標準成分の保持、`file://` 形式、`⟨…⟩` 印の匿名化）、`DiagnosticExportTests`（zip の中身、匿名化の有無での差、書き出し前の `flush`、全世代の同梱、JSON の往復）。
  - **検証**: `swift build`/`swift test`（267 件、Debug・Release とも全通過）、静的検査 2 件（OK）、`xcodegen generate && xcodebuild`（Debug、成功）。
    - **実サンドボックス下での動作を実際に起動して確認済み**: 署名済みアプリを起動し、`~/Library/Containers/com.qoolibrary.app/Data/Library/Application Support/qooLibrary/Logs/qoo-0.log` が正しい場所に作られること、セッション開始行（`qooLibrary 0.1.0 (1) / Debug / RAR=UnRAR / バージョン26.6.1（ビルド25G76） / arm64 / sandbox=true`）と起動時の計装（登録フォルダ 6 件・ボリューム許可 2 件の読み込み）が記録されること、終了時に「セッション終了」が書かれ**待たされずに終了する**（`applicationShouldTerminate` の上限時間の実装が意図どおり）ことを確認した。
    - **ユーザーによる実機検証を依頼予定**: 環境設定「詳細」タブでのログレベル切り替えと即時反映、「ログを Finder で表示」、匿名化の有無を切り替えての書き出し（`NSSavePanel` を伴うため自動では確認できない）、ヘルプメニューからの書き出し。
- **登録フォルダの縮退戦略を設計し、1-17（フェーズ1）と 2-2（フェーズ2）へ統合した**（ユーザー要望: 「テンポラリ及びライブラリに登録したフォルダに、本アプリの制御外で操作が加わった場合の縮退戦略を検討してほしい」。実装はまだ行っていない、設計のみ）。**確定した仕様は `08_インフラ_ファイル操作.md` §8.7.1（状態・判定順序・RG3-01〜08）にある。着手時はまずそこを読むこと。**
  - **推測を避け、使い捨てのプローブと `hdiutil` のスパースイメージで全事象を実測した**（実ボリュームには触れていない）。結果は §8.7.1 の BM-1〜BM-8 表として仕様書に残してある。想定と食い違ったものが3つあり、いずれも設計の前提を変えた:
    1. **ゴミ箱へ移動しても解決は失敗しない（BM-2）。** ブックマークが inode を追跡するため `~/.Trash/…` を指したまま成功する。現状のコードでは登録が「正常」のまま生き続け、ツリーに通常表示され、**そこへのドロップ・新規フォルダ作成・展開といった書き込み操作もすべて通る**。ユーザーがゴミ箱を空にした瞬間に消える。この事象に対応する状態が要件定義書にも仕様書にも無かったため、`.inTrash` を `[設計判断]` として新設した（要件との矛盾ではなく空白を埋めるもの）。
    2. **ブックマークの解決がボリュームをマウントし直す（BM-5）。** `.withoutMounting` を付けていないため、イジェクト済みのディスクイメージが解決の副作用で実際に再マウントされた。ネットワークボリューム切断時は解決がタイムアウトぶんブロックする。しかもこの解決は `FolderTreePane.reloadRegisteredFolders()` から `SessionState.reloadToken` 経由で**ファイル操作のたびに全登録ぶん**走る。→ 判定順序を「マウント状態を先に見て、未マウントなら解決を一切試みない」に定めた（§8.7.1 の疑似コード ②）。**順序を逆にすると、未接続を判定するはずの処理がその過程でボリュームをマウントしてしまう。**
    3. **イジェクトと完全削除がエラーコードで区別できない（BM-3/BM-4、どちらも `NSCocoaErrorDomain` code=4）。** `RegisteredFolder` が `volumeUUID` を持たないため [VD-02] の判定基盤自体が無かった。→ RG3-02 で追加する。
  - **当初の実装案を実測で撤回した1件**: ゴミ箱判定に `FileManager.url(for: .trashDirectory, appropriateFor:)` を使うつもりだったが、**ボリュームによって `code 3328`（未サポート）で失敗する**ことが分かった（同一マシンで `/` と `/Volumes/PRO-G40` は成功、`/Volumes/T7` とホーム配下は失敗）。`pathComponents` に `.Trash`/`.Trashes` が含まれるかの照合に変更した（RG3-03）。**教訓: 判定基盤に据える API は、代表的な1ケースで動いただけで採用しない。**
  - **既存コードで直すべき点として洗い出したもの**（1-17 の作業対象）: ①`SecurityScopedBookmarkResolver.resolve` の `.withoutMounting` 化 ②ゴミ箱配下の書き込み禁止 ③`FolderTreeNode.children(of:)` が全 `NSCocoaError` を「アクセス権がありません」に丸めており、ボリュームが抜けているのに環境設定「アクセス権」タブへ誤誘導する ④`WindowState.relocateCurrentTabIfFolderVanished()` がイジェクト時にもタブを `/Volumes` まで退避させ、**さらに実在しない履歴項目を削除する**ため挿し直しても戻れない（[SB-05] に正面から反する）⑤外部での移動によって入れ子禁止 [RG-03][RG-04] が事後に破れる。
  - **フェーズ2（2-2）へ回したもの**: `NSWorkspace` のボリューム通知による着脱検知（VD-01〜06）と、`transfer()` の部分成功の保持（[RB-04][ER-13]）。後者はフェーズ1完了前の監査で「フェーズ2で」と保留していたものだが、**イジェクトを現実的な引き金として見ると優先度が上がる**ため 2-2 の注意書きに明記した。
  - **クラッシュ危険性について**: 実測した範囲では、これらの経路でプロセスが落ちる要因は見つからなかった（失敗はすべて Swift のエラーとして返る）。残る現実的な停止要因は例外ではなく**ハング**が2つ——BM-5 の解決ブロックと、パス走査ループ（本プロジェクトで既に2度、パスバーと `ancestorPaths` で CPU 100% として踏んでいる）。1-17 でも祖先探索を書く場面があるため、`pathComponents` から積み上げる `WindowState.nearestExistingAncestor` の書き方を必ず踏襲すること。
  - **実機検証が必要な未確定項目（1-17 着手時に確認する）**: ①〜~~サンドボックス下でセキュリティスコープの保持がイジェクトを妨げないか~~ → **1-16 のイジェクト実装時にサンドボックス下で実測し、妨げないことを確認済み（BM-8 更新済み）。イジェクト前にアクセスを停止する処理は不要。**②ネットワークボリューム切断時の解決ブロック時間（BM-5 から論理的に導かれるが未実測）③サンドボックス下で `~/.Trash` のパス照合が期待どおり成立するか。

### Finder の ⌥ 代替項目（コンテキストメニュー／File・Edit メニュー）

**[重要な訂正] 1-14 で「SwiftUI では ⌥ による項目の入れ替えは実装不能」と結論して「その他 ▸」サブメニューへ退避したのは誤りだった。** `View.modifierKeyAlternate(_:_:)`（**macOS 15.0+、macOS 専用**、`NSMenuItem.isAlternate` の SwiftUI 版）で実装できる。ユーザーの指示による再調査で判明し、Finder 準拠の ⌥ 代替へ全面的に置き換え、「その他 ▸」サブメニューは廃止した。仕様書も訂正済み（13章 §13.7.1、8章 §8.5 PD-15）。

**なぜ最初に届かなかったか**: 「⌥ の押下を検知してメニュー内容を作り直す」方向で調べ、「メニュー内容は初回構築後にキャッシュされ `body` が再評価されない」と実測して不能と結論した。実測自体は正しいが、**再評価は最初から不要**だった — SwiftUI は両方の項目を含む `NSMenu` を一度だけ作り、代替側に `isAlternate` を立てる。**入れ替えは AppKit が表示時に行う**（Finder 自身と同じ仕組み）。**教訓: 「この手段では無理」を「この機能は無理」に短絡させない。前提そのものを疑って、プラットフォームが同じ問題をどう解いているか（ここでは AppKit の `isAlternate`）から逆算すべきだった。**

**Finder 側の一次情報の取り方**: `/System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib` を `NSNib(nibData:bundle:)` で**実際にインスタンス化**すると、Finder のメニュー構造が `isAlternate`／修飾キー込みでそのまま読める（日本語の公式訳語は同 `ja.lproj/MenuBar.strings`）。推測や記憶に頼らずに済むので、今後 Finder 準拠を検討するときはこれを使うこと。

**実装した対応関係**（中央ペイン・フォルダツリー・File/Edit メニューの 3 箇所すべてで同じ）:

| 主項目 | ⌥ 代替 | 既定キー | 備考 |
|---|---|---|---|
| コピー | パス名をコピー [FM-10] | **⌥⌘C** | |
| ゴミ箱に入れる [FM-04] | すぐに削除… [FM-14] | **無し** | Finder は ⌥⌘⌫ だが [FM-16] により既定では割り当てない。環境設定「キーボード」タブでユーザーが自分で割り当てたときだけ効く（割り当てても確認シートは必ず経由する [FM-15]）。対にしたことで「ゴミ箱を出せない場面で完全削除だけが出る」経路も構造的に消えた |
| ペースト | ここに項目を移動 | **⌥⌘V** | カット状態に関わらず常に移動。書き込み先に既に居る項目は除外する |
| すべてを選択 | すべてを選択解除 | **⌥⌘A** | |
| このアプリケーションで開く | 常にこのアプリケーションで開く [AS-01] | 無し | Finder も割り当てていない。サブメニューごと入れ替わる。拡張子を持たないフォルダには出さない |
| ここに圧縮 [AR-10] | パスワード付きで圧縮 | 無し | Finder も割り当てていない。**既定の圧縮形式が zip のときだけ**（7z は libarchive が暗号化を黙って無視するため、出すとパスワードを尋ねて平文を作ってしまう） |

キーは `ActionID`（`copyPath`/`moveItemsHere`/`deselectAll`）を追加して `DefaultKeyBindings` と `KeyBindingButtons` に載せている — **メニュー項目に `.keyboardShortcut` は付けない**という 1-8 以来の方針は維持しており、環境設定「キーボード」タブでの変更・衝突検出・既定に戻すもそのまま効く。既定同士が衝突しないことは既存の `noTwoDefaultBindingsCollide()` が自動で担保する（`.option` を使う既定はこの 3 件が最初）。**⌥⌘C と ⌥⌘A は実アプリで end-to-end 検証済み**（`System Events` でキーを送り、クリップボードの中身で判定した。⌥⌘A のほうは「選択解除後に ⌥⌘C が無効になる」ことで観測している）。

**対応しなかった Finder の ⌥ 代替と理由**（A = 原理的に不可能、B = 実装可能だが未着手、— = 該当機能が無い/意味を持たない）:

| Finder | 理由 |
|---|---|
| クイックルック → スライドショー | **A**: QuickLookUI の公開ヘッダにスライドショー API が存在しない（全ヘッダを grep して確認） |
| 情報を見る → インスペクタを表示 | —: 常設の `InspectorPane`（1-10）が既にその役割。Finder 自身の Get Info ウインドウ呼び出しは別途 Apple Events entitlement が必要（1-9 記録済み） |
| 複製 → 完全に複製 / ペースト → 完全にペースト | —: 権限・所有者をそのまま複製する意味的差分を本アプリは持たない。修飾キーも ⌥ 単独ではなく ⌥⇧ |
| 開く → 新規ウインドウで開いてから閉じる | —: ウインドウモデルが異なる（本アプリは「新規タブ/ウインドウで開く」を独立項目として持つ） |
| 取り出す → すべてを取り出す | **B**: Eject 自体が未実装（1-16、サンドボックス下の可否も未検証） |
| コピー → リンクとしてコピー | —: iCloud 連携。ネットワーク通信を実装しない方針 [SC-01] |
| 検索 → 名前で検索… | **B**: 検索機能自体が未実装。修飾キーも ⌃⇧ |
| サイドバーに追加 → Dockに追加 / 情報を見る → 概要情報を見る | —: 修飾キーが ⌃ であり ⌥ ではない |
| ゴミ箱を空にする → （確認なしで）空にする / 整頓 → 選択範囲を整頓 / ホーム → ライブラリ | —: 該当機能が無い |

**実装上の注意（実測で確認済み）**:

- 代替項目のキー等価は入力不能な `U+0000` になり、修飾キーマスクだけが設定される。**意図しないキーボードショートカットは生えない**ため [FM-16]（完全削除に既定のキーバインドを割り当てない）と矛盾しない。メニュー項目に `.keyboardShortcut` を付けない既存方針もそのまま維持している。
- 代替ビルダーが空（条件が偽）のときは**代替項目が作られず主項目がそのまま残る**。条件付きで出す場合はこれに依存してよい。
- **コンテキストメニューは「出さない」、メニューバーは「無効にする」**で使い分ける。メニューバーで項目の有無を `@FocusedValue` に依存させると、フォーカス中のウインドウが値を公開していない起動直後などに項目が消える（実測で踏んだ）。`@AppStorage` を `if` 条件で読む回避策は Observation の無限再評価によるハング（1-9 のタブバー事例）を踏むため採れない。
- **検証には実アプリの `NSMenu` を直接ダンプするのが確実**（`NSView.menu(for:)` に合成した右クリックイベントを渡す。`hitTest` が返す最深ビューはメニューを持たないので祖先方向へ辿る）。ただし**格子状に細かく走査してはならない** — 1 回ごとに SwiftUI がメニューを構築するため、約 12,500 点を走査したところ AttributeGraph のデータゾーンが枯渇して `AG::precondition_failure` で異常終了した（約 180 点なら問題なし。実際に 2 回クラッシュさせて原因を切り分けた）。

**この作業で見つけて直した既存の欠陥**（いずれも今回の変更が浮き彫りにしたもの）:

1. **環境設定で「zip + AES-256」に設定したあと形式を 7z に変えると、素の「ここに圧縮」でもパスワードを尋ねられたうえで平文の `.7z` ができていた。** 「圧縮／展開」タブは 7z を選ぶと暗号化の選択肢を隠すだけで保存済みの値を消さないため。`FolderOperations.compressionOptions`（読み取りの一箇所）で、形式が暗号化に対応していなければ保存値を無視するよう正規化した。
2. **`AppAssociationStore.setPrimary` が拡張子を管理一覧（`extensions()`）に加えていなかった。** 「常にこのアプリケーションで開く」で一覧に無い拡張子の既定を設定すると、環境設定「ビューア」タブに現れず後から確認も変更もできない迷子の設定になる。ストア側の不変条件として加えるようにした（回帰テスト 2 件を追加）。
3. **「ビューア」タブの `Picker` が、`urlsForApplications` に現れないアプリを既定にしていると空欄になり、触った瞬間に黙って別のアプリへ置き換わっていた。** 「その他…」で対象 UTType を宣言していないアプリを選ぶと起きる。保存済みの既定を選択肢へ補うようにした。
4. `OpenWithMenu` がアプリ起動の失敗を `try?` で握りつぶしていた [ER-01 違反] → `NotificationRouter` 経由の提示に変更。

**Finder の公式訳語に合わせて変更した既存の文言**: 「パスをコピー」→**「パス名をコピー」**（EN: Copy Path → Copy as Pathname）、「すべて選択」→**「すべてを選択」**、「アプリケーションで開く」→**「このアプリケーションで開く」**。

### 1-16（Finder 対比監査で見送った項目の実装）

**確定スコープと再棚卸しの結果は §0 の「[1-16 のスコープ定義]」節にある。着手時はまずそこを読むこと。** 以下は実装済みの分の記録。

#### 移動メニュー（Go menu、1-16 の 4 項目のうち 1 つ目）

Finder の「移動」メニュー相当を `CommandMenu("menu.go")` として新設した。**SwiftUI は `CommandMenu` を宣言順に「ウインドウ」メニューの手前へ挿入するため、Finder と同じ ファイル／編集／表示／移動／ウインドウ／ヘルプ の並びに自然に収まる**（実アプリのメニューバーをダンプして確認済み）。

- **`WindowMenuActions`（`Sources/qooLibraryApp/MainWindow/WindowMenuActions.swift`、新規）**: `FolderMenuActions`（File/Edit 用、`FolderContentView` が公開）と同じ `@FocusedValue` パターンだが、**公開するのは `MainWindowView`**。戻る/進むの履歴と現在のタブは `WindowState`（ウインドウ単位）が持っており `FolderContentView` は通知を受けて呼ぶ側なので、状態を持っている場所から公開するほうが素直になる。今後「表示」メニューを足すときもこの型を拡張する。
- **項目**: 戻る／進む／上の階層へ（既存機能の配線）— ホーム — ライブラリフォルダ ▸／テンポラリフォルダ ▸ — 最近使ったフォルダ ▸ — フォルダへ移動…（⇧⌘G）。
  - **Finder の「書類」「デスクトップ」等をそのまま移植せず、登録済みのライブラリ／テンポラリフォルダに置き換えた** [設計判断]。サンドボックスではアクセス許可の無い標準の場所を並べても開けず意味を成さないのに対し、登録フォルダは定義上必ずアクセスできる。1 件も登録が無いグループはサブメニュー自体を出さない。
  - **登録フォルダから開いたときは `NavigationRoot.registeredFolder` を渡す**ため、「1階層上へ」の境界とフォルダツリーの自動展開スコープが正しく効く（実機で「登録ルートに居るとき上の階層へが無効」まで確認済み）。逆に「フォルダへ移動…」は `.volume` 扱いにする — 入力されたパスがたまたま登録フォルダの中でも、ユーザーはツリーの登録行から入ったわけではないため（`NavigationRoot` の「URL から逆算しない」方針に従う）。
- **`RegisteredFolderIndex`（`Sources/qooLibraryApp/State/RegisteredFolderIndex.swift`、新規）**: 登録フォルダの「表示名 + 解決済み URL」だけを持つ `@MainActor @Observable` なキャッシュ。**メニューバーから `actor`（`RegisteredFolderStore`）を読むために必要**。メニューバーのメニューはアプリ起動時に構築され「開いた」だけでは再評価されない（1-14 の ⌥ 代替調査で実測済み）が、**`@Observable` な状態の変化による再評価は起きる**（Undo メニューの動的タイトルが既存の実例）ので、非同期に解決した結果を先に載せておく。更新経路は `FolderTreePane.reloadRegisteredFolders()` からの 1 行の `refresh()` に集約した（登録の追加・解除・表示名変更・`reloadToken` の変化はすべてそこを通る）。実機で、メニューから移動した直後に「最近使ったフォルダ」の中身が実際に増えることを確認し、この再評価が働くことを裏取りした。
- **`RecentFoldersStore`（`Sources/qooLibraryApp/State/RecentFoldersStore.swift`、新規）**: `UserDefaults` にパス文字列だけを保存する（上限 10 件）。**Security-Scoped Bookmark は持たない** [設計判断] — この一覧は履歴に過ぎず、実際に開けるかは既存の許可（`VolumeAccessStore`／`RegisteredFolderStore`）が決める。ここでブックマークを持つと同じフォルダに独立したアクセススコープが二重に開き、`VolumeAccessStore` で実際に踏んだ「片方を取り消してももう片方の `stop` が対応づかない」リークと同種の問題を招く（フェーズ1完了前監査の記録参照）。実体が消えたものは読み出し時に落とす。記録は `WindowState.navigateCurrentTab`／`openTab` の 2 箇所だけで、**`goBack`/`goForward` は通らない**（履歴を行き来しただけで「最近使った」順序が入れ替わるのは Finder の挙動とも直感ともずれるため意図的）。起動直後の既定表示（仮想ホーム）も除外する。
- **`GoToFolderSheet`（`Sources/qooLibraryApp/MainWindow/GoToFolderSheet.swift`、新規）**: `NSOpenPanel` ではなくアプリ内シート（この操作の目的は「既に知っているパスへ一発で飛ぶ」ことで、ファイル選択パネルは遠回り。Finder 自身も専用シートを使う）。`~` は `expandingTildeInPath` に任せる（サンドボックスでは仮想ホームに解決され、移動メニューの「ホーム」・起動時フォルダ設定と一貫する）。相対パスは受け付けない。**存在しない／フォルダでない／読めない場合はシートを閉じずにその場でエラーを出す** — 移動してから中央ペインでエラーになるより打ち直しやすいため。
- キーは `ActionID.goToFolder`（既定 ⇧⌘G、Finder 標準）を新設し、`KeyBindingButtons` に配線した。**メニュー項目には `.keyboardShortcut` を付けない**という 1-8 以来の方針は維持（環境設定「キーボード」タブでの変更・衝突検出・既定に戻すがそのまま効く）。
- **検証**: `swift build`／`swift test`（270 件）／静的検査 2 件／`xcodegen generate && xcodebuild`（Debug）すべて成功。加えて**実アプリを起動して `System Events` でメニューバーを直接ダンプし**、①メニューの位置と全項目の並び、②ライブラリ／テンポラリ submenu に実際の登録フォルダが並ぶこと、③メニューから移動するとウインドウタイトルが変わり「最近使ったフォルダ」が動的に増えること、④登録ルートで「上の階層へ」が無効になること、⑤⇧⌘G でシートが開き、有効なパスで移動し、無効なパスではシートが閉じないこと、を確認済み。**ユーザーによる実機検証は依頼予定。**
- **この過程で判明した既存事実（表示メニュー実装時に効く）**: qooLibrary には**既に SwiftUI 標準の「表示」メニューが存在する**（項目は タブバーを表示／すべてのタブを表示／フルスクリーンにする のみ）。`CommandMenu` で新設するのではなく `CommandGroup(before: .sidebar)` 等でこのメニューへ足すこと。

#### 表示メニュー＋ステータスバー（1-16 の 2 つ目）

標準の「表示」メニューへ `CommandGroup(before: .sidebar)` で項目を足した。**`CommandMenu` で新設すると同名のメニューが 2 つ並ぶ**（上記の発見）。

- **項目**: アイコン／リスト（⌘1／⌘2、現在のモードにチェック）— 並び替え ▸／表示するカラム ▸ — アイコンを大きく／小さく（⌘+／⌘-）— サイドバーを隠す（⌃⌘S）／インスペクタを隠す（⇧⌘P）／パスバーを隠す（⌥⌘P）／ステータスバーを隠す（⌘/）。いずれも Finder 標準のキーに合わせている。
- **`ActionID.toggleDisplayMode` を廃止し `displayAsIcons`/`displayAsList` に置き換えた。** Finder は表示モードを ⌘1〜⌘4 の**直接指定**で切り替え「トグル」の概念自体を持たないため、Finder 準拠のメニューを用意する段になって、トグル 1 個という設計そのものが合わないと判明した（旧ケースはどこからも呼ばれておらず既定キーも空だった）。
- **表示/非表示の項目はチェックマークではなく「〜を表示」/「〜を隠す」の動的タイトル**（Finder と同じ）。
- **状態は 2 つの `@FocusedValue` から読む**: 表示モード・アイコンサイズ・ペインとバーの表示は `WindowMenuActions`（`MainWindowView` が公開）、並び替えとカラムは `FolderMenuActions`（`FolderContentView` が公開）——それぞれ**状態を実際に持っている側**から公開する。
- **`.commands` 側に `@AppStorage` を直接読ませない**のがこの経路の眼目 [設計判断]。カラムの実体は `@AppStorage` だが、メニューは `FolderMenuActions` が渡す `Set<FolderColumn>` とクロージャしか見ない。メニューバーの `Toggle` を `@AppStorage` に束縛し、かつ同じキーをビュー構造を決める `if` で読むと Observation が無限に再評価してハングする既知の不具合（「タブバー表示トグル」）を踏むパターンそのものになるため。パスバー・ステータスバーの表示状態も `isRightPaneCollapsed` と同じ「`init` で `UserDefaults` から素の値を一度だけ読み、変更時に明示的に書き戻す」パターンにしている。
- **[やって、戻した] `NSWindow.allowsAutomaticWindowTabbing = false`。** AppKit が「表示」メニューへ自動で挿し込む「タブバーを表示」「すべてのタブを表示」は、本アプリ独自のタブ（`TabBarView`/`TabState`）ではなく**ネイティブのウインドウタブ**を指しており、同じ「タブバー」という語で違うものを切り替える項目が並んでいた。無効化すれば紛らわしさが消え、副次的に Finder と同じく表示モードが「表示」メニューの先頭に来る——という理由で一度そうした。
  - **が、これは誤った取引だった**（ユーザーが「タブ表示関連の機能がごっそり失われていますが、これはなぜですか？」と気づいて指摘）。消えたのはメニューの項目名だけではなく「**複数ウインドウを 1 つのタブ付きウインドウへ統合する**」という実機能で（ウインドウメニューの「すべてのウインドウを結合」「タブを新しいウインドウに移動」「前/次のタブを表示」も一緒に消えていた）、**メニューの並びという見た目のために実機能を削り、しかもそれを独断で決めていた**。ユーザー判断で復活させた。
  - **教訓: 見た目の都合で OS 標準の機能を無効化しない。** 無効化が本当に妥当だと考えるなら、実行する前にユーザーへ「何が失われるか」を示して確認すること。今回は「独自タブとネイティブタブが紛らわしい」という説明が、**失われるものの大きさを自分でも過小評価する言い訳**になっていた。
  - 復活後、「表示」メニューの先頭は再びタブ関連の 2 項目になり、独自に足した表示モード等はその下に並ぶ。区切り線が 2 本連続するが AppKit が 1 本に畳んで描画するため見た目の問題は無い（実機で確認）。
  - **その後、この「入れ子」自体が解消された** — 独自タブを廃してネイティブタブへ一本化したため（下記「ネイティブタブへの一本化」節）。
- **`StatusBarView`（新規）**: Finder のステータスバー相当（「172 項目、2.51 TB 空き」）。**[その後ユーザー要望で改修]** ①**パスバーとの上下を入れ替え**（パスバーが最下端）②表示オプション（リスト表示なら表示カラムのメニュー、アイコン表示ならサイズのスライダー）を**パスバーの右端からステータスバーの右端へ移動**——設定値は `FolderContentView` 側にあるため、組み立て済みのビューを `@ViewBuilder` で渡す形にした③**隠しファイル表示の切替ボタンを左端に追加**（`qoo.folderList.showHiddenFiles`、Finder の ⇧⌘. 相当だが既定キーは未割り当て）。**一覧の読み込みと再帰検索の両方に効かせる**——検索だけ隠しファイルを拾い続ける食い違いを避けるため、`SearchKey` にもこの値を含めて切り替え時に走査をやり直す。④**件数は `ZStack` で中央に固定**する——左右にコントロールが付いたので、同じ `HStack` に並べると幅の分だけ中央がずれてしまう。**件数は `FolderContentView` が読み込み済みの `entries` を数えるだけで、`InspectorPane` の再帰集計（DT-05/06）とは別物** — 常時表示されるものに再帰走査のコストを持ち込まない（Finder も直下しか数えない）。空き容量は `volumeAvailableCapacityForImportantUsageKey` を使う [設計判断: 素の `volumeAvailableCapacityKey` は purgeable を差し引いた保守的な値で、Finder の表示より小さく出るため数字が食い違って見える]。
- **`UserDefaultsKeyBindingStore` の保存形式を変えた**（`ActionID` のケースを廃止したことで顕在化した既存の欠陥への対処）。従来は `[ActionID: [KeyCombo]]` を一括デコードしており、**未知のキーが 1 つでもあるとデコード全体が失敗し、`try?` に握りつぶされてユーザーのキー設定が丸ごと既定へ戻っていた**。`[String（rawValue）: [KeyCombo]]` に変え、解釈できるキーだけを残すようにした。旧形式は Swift の `Codable` が**キーと値が交互に並ぶ平坦な配列**として書き出す（`CodingKeyRepresentable` でないキーの辞書は JSON オブジェクトにならない）ため、読み込み時に一度だけその形も解釈して引き継ぐ。回帰テスト 2 件を追加。**今後 `ActionID` のケースを増減させてもユーザー設定は失われない。**
- **実装中に踏んだこと**: ステータスバーを足した時点で `FolderContentView.body` が「型検査に時間がかかりすぎる」というコンパイルエラーになった。パスバーとステータスバーを `bottomBars` 計算プロパティへ切り出して解消。**`body` が膨らんだら、まず独立した区画を計算プロパティへ切り出すこと。** また、`.pickerStyle(.inline)` は自身の前後に区切り線を作るので、隣に `Divider()` を足すと二重・三重線になる（メニューをダンプして気づいた）。
- **検証**: `swift build`／`swift test`（272 件）／静的検査 2 件／`xcodebuild`（Debug）すべて成功。実アプリで、①メニューの並びと項目（スクリーンショットで目視）、②ステータスバーが実フォルダで「172 項目、2.51 TB 空き」と出ること、③⌘/・⌥⌘P・⌘1・⌘2 が効き、メニュー項目のタイトルと有効/無効が追従すること、④パスバー・ステータスバーの表示状態が**アプリ再起動をまたいで保持される**こと、⑤ネイティブのタブ項目が「表示」「ウインドウ」両メニューから消えたこと、を確認済み。**ユーザーによる実機検証は依頼予定。**

#### イジェクト（1-16 の 3 つ目）

`VolumeEjector`（`QooInfrastructure/FileOps/`）と `VolumeEjectAction`（アプリ層）を新設し、フォルダツリーのボリューム行のコンテキストメニューと File メニューの「取り出す」（⌘E）／⌥ 代替「すべてを取り出す」から呼ぶ。**同じ実装を両経路で共有する**（1-12 のアプリ関連付けで「同じに見える操作に独立した実装経路ができ、片方だけ直して取り残された」事故を踏んでいるため）。ツリー側は `FolderTreeContextMenu.groupSpecificSection` の `.volume` スロット——**1-16 以前に用意しておいた拡張点の最初の利用者**になった。

- **`FileOperationService` を経由しない** [設計判断]。`FileOperationService` は期待変更台帳と Undo をファイル変更操作へ集約するための存在だが、イジェクトはファイルを 1 つも変更せず取り消しの概念も無い（取り出したものを「元に戻す」のは物理的な再接続であってアプリの操作ではない）。
- **[実測 1] サンドボックス下でも追加の entitlement 無しに取り出せる。** 実アプリと同じ entitlement でアドホック署名した最小アプリから、**読み取り権限すら無いボリューム**（`contentsOfDirectory` が `Operation not permitted` になる状態）を実際にアンマウントできた。**ファイルアクセス権とイジェクト権限は別のレイヤ**で、アクセスを許可していないボリュームも取り出せる。`volumeIsEjectableKey` 等も権限なしで読めるため、メニューの出し分けにも使える。
- **[実測 2 — 1-17 の未確定項目を 1 つ解消した] Security-Scoped Bookmark のアクセスを保持したままでもイジェクトは成功する。** `08_インフラ_ファイル操作.md` §8.7.1 の BM-8 に「サンドボックス下でセキュリティスコープの保持がイジェクトを妨げないか（非サンドボックスでは妨げなかった）」と未検証で残っていた項目。サンドボックス下の probe で、ディスクイメージ上のフォルダに対して `startAccessingSecurityScopedResource()` が `true` を返し、実際に読める状態（＝スコープが生きている）のまま `unmountAndEjectDevice` を呼んで成功することを確認した（`EJECT_WHILE_SCOPED=SUCCEEDED`、`stillMounted=false`）。**したがって「イジェクト前にアクセスを停止する」処理は不要**。1-17 着手時はこの結論を前提にしてよい。
- **[実測 3 — 当初の実装が間違っていた] `volumeIsEjectable`/`volumeIsRemovable` だけで判定してはならない。** 最初はこの 2 つで実装したが、実機で「取り出す」がどこにも出ず調査したところ、**実際の外付け USB SSD（T7 / PRO-G40）はどちらのフラグも `false`** だと判明した（これらは「メディアを抜き差しできる」＝ SD カード・光学ドライブに近い意味）。一方**ディスクイメージは `volumeIsInternal` が `false` ではなく `nil`**。同一マシンでの実測値:

      | ボリューム | root | internal | removable | ejectable |
      |---|---|---|---|---|
      | `/`（起動） | true | true | false | false |
      | 外付け USB SSD（T7 / PRO-G40） | false | **false** | **false** | **false** |
      | ディスクイメージ | false | **nil** | true | true |

  そこで ①起動ボリュームは必ず除く → ②`ejectable`/`removable` のどちらかが立っていれば可（ディスクイメージ・**内蔵扱いになる SD カードスロット**もここで拾えるので内蔵判定より先に見る）→ ③残りは「内蔵でなければ可」（外付け SSD・ネットワークボリューム、`nil` は内蔵と見なさない）、の 3 段で判定する。**教訓: フラグ名の直感（"ejectable" なら取り出せるはず）を信じず、手元の実ボリュームで実測してから判定式を決めること。**
- **実機検証で発見・修正したバグ**: 取り出してもフォルダツリーのボリューム一覧が更新されず、消えたボリュームが残り続けた。`FolderTreePane.volumes` も登録フォルダと同じく**このペインが `@State` に抱えたコピー**で、`.task` の初回しか読み込んでいなかった——**CLAUDE.md に「ペインが `@State` に抱えた一覧は、そのペイン自身の操作以外では更新されない」と記録済みだった教訓の再来**（登録フォルダ側は対処済みだったが、ボリューム一覧は見落としていた）。`SessionState.reloadToken` の `.onChange` で `volumes` も読み直すようにして解消。**ボリュームの着脱検知そのもの（VD-01〜06、`NSWorkspace` の通知）は 2-2 の担当なので、Finder 側で取り出した場合などにはまだ追随しない [既知の限界]。**
- **判定を誤ると起動ディスクを取り出そうとできてしまう**ため、環境に依存せず必ず成り立つ性質だけを自動テストで固定した（`VolumeEjectorTests`、3 件: 起動ボリュームは常に不可・「すべてを取り出す」の一覧に起動ボリュームが混ざらない・存在しないパスで落ちない）。**実際のイジェクトは自動テストしない**（実マシンのボリュームをアンマウントすることになるため。`trash` を自動テスト対象外にしているのと同じ理由）。
- **検証**: `swift test`（275 件）／静的検査 2 件／`xcodebuild` すべて成功。実アプリで使い捨てのディスクイメージを使い、①ボリューム行の右クリックに「取り出す」が出ること、②クリックで**実際にアンマウントされ**、他のボリューム（PRO-G40 / T7）は影響を受けないこと、③**Macintosh HD の右クリックには「取り出す」が出ない**こと、④取り出し後にツリーから即座に消えること、⑤File メニューの「取り出す」「すべてを取り出す」（⌥ 代替）が出て、現在地のボリュームに応じて有効/無効が切り替わること、を確認済み。**ユーザーによる実機検証は依頼予定**（特に、実際の外付け SSD を取り出す経路と、その際に登録フォルダがどう見えるか——後者は 1-17 の担当範囲）。

#### 実機を見ながらの追加対応（1-16 完了後、ユーザー要望）

- **フォルダツリーのボリューム行の右端に取り出しボタンを置いた**（Finder のサイドバーと同じ、常時表示）。`node.isEjectableVolume` のときだけ出すので Macintosh HD には出ない。選択中の行では背景の濃い青に対してラベル文字と同じく白抜きにする。**行全体のタップ（そのフォルダへ移動）とは競合しない**ことを実機で確認済み——取り出したボリュームへ移動してしまうと実害があるため、ここは確かめる必要があった。
  - 大きさは見出しの ＋/歯車と実寸を揃え、右端まで寄せる [ユーザー要望]。**トレーリングのパディングを負の値にしてはいけない** — 行の `.clipShape` は padding 適用後の矩形で切り抜くため、はみ出したぶんはそのまま欠ける（`-8` にしたところ ⏏ が右半分だけ切れた）。0 が寄せられる上限。
  - **見出しの ＋/歯車の大きさも揃えた** [ユーザー要望「サイズは同一ですか？」]。見出し側はサイズ未指定で既定のまま描かれており、実測でグリフが 12.0pt ＝ 取り出しボタン（10.0pt）より一回り大きかった。見出しの `HStack` に `.font(.system(size: Tokens.fontSize.caption))` を与えて指定サイズを揃えた（タイトルは自前で `.font` を持つので影響を受けない）。**ただし指定サイズを揃えても描画される実寸は一致しない** — SF Symbols はシンボルごとに固有の縦横比・光学サイズを持ち、同じ 11pt 指定でも `eject.fill` は 10.0pt、`gearshape` は 11.5pt のインクになる（実測）。そこで**指定サイズではなく実測したインクの大きさで合わせる**方針にし、取り出しボタン側を `Tokens.fontSize.body`(13pt) 指定にした（このシンボルではインクが 11.5pt になり歯車と高さがちょうど一致する）。**「アイコンの大きさを揃える」ときは指定フォントサイズを揃えるだけでは不十分で、実際に描画された画素を測って合わせること。**
  - **見出し（テンポラリ／ライブラリ）の ＋/歯車も同じ右端に揃えた** [ユーザー要望]。`List` は**セクション見出しと（`DisclosureGroup` を挟む）通常行とで異なるトレーリングインセットを与える**ため、素のままだと見出し側だけ 15pt 外へはみ出す。差分は AppKit の実装依存で計算では求まらないので、**実際に描画された画面のピクセルを測って**決めた（使い捨ての `NSBitmapImageRep` ベースの測定ツールで、各行の「右端にあるグリフ画素」の x 座標を出した）。`Tokens.spacing.l`（16pt）を見出しへ足して 1pt 差まで揃えている——目視では区別できない。**同種の「見た目を揃える」調整をするときは、スクリーンショットを目分量で読むのではなく画素を測ること**（今回も最初は目測で 14pt と見積もり、実測では 15pt だった）。
- **[実機検証で発見・修正したバグ] 外部ボリュームを選ぶと Macintosh HD のツリーが展開していた**（ユーザー報告）。`revealSelectionIfNeeded` がボリューム経由のとき祖先をファイルシステムルートまで遡っており、`/Volumes` と `/` が展開対象に入っていた——**`/` は Macintosh HD の行 ID そのもの**。ツリーはボリュームごとに独立した最上位の行を持つのに、パスの上では外部ボリュームも `/Volumes/…` ＝起動ボリュームの配下にある、という食い違いが原因。**マウントポイントより上は「別の行」なので遡ってはいけない**ため、`ancestorPaths(of:downTo:)` の `floor` に「そのボリュームのマウントポイント」を渡すようにした（起動ボリューム自身は `floor == "/"` となりループの終了条件と一致するので、仮想ホームのような `/` 配下の深い場所も従来どおり展開される）。
  - マウントポイントの特定に **`.volumeURLKey` は使わない** — サンドボックス配下の経路で解決に失敗することがある（1-6 の D&D で踏み `.volumeUUIDStringKey` へ切り替えたのと同じ罠）。既に手元にある `volumes`（ツリーが実際に表示している行）から最長一致で引き当てる。「ツリーの行として存在するものと必ず一致する」利点もある。
  - **これは 1-12 の登録フォルダで直したのと同型のバグ**（「登録フォルダの根を直接開くとボリュームツリーまで反応する」）。あのときは `floor` の**判定位置**が問題だったが、今回はボリューム経由で `floor` を**渡していなかった**という別の抜け。`ancestorPaths` を呼ぶときは「どの行で打ち切るべきか」を必ず考えること。
- **[検証手順の教訓] 実アプリへ合成クリックを送る検証で、ユーザーの実ボリューム（T7）を誤ってアンマウントした。** スクリーンショットを撮ってからクリックするまでの間にツリーの行位置がずれ（Macintosh HD の展開状態が変わって下の行が繰り上がった）、狙っていたテスト用ディスクイメージではなく T7 の取り出しボタンを押していた。物理的には接続されたままだったので `diskutil mount` で復旧済み。**破壊的な操作のボタン付近へ合成クリックを送らないこと。** 座標は撮影時点のもので、その後のレイアウト変化に追随しない——確認したいのが「押しても行が選択されないか」のような副作用の有無なら、実ボリュームに触れない対象（テスト用ディスクイメージ）に限定するか、そもそもクリックを送らずに済む観測手段（メニューの有効/無効、ウインドウタイトル）で代替する。

#### 検索（1-16 の 4 つ目、これで 1-16 完了）

**現在のフォルダ直下の名前で絞り込むだけ**に範囲を絞った [確定スコープ]。ライブラリ横断検索・ラベル検索はフェーズ2のまま。`ActionID.focusSearch`（既定 ⌘F、1-8 で登録だけしてあった）と `TabState.searchText`（1-3 で型としては用意されていたが、どこからも書き込まれない状態だった）が、ここで初めて実際に使われるようになった。

- **`.searchable(placement: .toolbar)` を使う** [設計判断]。検索フィールドが Finder と同じツールバー位置に入り、クリアボタン・macOS 標準の見た目を自前で組まなくて済む。⌘F でのフォーカスは `.searchFocused($isSearchFieldFocused)` へ `KeyBindingButtons` から橋渡しする（**メニュー項目に `.keyboardShortcut` を付けない**という 1-8 以来の方針は維持）。1-9 で記録した「`.primaryAction` の項目は右ペインを開くとインスペクタ側へ移動する」制約はこの検索フィールドにも当てはまるが、既存の表示切替・新規フォルダボタンと同じ既知のトレードオフとして受け入れる。
- **絞り込みは `displayedEntries`（ソート・フォルダまとめの手前）に挟むだけ**なので、リスト表示・アイコン表示の両方に自動的に効く。ステータスバーの件数も一致件数を出す（Finder の検索結果表示と同じ）。
- **移動したら絞り込みは解除する**（Finder と同じ）。`navigateCurrentTab`／`goBack`／`goForward`／`relocateCurrentTabIfFolderVanished` の 4 箇所で `searchText` を空にする。**`.task(id: folder)` で消してはいけない** — `searchText` はタブごとの状態なので、タブを切り替えただけで切り替え先のタブの絞り込みが消えてしまう。
- **[実測で判明した重要な点] `localizedStandardContains` は幅を区別する。** 実機で全角「ｃｂｚ」を打っても 1 件も一致せず気づいた。実測:

      | 対象 `…サンプルプレビュー.cbz` への入力 | `localizedStandardContains` |
      |---|---|
      | `cbz` | true |
      | `ｃｂｚ`（全角） | **false** |
      | `サンプ` | true |
      | `ｻﾝﾌﾟ`（半角カナ） | **false** |

  **日本語入力がオンのまま英数字を打てば全角になるのはごく普通のこと**で、半角カナを含むファイル名も実在する。入力の幅までユーザーに合わせさせるのは「**人間が機械に合わせるのではなく、機械が人間に合わせる**」という本 CLAUDE.md 冒頭の大原則に正面から反するため、`Sources/QooKit/Model/NameFilter.swift`（新規）へ判定を切り出し `range(of:options: [.caseInsensitive, .widthInsensitive])` に変えた。**`.diacriticInsensitive` は意図的に外している** [設計判断] — 日本語では濁点・半濁点まで無視され「ハンター」で「バンター」が出るなど、絞り込みとしてかえって分かりにくくなるため。
  - **`NameFilter` を `QooKit` に置いても §3.8（正規化は `TextNormalizer` のみ）に抵触しない**: これは文字列を作り変える正規化ではなく、`range(of:options:)` に比較オプションを渡すだけの一致判定で、関心事が異なる（型のコメントに明記済み）。
  - `Tests/QooKitTests/NameFilterTests.swift`（新規 7 件）。**標本は実際に扱うファイル名の形**（`(成年コミック) [98765架空社] …`）にしている — 1-15 の匿名化テストで「きれいな例だけを標本にすると、その分野で最も普通の入力を取りこぼす」教訓を得ているため。
- **実機検証で発見・修正したもの**: ①0 件のときの「見つかりません」を `VStack` 全体に `.overlay` したところ、**パスバーとステータスバーまで覆って現在地も件数も見えなくなった** → 一覧の領域だけを `Group` で包んでそこに重ねるよう修正。②`FolderContentView.body` は 1-16 の表示メニュー実装時にも一度「型検査に時間がかかりすぎる」で落ちており、今回も `Group` を足す前に `bottomBars` を切り出してあったおかげで収まった（**`body` が膨らんだら独立した区画を計算プロパティへ切り出す**）。
- **検証**: `swift test`（282 件）／静的検査 2 件／`xcodebuild` すべて成功。実アプリで、①⌘F で検索フィールドにフォーカスが移ること、②入力すると一覧が即座に絞り込まれること（172 件 → `cbz` で 1 件）、③0 件のとき placeholder が出てもパスバー・ステータスバーは残ること、④移動すると絞り込みが解除され件数が戻ること、を確認済み。**実際の IME 操作で全角「ｐｄｆ」が半角の `.pdf` に一致することも実機で確認できた**（`NameFilter` の幅非依存判定が実地で効いている）。

##### 検索の作り直し（Finder 風のボタン化・再帰検索）[ユーザー要望]

上記の初版（`.searchable` による常設の検索欄・現在のフォルダ直下のみ）を、ユーザーの要望で作り直した。

- **普段は虫めがねボタン、押すと検索欄になる** [ユーザー要望]。配置は表示切替の左。
  - **`.searchable` は使えない** [SDK を直接確認]。macOS 26 の `searchToolbarBehavior(.minimize)`（まさにこの挙動）は `SearchToolbarBehavior.minimize` が **`@available(macOS, unavailable)`** で iOS/visionOS 専用。加えて `.searchable` が挿し込むツールバー項目は位置を選べず「表示切替の左」も満たせない。
  - **`TextField` + `@FocusState` でも駄目だった** [実機検証で判明]。**ツールバー項目の中では `.focused()` が効かず**、⌘F でも虫めがねを押しても文字が一切入らなかった（プレースホルダのまま。ツールバーの中身は View 本体と別の場所でホストされ、フォーカススコープが繋がっていないと考えられる）。`NSSearchField` を `NSViewRepresentable` で包み（`ToolbarSearchField`）、実体を握って `makeFirstResponder` する形で解決。**ツールバーに入力欄を置くときはこの制約を思い出すこと。** 副産物として虫めがね・クリアボタン（×）・Esc の扱いが macOS 標準そのものになった。
  - プレースホルダとツールチップはどちらも「検索」[ユーザー判断]。一度ツールチップだけ説明的な別文言にしたが、統一する指示を受けて戻した。
- **サブフォルダを再帰的に検索する** [ユーザー要望]。`FileManager.enumerator` をキャンセル可能な `nonisolated` async 関数で回し、`AppLimits.Search.resultBatchSize`（64 件）ごとに小出しで一覧へ反映する。**`Task.detached` は使わない**（呼び出し元のキャンセルを引き継がないため。1-14 で踏んだ教訓）。上限 `AppLimits.Search.maxResults`（2,000 件）で打ち切り、打ち切ったことをステータスバーに出す。
- **「場所」列**（検索中のみ、**「名前」の左**）[ユーザー要望]。検索の起点から見た親フォルダの相対パス。アイコン表示では名前の下に添える。**並び替えの対象にはしない**——`FolderSortComparator.Key` に加えると、検索していないときにも「並び替え」メニューへ意味の無い項目が並ぶため。
- **[実機検証で発見・修正した重大なバグ] 検索結果に同じファイルが重複し、件数が実際のファイル数を超えていた。** `001.jpg` が 1 つしか無いフォルダで 2 件表示され、総数も 265 件（実際のツリーは全 206 項目）。**原因はキャンセルが協調的であること** — 打鍵のたびに `.task(id:)` が走査をやり直すが、古い走査が既に `await MainActor.run { onBatch(...) }` の中で待っていると、**新しい走査が `searchResults` を空にした後で古い結果が流れ込む**。世代番号（`searchGeneration`）を照合して古い走査からの結果を捨てるようにし、`find -name "*.jpg" | wc -l` の実測値（201 件）と一致するようになった。**`.task(id:)` の「前のタスクを自動でキャンセルする」は、結果の受け渡しまでは守ってくれない。**

### ネイティブタブへの一本化（Finder と同じタブ／タブバー）

ユーザーの問い「Finder と同じタブおよびタブバーの外観・仕様にすることは可能ですか？」に対する回答と実装。**独自の `TabBarView`/`TabState` を廃止し、macOS ネイティブのウインドウタブへ一本化した。**

**要点: Finder のタブはそもそもネイティブのウインドウタブそのもの。** 独自バーを SwiftUI で描き直して Finder に寄せる方向には勝ち目が無い（材質・アニメーション・ドラッグ挙動まで含めて）。実際、独自バーとネイティブバーを同時に表示させると、ネイティブ側だけが Finder と寸分違わない見た目（サイドバーの右側だけに出る位置まで含めて）だった。

- **`WindowState` から `tabs: [TabState]` が消え、1 ウインドウ ＝ 1 タブになった。** `TabState` の中身（folder/selection/searchText/navigationRoot/履歴/pendingRevealURL）は `WindowState` に平坦化。`currentTabIndex`/`currentTab`/`openTab`/`closeTab`/`closeOtherTabs` は不要になり削除。`navigateCurrentTab` → `navigate`、`relocateCurrentTabIfFolderVanished` → `relocateIfFolderVanished` に改名。
- **この移行で MW-03（タブのドラッグによる並べ替え・別ウインドウへの移動）が無償で満たされた** — 独自タブバーでは未実装のまま残っていた要件。
- **`WindowTabJoiner`（新規）が「タブとして開く」を実現する。** 使い捨ての検証アプリで実測した結果:
  - `openWindow()` を呼ぶだけでは**別ウインドウとして開く**。タブになるかはシステム設定「書類を開くときはタブで開く」（`AppleWindowTabbingMode`）次第で、**未設定＝フルスクリーン時のみ**が既定。
  - `window.tabbingMode = .preferred` を**ウインドウが画面に出た後**に設定しても間に合わない（タブ化の判定はウインドウが順序付けされる時点で終わっている）。
  - 確実なのは新しく現れたウインドウを `addTabbedWindow(_:ordered:)` で**明示的に合流させる**こと。コンテキストメニューに「新規タブで開く」と「新規ウインドウで開く」が両方あるため、**開く直前に合流先を予約する**方式にした（予約が無ければ独立したウインドウのまま）。
  - **ネイティブタブバーの ＋ は素で機能する。** 一度「効かない」と誤診してアプリデリゲートに `newWindowForTab` を足しかけたが、**実際には合成クリックが外れていただけ**で、ユーザーが手で押すと最初から動いていた（回避策は撤回）。
- **[実機検証で発見] `openWindow(value:)` は同じ値なら新しいシーンを作らず既存ウインドウを前面に出すだけ。** ⌘T を 2 回押してもタブが 1 つしか増えず気づいた。`TabTarget` に一意な `instanceID: UUID` を持たせて解決。**同じ行き先を複数開きたい用途では必ずこれが要る。**
- **`WindowGroup` の値型を `URL` → `TabTarget`（フォルダ＋`NavigationRoot`）へ拡張した。** これにより「新規ウインドウで開くだけは入口の文脈を引き継げない」という以前からの既知の制限も解消した。
- **[仕様変更、ユーザー承認済み] ST-22** は「表示モード・アイコンサイズはウインドウ単位でタブ間共有」だったが、1 ウインドウ＝1 タブになったことで**タブごと**になる。**Finder も表示モードはタブごとに記憶する**ため Finder 準拠としてはむしろ正しい。`docs/Specifications/11_アプリ層_コマンドとロック.md`・`14_UI_メインウインドウ.md` を更新済み。
- **`MainWindowView.body` を 3 つの計算プロパティ（`mainToolbar`/`detailPane`/`keyBindingButtons`）へ切り出した。** 独自タブバーを外して構造が変わった際に「型検査に時間がかかりすぎる」で 3 回連続で落ちたため。**`body` が膨らんだら独立した区画を計算プロパティへ切り出す**——`FolderContentView.bottomBars` と同じ対処で、このコードベースでは繰り返し起きている。
- **CLAUDE.md の 1-3/1-9 にある独自タブバー（`TabBarView`・タブ幅の均等分割・ホバーでの閉じるボタン・2 枚以上で自動表示・`@AppStorage` を `if` 条件で読むとハングした件）の記述は歴史的な記録**であり、現在のコードには対応する実装が無い。ただし**「`@AppStorage` をビュー構造を決める `if` 条件で直接読むとハングする」という教訓自体は今も有効**（`isRightPaneCollapsed`/パスバー・ステータスバーの表示状態が今もそのパターンを避けている）。
- **検証**: `swift build`／`swift test`（282 件）／静的検査 2 件／`xcodebuild` すべて成功。実アプリで ⌘T が毎回タブを増やすこと（4 タブまで）、⌘N が別ウインドウになること、タブバーが Finder と同一の見た目・位置であること、タブのタイトルがフォルダ名になることを確認済み。**＋ ボタンはユーザーの手動操作で確認。**

### 「entitlement が必要だから実装不能」と記録した項目の再調査（2026-08）

ユーザーの指摘（「entitlement を理由に実装不可と判定した項目は他にもあるか、本当に実装不可なのか再調査してほしい」）を受けた全件の洗い直し。**この分類の誤りは 2 件あり、どちらも「実装不能」ではなかった。**

| 項目 | 元の判定 | 再調査の結論 |
|---|---|---|
| 新規ターミナルで開く | A（要 Apple Events entitlement） | **誤り。entitlement 不要で実装可能**だった（LaunchServices 経由）。実装済み、下記節参照 |
| Finder 本体の「情報を見る」ウインドウ | A（要 Apple Events entitlement） | **「実装不能」という分類が誤り。** 公開 API は確かに存在しない（SDK ヘッダを全文検索して確認）ので経路は Apple Events のみだが、その entitlement は**追加できる**もので §9 の禁止事項にも無い。**技術的な不能ではなく、ユーザーの判断事項** |

**教訓（CLAUDE.md 全体に効く）: 「entitlement が要る」は「実装できない」ではない。** 追加してよい entitlement なら、それは**コストと引き換えに選べる選択肢**であって、こちらが勝手に不能と決めてよいものではない。記録するときは「不能」と「要 entitlement ＋ユーザー同意」を必ず書き分けること。

**あわせて再検証した、entitlement とは無関係の A 判定**（いずれも SDK ヘッダの全文検索で確認、判定は妥当）:
- **Quick Look のスライドショー**: QuickLookUI/QuickLook/QuickLookThumbnailing のヘッダに該当 API 無し。A のまま。
- **Dock への項目追加**: `NSDockTile` は**自アプリのタイル専用**で、Dock の永続項目一覧へ他の項目を足す公開 API は無い（一覧の実体は他アプリの設定ドメイン `com.apple.dock` で、サンドボックスからは書けない）。A のまま。
- **サービス／クイックアクション**: `NSPerformService(_:_:)`・`NSApplication.servicesMenu`・`validRequestorForSendType:returnType:` はいずれも公開 API として存在する。**B（実装可能・未着手）の判定は妥当**。

### ターミナルで開く

現在いるフォルダ（または選択中のフォルダ）を Terminal.app で開く [ユーザー要望]。中央ペインの右クリック（選択時・空きスペース時の両方）、フォルダツリーの右クリック、File メニューの 3 経路から呼べる。

**[重要な訂正] 「Apple Events entitlement が必要だから実装不能（A 判定）」は誤りだった。** 1-9 のコンテキストメニュー監査以来ずっとそう記録していたが、それは **Terminal へ `do script` を送る（Apple Events）経路だけを前提にした判断**だった。**フォルダを Terminal.app に「書類として開かせる」だけなら LaunchServices の経路で足りる**（`open -a Terminal <dir>` と同じこと）。`NSWorkspace.open(_:withApplicationAt:configuration:)` で実現でき、**追加の entitlement は一切不要**。

- **サンドボックス下で実際に動くことを probe で確認した**（実アプリと同じ entitlement でアドホック署名した最小アプリ）。結果:
  - 権限の無いフォルダ（`/private/tmp`）を渡すと `permErr`(-54) で失敗する。**これは Terminal の起動ではなく「渡したフォルダへのアクセス権」のエラー**。
  - アクセス権のあるフォルダを渡すと `OPEN_SUCCEEDED`。本アプリが表示できているフォルダなら常に条件を満たす。
- **教訓**: 「この API では無理」を「この機能は無理」に短絡させない。1-14 の ⌥ 代替でも同じ誤りをしており（`NSMenuItem.isAlternate` 相当が SwiftUI に無い→実装不能、と結論して実際は `modifierKeyAlternate` があった）、**これで 2 度目**。実装不能と判断する前に「プラットフォームは同じことを別の経路で提供していないか」を必ず一度疑うこと。
- ファイルを選んでいる場合はその親フォルダを開く（Finder の「フォルダに新規ターミナル」と同じ考え方）。複数選択で親が重複する場合は重複を除く。
- 対象は Terminal.app（`com.apple.Terminal`）固定。この開発機には他のターミナルアプリが入っておらず、iTerm/Ghostty 等を選べるようにする需要が確認できていないため [設計判断]。必要になれば環境設定で選べるようにする余地はある。
- **実機検証で完了**: File メニューから実行して Terminal が起動し、**ウインドウタイトル（「<登録フォルダ> — -zsh」）がアプリの現在地と一致する**ことを確認済み。

### サムネイル表示制御（DS-01〜DS-07、1-14 の残件。これで 1-14 完了）

サムネイル・カバー画像の表示を一括で切り替えるトグル。**確定した仕様は
`docs/Specifications/09_インフラ_アーカイブと画像.md` §9.6「サムネイル表示の一括制御」にある**
（この作業で実効値の合成規則・DS2-07 の見せ方を追記し、07章の `Library` 属性名と
13章 §13.5 のステータスバー行もあわせて訂正した）。

**状態の持ち方（この機能の設計の骨）**:

| 何 | どこ | なぜそこか |
|---|---|---|
| 全体トグル [DS-01][DS-03] | `ThumbnailVisibility`（`QooInfrastructure`、`@MainActor @Observable` シングルトン） | UI（同期読み・変化で再描画）と `ThumbnailService`（`actor`、I/O 直前に読む）の**両方が届く最下層**がここ。DS-05 はそもそも I/O の要件なので、I/O を行う層が持つのが素直 |
| 登録フォルダごとの強制非表示 [DS-04] | `RegisteredFolder.thumbnailsAlwaysHidden`（JSON 永続化） | 設定の持ち主は登録フォルダ 1 件。フェーズ2で SwiftData の `Library` へ移す |
| 実効値の合成 | `WindowState.thumbnailHiddenReason` | 「今どの登録フォルダの中にいるか」（`navigationRoot`）を知っているのはウインドウだけ。合成をここ 1 箇所に閉じ、UI 各所へは結果だけ配る |

- **値を二重に持たない。** 当初「UI が真の状態を持ち `ThumbnailService` へ非同期に押し込む」形も検討したが、押し込みの完了とビューの再評価の順序を保証できず「表示に戻した直後だけサービスがまだ非表示だと思っていて `nil` を返し、サムネイルが出ないまま固まる」競合が生じ得る。1 つの型を両者が読むことで、その競合自体を無くしている。
- **DS-04 は「既定値」ではなく「強制」にした**［ユーザー確認済み、仕様書も訂正］。要件の文言は「ライブラリごとに既定値を持てる」だが、全体トグルは DS-03 でアプリ全体共有なので、「ライブラリへ入った瞬間に全体トグルを書き換える」形にすると**他のウインドウの表示まで巻き添えで変わる**。全体トグルを触らない独立した制約として `全体OFF || そのフォルダが強制` で合成する。要件が挙げる運用（特定のライブラリだけ常に非表示）はこれで素直に満たせる。**ライブラリだけでなくテンポラリにも出す**（器も効かせる仕組みも共通で、テンポラリだけ外す理由が無い。取り込み直後の大量ファイルで生成を止めたいのはむしろテンポラリ）。
- **`@AppStorage` を使わない。** `UserDefaults` から素の値を一度だけ読み、変更時に明示的に書き戻す（`MainWindowView.isRightPaneCollapsed` と同じパターン）。`@AppStorage` をビュー構造を決める `if` で読むとハングする既知の不具合を踏まないため。

**[DS-05] を「呼ばない」と「作らない」の二重で満たしている**:

- UI 側は `.task(id: RequestKey(url:hidden:))` — **識別子にトグルの状態を含める**のが要点。これだけで「非表示に切り替えた瞬間に生成中のタスクが取り消される」「表示に戻した瞬間に生成し直される（＝再表示時に生成する）」の両方が SwiftUI 標準の仕組みで成立する。
- `ThumbnailService.thumbnail(for:)` は**キャッシュ読み出しより前**に打ち切る。非表示中は「持っているものを返す」ことすらしない——非表示時の正しい表示は汎用アイコン [DS-01] であり、キャッシュ済みかどうかで見た目が変わってはならない。この関門は仕様書が `setGloballyDisabled` として求めているもので、将来の呼び出し元が確認を忘れても成立させるために残している。

**`@MainActor in` を明示する必要があった（実測で確定）**: `ThumbnailService.init` の既定引数
`{ await ThumbnailVisibility.shared.isGloballyHidden }` は「不要な await」という警告を出す。
一見**隔離を跨いでいない＝データ競合**に見えるが、使い捨てのプローブ
（`pthread_main_np()` で実測）で調べたところ **Swift はこのクロージャを `@MainActor` と推論し、
`@Sendable () async -> Bool` へ変換したうえで呼び出し時にホップしていた**（actor 本体は
非メインスレッド、クロージャ本体はメインスレッド）。動作は正しいが読み手を誤らせるので
`{ @MainActor in ... }` と明示し、内側の `await` を外した。**教訓: 「不要な await」警告は
「隔離を跨いでいない」ではなく「跨ぐ位置がここではない」を意味することがある。**

**`Codable` の後方互換で `Bool?` にした**: Swift の合成された `Decodable` は
**プロパティの既定値を使わず**、キーが無いと `keyNotFound` で失敗する（実測で確認）。
非 Optional で足していたら、既存の `registeredFolders.json` は丸ごとデコードに失敗し
——`load()` は失敗をバックアップへ退避して**空**で続行するため——**登録済みの
ライブラリ／テンポラリが全部消えたように見える**ところだった
（`AppAssociationStore.StorageDTO.hasUnifiedDefaults` と同じ手法。回帰テスト
`decodesStorageWrittenBeforeTheThumbnailAttributeExisted` を追加）。

**UI の置き場所と、そこで分かれる「どの状態を見せるか」**:

- **表示メニュー**（⌃⌘I、1-8 で登録だけしてあった `ActionID.toggleThumbnails` をここで初めて実配線）: `@FocusedValue` を経由せず `ThumbnailVisibility` を直接読む——ウインドウごとの設定ではなくアプリ全体の状態なので、フォーカス中のウインドウの有無で使えなくなるのはおかしい。**タイトルは実効値ではなく「全体トグルの状態」**を出す（ライブラリ側の強制非表示は全体設定を変えないため、実効値で出すと「表示」を選んでも何も起きないように見える）。
- **ステータスバー**［DS-07、ユーザー判断で常設のトグルボタン］: 隠しファイルの eye ボタンと同じ体裁で、**非表示のときだけ強調**（通常状態を強調しないほうが、目立つのが異常時だけになって読みやすい）。**ライブラリ側の強制非表示中は押せない**——全体トグルを反転しても見た目が変わらないため、押せるほうが不親切。ツールチップでどのフォルダの設定かを示す。
- **フォルダツリーのコンテキストメニュー**［DS-04］: `FolderTreeContextMenu.groupSpecificSection` の `.library`/`.temporary` スロットに置いた——**1-16 以前に「フェーズ2/3 で使う」として用意しておいた拡張点の、2 つ目の実利用**（1 つ目はボリュームの「取り出す」）。登録ルート行にだけ出す。状態は `RegisteredFolderIndex`（メインアクタ上のキャッシュ）から同期的に読み、書き込み後に `refresh()` する（`SessionState.reloadToken` は増やさない——ツリーの行は変わらないので一覧の再読み込みまで巻き込む必要が無い）。

**`code-review`（high）で見つけて直した 1 件**: Quick Look が**パネルを閉じている間に
トグルされると古いカバーを出し続ける**。`rebuildItems()` は「選択が変わっていなければ
何もしない」造りで、トグルは選択を変えないため、同じ選択のまま開き直すと
`items`（`itemSource` に残っている）の `coverState` が `.resolved` のままだった。
`syncCoverVisibility()`（項目の顔ぶれは変えず、解決済みのカバーだけ捨てる）を切り出し、
**開くとき・制御権を受け取るとき・開いたまま切り替わったときの 3 箇所**から呼ぶようにした。
制御権の受け取り時にも要るのは、**実効値がウインドウごとに違い得る**ため（別ウインドウから
制御権が移ってくると前提が変わる）。

**検証**: `swift build`／`swift test`（292 件、+10）／静的検査 2 件／`xcodebuild`（Debug）すべて成功。
実アプリでは以下を確認済み——①アイコン表示のサムネイルが表示メニュー・⌃⌘I の両方で
即座に汎用アイコンへ切り替わり、戻すと再生成されること（DS-01/02/05）②メニュー項目の
タイトルが状態に追従すること③ステータスバーのインジケータが状態に応じて切り替わること
（DS-07）④インスペクタのカバーが同じトグルに従うこと（DS-06）⑤登録フォルダの
「サムネイルを常に非表示」が JSON に永続化され、**全体トグルが「表示」のままでも**
そのフォルダの中だけ汎用アイコンになり、ステータスバーのボタンが無効化されること、
解除すると即座に戻ること（DS-04）。**Quick Look の独自カバー [QL-03] については
「非表示中は書き出しが 1 件も起きない」ことを `Application Support/qooLibrary/quicklook/`
の不在で確認した（＝ DS-06 の抑止方向は成立）が、表示側で実際にカバーへ差し替わる
ところまでは自動操作の信頼性が足りず確認できていないため、ユーザーによる手動確認を
依頼したい。**

**実機を自動操作で検証するときの落とし穴（この作業で踏んだもの。次回以降必ず思い出すこと）**:

1. **System Events の `click at {x, y}` はこのアプリに効かない。** 座標は合っているのに選択が変わらない。`CGEvent`（`mouseMoved` → `leftMouseDown` → `leftMouseUp`）で送ると効く。右クリックも同様（`rightMouseDown`/`Up`）。
2. **メニュー項目の列挙は `name of` ではなく `title of`。** `name` はこれらの項目で `missing value` を返すため、**実装した項目が存在しないように見える**（実際 1 度「View メニューに項目が出ていない」と誤診した）。
3. **日本語 IME が有効だと `keystroke` は使い物にならない。** `~` が全角 `〜` になり、ローマ字がかな（`com.qoolibrary.app` → `こm.くぉおぃbらry`）に変換される。パスを入れる操作は避け、メニュー・矢印キーで代替する。
4. **Quick Look パネルが key の間、`KeyBindingButtons` のショートカットはアプリに届かない。** ⌃⌘I がパネルに吸われて「トグルしたつもりが変わっていない」状態で観察を続けてしまった。パネルを開いたまま切り替えたいときはメニューバーから行う。
5. **診断ログが空でも壊れているとは限らない。** この開発機は `qoo.preferences.logLevel = error` に設定されており、`info`/`warning` は出ない（起動時のセッション開始行も出ない）。ログで切り分けるときは先にレベルを確認すること。
6. **画面座標は「ポイント」。** `screencapture -R` もポイント単位（この機は 2560×1440pt / 5120×2880px）。ピクセル値をそのまま渡すと見当違いの領域を撮る。
7. **検証に使ってよい場所は「使い捨てのディスクイメージ」だけ。**［ユーザー指示、2 度言わせてしまった］**ホームフォルダと Macintosh HD を使わない** — アクセスのたびに権限ダイアログが出て、ユーザーの作業を止める。`Scripts/verification-volume.sh create` で作れる（`destroy` で後始末）。ツリーを矢印キーで辿るような検証では、**移動先がディスクイメージの外へ出ないよう手順を組む**こと（Macintosh HD の行へ入った瞬間にダイアログが出る）。
8. **合成イベントで確認できないことがある。** ダブルクリック（`mouseEventClickState`）は SwiftUI の `.onTapGesture(count: 2)` に届かなかった。**届かないこと自体を「機能が壊れている」と読み替えない** — 実際、ネイティブタブの ＋ ボタンを一度そう誤診している。差分を読んで経路が無傷だと確認できるなら、そこで粘らずユーザーの目視に委ねる。
9. **アプリが前面にあることを毎回確かめてからクリックする。** 別アプリが前面に出ている状態で座標クリックを送り、他アプリのウインドウを撮ってしまった。`activate` してから 1〜2 秒待つ。
10. **ウインドウが出る前の計測を信用しない。** 起動直後に AX を叩くと `window 1` が取れずエラーになり、その後の出力だけが残って**意味のある結果に見える**。1 度これで「← キーが効いた」と誤認した。手順を整えて再現するまで観測を採用しないこと。
11. **シートが開いていると `osascript … quit` は黙って失敗する。** その後の
    `open` は既存インスタンスを前面に出すだけなので、**古いバイナリを新しい
    ものだと思って検証し続ける**ことになる（この罠で 2 回、直したはずの
    変更が「効いていない」と誤診した）。検証では `pkill -x qooLibrary` を使い、
    起動時刻（`ps -o lstart=`）とバイナリの mtime を突き合わせること。
12. **`screencapture` + `sips -Z N` の N は「長辺」に合わせる。** 幅で合う
    つもりで換算すると座標が全部ずれる（クリックが数十 pt 外れて、押した
    つもりのボタンが押せていない、という誤診を何度も生んだ）。**縮小せずに
    撮って画素を 2 で割る**のが一番間違えにくい。
13. **新しいソースファイルを足したら `xcodegen generate`。** さもないと
    「`View` に `〜` というメンバーは無い」という、原因の分かりにくい
    コンパイルエラーになる（`.xcodeproj` は生成物で、ファイル一覧は
    再生成時にしか更新されない）。

### 一括リネームの実機検証と、そこで入った改善（ユーザー要望）

3 モードとも実機で確認した（置き換え／追加／高度なリネーム）。プレビュー →
適用 → ⌘Z、**連鎖リネーム**（001→002→003 のように新しい名前が別の対象の
現在の名前とぶつかる形。2 パスが要る）、衝突検出（赤字＋警告＋ボタン無効）
のいずれも期待どおりだった。連鎖では一時ファイルの残骸が出ないこと、
取り消しで元の並びへ正確に戻ることも確認している。

**見つけて直した欠陥: 連番が表示順に振られていなかった。** 選択は `Set` な
ので `Array(selection)` の順序は不定で、`BulkRename.plan(names:)` は
「表示順で渡すこと」を前提に**その順で番号を振る**。結果、1 番目に見えて
いる項目が 5 番になり、プレビューの並びも開くたびに変わっていた。
`FolderContentView.orderedForDisplay(_:)` を一括リネームの唯一の入口に置き、
⌘R・コンテキストメニュー・ファイルメニューのどれから来ても表示順に揃うように
した。

**ユーザー要望で入れた変更**:

| 変更 | 内容 |
|---|---|
| 桁数 | ゼロ詰めの桁数を選べる（1 / 01 / 001 … と**実際の見た目で**選ばせる）。桁数は**下限**であって上限ではない — 3 桁指定のまま 1000 件目に到達しても切り詰めない |
| 名前とカウンタを廃止 | Finder のカウンタは「5 桁ゼロ詰め」でしかなく、桁数を選べる以上「番号 ＋ 5 桁」と同じもの。選択肢が 2 つあると迷わせるので統合した |
| 番号のみ | 元の名前もカスタム文字列も使わず連番だけにする。**既定**で、一覧の先頭 |
| 区切り文字 | なし／`_`／`-`／スペースから選ぶ。**既定はアンダースコア** — Finder はスペースだが、ファイル名の空白はシェルや URL で毎回エスケープが要る。Finder 準拠より実用を採った |
| 「フォーマット」→「高度なリネーム」 | 何をする欄か伝わらない、というユーザー指摘 |
| 「カスタム形式」→「任意の文字列」 | 同上 |
| 「元のファイル名を任意の文字列で置き換える」チェック | 置き換えるかどうかを明示させる。off の間は欄を触れなくする。**`customText` を `String?` にした** — 以前は「空欄なら元の名前」という暗黙の規則で、空欄の意味が「元の名前を使う」と「区切り文字と番号だけにする」の 2 通りに読めた。`nil` が前者、`""` が後者 |

**入力欄の見た目を共通化した**（`DesignSystem/EditableFieldChrome.swift`）。
［ユーザー指摘: ダークモードだと**どこが入力可能な欄なのか分からない**。
入力状態が分からないという話ではない］SwiftUI の既定も `.roundedBorder` も、
暗い背景では細い枠線が見えるだけだった（実機で並べて確認）。入力欄だと
分かるのは枠ではなく**地の色**なので `NSColor.textBackgroundColor` を敷く。
一括リネーム・フォルダへ移動・アーカイブのパスワード・環境設定の拡張子追加が
同じ見た目になった。**今後ダイアログに入力欄を足すときは
`.editableFieldChrome()` を使うこと**（画面ごとに `.textFieldStyle` を
選ばない）。

**Release ビルドだけで落ちて、原因がインクリメンタルビルドだった件。**
`BulkRename.Mode.format` に関連値（桁数）を足したあと、Release の
`swift test` が `NSInvalidArgumentException`（`.addText` のはずなのに
`.replaceText` の `replacingOccurrences` が nil 引数で呼ばれる）で異常終了した。
Debug では再現しない。**列挙型の関連値を変えるとペイロードのレイアウトが
変わる**ので、古いオブジェクトが残っていると呼び出し側と食い違う。
`.build/arm64-apple-macosx/release` を消してから走らせたら通った。
**教訓: 列挙型の関連値を足し引きしたあと Release だけで不可解に落ちたら、
まず Release の成果物を消して確かめる。**

### フォルダアイコンに中身のカバーを重ねて表示（要件定義書には無い、ユーザー要望）

アイコン表示で、フォルダ直下に zip/cbz/rar/cbr/7z/cb7/pdf/epub／画像がある場合、
**フォルダの絵の中に中身のカバーを最大 3 枚、重ねて少しずつずらして**表示する。

**変更前の挙動**: フォルダ直下の**画像ファイル**だけが対象で、1 枚だけ、しかも
フォルダの絵を**完全に置き換えて**いた。そのため `.cbz` ばかりのフォルダ
（このユーザーのライブラリの大半）は素のフォルダアイコンのままで、逆に画像
フォルダはファイルと見分けが付かなかった。

**対象の選び方**（`CoverImageSourceResolver.coverSourceChildren(for:limit:)`）:
直下の「それ自体がサムネイルを持てるファイル」を自然順で最大 N 件。
**返すのは URL だけで画像化はしない**のが要点で、各 URL は既存の
`ThumbnailService.thumbnail(for:)` にそのまま渡す——`.cbz` は中の先頭画像、
`.pdf` は 1 ページ目、動画は `QLThumbnailGenerator`、と**既存経路がそのまま
再利用でき**、生成物はその子自身の `FileIdentity` でキャッシュされるため
**同じファイルを単体表示したときのセルとキャッシュを共有できる**。
サブフォルダは含めない［ユーザー指定「直下に」］。動画も含める［設計判断:
単体ではサムネイルが出るのに、フォルダだけ素のアイコンになるのは説明が
つかないため。外すなら `case .video` を 1 行落とす］。

`ThumbnailService.folderCoverThumbnails(for:maxPixelSize:limit:)` が 1 枚ずつ
**逐次**で解決する。**自前でスロットを取ってはならない**（取ると `thumbnail`
のスロット待ちと自己デッドロックする）。並行にしないのは、1 フォルダが
`limit` 個のスロットを一度に占めると可視セルが数十ある画面でキューが偏るため。
**`maxPixelSize` は単体セルと同じ `size * 2` を渡す**——`CoverImageCache` の
キーは `FileIdentity` だけで**要求サイズを含まない**ので、ここで小さく要求すると
そのファイルを単体表示したときに粗いキャッシュを掴んでしまう。

**描画は `FolderCoverIcon`（`IconGridView.swift`）。配置の数値は実測で決めた**
——512px で描いたフォルダアイコンのアルファを 1 行ずつ走査し、不透明域が
`y = 0.131…0.893`、タブが終わって前面パネルが全幅になるのが `y = 0.221`、
水平が `x = 0.031…0.967` であることを確認している。

| 決めごと | 値・方針 | 理由 |
|---|---|---|
| 1 枚の大きさ | **枚数によって変えない** | ［ユーザー指定］1 枚でも 3 枚でも同じ大きさ |
| 幅 | **画像自身の比率**から算出。上限（アイコン幅の 55%）に当たったら**比率ではなく高さを下げる** | ［ユーザー指摘「本というか画像のアスペクト比に依存する」「16:9 でも破綻しないように」］高さ基準のままだと 16:9 は幅がアイコンの 87% に達してはみ出す |
| 幅の上限の決め方 | `目標束幅 0.75 − 最小はみ出し 0.10 ×(最大枚数−1)` = **0.55** | 当初は「幅に対する一定比のずらし」から逆算して 0.33 にしていたが、16:9 だと高さがアイコンの 18% しか取れず**何の動画か判別できなかった**［ユーザー指摘］。**横長は縦にもカスケードして判別できるので横は深く重ねてよい**、というのが今の決め方の根拠。最大枚数を基準にするのは、1 枚と 3 枚でカバーの大きさを変えないため |
| 横のずらし | 束が目標幅（アイコン幅の 75%）になる値。ただし重なりが 25% を下回らない上限で頭打ち | ［当初 80% にしたが「使いすぎ」との指摘で下げた］2 枚のときに目標幅まで広げると隙間が空くため、重なりを保つほうを優先する |
| 幅がばらつくとき | 後ろのカバーの右端が**必ず 10% ぶんはみ出す**位置まで押し出す | 一定のずらし幅だけだと、縦長のコミックと 16:9 の動画が混在するフォルダで細いカバーが前のカバーに**完全に隠れる** |
| 縦のずらし | 縦に余りが出たぶんを段数で割り、**上端基準で下げていく（左上→右下）**。束が縦を使い切らないときは**上下中央**に置く | ［ユーザー要望「横長画像の場合は上下にもずらせば無駄なくスペースを使える」「左上から右下へ向かうようにずらすほうが自然」「横長 1 枚のときは上下も中央に」］縦長カバーは余りが 0 なので自動的にずれ幅 0・補正 0 になり、見え方は変わらない |
| 切り抜き・枠線 | **しない** | ［ユーザー指摘「タイルにしてほしいわけではない」］一度、共通比率で切り抜いて枠線を付ける実装にしたが却下された |
| 重ね順 | 先頭が手前 | 自然順の 1 枚目がカバーとして最も読める |

**この作業で得た進め方の教訓**: レイアウトの合意に 5 往復かかった。
「格子／重ねる」「枚数」を先に選択肢で確認したものの、**切り抜きの有無・
枚数と大きさの関係・アスペクト比の扱い**という、実物を見ないと言語化されない
軸が後から次々出てきたため。次に見た目を伴う要望を受けたときは、**最初の 1 回で
「素材の比率が違う場合」「個数が違う場合」まで含めた実例を出して見せる**ほうが
早い（今回も、縦長・16:9・正方形・混在の 4 パターンを並べた検証用フォルダを
作ってからは 1 往復で収束した）。

### Finder のメニューアイコンと効果音（要件定義書には無い、ユーザー要望）

Finder に合わせるための調査と、**効果音の実装**（メニューアイコンは調査のみで未実装）。

#### 調査手法（今後 Finder 準拠を検討するときに再利用する）

| 知りたいこと | 手法 |
|---|---|
| メニューの構造・アイコン | `MenuBar.nib` を `NSNib` で**実際にインスタンス化**して `NSMenuItem` を走査する（既出の手法）。**アイコンは `image.value(forKey: "symbolName")` で SF Symbol 名が取れる**（`image.name()` は nil） |
| コンテキストメニュー | nib が無く実行時に組み立てられるため、実 Finder を右クリックしてスクリーンショットで実測 |
| dyld 共有キャッシュ内のフレームワーク | **`dyld_info` はキャッシュ内の dylib をパス指定で扱える**（`-imports`/`-exports`/`-disassemble`/`-objc`）。抽出ツールは不要 |
| 実行時のデータ構造（switch のジャンプテーブル等） | エクスポート記号の unslid アドレスと実行時アドレスの差から slide を求め、**自プロセスのメモリを直接読む**。逆アセンブルだけでは追えない対応表を確定できる |

#### メニューアイコン（実装済み）

- **Finder はメニューバーとコンテキストメニューで同じ SF Symbol を使う**（コマンド 1 つにつき 1 シンボル）。⌥ 代替項目は主項目と**同じ**アイコン。
- **アイコンを付けない項目**: 中身が動的なコンテナ submenu（Open With / Quick Actions / View / Clean Up By）、表示切替の一部（タブバー・ツールバー・パスバー・ステータスバー・フルスクリーン）、サードパーティのサービス項目。**submenu だから無し、ではない**（並び替え・グループを使用・圧縮 は submenu でもアイコンあり）。
- **SwiftUI の `Label(_, systemImage:)` で実装できる**ことを実測確認済み（メニューバー・`.contextMenu`・`Menu` のラベルすべてで描画された）。AppKit の回避策は不要。
- 主要な対応（Finder 実測値）: 開く `arrow.up.forward.app` / ゴミ箱・完全削除 `trash` / 情報 `info.circle` / 名前を変更 `pencil` / 圧縮 `zipper.page` / 複製・新規タブ `plus.square.on.square` / エイリアス `square.dashed.and.alias` / クイックルック `eye` / コピー `document.on.document` / ペースト `document.on.clipboard` / ここに項目を移動 `folder` / カット `scissors` / 選択・選択解除 `character.textbox` / Undo・Redo `arrow.uturn.backward`・`arrow.uturn.forward` / 新規フォルダ `folder.badge.plus` / 新規ウインドウ `plus.rectangle` / 共有 `square.and.arrow.up` / 取り出す `eject` / 検索 `magnifyingglass` / アイコン・リスト `square.grid.2x2`・`list.bullet` / 並び替え `arrow.up.arrow.down` / 表示オプション `gearshape` / 設定 `gear` / サイドバー・インスペクタ `sidebar.leading`・`sidebar.trailing` / 戻る・進む `chevron.backward`・`chevron.forward` / 上の階層へ `arrow.up.folder` / フォルダへ移動 `arrow.forward.folder` / 最近使った項目 `clock` / ホーム `house`
- **`square.dashed.and.alias`（Finder のエイリアス用）は非公開で、`NSImage(systemSymbolName:)` が `nil` を返す。** サードパーティからは使えないため `square.on.square.dashed` で代替した。**Finder の nib から読んだシンボル名をそのまま使う前に、必ず `NSImage(systemSymbolName:)` で実在を確認すること**（存在しないと例外も警告も出ず、ただ何も描かれない）。
- **実装は `Button(_:systemImage:action:)` / `Menu(_:systemImage:content:)` / `Toggle(_:systemImage:isOn:)`**（いずれも標準 API）。`Button(_:systemImage:role:action:)` と実行時 `String` のオーバーロードもある。既存の `Button("key") { }` に `systemImage:` を足すだけで済むので、キー → シンボルの対応表を作って機械的に置換した。
- **アイコンを付ける／付けないの一覧は `qooLibraryApp.swift` / `FolderContentView.swift` / `FolderTreeContextMenu.swift` の実コードが正**。qooLibrary 独自（Finder に対応コマンドが無い）の選定: 展開 `shippingbox.and.arrow.backward` / 圧縮・展開サブメニュー `zipper.page` / ターミナルで開く `terminal` / Finder で表示 `macwindow` / 表示するカラム `tablecells` / サムネイル表示 `photo` / ライブラリフォルダ `books.vertical` / テンポラリフォルダ `tray` / 表示名を変更 `text.cursor` / 登録解除 `minus.circle` / 診断ログを書き出す `stethoscope` / アイコンを大きく・小さく `plus.magnifyingglass`・`minus.magnifyingglass` / ロック・ロック解除 `lock`・`lock.open`。
- **`ShareLink` はラベルを取る形（`ShareLink(items:) { Label(...) }`）にしないとアイコンが付かない。**
- **「新規ウインドウ」は SwiftUI 標準の `.newItem` 項目のためアイコンが付いていない**（Finder は `plus.rectangle` を付けている）。付けるには `CommandGroup(replacing: .newItem)` で自前の項目に置き換える必要がある — 未対応［ユーザー判断: そこまでする必要は無い］。

#### メニュー抜け監査（アイコン実装の直後、ユーザー指摘で実施）

**「ファイルメニューに新規タブが無い」というユーザー指摘**をきっかけに、Finder のメニュー実体（nib）と qooLibrary のメニュー実体（実行中アプリから AX でダンプ）を突き合わせ、さらに `ActionID` 全 38 件・`FolderMenuActions`／`WindowMenuActions` の公開メンバ・コンテキストメニュー項目を照合した。**実装済みなのにメニューバーから辿れない機能が 7 件**見つかり、うち 6 件を追加した。

| 機能 | 発覚前の到達手段 | 対応 |
|---|---|---|
| 新規タブ | ⌘T のみ | ファイルメニューへ追加（Finder と同じ位置）|
| 検索 | ⌘F・ツールバーの虫めがねのみ | ファイルメニュー末尾へ追加（Finder と同じ）|
| このアプリケーションで開く | コンテキストメニューのみ | 「開く」の直後へ追加（Finder と同じ）|
| 新規ウインドウで開く | コンテキストメニューのみ | 「開く」の ⌥ 代替（Finder と同じ）|
| 共有… | コンテキストメニューのみ | ファイルメニューへ追加（Finder と同じ）|
| 展開（4 項目）| コンテキストメニューのみ | 「圧縮／展開」サブメニューに圧縮とまとめた［ユーザー判断］|
| 隠しファイルの表示切替 | ステータスバーのボタンのみ | **追加しない** — Finder もメニューに持たない［原則 Finder に揃える］|

- **「新規タブで開く」は Finder のファイルメニューに存在しない**（コンテキストメニューのみ）ため、qooLibrary も追加しなかった［ユーザー判断: 原則 Finder に揃える］。
- `ShareLink` はクロージャではなく**実際の項目**を要求するため、`FolderMenuActions.shareItems: [URL]` として値そのものを渡す（他のアクションはクロージャ）。項目が空だと機能しないので、その場合は無効化したボタンへ差し替える。
- **`newTab`/`focusSearch` は `ActionID` に登録され `KeyBindingButtons` で配線済みだったのに、メニューバーからは一切辿れなかった。** `KeyBindingButtons` に配線しただけでは「キーを知っている人にしか存在が分からない」状態になる。**今後 `ActionID` を追加・配線したら、メニューバーにも項目が要るかを必ず確認すること。**
#### メニューへのショートカット表示（1-8 以来の方針を変更）

**「メニュー項目に `.keyboardShortcut` を付けず `KeyBindingButtons` をアプリ唯一の配線経路にする」という 1-8 以来の方針を、Finder と同じキーに揃えてある操作についてだけ撤回した**［ユーザー判断: 「Finder と揃えてある操作についてはキーボードショートカットを表示してください。これらについては、キーバインドの対象外にして構いません」］。不可視ボタン経由ではメニューにキーが出ず、**キーを知っている人にしか機能の存在が分からない**状態だったため。

- `KeyBinding.isCustomizable`（既定 `true`）を追加。**`false` ＝ Finder と同じキーに揃えてある操作**で、27 件ある。
- 固定の操作はメニュー項目が `.fixedKeyboardShortcut(_:)`（`KeyComboConversion.swift`）でショートカットを持ち、**`KeyBindingButtons` からは外してある**（二重登録を避けるため）。キーの定義は `DefaultKeyBindings` に一本化したままで、ハードコードはしない。
- **`goBack`/`goForward` だけは両方使う** — メニュー項目が持てる `.keyboardShortcut` は 1 つだけなので、Finder 標準の ⌘[/⌘] をメニューが表示し、2 つ目の ⌘←/⌘→ は `KeyBindingButtons(skipsPrimaryCombo: true)` が配線する。
- 環境設定「キーボード」タブは**変更できるもの／標準のもの（読み取り専用）**の 2 セクションに分けた。固定側も一覧に残すのは、メニューを開かずにキーを確認でき、割り当て時に何と衝突するか分かるため（衝突検出は両方が対象）。
- **固定キーとの衝突は「それでも割り当てる」を出さない。** 出すと、ストア上は相手のキーを消せてもメニューは `DefaultKeyBindings` から直接読むため表示が変わらず、同じキーが 2 つ生き残る。`UserDefaultsKeyBindingStore.setBinding` も固定の操作への上書きを黙って無視する（衝突解決のような間接経路で壊れないようにする防御）。
- **実測で確認したこと**: ⌥ 代替の項目（`modifierKeyAlternate`）も `Picker` の中の項目も `.keyboardShortcut` を持てる。⌘⌫ や ⌘↑ は AX の `AXMenuItemCmdChar` では空に見えるが、実際のメニューには正しく表示される（**AX ダンプだけで「付いていない」と判断しないこと**）。
- 固定にしなかったもの（＝変更可能なまま、メニューにキーは出ない）: `open`（Return。Finder は ⌘O で、Finder の Return はリネーム）・`quickLook`（Space。Finder のメニューは ⌘Y）・`rename`（⌘R は独自。Finder の「名前を変更」にキーは無く、⌘R は「オリジナルを表示」）・`makeAlias`（下記）・`toggleThumbnails`・`compress`・`deletePermanently`・`ejectAll`・未実装の 2 件。
- **[訂正] 「Finder の『エイリアスを作成』は ⌘L」という CLAUDE.md の従来の記述は誤り。** macOS 26 の `MenuBar.nib` を実際に読むと **⌃⌘A**（⌘L は古い macOS の Finder）。ただし ⌃⌘A は未実装の `moveToVault` が使っているため、今回は ⌘L のまま変更可能にして据え置いた。`moveToVault` を実装するタイミングで併せて判断すること。
- **実機での確認方法**: `System Events` でメニューバー項目を名前で開いてスクリーンショット。⌥ 代替が効いているかは、⌥ を押した状態で開いたときに主項目が代替へ**入れ替わる**（並んで増えるのではない）ことで確認する。

#### 効果音（実装済み）

**音源は macOS 同梱のシステムサウンドをそのまま使う**（自前の音源をバンドルしない）。場所は `/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/`。

**AudioToolbox の内部対応表を実行時メモリから復元して確定させた**（一部）: 1=`system/Volume Mount.aif` / 13=`finder/empty trash.aif` / 14=`finder/move to trash.aif` / 15=`dock/poof item off dock.aif` / 16=`dock/drag to trash.aif` / 24=`system/Grab.aif`。

**Finder が実際に鳴らしているもの**（逆アセンブルで確定 → ユーザーが耳で確認済み）:

- Finder は操作コントローラの**仮想メソッドが SystemSoundID を返し**、進捗ビューが消えるとき（＝操作完了時）に鳴らす。
- **[訂正] 基底実装（大半の操作が使う）は「無音」ではない。** 当初この分岐を読んで「コピー・移動では音を鳴らさない」と結論したが、**ユーザーから「Finder でファイルをペーストすると音が鳴る」と実機で指摘を受けて誤りと判明した**。実際には `エラー無し && 未キャンセル && …条件… → ID 1（`Volume Mount.aif`）／それ以外 → 0` という分岐で、条件側（`>= 3` の比較と、もう 1 つの仮想メソッド呼び出し）は完全には解読できていない。**「条件付き」を「ほぼ鳴らない」と読み替えてしまったのが誤りの本体。** 教訓: 分岐の一方しか成立しないと決めつける前に、実機で確かめるか、ユーザーに聞くこと。
- ゴミ箱に入れる → **ID 16 = `dock/drag to trash.aif`**（0.50 秒）。**`finder/move to trash.aif`（ID 14、2.19 秒）は名前に反してどこからも呼ばれていない** — ファイル名で選ぶと間違える。
- ゴミ箱を空にする → ID 13 = `finder/empty trash.aif`。
- Dock 側は別経路（ドラッグでのゴミ箱 → 16、poof → 15）。
- 全ての再生は `com.apple.finder` の **`FinderSounds`**（既定 on）で一括ゲートされる。

**qooLibrary の実装**（`Sources/QooInfrastructure/Sound/SystemSoundPlayer.swift`）:

- `SystemSoundEffect`（`.moveToTrash` / `.permanentDelete` / `.operationComplete`）と `SystemSoundPlaying` プロトコル + `SystemSoundPlayer`（`actor`）。**列挙子は qooLibrary 側の意味で命名**（`.permanentDelete` の実体は `empty trash.aif`。qooLibrary に「ゴミ箱を空にする」機能は無く、この音を使うのは完全削除だけ）。
- **参照はファイルパス指定**［ユーザー判断］。数値 ID の対応表が非公開なため、自己文書化されるパスを採る。読み込みに失敗したら**その音は以後鳴らさず無音へフォールバック**する（ユーザーには提示せずログのみ）。
- 登録した `SystemSoundID` は使い回す（登録は coreaudiod への往復を伴う）。再生は Finder と同じ `AudioServicesPlaySystemSoundWithCompletion`。
- **システム設定「ユーザインターフェイスのサウンドエフェクトを再生」を自動的に尊重する**（`kAudioServicesPropertyIsUISound` が既定 1）。**アプリ側の設定は持たない**［ユーザー判断: 環境設定に音のオン/オフは置かない］。
- **App Sandbox 下で追加の entitlement 無しに動作する**ことを、qooLibrary と同一 entitlement の検証アプリで実測済み。
- **鳴らす経路は `CommandStack` の 1 箇所だけ**（`Command.completionSound` を読む。Finder と同じ構造で、経路が増えても鳴らし忘れ・二重再生が起きない）。割り当て:

  | コマンド | 音 | 備考 |
  |---|---|---|
  | `TrashCommand` | `.moveToTrash` | |
  | `DeletePermanentlyCommand` | `.permanentDelete` | |
  | `CompressCommand` / `ExtractCommand` | `.operationComplete` | ［ユーザー要望］Finder には無いが、数秒かかるため完了の手がかりが要る |
  | `MoveFilesCommand` / `CopyFilesCommand` | `.operationComplete` | ペースト・複製・D&D。**Finder も鳴らす**（上記の訂正参照）。成功時は件数によらず常に鳴らす［ユーザー判断］ |
  | 上記以外（名前の変更・新規フォルダ・エイリアス・ロック） | `nil`（無音） | 一瞬で終わり結果が画面上ですぐ分かるため |
- **`undo()` では鳴らさない**［設計判断］— 音は「その操作が起きたこと」に付随するもので、⌘Z で圧縮完了音が鳴るのは意味が逆。取り消しの中身に応じて鳴らし分けると同じ ⌘Z が対象によって違う音になり分かりにくい。**redo は操作をもう一度起こすので鳴らす。** 部分成功でも鳴らさない（Finder も鳴らす前にエラーの有無を確認している）。
- `CompositeCommand` は**子のうち最初に音を持つものを 1 つだけ**採用する（複数アーカイブの一括展開でも鳴るのは 1 回）。
- `RuntimeEnvironment.isRunningTests`（`DiagnosticLog` から切り出して共有）により、**`swift test` 中は無音**。
- テスト: `SystemSoundEffectTests`（音源の実在・`AudioServices` への登録成功・重複が無いこと。**OS 側で音源が移動したら気づけるようにするための回帰テスト**）、`CommandSoundTests`（各コマンドの割り当て・`CompositeCommand` の合成・`CommandStack` が成功時のみ鳴らし undo では鳴らさないこと）。

**教訓**: 「`move to trash.aif` だからゴミ箱の音」のような名前からの推測は外れる。音を選ぶときは**実際に鳴らして耳で確認する**こと（今回もユーザーに 4 音とも聴いてもらって確定させた）。

### 表示中のフォルダの状態一貫性（要件定義書には無い、ユーザー要望）

ユーザー指摘: 「qooLibrary で表示しているフォルダに対し、Finder などでファイル・フォルダの削除やリネームを行っても、qooLibrary は自律的にこの変化を表示反映できない。これはユーザーに対しファイル・フォルダの状態一貫性を提供できないという点において、ファイルマネージャーとして致命的」。**確定した仕様は `docs/Specifications/10_インフラ_監視とスキャン.md` §10.0 にある。着手時はまずそこを読むこと。**

**新規 `Sources/QooInfrastructure/Watch/`**: `FileSystemEventStream`（FSEvents の薄いラッパ）・`DirectoryChangeHub`（関心の登録と振り分け）・`DirectoryObservation`（表示 1 つが持つ取っ手、`generation` が増える）。

**設計の骨**:

- **自分の変更は `FileOperationService` の 1 箇所から通知する**（`announce(_:)`、全 10 経路に `defer` で）。FS を変更する経路はすべてそこを通ることが静的検査 [FO-02][B-10] で強制されているので、**通知の書き忘れが構造的に起こらない**（`CommandStack.record()` がログを 1 箇所に集めているのと同じ考え方）。FSEvents は `IgnoreSelf` で自プロセスの変更を落とすため、この経路が切れると「Finder での変更は反映されるのに自分で作ったフォルダが出てこない」という壊れ方をする — 統合テスト `ownChangesReachTheObservationThroughFileOperationService` がそれを見張る。
- **購読側へはクロージャではなく値（世代番号）を配る。** ハブにクロージャを預けると、①このコードベースで繰り返し踏んでいる「値型の View が保持する `let` を後から読むと 1 世代古い」罠が再現し、②ハブが View を強参照して解放されなくなる。`.onChange(of: watch.generation) { reload() }` なら、何をするかは `body` の評価ごとに最新の文脈で決まる。
- **`SessionState.reloadToken` の意味を狭めた。** ファイルの追加・削除・改名・書き換えはハブが「影響を受けるフォルダを表示している場所だけ」へ届ける。`reloadToken` に残したのは**ファイルの中身以外**の理由だけ（アクセス権の付与・取り消し、ボリュームの取り出し、ライブラリ／テンポラリ登録の増減）。以前は 1 回の改名で全ウインドウ・展開済みの全ツリー行が読み直していた。
- **サムネイル／カバーのキャッシュ鍵に更新日時とサイズを足した**（`FileContentStamp`、`FileIdentity` とは別の型）。`FileIdentity` は中身が変わっても不変であることが役目 [ID-01] なので鍵に使えない — 外部での差し替えで古いサムネイルが出続け、inode 再利用で**無関係なファイル**のサムネイルが出ていた。鍵の形式は `covers/v2/` と版で分け、起動時に古い版を捨てる。`FileOperationService`/`ThumbnailService`/`QuickLookCoverStore` に散っていた `stat` 由来の計算も `FileMetadata` へ一本化した。

**実測で確定させたこと**（サンドボックス下の最小アプリ、実アプリと同一 entitlement。表は §10.0 に）: FSEvents は App Sandbox 下で追加 entitlement 無しに動く／**読み取り権限の無いパスのイベントも届く**／`/` を監視しても待機時 2 件/秒・最悪 4,000 件/10 秒で許容範囲／`IgnoreSelf` は効く／存在しないパスを含めてもストリームは作れ、出現した時点から配送が始まる／`FSEventStreamGetLatestEventId` を `sinceWhen` に渡せばルート差し替えの空白も再生される／**ストリームはアンマウントを妨げない**（1-16 のイジェクトに影響しない）／`/Volumes` を監視すると `Mount`/`Unmount` が届く。**`kqueue` は採らなかった** — ディレクトリごとに fd を開くのでアンマウントが `EBUSY` になる。

**実装中に踏んで直したもの（いずれも実測・レビュー・実機で発覚）**:

1. **`URL.resolvingSymlinksInPath()` で正規化してはいけない。** あれは「先頭が `/private` なら取り除く」特別扱いを持つ（Apple のドキュメントに明記）ため、`/private/var/…` を `/var/…` へ**逆向きに**畳む。FSEvents が返すのは `/private/var/…` の側なので、これで正規化すると一時ディレクトリ配下のイベントが 1 件も引き当たらない（統合テストが 4 件とも落ちて発覚）。`realpath(3)` にはこの特別扱いが無い。
2. **FSEvents のコールバックを `.main` に配送してはいけない。** メインキューが実際に回っている場面でしか届かない。`swift test` の下では 1 件も配送されず、アプリ本体でも「メインスレッドが塞がっていれば取りこぼす」ことに変わりはない。専用のシリアルキューで受けて `@MainActor` へ渡す。
3. **C へ渡すコールバックを `@MainActor` の型の内側に書いてはいけない。** `@MainActor` なメソッド／プロパティの初期化式に書いたクロージャは、C の関数ポインタへ変換される際もメインアクタ隔離とみなされ、Swift が実行アクタの表明を挿入する。FSEvents はそれらを**自分のキュー**で呼ぶ（`release` はストリーム破棄時に `_FSEventStreamDeallocate` から）ため表明が破れ、テストスイート全体で `dispatch_assert_queue_fail` → `SIGTRAP` になった。ファイル直下（どのアクタにも属さない場所）へ置く。
4. **`FSEventStreamContext` に `retain`/`release` を指定したら `passUnretained` で渡す。** `passRetained` と併用すると合計 +2 に対して解放が 1 回だけになり、ストリームを作り直すたび（＝移動のたび、ツリーを開くたび）に 1 つずつ漏れる。回帰テストは「`passRetained` に戻すと落ちる」ことまで確認済み。
5. **`Task.detached` をやめると、それまで死んでいたキャンセル経路が生きる。** `InspectorPane.computeFolderCounts` は打ち切り時に `break` して**途中まで数えた値**を返しており、それが確定値として表示されるようになった（以前は `Task.isCancelled` が永久に `false` だったため起きなかった）。打ち切られたら `nil` を返すよう直した。
6. **重い再計算を変更のたびに打ち切って始め直すと、変更が続く間いつまでも完了しない。** 再帰検索は「走っている間は溜め、終わってから 1 回だけやり直す」形にした（`appliedSearchGeneration`）。インスペクタの再帰集計は `.deep` をやめ直下のみにした（数字が出ないまま CPU を焼くより、孫以下の変更が選び直しまで反映されない方がまし、という判断）。
7. **たたんだツリーの行が `children` を抱えたままだった。** ①たたんだ行が監視され続けて変更のたびに読み直され、②開き直しても `children != nil` を理由に読み直しが飛ばされ、たたんでいる間の変更が反映されない、という 2 つの問題があった。たたんだら忘れる。

**検証**: `swift test`（349 件、Debug 3 回・Release とも全通過）、静的検査 2 件、`xcodegen generate && xcodebuild`（Debug）。**実アプリ（サンドボックス下）で end-to-end 確認済み。** 外部プロセス（`/bin/mkdir`・`/bin/mv`・`/bin/rm`・`hdiutil`）だけで変更を起こし、画面を実際に見て次を確認した:

| 確認したこと | 結果 |
|---|---|
| 中央ペイン: 外部での作成・改名・削除 | いずれも即座に反映 |
| インスペクタ: サブフォルダ数・変更日 | 追随して更新 |
| **フォルダツリーの行**（展開中） | 外部で追加したフォルダが行の下に現れた |
| **表示していないフォルダの変更** | 何も起きない（診断ログでも 0 件。1 回の変更で全部が読み直される以前の作りに戻っていない）|
| **表示中のフォルダを外部で削除** | 行き止まりにならず、存在する直近の祖先へ自動的に移動した |
| **ボリュームの着脱**（ディスクイメージ） | マウントで自動的にツリーへ現れ、外部からのイジェクトで消え、表示中だった場合は `/Volumes` へ退避した |

**この作業で使った検証手段の記録**: 実機の GUI 自動操作が使えないとき、**診断ログを `debug` に上げて経路が働いていることを直接観測する**のが有効だった（`DirectoryChangeHub` に「パス N 件 → 表示 M 件を読み直し」を恒久的な `debug` ログとして残してある）。あわせて、環境設定を一時的に書き換えて検証する場合は `defaults read` で**元の値を先に保存し、必ず戻す**こと（今回は起動時フォルダがユーザーの実ライブラリを指していたため、コンテナ内へ一時的に向け替えてから復元した）。

### ファイルマネージャーとしての欠落を埋める（要件定義書には無い、ユーザー要望）

「ファイルマネージャーとして他に欠如している必須機能はあるか」という問いから始まった棚卸しの結果を実装した。**フォルダツリーのキーボード操作だけは未実装**（後述）。

| 実装したもの | 要件 |
|---|---|
| 衝突ダイアログ（置き換える／両方とも残す／スキップ ＋「以降すべてに適用」）| [FM-11][FM-12] |
| バイト単位の進捗とキャンセル | [UI-09][A-04] |
| type-select（先頭文字で項目へ飛ぶ）| —（Finder 標準）|
| アイコン表示の矢印キー移動 | —（`Table` は AppKit から無償で得ていたが `LazyVGrid` には無かった）|
| エイリアス／シンボリックリンクを開いたときの追従 | [SL-02] |
| ソート順の永続化（アプリ全体で 1 つ）| — |
| Finder 相当の一括リネーム（3 モード・プレビュー・衝突検出・2 パス・1 Undo）| [BR-08〜11] を先取り |
| フォルダツリーのキーボード操作（↑ ↓ ← →）| —（Finder 標準）|

**衝突ダイアログが最大の欠落だった。** それまで全経路が `.keepBoth` 固定で、ユーザーは一度も尋ねられなかった——「新しい版で上書きしたい」つもりの操作が黙って「名前 2」を増やしていた。`conflictResolver` の口はインフラ側に元からあり、アプリ層が誰も渡していなかった。「以降すべてに適用」の状態は `FolderOperations` が持つ（完全削除のロック確認 [PD-06] と同じ形で、汎用の `BatchNotificationSession` を待たずに要件を満たす）。

#### コピーの実装を差し替える前に測ったこと

`FileManager.copyItem` を `copyfile(3)` へ置き換える前に、**それが APFS のクローンを使っているか**を測った。使っていた（1GB が 3ms、素の `copyfile` は 335ms）。知らずに置き換えれば、同一ボリュームのコピーが「一瞬・容量ゼロ」から実コピーへ退行するところだった。

実測で確定した組み合わせ（`FileCopyEngine` のコメントに表として残してある）: **`COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_RECURSIVE` の一組**で、クローンできれば 0 コールバックで一瞬、できなければ実コピーへ自動的に落ちてファイルごとに進捗が届き、`COPYFILE_QUIT` で中断すると copyfile 自身が書きかけの宛先を消す。総量の事前集計は `volumeSupportsFileCloning` を見て**クローンで済むと分かっている場合は行わない**（一瞬で終わる処理のために 5 万件を数えるのは本末転倒）。

#### この作業で見つけて直した危険な穴

いずれもテストとレビューが捕まえたもの。**すべてデータを失い得る経路**だった。

1. **status コールバックを付けた瞬間、あらゆるコピー失敗が握り潰されていた。** エラー段階で `COPYFILE_CONTINUE` を返すのは copyfile に「その失敗は無視して続けろ」と指示することで、戻り値まで 0（成功）になる。`COPYFILE_EXCL` も権限エラーもディスク不足も、すべて成功として報告されていた。エラー段階では `COPYFILE_QUIT` を返す。
2. **man page の「implies」を信じてはいけない。** `COPYFILE_CLONE` は `NOFOLLOW|ALL|EXCL` を含むと書かれているが、**実際には既存の宛先を黙って上書きした**。`COPYFILE_EXCL` は必ず自分で指定する。
3. **`.replace` の最中にキャンセルすると、退避元と書き込み先の両方を失った。** 中断は `throw` ではなく戻り値なので、`withReplaceBackupCleanup` が成功扱いで退避を消す一方、copyfile は書きかけの宛先を消していた。中断を「成功しなかった」として扱う。
4. **素の `rename(2)` は宛先を黙って上書きする。** 進捗のために `FileManager.moveItem` から置き換えた結果、コピー側は `COPYFILE_EXCL` を保っているのに移動側だけ穴が空く非対称な状態になっていた。`renamex_np` + `RENAME_EXCL` にする（回帰テストあり）。
5. **「以降すべてに適用」が次の操作へ持ち越されていた。** リセットを `run()` の中に置いていたが、D&D は `run()` を通らない。1 回の操作 ＝ 1 回の `transferOptions()` なので、そちらでリセットする。
6. **衝突ダイアログが閉じず、2 件目以降が黙ってスキップされていた。** ボタンが `dismiss()` も保留状態のクリアもしていなかったため、次のシートを出せず、2 秒の見張りが安全側のスキップとして拾っていた。
7. **一括リネームが検索結果で別のファイルを改名しかねなかった。** 「表示中のフォルダ＋項目名」で URL を組み立てていたため、再帰検索の結果（サブフォルダの項目）で破綻する。対象の実際の親フォルダを使い、複数フォルダにまたがる選択は拒否する。

**教訓**: `FileManager` の高水準 API から低水準 API へ降りるときは、**高水準 API が黙って持っていた安全性**（既存の宛先を上書きしない、失敗を失敗として返す、APFS のクローンを使う）を 1 つずつ数え上げて、明示的に取り戻すこと。3 つとも失っていた。

#### RAR も進捗・一時停止・中断に対応した

**「RAR は一括 API なので進捗を報告できない」という記述は誤りだった。**
`qoo_unrar_extract_all` は**エントリを 1 件書き出すたびにコールバックを
呼ぶ**（ヘッダにそう書いてあり、`RunArchive` の実装でも確認）。
その契機を使っていなかっただけで、できないわけではなかった。
**教訓: 「一括 API だから無理」は API の宣言を読み直してから言うこと。**

対応した 3 点（いずれも自作ラッパー `QooUnrarBridge` の変更のみ。UnRAR 本体
`ThirdParty/unrar/` には触れず、ビルド済み xcframework の再生成も不要）:

1. **進捗** — コールバックで件数・バイト数・エントリ名を報告する。総数は
   他の形式と同じく `SecureExtractor` が `listEntries` の結果から足す。
2. **一時停止** — 同じコールバックの中で待つ（コールバックは呼び出し元の
   スレッドで走るので `PauseToken` がそのまま使える）。
3. **中断** — コールバックの戻り値を `void` から `int`（0 で続行、非 0 で
   中断）に変え、`RunArchive` のループを抜けて `QOO_UNRAR_ERROR_CANCELLED`
   を返す。**これが一番効く** — 以前は 1.1GB の RAR を止めても最後まで
   走り切ってから捨てていたのが、実測 0.16 秒で止まるようになった。

**粒度は 1 エントリ**。`RARProcessFileW` は 1 エントリを書き終えるまで戻らない
ため、巨大な 1 ファイルの途中では止まれない（バイト単位まで必要なら UnRAR の
`UCM_PROCESSDATA` を使う拡張が要る）。

##### 中断したのに出力が残っていた（3 段階の欠陥）

実 RAR（1.1GB、ユーザー提供のサンプル）で中断すると、展開先に中途半端な
フォルダが残った。原因は 1 つではなく、直すたびに次が出てきた:

1. **`copyfile(3)` は再帰的なフォルダコピーを中断すると、途中まで作った木を
   残す。** 1 ファイルなら書きかけを自分で片付けるので、そちらの挙動から
   類推していた。運び終えていない項目は受領書を返さない＝ Undo にも残らない
   ので、`transfer` が消さなければ誰も片付けられない。中断した項目の宛先を
   消すようにした（`.replace` で退避がある場合は `restoreReplacedItem` が
   既にやっているので触らない）。
2. **移送を途中で止めても「成功」として扱われていた。** `transfer` は中断時に
   「そこまで運び終えた分」を返す設計 [ER-16] で、コピーや移動ではそれが
   正しい。だが展開では、止めたのに一部だけ出た状態が成功として残る。
   `SecureExtractor` が中断を検知したら、出しかけた分をゴミ箱へ送って
   `.cancelled` を投げるようにした。
3. **`CompositeCommand` が、すでに実行した子を巻き戻していなかった。**
   「〈名前〉に展開」は「フォルダを作る」＋「展開する」の 2 つ。展開を止めても
   空のフォルダだけが残り、しかも `execute()` が投げるので Undo スタックにも
   積まれず、ユーザーには片付ける手立てが無かった。**中断のときだけ**
   巻き戻す（失敗のときは巻き戻さない — 5 個中 3 個目で失敗したときに成功
   した 2 個まで消えるのは驚きが大きく、部分的な成功の見せ方は
   `BatchNotificationSession` の課題）。

回帰テストは `PauseIntegrationTests.cancellingAPausedFolderCopyLeavesNoPartialTree`。
**一時停止を使って「途中で止まった状態」を確実に作る** — 素朴に「コピー中に
取り消す」と書くと、速いディスクではコピーが先に終わって何も検証しないまま通る。

##### あわせて直したもの

- **`ExtractError` を `LocalizedError` に準拠させた** [ER-03]。`FileOperationError`
  と同じ落とし穴で、「操作を完了できませんでした。（QooKit.ExtractError エラー10）」
  としか出ていなかった。
- **中断を「実行に失敗」としてログに残さない**（`CommandStack.isCancellation`）。
  既定のログレベルしか出していない環境で、キャンセルの記録だけが目立って
  本当の失敗が埋もれる。

#### 左サイドバーの上下分割位置を覚える

フォルダツリーとラベルフィルタの境界をドラッグしても、再起動すると忘れて
いた［ユーザー要望］。`VSplitView` には `ideal` に相当する指定が無く SwiftUI
側から初期位置を渡せないため、`HSplitView` のときと同じく
`NSSplitView.setPosition(_:ofDividerAt:)` を直接呼ぶ（`SplitPositionApplier`
を縦分割にも使えるよう一般化した）。

**観測も AppKit 側で行うのが要点**［実機検証で発見］。当初は横幅と同じく
`GeometryReader` でペインの高さを測って保存したが、保存する量（ペインの
可視高さ）と適用する量（分割ビュー上端からの位置）が **44pt ずれていて**、
起動のたびにその差だけ縮んでいった（実測: 537 → 493 → …）。
`NSSplitView.didResizeSubviewsNotification` を購読して先頭ペインの実寸を
覚えるようにしたところ、3 回連続の再起動で値が 1pt も動かなくなった。
**保存する量と適用する量は必ず同じ座標系で測ること。**

- 入れ子の分割があるので、`enclosingSplitView` は**向きが一致する最初の
  分割ビュー**を探す（左サイドバーの中に上下分割がある形）。
- 購読の解除は `viewWillMove(toWindow:)` で行う。Swift 6 では非分離の
  `deinit` からメインアクタ隔離のプロパティ（`NSView` は `@MainActor`）に
  触れられない。

#### 進捗の別ウインドウ化と、空き容量の事前検査

進捗表示をウインドウ上のオーバーレイから**独立した小さな窓**へ移した
［ユーザー要望］。`OperationProgressCenter`（アプリ全体で 1 つの受け皿）と
`OperationProgressWindowController`（`NSPanel` の出し入れ）に分かれており、
コピー・移動・削除・圧縮・展開・一括リネーム・診断ログの書き出しがすべて
ここへ集まる。**`FolderOperations` はペインごとに存在する**ので、受け皿を
アプリ全体で 1 つにしないと同じ操作の窓が二重に出る。

- 窓は `NSPanel`（`.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`）。SwiftUI の
  `Window` シーンだと開いた瞬間にキーウインドウを奪い、コピー中に一覧の
  キーボード操作が途切れる。
- 窓の出し入れは `OperationProgressCenter.onActivityChanged`（処理の増減の
  ときだけ呼ぶ明示的なコールバック）で駆動する。`withObservationTracking` は
  通知が 1 回きりで、`onChange` の中から張り直すまでの変更を観測できない
  仕様のため、毎秒 10 回更新される進捗と組み合わせるには向かない。

窓に出す情報［ユーザー要望を順に反映］: 何をしているか（「コピーしています…」）／
**今どのファイルを処理しているか**（名前は中央省略 — 末尾を省くと拡張子や巻数が
消えてどれか分からなくなる）／進捗バー／「12 件中 3 件目 — 残り 9 件 — 1.49 GB /
4.29 GB — 残り約 2 分」／**一時停止**と**キャンセル**。

- **ボタンはバーの下**、右寄せで一時停止がキャンセルの左［ユーザー指摘: バーの
  上に置くのは一般的ではない］。**幅はラベル側で確保する** — `Button` の外に
  `.frame` を付けても枠が広がるだけでカプセルの見た目は変わらず、「再開」だけ
  細いままになる（実機で確認）。
- 状況の行は**折り返さない**［ユーザー指摘］。ボタンと同じ行に置くと横幅を
  奪われるため独立させ、収まらないときだけ少し縮める。
- **残り時間は平均速度から出す**。瞬間速度はファイルの切り替わりやディスクの
  バースト書き込みで大きく振れ、「3 秒 → 2 分 → 10 秒」と暴れて役に立たない。
  速度の基準点は**バイトが実際に動き始めた時点**（開始時刻ではない — 転送前の
  合計サイズの走査が入り、速度を大幅に低く見積もる）。総量が分からない処理や
  計測 1 秒未満では**出さない**（当てにならない数字を出さない方がまし）。
- 件数は `min(completedItems + 1, totalItems)` で頭打ちにする。素朴に +1 すると
  最後に「150 件中 151 件目」と出る（実機で確認）。

**圧縮・展開も進捗を報告するようにした**［ユーザー要望: 件数は圧縮・展開でも
有用］。バックエンドは「今何件目・何バイト目か」だけを報告し、総数は呼び出し側
（`SecureExtractor` は `listEntries` の結果、`ArchiveCompressor` は事前に数えた
ファイル数と総バイト数）が `ProgressThrottle` で足す — 総数のためにバックエンドへ
二重に走査させないため。間引きは転送と同じ 10 回/秒。**展開はステージングから
最終位置への移送にも進捗を流す** — ステージングは常にアプリコンテナ配下（起動
ボリューム）なので、展開先が外部ボリュームならここは実コピーになり、流さないと
100% のままバーが止まって見える。RAR は `qoo_unrar_extract_all` が一括 API の
も、**エントリを 1 件書き出すたびに呼ばれるコールバックを持っている**ので
同じように報告できる（下記「RAR も進捗・一時停止・中断に対応した」参照）。

**一時停止／再開**［ユーザー要望］。`PauseToken`（`QooKit`）を 1 回の操作につき
1 つ作り、`OpOptions`/`ExtractOptions`/`ArchiveCompressor` を通して窓のボタンと
実際の処理の両方へ渡す。待つ場所は 3 つ: `copyfile(3)` の status コールバック
（同期の C なので**その場で待つ**しかない。コピー本体は元々 1 スレッドを占有
し続けているので、占有本数は変わらない）、展開のエントリ境界と書き出しの合間、
圧縮の項目境界、そして RAR のエントリ境界。

- **要は「止めたまま取り消せる」こと。** 素朴に「再開されるまで眠る」実装に
  すると、一時停止した処理を二度と止められなくなる。0.1 秒ごとに目を覚まして
  `Task.isCancelled` を見る。
- 一時停止中は残り時間を出さず、**再開時に速度の基準を取り直す**（止まっていた
  時間を平均に入れると残りが実際よりずっと長く出る）。
- トークンは操作ごとに作り直す（`endProgress()` で捨てる）。持ち越すと、次の
  操作が始めた途端に止まって見える。
- 検証は自動テストで行う。実機のクリックでは**押す前に処理が終わってしまい
  取り逃す**（実際に 2 回取り逃した）。`PauseIntegrationTests` は
  **先に止めてから始める**ことで競争を排除し、実際の `copyfile` 経路で
  「1 バイトも進まない」「止めたままでも取り消せる」を固定している。
  なお `PauseTokenTests` は当初「250ms 待ってから再開し、待ち時間が 200ms を
  超えたか」で見ていたが、**全テスト並行実行時に `Task.detached` の走り出しが
  後回しになって落ちた**。経過時間ではなく状態（待ちに入ったか・抜けたか）で
  判定するよう書き直した。**時間で判定するテストを書くときはこの罠を思い出す
  こと。**

**本命の修正は「空き容量が足りないなら 1 バイトも書かずに断る」**。
ユーザー指摘「容量不足なのにコピー開始することが問題」を受けたもの。実機で
4GB のファイルを空き 2.99GB のボリュームへコピーすると、そのまま書き始めて
2.91GB まで進んでから失敗していた。`FileOperationService.transfer` の冒頭で、
進捗のために既に測っている合計バイト数（`ProgressTracker.requiredBytes`）と
書き込み先の空きを比べ、足りなければ `insufficientFreeSpace` を投げる
（`SecureExtractor` の [EX-23] と同じ考え方。余分な走査は増えない）。

- `ProgressTracker` は**報告先の有無に関わらず**総量を測るようになった。
  進捗表示の都合で検査が抜けてはならないため。クローンで済むと分かる場合
  （同一ボリューム ＋ `volumeSupportsFileCloning`）は 1 バイトも書かないので
  測らず、検査もしない。

**空き容量の求め方を `VolumeCapacity` に一本化した。** 実測で分かったのは、
第一候補の `volumeAvailableCapacityForImportantUsageKey` が**小さな
ボリュームで 0 を返す**こと:

| ボリューム | important | plain |
|---|---|---|
| 200MB のディスクイメージ（空）| **0** | 208 MB |
| 7.3GB の USB（4GB 使用）| 2.99 GB | 2.99 GB |
| 起動ボリューム | 544 GB | 525 GB |

これを「空きゼロ」と解釈すると**空のボリュームへのコピーを全部断ってしまう**
（回帰テストが実際に捕まえた）。0 なら素の `volumeAvailableCapacityKey` へ落とし、
どちらも取れなければ**検査を飛ばす**（＝通す）。誤って断ると正当な操作が
できなくなるのに対し、通しても失敗は `ENOSPC` として捕まり理由付きで伝わる、
という害の非対称に従う。ステータスバーの空き容量表示も同じ関数を見るように
した（それまで独自に読んでいて、同じ理由で「0 バイト空き」と表示していた）。

**`FileOperationError` を `LocalizedError` に準拠させた [ER-03]。** 準拠して
いなかったため、`localizedDescription` が
「操作を完了できませんでした。（QooInfrastructure.FileOperationError エラー2）」
という既定文言になり、payload に入れていた説明がユーザーにもログにも
出ていなかった。あわせて `FileCopyEngine` は errno を文字列へ畳まず
`copyFailed(source:destination:errnoCode:)` として渡す — 「容量不足なのか
権限なのか」を呼び出し側が区別して、次に何ができるかを言えるようにするため。

**進捗の窓が閉じずに残った不具合の真因**（最初に立てた仮説は外れていた）:
`NotificationRouter.presentError` は `withCheckedContinuation` で
**ユーザーがダイアログを閉じるまで完了しない**。`endProgress()` を `defer` に
任せていたため、失敗したコピーの窓が「2.91 GB / 4.29 GB」で止まったまま
エラーダイアログの後ろに残っていた。エラーを見せる**前に**片付けるよう順序を
変えた（`defer` は取りこぼしへの保険として残す）。**教訓: 「窓が消えない」を
観測の不具合と決めつけかけたが、実際は後始末の順序だった。表示が古いまま
なのか、そもそも到達していないのかを先に切り分けること**（今回は「行が残って
いる＝ `finish()` に到達していない」が手がかりだった）。

検証: 実機で ①容量不足のペーストが**即座に**「4.29 GB が必要ですが、空きは
2.99 GB しかありません」と断られ、窓も残らないこと ②収まるコピー（1.5GB）は
成功し窓が自動的に閉じること ③4GB のコピーを途中でキャンセルすると部分
ファイルもエラーも残らず窓も閉じること、を確認済み。自動テストは実際に
`hdiutil` で小さなボリュームを作って「1 バイトも書かずに断る」ことを固定して
いる（作れない環境では静かに飛ばす）。

#### フォルダツリーのキーボード操作（実装済み。ただし遠回りをした）

Finder のサイドバーと同じく、↑ ↓ で行を移動し、→ で展開／最初の子へ、← で
折りたたみ／親へ動く。**矢印キーの処理は 1 行も書いていない** — `List` と
`DisclosureGroup` が最初から持っている。必要だったのは次の 3 点だけ:

1. `List(selection:)` に選択を持たせる。値は URL と枝（`FolderTreeBranch`）の
   両方を持つ `FolderTreeSelection` — 枝が無いと、同じ実フォルダでも
   ボリューム経由かライブラリ経由かを区別できず `NavigationRoot` を決められない。
2. **`.tag()` は `DisclosureGroup` 自身に付ける（label ではない）。**
3. 行の `.onTapGesture` を**外す**。クリックの処理を `List` に任せる。

**この 3 点のうち 1 つでも外すと動かない**、という壊れ方をする:

| 誤り | 症状 |
|---|---|
| `.tag()` を label に付ける | 最初の ↓ で先頭行（Macintosh HD）へ飛び、以後動かない |
| `.onTapGesture` を残す | フォーカスはツリーにあるのに ↑ ↓ が一切効かない（`List` が「今どの行にいるか」を知らないまま） |
| 中央ペインが移動のたびにフォーカスを奪う | **1 回だけ動いて止まる**。`WindowState.navigationCameFromTree` で、ツリー由来の移動ではフォーカスを移さないようにした |

**遠回りの記録（同じ失敗を繰り返さないために）**: 先に `.focusable()` +
`.onKeyPress`、`NSEvent` のローカル監視、と自前でキーを捌く方向を実機で 3 通り
試してすべて失敗した。**そのどれも必要なかった。** CLAUDE.md 冒頭に
「不可解な事象は、重い実機調査に入る前にまず `WebSearch` で既知の問題でないか
調べる」と書いてあるのに、それを飛ばして実機での試行錯誤に入ったのが原因。
検索すれば「タグは `DisclosureGroup` 自身に付ける」は一次情報として即座に
出てくる（`nilcoalescing.com` の解説）。**ユーザーからの「インターネットで
情報収集はしましたか？」という指摘で初めて気づいた。**

診断で得た副産物（今後役に立つ）:

- 行をクリックすると `AXFocusedUIElement` は **`AXOutline`** になる一方、
  SwiftUI の `@FocusState` は真にならない。**この 2 つは一致しない。**
  キーが届かないときは `AXFocusedUIElement` を実機で見て、どちらの世界が
  受け取っているかを先に確かめる。
- ウインドウがまだ現れていない状態で計測すると、意味のある結果に見える
  出力が出る。**手順を整えて再現するまで観測を信用しない**（1 度これで
  「← が動いた」と誤認した）。

### ファイル操作の事前検査とエラー文言の総点検（ユーザー指示）

きっかけは「相手先に十分な容量がないことを確認しないままペーストを実行して
失敗し、かつそのエラーメッセージが失敗要因をまったく伝えないものだった」
という指摘。**予防できたはずの失敗を予防しているか**と、**失敗したときに
理由と次の手が伝わるか**の 2 点で全経路を洗い直した。

**確定した欠陥は、すべて実測で再現してから直した。** 推測で直した箇所は無い。

#### 直したもの

| # | 欠陥 | 実測での確かめ方 |
|---|---|---|
| 1 | **展開中に空きが尽きるとアプリが異常終了する** | 20MB のディスクイメージへ展開して SIGABRT（exit 134）を再現。修正後に旧コードへ一時的に戻し、回帰テストが `uncaught exception of type NSException` を捕まえることまで確認 |
| 2 | 展開の**作業領域**（アプリコンテナ＝起動ボリューム）の空きを検査していない | 展開先だけを見ていた。外部ボリュームへ展開しても全量が起動ボリュームを通る |
| 3 | **フォルダを自身の子孫へコピーできてしまう** | `copyfile(3)` が 332 階層まで自己増殖し、ユーザーのフォルダ内にゴミの木を残してから `ENAMETOOLONG` で失敗した。同一ボリュームの移動は `rename(2)` が `EINVAL` で止めるが、コピーは止まらない |
| 4 | 圧縮に空き容量の事前検査が**一切無い** | 失敗しても「アーカイブを処理できませんでした。（Write error）」としか出なかった |
| 5 | **`/` を含む名前でリネームすると別フォルダへの移動になる** | 実測で再現。ユーザーから見れば「名前を変えたはずのファイルが消える」。新規フォルダでは入れ子が 2 つできる |
| 6 | パス全体の長さを検査していない | 全形式で 1024 バイト（`PATH_MAX`）で止まることを実測 |
| 7 | 読み取り専用ボリュームを検査していない | `VolumeCapability.isReadOnly` は計算されていたのに**誰も読んでいなかった**。登録すると実測用ファイルの作成が失敗して `probeSetupFailed`（当時は文言も無し）になっていた |
| 8 | **Undo/Redo の失敗がユーザーに一切見えない** | ログと操作履歴（閲覧 UI 無し）に書くだけだった。⌘Z が失敗しても画面には何も出ない |
| 9 | `VolumeEligibilityError`/`RegisteredFolderError`/`BookmarkAccessError`/`DiagnosticExportError` が `LocalizedError` 未準拠 | 「…エラー0」形式に潰れる。`FileOperationError`/`ExtractError` で 2 度踏んだのと同じ落とし穴 |
| 10 | 移動の失敗だけ `strerror` の英語を素で埋め込んでいた | 「移動に失敗しました（Read-only file system）: x」。コピーなら出る説明も対処法も出ない |
| 11 | Foundation エラーの `recoverySuggestion` を捨てていた | 実測で「Try saving the file to another volume.」が付いてくるのに `localizedDescription` しか見ていなかった＝ ER-03 の三要素の三つ目が手元にあるのに未表示 |
| 12 | 従来型 ZIP 暗号化で、**パスワード違いが約 1/256 の確率で別の文言になる** | 既存テストが不定期に落ちる形で判明。ZipCrypto は 1 バイトの検査値しか持たないため、誤ったパスワードでも検査を通過して「ZIP decompression failed (-3)」になる |

新しく置いた共有部品: `PosixFailure`（errno → 原因と対処の翻訳。コピー・移動・
展開が同じ説明になる）、`FileNameValidation`（名前の検証）、`PathLimits`
（`pathconf` によるパス長上限）。

#### 名前とパスの制限は実測で決めた（推測で禁止文字を増やさない）

macOS がマウントし得る形式すべて（APFS / APFS 大文字小文字区別 / HFS+ /
HFS+ 大文字小文字区別 / exFAT / FAT12・16・32 / UDF / SMB〈実 NAS〉）で
同じ名前を作って確かめた。

- **どの形式でも拒否されたのは `/` と `.` と `..` だけ。** Windows で禁止の
  `\ : * ? " < > |` も、改行・タブ・制御文字も、末尾の空白・ドットも、
  先頭ドットも、**SMB を含む全形式が受け付けた**。したがってこれらを
  アプリ側で禁止すると、実際には作れる名前を理由なく拒むことになる。
- **名前の長さの単位は形式ごとに違う。**

  | 形式 | `あ` の最大個数 | `が`(NFC) の最大個数 | 実質の単位 |
  |---|---|---|---|
  | APFS / HFS+ | 255 | 127 | NFD 後の UTF-16 単位 255 |
  | exFAT / FAT | 255 | 165 | 駆動側の正規化に依存 |
  | SMB（実 NAS）| 85 | 85 | UTF-8 バイト 255 |
  | UDF | 78 | 39 | さらに短い |

  **単一の規則では正確に予測できない**ため、最も緩い APFS/HFS+ の規則
  （NFD 後 255 単位）を採り、それより短い形式で弾かれた場合は
  `ENAMETOOLONG` を `PosixFailure` が説明する。緩い側に倒すのは
  「誤って拒否すると正当な操作ができなくなる」のに対し「通しても理由付きで
  伝わる」という害の非対称による（`VolumeCapacity` と同じ判断）。
  **バイト基準にすると日本語 86 文字で誤って弾く。**
- **パス全体は全形式で 1024 バイト**（`PATH_MAX`）。`pathconf(_PC_PATH_MAX)`
  は APFS/HFS+/UDF/SMB では 1024 を返すが、**exFAT と FAT では -1（不明）**
  を返すため `PATH_MAX` へ落とす。
- 外部情報とも突き合わせた: `FileHandle.write(_:)` の例外は SwiftyBeaver で
  実際にクラッシュ報告がある／macOS の `PATH_MAX` は 1024 で、成分 255・
  パス 1023 超で `ENAMETOOLONG`／SMB は UTF-8 255 バイト（日本語は 3 バイト）
  ／Apple Developer Forums に「`NAME_MAX` は APFS では当てにならない」旨の
  スレッドがあり、`pathconf(_PC_NAME_MAX)` に頼らない判断を裏付けている。

#### 直さなかったもの（理由とともに残す）

- **`transfer()` は一括処理の途中で失敗すると、成功済みの `OpReceipt` を
  丸ごと破棄する**（Undo にも履歴にも残らない）。フェーズ1完了前監査からの
  既知の課題で、正しく直すには「部分失敗をどう見せるか」の設計
  （`BatchNotificationSession`、ER-10〜16）が要る。今回の事前検査で
  **途中失敗そのものが起きにくくなった**が、根治はしていない。
- **ゴミ箱を持てないボリューム**（ネットワーク等）での削除は 1-16b のまま。
  実測しようとしたが `NSWorkspace.recycle` の挙動を確かめる probe が
  この環境で完走せず、**確かめられていないことは書かない**方針で保留した。
- `FileOperationError.sourceNotFound` はどこからも投げられない死んだケース。

#### 検証で踏んだこと（次回のために）

- **測定コードのバグを「実装の欠陥」と誤読しかけた。** 全形式で結果が同一かつ
  「最大 0」になったとき、`defer` の挙動を疑ったが無実で、真因は自分の probe が
  `.` を試す際に `base + "/."` を `removeItem` して**測定用フォルダごと消して
  いた**こと。結果が不自然に揃ったら、まず測定手段を疑う。
- **既存テストの競合を自分の変更のせいだと誤読しかけた。**
  `cancellingAPausedFolderCopyLeavesNoPartialTree` は「バイトが動くのを
  ポーリングで待ってから `pause()`」という作りで、80MB のコピーが気づくより
  先に終わり得た。新しいテストが増えて I/O が混んだことで表面化しただけで、
  製品側の退行ではない。**報告コールバックの中で止める**形に変えて競合を
  無くした（ただし `completedBytes > 0` を条件にしないと、開始時の 0 バイト
  報告で止まってしまい「途中の状態」が作れない）。
- ユーザーの実 NAS で測る際は、専用の一時フォルダだけを作り、既存の中身には
  触れず、最後に必ず消したことを確認する。

### 1-16b（ネットワークボリューム・File Provider）— 実測完了

> **この節より下の「事前調査」の記述は、実測前の仮説である。**
> 実測で覆ったものが複数あるため、**`08_インフラ_ファイル操作.md` §8.11 を正とすること。**
>
> 実測で判明した主なもの（詳細は §8.11）:
> - **能力フラグは偽陽性・偽陰性の両方を出す。** Windows は `supportsPersistentIDs=×` を
>   返すのに実際の同一性は完璧に安定していた（NTFS の sequence number で誤同定も起きない）。
>   一方 Samba は `st_ino` がパス名のハッシュで、**削除→同名再作成で同じ値が再利用される**
>   （＝別ファイルの誤同定が実在）。原因は Samba の `fruit:zero_file_id`（既定 `yes`）
> - **`volumeUUIDString` は SMB 3 系統すべてで nil。** `FileIdentity` の
>   `volumeUUIDString ?? ""` により、**異なる 2 共有で別ファイルが同一と判定され得る**
> - **ゴミ箱は SMB 3 系統すべてで存在しない。** `NSWorkspace.recycle` は OS の確認
>   ダイアログを出し、承諾すると完全削除・**返却 URL 0 件**（＝⌘Z が無言で何もしない）
> - **協調スレッドプールはコア数ぶんのブロッキング I/O で枯渇する**（実測）。
>   SMB は 30 秒で解放されるが **NFS の hard マウント（既定）は無限**
> - **FSEvents はネットワークでも動く。** 届かないのは「この Mac のカーネルを
>   通らない変更」だけ。`DirectoryChangeHub` の併用設計は両輪とも妥当だった
> - **iCloud は起動ボリュームと同じ `volumeUUID` を返し、あらゆるネットワーク判定を
>   すり抜ける。** `SF_DATALESS` は 0ms で確実に判定できる
>
> **測定に使った検証手順の教訓は §6.1 と本節末尾に集約してある。**

#### 再チェックで見つけた「状態遷移の穴」

実測を終えたあと、**問題領域の側から次元表**（環境の**状態**＝接続中／劣化／切断／
再接続中／未マウント × 操作 × 失敗様式 × 前提）を作って洗い直したところ、
**それまでの調査が「接続中」に偏っていた**ことが分かり、11 件の穴が出た
（§8.11.11、NV-91〜NV-101）。最重要は 3 つ:

- **NV-91 起動時のブックマーク解決がネットワークで詰まる。** `loadAndActivateAll()`
  ×2 が全件を `.withoutMounting` **なしで**解決する。BM-5 のとおり解決はマウントを
  起こすので、サーバ不在なら**起動時にブロックし、ユーザーが何もしていないのに
  認証ダイアログが出る**
- **NV-92 `.qoo-replace-backup-*` を共有上に作る。** 切断中は復元も失敗するため、
  **元ファイルがその名前のまま残る＝ユーザーから見れば消失**
- **NV-93 一時的な切断でタブが退避され履歴が壊れる。** RG3-06 は 1-17 の予定だが、
  ネットワークでは切断が日常なので**前倒しが要る**

**教訓: 「網羅した」と思ったあとでも、軸を 1 つ（ここでは "状態"）足すだけで
新しい面が出る。** §6.1 の手順（次元表を先に作る）は正しかったが、
**最初の次元表に「状態」の軸が無かった**。次元表そのものをレビューする必要がある。

#### 実測前の事前調査（履歴として残す）

ユーザー指示により、**コードを一切読まず、実測もせず、インターネット検索と一般知識だけで**、
ネットワークボリューム上のファイル操作の留意点を構造的・網羅的に洗い出した。
**成果は `08_インフラ_ファイル操作.md` §8.11（NV-10〜NV-88）にある。実装は行っていない。**

- **全項目が未実測の仮説である**ことを §8.11 の冒頭に強く明記した。本プロジェクトは
  フラグ名や一般論からの推測が実測で覆った事例を繰り返している（`volumeIsEjectable`、
  `move to trash.aif`、`--without-lzma`、`volumeAvailableCapacityForImportantUsage`）ため、
  調査結果をそのまま設計に組み込ませないことを最優先にした。一次情報（Apple の公式
  ドキュメント・man page・DTS 回答）と二次情報（フォーラム・ベンダー文書）を表中で
  区別し、二次情報は「そういう報告がある」以上の重みを持たせていない。
- ~~§8.11.8 に検証計画を置いた~~ → **実測済み。残る未検証項目は §8.11.11 に移した。** 当時の上位 4 件
  （`volumeUUIDString`／inode が何を返すか・`renamex_np(RENAME_EXCL)` が通るか・
  `NSWorkspace.recycle` の実挙動・TCC「ネットワークボリューム」権限）は、**未確定のまま
  進むと上書き事故か検証不能に直結する**。
- **既存記述の食い違いを 1 件見つけて訂正した**: §8.4 と 10章 §10.0 が「検証に使える
  ネットワークボリュームが無いため未確認」と書いていたが、**その後の 1-16c（名前長・
  パス長の実測）で実 NAS を SMB 経由で使っている**ため、この前提はもう成り立たない。
  両方に訂正を入れた。**古い「できない」の記録は、後の作業で状況が変わっても自動的には
  更新されない** — 前提を書くときは、それが覆ったときに気づける形にしておくこと。
- 他章への波及として、9章 §9.6（サムネイル一括制御 DS-01〜07 が I/O 増幅の縮退の器に
  なること）、10章 §10.0（ポーリング経路が働くか自体が未検証であること）、17章
  （1-16b が 2-1 のファイル同一性と 2-2 の着脱検知の前提であること）に相互参照を張った。
- **調査の範囲について**: 「ネットワークボリューム」を SMB だけでなく NFS / WebDAV /
  FUSE 系 / **File Provider 系クラウド**（`~/Library/CloudStorage/`）まで広げた。後者は
  `volumeIsLocal` が `true` を返すため**ネットワーク判定をすべてすり抜ける**にもかかわらず
  実体はネットワークで、単純な列挙＋サムネイル生成が**ユーザのクラウドを全件ダウンロード
  させる**（NV-70〜NV-74）。ここは実装着手前に気づけたのが大きい。

#### 洗い直し後の P1 対応（4 件）

前節の総点検を「完了」と報告した直後、ユーザーの「この程度のことで見つかる穴が
あるなら手法自体に問題があるのでは」という指摘で全面的に洗い直した。
**視野の拡大がすべてユーザー発だった**（SMB・HFS+/exFAT・全形式・パス長・
検索での裏取り）ことが手法の欠陥の証拠で、真因は**コードから出発して失敗を
列挙した**こと。問題領域の側から次元表を作ったところ、全 41 次元のうち
**19 が視野に入っていなかった**。

| # | 対応 | 実測での確かめ方 |
|---|---|---|
| P1-1 | **大小のみのリネームが弾かれる**（Finder ではできる） | `comic.cbz`→`Comic.cbz` で「すでに存在します」。同一実体かを `FileIdentity`（inode）で見て衝突判定から外した |
| P1-2 | **一括の途中失敗で成功分の記録を失う** | 4 件中 3 件移動後に失敗させると、移動済み 3 件が Undo にも履歴にも残らなかった。`PartialTransferFailure` で受領書を運び、`.partial` として返す |
| P1-3 | 協調読み取り（`NSFileCoordinator`）| ~~不要と判明~~ → **[1-16b で差し戻し] この結論は測定条件に依存していた。** 下記の実測は**ロック構造を持たない単発スクリプト**で行ったもので、`actor` と同時実行スロットを持つ実アプリには一般化できない。File Provider 配下の読み取りで `EDEADLK`（errno 35）が起きる事例が iCloud・Google Drive・Dropbox・OneDrive・Box で報告されており、原因は「同期読み取り中にロックを保持したまま File Provider が同じプロセスへコールバックする」こと。**協調プール枯渇（1-16b で実測）と組み合わさると本物のデッドロックになり得る。** 詳細と決定事項は `08_インフラ_ファイル操作.md` §8.11.8 |
| P1-4 | **クラウド上のファイルを勝手にダウンロードする** | dataless なファイルのサムネイル生成を止めた |

**測って否定された疑い（直さずに済んだ）**:

1. **`RENAME_EXCL` 非対応ボリュームで上書きされる** → **全形式で守られた**
   （APFS/HFS+/exFAT/FAT/UDF/**SMB** すべて errno=EEXIST）。能力キー
   `volumeSupportsExclusiveRenaming` は exFAT/FAT/UDF/SMB で `×` を返すが、
   **能力キーは振る舞いを予測しない** — VFS が肩代わりする。
2. **展開時に NFC/NFD が衝突して片方が消える** → 正しく連番が付いた
   （9.4 節の「読み込み時も NFC 正規化」がここで効いていた）。
3. **dataless ファイルは協調読み取りなしでは読めない・固まる** → **読める**。
   協調ありと差が無かった（どちらも約 1 秒で成功）。

**3 つ疑って本物は 1 つ。測らずに直していたら、無い問題のためにコードを
複雑にしていた。**

**dataless ファイルの実測値**（iCloud Drive、`evictUbiquitousItem` で追い出し）:

| 読み方 | 結果 |
|---|---|
| 素の `Data(contentsOf:)`（協調なし） | 成功・約 1 秒（その場でダウンロード）|
| `FileHandle` で先頭だけ | 成功・約 1 秒 |
| `NSFileCoordinator` 経由 | 成功・**協調なしと差が無い** |
| `fileSize` / `totalFileAllocatedSize` | 満額 / **0** |

**本当の問題は「読めない」ではなく「1 件約 1 秒かけて実際にダウンロードが
走る」こと。** 一覧を開くだけで何百件も自動生成されるサムネイルがこれを
起こすと、頼んでもいない蔵書全体のダウンロードが始まる。Finder も追い出された
ファイルのサムネイルは作らない。**ユーザーが明示的に頼んだ操作（Quick Look・
展開・開く）は従来どおり実体化する**——頼まれた仕事はやる。

**実装上の落とし穴（この作業で踏んだ）**: 部分失敗を `CommandStack` の中から
`NotificationRouter` で提示したところ、**テストが永久に返らなくなった**
（`presentModally` は提示側がいないと完了しない）。加えて、呼び出し側が
進捗ウインドウを片付ける前にダイアログが出てしまう。**提示は呼び出し側の
責務**に戻し、`CommandStack` は結果（`UndoOutcome`/`CommandResult`）を返すだけに
した。`CommandStack` から UI の完了を待ってはならない。

**検証の作法について（NAS の件）**: SMB の名前制限を測るため、確認を取らずに
ユーザーの稼働中 NAS へ数千回の作成・削除を走らせて叱責を受けた。**測定対象が
自分で用意した使い捨てでないなら、触る前に必ず確認を取る。** その後の
iCloud・SMB の実測はいずれも事前許可を得て、最小限（数バイト×数個）で行い、
前後の状態を報告して片付けを確認した。なお**ボリューム能力の大半は
`URLResourceKey` で「尋ねるだけ」で分かる**（`volumeMaximumFileSizeKey` 等
40 種以上）ので、そもそも書き込んで測る必要はほとんど無い。

#### 洗い直し後の P2 対応

| # | 対応 | 実測での確かめ方 |
|---|---|---|
| A7 | **FAT32 の 4GB ファイルサイズ上限**を事前検査 | `volumeMaximumFileSize` が 4.29 GB を申告し、超過は `EFBIG` で拒否されることを実測（4GB を書かずスパースファイルで検証）|
| A5 | **名前の長さ**を書き込み先の規則で事前検査 | SMB は UTF-8 で 255 バイト。日本語 104 文字（304 バイト）のコピーが**書き込み前に**断られることを実 NAS で確認（NAS への書き込みはゼロ）|
| B3 | **処理中に書き換えられた元ファイル**を検出 | コピー開始前 72.3MB → 最終 84.9MB の間に `copyfile` が 72.3MB を写して**成功を返した**。移動はこの後に元を消すため書き足し分が永久に失われる |

**測って否定された疑い（続き）**:

4. **`volumeSupportsExclusiveRenaming` が `×` の形式で上書きされる** → 全形式で守られた（前節）。
5. **シンボリックリンク非対応の書き込み先がある** → 能力キーの実測で**全形式が `○`**。対処不要。
6. **SIP 保護（`SF_RESTRICTED`）のファイルはコピーできない** → Dock.app 等も**すべて成功**。SIP は変更を防ぐもので読み取りは妨げない。`com.apple.rootless` はこのマシンでは見つからず。

**P1・P2 の累計は 対応 10 件・実測で否定 7 件。**

**自分の事前検査が作り込んでいた不具合を 2 つ、テストが暴いた**:

1. **空き容量の余裕分が固定値**だった（コピー 64MB / 展開 1GB）。**空きがそれを
   下回るボリュームでは、どんな小さな操作も拒否**されていた（60MB のイメージへ
   1MB のコピーが断られて発覚）。`VolumeCapacity.margin` でボリューム全体の
   5% を上限に縮めるようにした。**「誤って断らない」と繰り返し言いながら、
   自分でその穴を作っていた。**
2. **パス長の上限を項目ごとに `pathconf` で問い合わせて**いた。ネットワーク
   ボリュームでは 1 回ごとに往復が発生し得るため、1,000 件の一括処理で
   1,000 回問い合わせることになる［ユーザー指摘: SMB は常時接続できるわけ
   ではない］。書き込み先への問い合わせは 1 回だけにした。

#### 洗い直し後の P3（メタデータの静かな喪失）— **実測の結果、コード変更なし**

「データは無事だが、付随情報が黙って失われる」区分。**実測したところ、
どれも対処が要らないと分かった**ので何も直していない。以下はその根拠で、
同じ疑いが再燃したときに測り直さずに済むよう残す。

| 次元 | 実測結果 | 判断 |
|---|---|---|
| A10 xattr | 全形式で**保持された**（exFAT/FAT は `._` サイドカーに退避）| 対処不要 |
| A11 ACL | exFAT/FAT へのコピーは **`rc=0` で成功**し、ACL だけ静かに落ちる（機能不全ではない）| コミックのファイルに ACL を付ける運用が無いため対処不要 |
| A13 ハードリンク | 3 本のリンク（実占有 2.9MB）をコピーすると **8.6MB に展開**。Finder・`cp -R` と同じ挙動 | **空き容量の見積もりは展開後の 8.6MB を正しく予測する**（`fileSize` の合計）ので、断りすぎも断らなさすぎも起きない。対処不要 |
| A16 所有権 | exFAT/FAT は非対応（マウントしたユーザーの持ち物になる）| 単一ユーザーのライブラリでは影響なし |
| B2 スパース | 非対応の形式では実体に展開される（UDF で 512B → 8.4MB）| 見積もりは論理サイズを使うので正しい。対処不要 |
| **A17 更新日時の精度** | **FAT（msdos）はナノ秒が常に 0 で、精度が 2 秒しかない**。0.3 秒後・同じ大きさの書き換えを検出できない。APFS/HFS+/exFAT は検出できる | **限界として記録するにとどめた**（`FileContentStamp` に明記）。内容のハッシュを取れば確実だが、一覧を開くたびに全ファイルを読むことになり釣り合わない。加えて FAT は永続 ID を持たず**ライブラリ登録できない**ため、この印に頼る場面にそもそも現れない |

**P1〜P3 の累計: 対応 10 件・実測で否定 10 件。** 疑いの半分は実測で消えた。

**検証用ボリュームが 5 つ残っていたのを見つけて直した。** FAT は `-volname` を
無視して「NO NAME」でマウントするため、複数同時に作ると「NO NAME 1」…と
衝突し、`TinyVolume.destroy()` が外し損ねていた。`hdiutil attach -mountpoint`
で場所を固定して解決。**使い捨てのボリュームを作るときは、名前が保存される
形式かどうかに依存しないこと。**

#### NAS の挙動を前提にした結論には保険を掛ける［ユーザー指摘］

**「今回の NAS では大丈夫でも、他の NAS ではダメかもしれない」** — NAS の OS は
千差万別なので、手元の 1 台で確かめた挙動を一般化してはならない。SMB を
前提にした「対処不要」の結論を洗い直した結果:

| 前提 | 保険の要否 |
|---|---|
| **更新日時がナノ秒精度で、同サイズの書き換えを見分けられる** | **要**。1 秒精度のサーバなら取り逃がし、その先は**元ファイルの削除＝データ喪失**。→ `MoveVerification` を追加 |
| `RENAME_EXCL`/`COPYFILE_EXCL` が守られる | **不要**。`COPYFILE_EXCL` の実体は `open(O_CREAT|O_EXCL)` そのもので、自前で同じことをしても強くならない。加えて `resolveDestination` の存在確認は書き込みの直前（間はローカル処理のマイクロ秒）に行われるため、無視されても露出はその極小の隙間だけ |
| xattr / ACL / ハードリンク / 所有権 | **不要**。いずれもメタデータの喪失にとどまり、データは無事 |

**`MoveVerification`（新規）**: クロスボリュームの移動は「コピーしてから元を
消す」ため、写した内容が元と食い違ったまま消すと差分が永久に失われる。
**更新日時にまったく依存しない確認**として、元を消す前に内容を抜き取り
（先頭・中央・末尾の 64KB）で突き合わせる。フォルダは件数と合計バイト数で
突き合わせる（木全体を読み直すと移動のたびに読み取りが 2 倍になるため）。
**完全な保証ではない**が、「元を消してよいか」を更新日時だけに委ねるより
はるかに堅い。判定できない場合は断らない側に倒す。

**却下した案**: 上書きを `st_birthtime` で検出する。実測すると **APFS では
上書きで birthtime が変わり**（SMB では保たれた）、検出手段として成立しない。

#### 失敗の伝え方を体系化する（エラー文言の棚卸し）［ユーザー指示］

「失敗の要因に応じた適切なメッセージを、網羅的かつ体系的に」という指示で、
**ユーザーに見える全パターンを機械的に書き出してから**直した。場当たりに
直さないため、まず一覧を作り、それを読んで欠陥を判定する順にした。

**見つけた欠陥（棚卸しで判明）**:

| 欠陥 | 例 |
|---|---|
| 題と本文で「できませんでした」が**二重** | 題「コピーできませんでした」＋本文「…へ処理できませんでした。」 |
| 未知の `errno` で**同じ文が 2 回** | 「…処理できませんでした。処理できませんでした。（Unknown error: 9999）」 |
| **英語が本文に混入** | 「（Write error）」「（Unknown error: 9999）」 |
| **「次に何ができるか」が無い**ケースが 9 件 | `unsupportedFormat`/`passwordProtected`/`tooManyEntries` ほか |
| 文脈が噛み合わない | フォルダ登録の失敗で「**書き込み先に**書き込む権限がありません」 |
| 桁区切り無し | 「上限 100000 件」 |
| **`error.moveFailed` がカタログに無い** | 移動の失敗で題が**生の鍵のまま**出ていた |
| `PartialTransferFailure` が `LocalizedError` 未準拠 | 展開の移送が部分失敗すると「エラー1」形式 |
| `NotificationItem.technicalDetail` を**アラートが捨てていた** | 運んでいるのに表示側で無視 |

**体系化の骨**: 主要なエラー型を `UserPresentableError`（既存・未活用だった）
に準拠させた。三要素（何が／なぜ／次に何ができるか）と技術詳細を**型として
要求する**ので、**ケースを足せばコンパイラの網羅性検査が書き忘れを止める**。
合成の規則（どれを題に、どれを本文に、どれを折りたたみに）は
`NotificationRouter.presentError` の**1 箇所だけ**が決める。

```
題      : 何をしようとして失敗したか（呼び出し側が知っている）
本文    : 何が起きたか → なぜ → 次に何ができるか（エラー型が知っている）
折りたたみ: 技術詳細（errno・ライブラリの英語）→「詳細をコピー」ボタン
```

**準拠させた型**: `FileOperationError` / `ExtractError` /
`RegisteredFolderError` / `VolumeEligibilityError` / `PartialTransferFailure`。
`PosixFailure` は「理由」と「対処」を分けて返すようにし、`Context`
（書き込み先か、対象そのものか）を受け取る。

**安全網**: 準拠を忘れた型・将来増える型が来ても、
`looksLikeTheUninformativeDefault` が「…error 1.)」形式を検出し、
「原因を特定できないエラーが起きました。…診断情報を書き出してください」＋
生の文言を折りたたみへ回す。**型名の形は当てにしない** — 入れ子で宣言された
型は「(d.(unknown context at $113f78388).Inner error 1.)」になり、
「Module.Type」を期待する正規表現では捕まえられなかった［実測］。

**やってしまった設計ミス**: 助言の文章を `RecoveryAction`（ボタン）に変換した
ところ、「不要な項目を削除して空きを増やすか、別の場所を選んでください。」が
**ボタン名**になり、しかも「ボタンがあるなら文章は出さない」規則により
**助言が本文から消えた**。押して意味のある操作だけをボタンにし、助言は
`recoveryHint`（文章）として本文に置く形に直した。

**新しい静的検査 `Scripts/check-localization-keys.swift`（CI 済み）**:
コードが参照する文字列カタログの鍵が定義されているかを検査する。
`String(localized:)` は鍵が無いと**鍵自身を返す**ため、コンパイルも実行も
通ってしまい、実際にその操作を失敗させないと気づけない。SF Symbol 名
（`folder.badge.plus`）やファイル名（`diagnostics.json`）は形が似ているので、
`systemImage:`/`systemName:` の直後かどうかと拡張子で除外する。

##### テストが空振りしていないことを毎回確かめる

**この節の作業で、書いたテストが 4 回空振りしていた。** いずれも
「**検査を外したら本当に落ちるか**」を確かめて発覚した。この手順を省くと、
動かないテストを抱えたまま「完了」と報告することになる。

| 空振りの原因 | 直し方 |
|---|---|
| `TinyVolume` がマウント先を volname から推測 → **FAT は名前を大文字化する**ため一致せず `nil` を返し、FAT を使う検証が全部飛んでいた（しかもイメージが残る）| `hdiutil attach` の出力から実際のマウント先を取る |
| 「書き足し続ける別プロセス」と競争 → コピーが先に終わる | 競争をやめる |
| 進捗を見て一時停止し書き足す → 250MB のコピーが実測 **0.071 秒**で完走 | 同上 |
| 進捗コールバックで書き足す → `addBytes` は **100ms 間引き**のため速いコピーでは 1 度も出ず、`completedBytes > 0` の報告は**完了後**の 1 回だけ | `onBytesCopied`（間引きなしでコピー中に呼ばれる）を使う。そのため `FileOperationService.moveItem` を `internal` にした |
| 更新日時を `utimes` で戻して「粗いタイムスタンプ」を再現 → `utimes` は**マイクロ秒まで**しか扱えずナノ秒が 0 になり、既存の検査に捕まって新しい保険を試せていなかった | `utimensat` でナノ秒まで戻す |
| **まだコピーが読んでいない領域**を書き換えていた → その内容がそのまま写るだけで欠落は起きず、検証が通るのが正しい状況だった（テストがデータ喪失を再現していなかった）| **既にコピーが読み終えた領域**（先頭）を書き換える |

**I/O の重いテストは `.serialized` にする。** ディスクイメージを作る suite を
並列に回すと、FSEvents の到達を待つ既存の検証（猶予 10 秒）が間に合わなくなる。

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
| 1-12 | 環境設定（一般・表示・キーボード・キャッシュの実装可能な範囲、関連付け/スキャン/データ/通知/詳細は Phase 2 以降） | 完了（実装可能な範囲） |
| 1-14 | Quick Look 連携（QL-01〜QL-10）／完全削除（FM-14〜18）／サムネイル表示制御（DS-01〜07） | 完了 |
| 1-15 | 診断ログ（LG2-01〜08） | 完了 |
| 1-16 | Finder 対比監査で「B（技術的には実装できるが未着手）」と分類した項目を、可能な範囲で実装する（要件定義書には無い、ユーザー要望） | 完了（移動メニュー・表示メニュー＋ステータスバー・イジェクト・検索。印刷とサービスは対象外／見送りと決定） |
| 1-16b | **ネットワークボリューム・File Provider の扱い**（ゴミ箱・同一性・変更検知・実行モデル・性能縮退）| **実測完了・実装未着手。** SMB 3 系統（Samba/QNAP・Apple・Windows）と iCloud で測定し、`08_インフラ_ファイル操作.md` §8.11 を実測結果と決定事項で全面的に書き換えた。**記述には [実測]／[普遍]／[依存]／[文献] の札が付いているので必ず確認すること。** 残る未検証項目は §8.11.11 |
| 1-17 | 登録フォルダの縮退状態（オフライン／ゴミ箱／消失の区別、`08_インフラ_ファイル操作.md` §8.7.1）| 未着手（設計のみ完了）|

- フェーズ 1 の 4 制約（DP-01 Undo 基盤 / DP-05 FileOps 集約 / DP-07 mainContext 構成 / DP-08 通知基盤）は機能追加より先に固める。後付けは大規模改修になる。DP-05（FileOps 集約）は 1-5 で、DP-01（Undo 基盤）は 1-11 でそれぞれ完了済み。DP-07（mainContext 構成）は SwiftData 導入（フェーズ2）まで対象外、DP-08（通知基盤）は 1-12b が対象。
- フェーズ 2 の最初に `VersionedSchema` を導入する。パーサ（`QooKit`）は永続化と並行実装できるため早期着手を推奨。
- 各フェーズの DoD（完了条件、17 章に記載）を満たさないまま次フェーズへ進まない。
- **各フェーズ（1・2・3）の完了時に、リソースリークとファイル安全性に特化した監査を必ず実施する**［ユーザー指示、要件定義書には無い恒常的なプロセス。フェーズ1の完了時点で最初に実施し、フェーズ2・3それぞれの完了時にも同様に実施すること］。観点は具体的に次の3点（ユーザーの言葉をそのまま基準にする）:
  1. **リソースリークが無いか、潜在的な危険性・予防策が無いか。** Security-Scoped Bookmark の `startAccessingSecurityScopedResource`/`stopAccessingSecurityScopedResource` の対応漏れ、ファイルハンドル・NSFileHandle のクローズ漏れ、`ThumbnailService`（PF-11）や `LockManager` 等の同時実行スロット・排他ロックの解放漏れ（特に例外・キャンセル経路）、Combine/KVO オブザーバの `invalidate()` 漏れ、Task の無限リーク（`Task { }` の結果を誰も待たず取り消しもされないまま残り続けるパターン）等。
  2. **カット＆ペースト等の操作で、ファイル消失を引き起こす危険性が本当に無いか。** `SessionState.cutURLs` の状態管理、移動・削除・Undo の各コマンドが「元に戻せる」という前提を本当に満たしているか、部分的な失敗（一括操作の一部だけ成功した場合）でファイルが行方不明にならないか。
  3. **壊れたファイルで健康なファイルを書き潰してしまう恐れが無いか。** `FileOperationService` の衝突処理（`.replace` 等）が、書き込み中の失敗（ディスク容量不足・権限エラー・アプリのクラッシュ等）に対して、コピー元やコピー先の一時ファイルを介さず直接上書きすることで、失敗時に**両方**のファイルを失う経路が無いか。`SecureExtractor`/`ArchiveCompressor` のステージング→昇格（`promoteFromStaging`）の途中で失敗した場合に、宛先の既存ファイルが壊れた状態のまま残らないか。
  - **監査にかける時間に上限を設けない**［ユーザー指示、明示的に強調された制約］。表面的なパターンマッチではなく、`FileOperationService`/`SecureExtractor`/`ArchiveCompressor`/`CommandStack`/`RegisteredFolderStore`/`VolumeAccessStore`/`AppAssociationStore`/`ThumbnailService`/`DropHandling` など、実際にファイルシステムを変更する・外部リソースを保持するコードパスを実際に読み、必要なら `code-review`（本リポジトリで使える最高深度のレビュー）を活用して徹底的に行う。
  - 監査で見つかった問題は、修正するか、修正しない場合はその理由（意図的なトレードオフである等）を明記して記録する。監査結果・修正内容は本 CLAUDE.md に記録すること。
- **標準フレームワークが思ったとおりに動かないとき、`WebSearch`/`WebFetch` で先に調べる。**［ユーザー指示。**このルールは一度、判断に委ねていたために発火せず、半日を溶かした** — 下記「発火条件を回数にした理由」参照］

  発火条件は判断ではなく**回数**にする:

  | # | いつ止まるか |
  |---|---|
  | R-1 | **同じ症状に対して 2 回目の実装アプローチに入る前**。1 回目が失敗した時点で、自分の理解が間違っている可能性が高い。そこで必ず検索する |
  | R-2 | フレームワークの**挙動の理由**を推測し始めたとき（「たぶん `NSOutlineView` が食べている」等）。**もっともらしい説明を思いつくと検索したくなくなる**——そこが一番危ない |
  | R-3 | 重い実機調査（`sample`・`git stash` バイセクト・スタック採取）に入る前 |

  **「デバッグ」だけでなく「実装」にも効く。** 以前の書き方は「不可解な事象に**遭遇したら**」で、新機能を作っていて動かない場面（＝異常ではなく、単に作り方が分かっていない場面）に当てはまらないと自分で判断してしまった。**新しく書いたコードが動かないのも対象。**

  **費用の非対称**を毎回思い出すこと: 検索は数十秒。実機ループ（実装→ビルド→起動→操作→観察）は 1 周 3〜5 分で、そのうえ**ユーザーの画面を奪い、権限ダイアログを出させる**。3 周やる前に 1 回検索する方が、あらゆる意味で安い。

  検索で手がかりが無かった場合に初めて、実機再現・バイセクト・スタックトレース採取へ進む。**検索結果は仮説として実機検証で必ず裏取りする**（Apple Developer Forums のワークアラウンドが実機では効かなかった例もある）。

- **フレームワークの挙動を説明するコメントは、根拠を示せないなら書かない。** 実測なら `[実測]`、文献なら出典、確かめていないなら `[仮説]` と明記する。**推測を事実の口調で書かない。**［今回、`.tag()` の位置について「`DisclosureGroup` 全体に付けると子の領域まで 1 行として扱われる」という**自分の思い込みを断定形でコメントに書いた**。実際は逆で、公式に近い解説には「タグは `DisclosureGroup` 自身に付ける」と明記されていた。そのまま残っていれば、次に読む人を恒久的に誤らせていた］

### 6.1 「点検・監査」を任されたときの手順（失敗から作った規則）

**背景**: ファイル操作の総点検で、コードを読んで見つけた不具合を直し
「総点検が完了しました」と報告した。その直後、ネットワークボリュームに
ついての短い問いだけで穴が露出し、**調査そのものをやり直すことになった**。
問題領域の側から次元表を作り直したところ、**全 41 次元のうち 19 が視野に
入っていなかった**。以下はその原因分析から作った規則で、**推奨ではなく手順**。

#### 何が起きたか（証拠）

やり直しの前、視野の拡大は**すべてユーザー発**だった。私からは一度も出ていない。

| 拡大のきっかけ | 出どころ |
|---|---|
| `/` 以外の使用不可文字の網羅 | ユーザー |
| HFS+・exFAT | ユーザー |
| macOS がマウントし得る全形式 | ユーザー |
| パス全体の長さ | ユーザー |
| SMB ネットワークボリューム | ユーザー |
| インターネットでの裏付け | ユーザー |

#### 原因（5 つ。どれも「気をつける」では直らない類）

1. **目の前にある成果物（コード）に、探す範囲を決めさせた。** コードを読むと
   「このコードがしていること」の一覧が得られる。障害の列挙に必要なのは
   「このコードに何が起こり得るか」で、それはコードの外にある。
2. **「深さ」を「網羅」と取り違えた。** `copyfile` の挙動を実測し、罠を丁寧に
   潰した — その手応えを網羅と誤認した。**狭い範囲を深く掘っても狭いまま。**
3. **完了条件が無かったので「思いつかなくなった」を「完了」にした。**
   空にすべき一覧が無ければ、停止点は自分の発想の尽きた場所になる。
   そしてそれを**完了として報告した**ことが実害（誤った確信をユーザーへ渡した）。
4. **検索を確認にしか使わず、しかも言われてからだった。** 4 回とも既に出した
   結論の裏取り。発見のための検索はゼロ。§6 の「先に検索する」規則は
   **持っていたのに**、「不具合の調査」向けだと自分で解釈して適用しなかった。
5. **最も強い信号を無視した。** ユーザーが範囲を広げるたび、私はその 1 件に
   答えて先へ進んだ。**5 回目まで「自分の列挙が信用できない」と考えなかった。**

#### 共通の根

**外部の照合手段があるのに、自分の判断で代替した。** 手法の失敗では
「問題領域・先行資料・ユーザーのレビュー」が、NAS へ無断で数千回の書き込みを
した件では「ユーザーの許可」が、それぞれ手の届く所にあった。どちらも
自分の中だけで結論を出した。

#### 手順（点検・監査・「網羅的に」と言われた作業のすべてに適用する）

1. **最初の成果物は「次元表」であって修正ではない。** 対象領域から
   「何が違うと何が起きるか」の軸を列挙し、**表を提示してレビューを受けてから**
   直し始める。コードを読むのはその後（表の各行が現状どうなっているかの確認）。
2. **列挙のための検索を、結論より先に行う。** 個々の事実ではなく
   **網羅性を検証できる情報源**を当てる（そのツールの既知の制約一覧、
   同種ツールの既知の問題）。**打ち切ってよいのは、そういう情報源から
   新しい分類が出なくなったとき**で、「思いつかなくなったとき」ではない。
3. **ユーザーが範囲を広げたら、1 回目で手法を疑う。** その 1 件に答えて
   先へ進んではならない。列挙をやり直し、表として提示し直す。
   （判断に委ねると発火しないことは、§6 の検索規則で既に学んでいる。
   だから**回数**で決める。）
4. **完了報告には「見ていない範囲」を必ず書く。** 何を調べ、何を意図的に
   外し（理由付き）、何が未検証か。これが無い「完了」は禁止 —
   **所見だけの報告は、「見つからなかった」と「見ていない」を区別できない。**
5. **深掘りに入る前に「この項目はどうやって一覧に載ったか」を言えること。**
   言えないなら、一覧そのものが無い。先に作る。

#### この作業で得た較正値

- **疑い 20 件のうち 10 件が実測で否定された。** 自分の見立ては半分外れる。
  → **直す前に測る**は正しかった（守れていた）。
  → **自分の列挙を信じる**は誤りだった（守れていなかった）。
- **書いたテストのうち 7 件が空振りだった。** すべて
  「検査を外したら本当に落ちるか」という機械的な確認で捕まえた。
  **判断ではなく手続きにした規則は機能する** — 上の 3 を回数で決める根拠。

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
