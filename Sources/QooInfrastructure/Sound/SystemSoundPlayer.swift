import AudioToolbox
import Foundation

/// ファイル操作の完了時に鳴らす macOS 標準の UI サウンド
/// [ユーザー要望、要件定義書には無い]。
///
/// **音源は macOS 同梱のシステムサウンドをそのまま使う**（自前の音源を
/// バンドルしない）。Finder と同じ音が鳴ることが目的なので、コピーを持つと
/// OS 側で音が差し替わったときに追随できなくなる。
///
/// 列挙子は **qooLibrary 側の意味**で名付けている（ファイル名ではない）。
/// 例: `.permanentDelete` の実体は `finder/empty trash.aif` だが、
/// qooLibrary に「ゴミ箱を空にする」機能は無く、この音を使うのは完全削除
/// [FM-14] だけのため。
///
/// **どの音がどの操作かは Finder の実装を逆アセンブルして特定し、実際に
/// 鳴らしてユーザーに耳で確認してもらった**（詳細は CLAUDE.md の
/// 「Finder のメニューアイコンと効果音」節）。特に `finder/move to trash.aif`
/// という紛らわしい名前のファイルは Finder からは呼ばれておらず、実際の
/// ゴミ箱音は `dock/drag to trash.aif` の方である点に注意。
public enum SystemSoundEffect: String, Sendable, CaseIterable {
    /// ゴミ箱に入れる [FM-04]。Finder・Dock と同じ音（SystemSoundID 16 相当）。
    case moveToTrash
    /// 完全削除 [FM-14]。Finder の「ゴミ箱を空にする」と同じ、
    /// 取り返しがつかないことを示す音（SystemSoundID 13 相当）。
    case permanentDelete
    /// 圧縮・展開の完了 [ユーザー要望]。Finder が一括操作の完了時・AirDrop の
    /// 受信完了時に鳴らしているのと同じ汎用の完了音（SystemSoundID 1 相当）。
    case operationComplete

    /// macOS が UI サウンドを置いている場所。
    ///
    /// SystemSoundID の数値（Finder/Dock が使っている 13/16 等）を直接渡す
    /// 方法もあるが、**その対応表は非公開**（AudioToolbox 内部の switch 文）
    /// なので、自己文書化されるファイルパス指定を採る［ユーザー判断］。
    /// パスが将来変わっても `SystemSoundPlayer` が無音へフォールバックする。
    private static let root = URL(
        fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds",
        isDirectory: true
    )

    public var fileURL: URL {
        switch self {
        case .moveToTrash:
            Self.root.appendingPathComponent("dock").appendingPathComponent("drag to trash.aif")
        case .permanentDelete:
            Self.root.appendingPathComponent("finder").appendingPathComponent("empty trash.aif")
        case .operationComplete:
            Self.root.appendingPathComponent("system").appendingPathComponent("Volume Mount.aif")
        }
    }
}

/// テストで差し替えられるようにするための境界
/// （`BookmarkResolving`/`VolumeEligibilityChecking` と同じパターン）。
public protocol SystemSoundPlaying: Sendable {
    func play(_ effect: SystemSoundEffect) async
}

/// `SystemSoundEffect` を実際に鳴らす既定実装。
///
/// **システム設定「サウンド」の「ユーザインターフェイスのサウンドエフェクトを
/// 再生」を自動的に尊重する。** `AudioServicesCreateSystemSoundID` で登録した
/// サウンドは `kAudioServicesPropertyIsUISound` が既定で 1 になり、この設定が
/// オフのときは `AudioServices` 側が鳴らさないため
/// （AudioToolbox の `AudioServices.h` に明記、実測でも値 1 を確認済み）。
/// **アプリ側で設定を読む必要も、独自のオン/オフ設定を持つ必要も無い**
/// ［ユーザー判断: 環境設定に音のオン/オフは置かない］。
///
/// App Sandbox 下でも追加の entitlement 無しに動作することを、qooLibrary と
/// 同一の entitlement でアドホック署名した検証アプリで実測済み。
public actor SystemSoundPlayer: SystemSoundPlaying {
    public static let shared = SystemSoundPlayer()

    private let isEnabled: Bool
    /// 登録済みの `SystemSoundID`。**1 度登録したら使い回す**
    /// （登録は coreaudiod への往復を伴うため、鳴らすたびに作り直さない）。
    /// Finder も同じく static な 1 個の ID を持ち回している。
    private var registered: [SystemSoundEffect: SystemSoundID] = [:]
    /// 登録に失敗した音。**再試行しない** — 失敗の原因は「OS 側で音源の場所が
    /// 変わった」等の恒久的なもので、操作のたびに往復とログを繰り返しても
    /// 直らないため。
    private var unavailable: Set<SystemSoundEffect> = []

    /// テスト実行中だけ無音になる（`swift test` のたびにゴミ箱音が鳴るのを
    /// 防ぐ。`DiagnosticLog` がログの出力先を一時ディレクトリへ振り替えるのと
    /// 同じ方針）。
    public init() {
        self.isEnabled = !RuntimeEnvironment.isRunningTests
    }

    /// - Parameter isEnabled: `false` にすると何も鳴らさない。
    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public func play(_ effect: SystemSoundEffect) {
        guard isEnabled, let id = soundID(for: effect) else { return }
        // 再生の完了は待たない（`AudioServicesPlaySystemSoundWithCompletion`
        // 自体は即座に戻る）。素の `AudioServicesPlaySystemSound` はヘッダ上
        // 「将来非推奨」と明記されているため、Finder/FinderKit と同じ
        // `WithCompletion` 版を使う。
        AudioServicesPlaySystemSoundWithCompletion(id, nil)
    }

    private func soundID(for effect: SystemSoundEffect) -> SystemSoundID? {
        if let id = registered[effect] { return id }
        guard !unavailable.contains(effect) else { return nil }

        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(effect.fileURL as CFURL, &id)
        guard status == noErr else {
            // 音が鳴らないだけで操作自体は成功しているため、ユーザーへは
            // 提示せずログに残すだけにする [ER-01 の対象外]。
            unavailable.insert(effect)
            Log.ui.warning(
                "システムサウンドを読み込めません（以後この音は鳴らしません）: "
                    + "\(Log.path(effect.fileURL)) — OSStatus \(status)"
            )
            return nil
        }
        registered[effect] = id
        return id
    }
}
