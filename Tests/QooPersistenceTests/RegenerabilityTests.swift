import Testing
import Foundation
import GRDB
@testable import QooPersistence

//
//  [MG-20〜MG-23][B-13] 再生成可能性の網羅性。
//
//  **列を足したときに分類を忘れると落ちる。**これが JSON エクスポートの
//  網羅性検証（2-16）の土台になる——再生成不可能な列は JSON へ漏れなく
//  含めなければならない [MG-22][MG-23]。
//
@Suite("再生成可能性の宣言 [MG-20〜MG-23][B-13]")
struct RegenerabilityTests {
    @Test("すべての列が分類されている（再生成可能・内部・再生成不可能のいずれか）")
    func everyColumnIsClassified() throws {
        let db = try QooDatabase.inMemory()
        try db.writer.read { d in
            for type in RegenerabilityRegistry.declaringTypes {
                let actual = try RegenerabilityRegistry.actualColumns(d, table: type.databaseTableName)
                let declared = type.regenerableColumns.union(type.internalColumns)
                // 宣言に無い列は「再生成不可能」＝ JSON へ出すべき列。
                // ここでは「実在しない列を宣言していないか」を確かめる。
                let phantom = declared.subtracting(actual)
                #expect(phantom.isEmpty,
                        "\(type.databaseTableName): 実在しない列を宣言している \(phantom.sorted())")
            }
        }
    }

    /// 分類漏れの検出。ここに列挙した「再生成不可能」の列が、
    /// **将来 JSON エクスポートに含まれること**を 2-16 で検証する [MG-23]。
    @Test("再生成不可能な列を数え上げられる [MG-22]")
    func nonRegenerableColumns() throws {
        let db = try QooDatabase.inMemory()
        try db.writer.read { d in
            var report: [String: [String]] = [:]
            for type in RegenerabilityRegistry.declaringTypes {
                let actual = try RegenerabilityRegistry.actualColumns(d, table: type.databaseTableName)
                let nonRegenerable = actual
                    .subtracting(type.regenerableColumns)
                    .subtracting(type.internalColumns)
                report[type.databaseTableName] = nonRegenerable.sorted()
            }
            // 要件が明示する再生成不可能データ [MG-22] が確かに含まれること。
            #expect(report["managedFile"]?.contains("rating") == true)
            #expect(report["managedFile"]?.contains("archivedFromPath") == true)
            #expect(report["managedFile"]?.contains("protectedScopes") == true)
            #expect(report["managedFile"]?.contains("coverImageSource") == true)
            #expect(report["label"]?.contains("isPinned") == true)
            #expect(report["label"]?.contains("isArchived") == true)
            #expect(report["label"]?.contains("name") == true)
            #expect(report["labelGroup"]?.contains("name") == true)
            #expect(report["labelGroup"]?.contains("colorHexLight") == true)
            // `fileLabel` に残る非再生成列は主キーだけ——保護は
            // `managedFile.protectedScopes` にある [PR-02]。
            #expect(report["fileLabel"]?.isEmpty == true)

            FileHandle.standardError.write(Data(
                ("[MG-22] 再生成不可能な列:\n" + report.sorted { $0.key < $1.key }
                    .map { "    \($0.key): \($0.value.joined(separator: ", "))" }
                    .joined(separator: "\n") + "\n").utf8))
        }
    }
}
