//
//  同名ライブラリの区別 [RG3-31][§19.10 ステージ 2] のテスト。
//
//  フォルダ名＝表示名にしたので、同名のライブラリは普通にできうる。
//  注記（親フォルダのパス）は**衝突している行にだけ**付く——全行に出すと
//  衝突していない大多数の行で雑音になる、という設計そのものを固定する。
//
import Foundation
import Testing

import QooApplication
import QooKit

@Suite struct LibraryNameDisambiguationTests {

    private func library(_ id: Int64, name: String, path: String) -> LibrarySummary {
        LibrarySummary(id: LibraryID(rawValue: id), uuid: UUID(), displayName: name,
                       resolvedPath: path, volumeUUID: "V",
                       libraryTypeID: LibraryTypeID(rawValue: 0), libraryTypeName: "T",
                       isOnline: true, isReadOnlyDueToFS: false, fileCount: 0,
                       settingsRevision: 0)
    }

    /// 衝突していない行には注記を付けない（雑音になる）。
    @Test func uniqueNamesGetNoAnnotation() {
        let annotations = LibraryNameDisambiguation.annotations(for: [
            library(1, name: "コミック", path: "/Volumes/A/コミック"),
            library(2, name: "同人誌", path: "/Volumes/A/同人誌"),
        ])
        #expect(annotations.isEmpty)
    }

    /// 同名の行には親フォルダのパスが付き、互いに区別できる。
    @Test func collidingNamesGetParentPathAnnotations() {
        let annotations = LibraryNameDisambiguation.annotations(for: [
            library(1, name: "コミック", path: "/Volumes/A/コミック"),
            library(2, name: "コミック", path: "/Volumes/B/コミック"),
            library(3, name: "同人誌", path: "/Volumes/A/同人誌"),
        ])
        #expect(annotations[LibraryID(rawValue: 1)] == "/Volumes/A")
        #expect(annotations[LibraryID(rawValue: 2)] == "/Volumes/B")
        #expect(annotations[LibraryID(rawValue: 3)] == nil)
    }

    /// 判定は表示名の**完全一致**。大小文字違いは画面上も違って見えるので
    /// 衝突と見なさない（同じ注記が付くとかえって混乱する）。
    @Test func caseDifferentNamesAreNotACollision() {
        let annotations = LibraryNameDisambiguation.annotations(for: [
            library(1, name: "Comics", path: "/Volumes/A/Comics"),
            library(2, name: "comics", path: "/Volumes/B/comics"),
        ])
        #expect(annotations.isEmpty)
    }
}
