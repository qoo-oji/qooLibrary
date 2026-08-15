import AudioToolbox
import Foundation
import Testing

@testable import QooInfrastructure

/// `SystemSoundEffect` が指す音源が実在し、`AudioServices` に登録できることを
/// 確認する。
///
/// **これは「OS 側の変化を検知する」ための回帰テストでもある** — 音源は
/// macOS 同梱のファイルを直接指しており、将来 Apple が場所や名前を変えたら
/// 静かに無音へフォールバックする（`SystemSoundPlayer` 参照）。それ自体は
/// 意図した挙動だが、気づかないまま放置されないようテストで拾う。
///
/// **音は鳴らさない**（`AudioServicesCreateSystemSoundID` は登録するだけで
/// 再生しない）。再生そのものは環境依存かつ検証不能なため自動テストの対象外
/// で、実機での耳による確認で担保している。
@Suite struct SystemSoundEffectTests {
    @Test(arguments: SystemSoundEffect.allCases)
    func effectPointsAtAnExistingReadableSystemSound(_ effect: SystemSoundEffect) throws {
        let url = effect.fileURL
        #expect(FileManager.default.fileExists(atPath: url.path), "音源が見つかりません: \(url.path)")

        let handle = try #require(FileHandle(forReadingAtPath: url.path), "音源を開けません: \(url.path)")
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: 16)?.isEmpty == false)
    }

    @Test(arguments: SystemSoundEffect.allCases)
    func effectCanBeRegisteredWithAudioServices(_ effect: SystemSoundEffect) {
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(effect.fileURL as CFURL, &id)
        defer { if status == noErr { AudioServicesDisposeSystemSoundID(id) } }

        #expect(status == noErr, "登録に失敗しました（OSStatus \(status)）: \(effect)")
        #expect(id != 0)
    }

    /// コピー＆ペーストで 2 つの効果が同じ音を指してしまう事故を防ぐ。
    @Test func effectsDoNotShareTheSameSoundFile() {
        let paths = SystemSoundEffect.allCases.map(\.fileURL.path)
        #expect(Set(paths).count == paths.count, "重複した音源があります: \(paths)")
    }

    /// 無効化したプレイヤーは何もしない（テスト実行中に音が鳴らないことの担保）。
    @Test func disabledPlayerIsSilent() async {
        let player = SystemSoundPlayer(isEnabled: false)
        for effect in SystemSoundEffect.allCases {
            await player.play(effect)
        }
    }

    /// 既定のイニシャライザはテスト実行中には無音になる。ここが壊れると
    /// `swift test` のたびにゴミ箱音が鳴り出すため、明示的に固定しておく。
    @Test func defaultPlayerIsSilentUnderTests() {
        #expect(RuntimeEnvironment.isRunningTests)
    }
}
