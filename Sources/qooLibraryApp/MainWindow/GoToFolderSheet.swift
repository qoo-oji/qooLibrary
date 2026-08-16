import QooInfrastructure
import SwiftUI

/// Finder の「フォルダへ移動…」（⇧⌘G）相当 [1-16 移動メニュー]。
///
/// パスを直接入力して移動する。`NSOpenPanel` ではなくアプリ内のシートにして
/// いるのは、この操作の目的が「既に知っているパスへ一発で飛ぶ」ことであり、
/// ファイル選択パネルを開くのは遠回りなため（Finder 自身も専用のシートを
/// 使う）。
///
/// **アクセス権はこのシートでは扱わない** [設計判断]。サンドボックスの都合で
/// 実際に開けるかどうかは既存の許可（環境設定「アクセス権」タブ／登録フォルダ）
/// が決めるため、ここは「入力されたパスがフォルダとして存在し、読めるか」まで
/// を判定し、読めない場合は理由を添えて入力欄に留める（シートを閉じてから
/// エラーダイアログを出すと、打ち直しのために開き直す手間が増えるため）。
struct GoToFolderSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    /// 検証を通ったフォルダだけが渡る。
    let onGo: (URL) -> Void

    @State private var path = ""
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            Text("goToFolder.title")
                .font(.system(size: Tokens.fontSize.title2, weight: .semibold))

            TextField("goToFolder.placeholder", text: $path)
                .editableFieldChrome()
                .focused($isFieldFocused)
                .onSubmit(go)
                .onChange(of: path) { _, _ in errorMessage = nil }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            QooDialogFooter(
                confirm: DialogButton(title: String(localized: "goToFolder.go", locale: locale)) { go() },
                cancel: DialogButton(title: String(localized: "common.cancel", locale: locale), role: .cancel) { dismiss() },
                confirmDisabled: resolvedInput == nil
            )
        }
        .padding(Tokens.spacing.l)
        .frame(width: 460)
        .onAppear { isFieldFocused = true }
    }

    /// 入力を実際に評価できる形へ整える。空白のみ・空文字は `nil`。
    ///
    /// `~` の展開は `NSString.expandingTildeInPath` に任せる。**サンドボックス下
    /// では `~` は仮想ホームに解決される** — 実ホームではないが、アプリ内の他の
    /// 「ホーム」の扱い（移動メニューの「ホーム」・起動時フォルダ設定）と一貫する。
    private var resolvedInput: URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        // 相対パスは受け付けない（基準となる「現在地」の概念が曖昧になるため）。
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    /// 入力されたパスを確かめて移動する。
    ///
    /// **確認はメインスレッドで行わない** [NV6-02]。ユーザーはネットワーク上の
    /// パスを直接打てるので、応答しないサーバのパスを入れられると、ここが
    /// そのままアプリの停止になる（この画面はまさにそういう入力を受け付ける
    /// ための場所である）。
    private func go() {
        guard let url = resolvedInput else { return }
        Task {
            let outcome = await FileIO.perform { Self.inspect(url) }
            switch outcome {
            case .ok:
                onGo(url)
                dismiss()
            case .notFound:
                errorMessage = String(localized: "goToFolder.notFound", locale: locale)
            case .notAFolder:
                errorMessage = String(localized: "goToFolder.notAFolder", locale: locale)
            case .noAccess:
                errorMessage = String(localized: "goToFolder.noAccess", locale: locale)
            }
        }
    }

    private enum InputCheck: Sendable {
        case ok, notFound, notAFolder, noAccess
    }

    /// **メインアクタの外で走る。** `FileIO.perform` の中からのみ呼ぶこと。
    private nonisolated static func inspect(_ url: URL) -> InputCheck {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .notFound }
        guard isDirectory.boolValue else { return .notAFolder }
        // 存在していても読めないことがある（サンドボックスで未許可のボリューム
        // 等）。移動してから中央ペインでエラーになるより、この場で理由を出して
        // 打ち直せるほうが親切なため、ここで一度だけ実際に読んでみる。
        guard (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil else { return .noAccess }
        return .ok
    }
}
