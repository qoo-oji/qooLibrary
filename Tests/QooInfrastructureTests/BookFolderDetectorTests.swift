//
//  画像拡張子の実効値 [§19.10 ステージ 2] のテスト。
//
//  「空の設定＝既定の画像拡張子」という解釈は
//  `BookFolderDetector.effectiveImageExtensions` の 1 箇所だけが持ち、
//  走査（`ScanEngine`）と登録ウィザードの推定が同じ関数を通る。
//  別々に解釈を持つと「ウィザードには画像フォルダの行が出ないのに、
//  走査ではブックフォルダとして検出される」という食い違いになる
//  （実機検証で実際に踏んだ形）。
//
import Foundation
import Testing

@testable import QooInfrastructure

@Suite struct BookFolderDetectorTests {

    /// **空の設定は「既定の画像拡張子」を意味する。** テンプレート草案は
    /// 空で来るため、文字どおり読むとブックフォルダが 1 つも検出されず、
    /// ウィザードの「画像フォルダ」行も永久に出ない（実機検証で発見）。
    @Test func emptyConfiguredImageExtensionsMeansTheDefaults() {
        let effective = BookFolderDetector.effectiveImageExtensions(from: [] as [String])
        #expect(effective == BookFolderDetector.defaultImageExtensions)
    }

    /// 設定があればそれを使う（小文字へ畳む）。既定は混ぜない。
    @Test func configuredImageExtensionsWinOverTheDefaults() {
        let effective = BookFolderDetector.effectiveImageExtensions(from: ["PNG", "Webp"])
        #expect(effective == ["png", "webp"])
    }
}
