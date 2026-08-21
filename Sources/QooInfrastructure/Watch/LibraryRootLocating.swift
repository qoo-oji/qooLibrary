//
//  ライブラリの根がいまどこにあるか [SB-05][VD-03][VD-05][VD-06][RG3-01〜08]。
//
//  1-17 で確定した登録フォルダの縮退状態（8章 §8.7.1）を、**走査の可否**という
//  1 つの軸へ畳んだもの。状態モデルと判定順序は 1-17 のまま変えない——2-2 の
//  役割は遷移を能動的に駆動することであって、判定を作り直すことではない。
//
import Foundation
import QooKit

/// 走査から見た根の所在。
public struct LibraryRootLocation: Sendable, Equatable {
    /// 走査してよい根。`nil` なら走査しない。
    public let url: URL?
    /// 診断ログとオフライン遷移の理由。`nil` は正常。
    public let unavailableReason: String?

    public var isOnline: Bool { url != nil }

    public init(url: URL?, unavailableReason: String? = nil) {
        self.url = url
        self.unavailableReason = unavailableReason
    }

    public static func online(_ url: URL) -> LibraryRootLocation {
        LibraryRootLocation(url: url)
    }

    public static func unavailable(_ reason: String) -> LibraryRootLocation {
        LibraryRootLocation(url: nil, unavailableReason: reason)
    }
}

/// 登録 ID → 根の所在。
///
/// **`library.resolvedPath` を信じて走査してはならない。** あれは最後に解決
/// できた場所の記録に過ぎず、ボリュームが外れていれば実体を指さないし、
/// **同じマウントポイントに別のボリュームが載っている**ことすらある
/// （`ScanEngine` の根の同一性検査が最後の砦になっている）。
public protocol LibraryRootLocating: Sendable {
    /// 登録 ID をキーにした所在。**ファイルシステムを待たせない実装であること**
    /// ——未接続と分かっているものにはブックマークの解決を試みず [RG3-01]、
    /// 残りにも上限時間を掛ける [NV6-05]。
    func libraryRootLocations() async -> [UUID: LibraryRootLocation]
}

/// `RegisteredFolderStore` を `LibraryRootLocating` として使う。
///
/// **判定は借りるだけで作り直さない。** ゴミ箱の中・消失・ファイルシステム
/// 非対応をオフラインと同じ「走査しない」に畳むが、**理由は保つ**——
/// 「接続すれば戻る」と「実体が見つからない」は利用者への案内が違う [VD-11]。
public struct RegisteredFolderRootLocator: LibraryRootLocating {
    public init() {}

    public func libraryRootLocations() async -> [UUID: LibraryRootLocation] {
        var result: [UUID: LibraryRootLocation] = [:]
        for state in await RegisteredFolderStore.shared.states(kind: .library) {
            result[state.folder.id] = Self.location(for: state.status)
        }
        return result
    }

    /// 縮退状態を「走査してよいか」へ畳む。**公開しているのは、この対応が
    /// 変わったときに気づけるようテストで固定するため。**
    public static func location(for status: RegisteredFolderStatus) -> LibraryRootLocation {
        switch status {
        case .online(let url):
            return .online(url)
        case .offline:
            return .unavailable("ボリュームが接続されていない")           // [SB-05][VD-11]
        case .inTrash:
            // 実体はあるが、ゴミ箱の中を蔵書として走査するのは意味が違う。
            return .unavailable("ゴミ箱の中にある")                      // [RG3-03]
        case .missing:
            return .unavailable("実体が見つからない")                    // [RG3-04]
        case .unsupportedFileSystem:
            // 同一性を追えないので、走査すると移動・改名のたびに紐づけが飛ぶ [FS-08]。
            return .unavailable("ファイルシステムが同一性の追跡に対応していない")
        }
    }
}
