//
//  バックアップ文書の読み書き [IE-03][IE-04][IE-14][JS-09]。
//
import Foundation

/// JSON の符号化・復号を 1 箇所に集める。
///
/// **書式は差分管理できる形に固定する** [IE-04]——整形して、キーを名前順に
/// 並べ、`/` を退避しない。この 3 つが揃うと、2 回書き出したものを `diff` で
/// 比べられる（バックアップの世代管理や、設定を変えたときの影響確認に効く）。
public enum BackupCoding {

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // `.sortedKeys` を付けないと、`Codable` の合成が宣言順に出すため
        // 型の宣言を並べ替えただけで全行が差分になる。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ document: BackupDocument) throws -> Data {
        try encoder().encode(document)
    }

    /// - Throws: ``BackupError/schemaTooNew(found:supported:)`` — この実装が
    ///   知らない版で書かれた文書 [IE-14][JS-09]。**読めるふりをして
    ///   取り込まない**。知らない列を落として書き戻すと、新しい版で足された
    ///   再生成不可能なデータを黙って失う。
    public static func decode(_ data: Data) throws -> BackupDocument {
        // 版だけを先に読む。本体のデコードに失敗する形でも、
        // 「新しすぎる」ことが理由なら理由を正しく言えるようにする。
        if let probe = try? decoder().decode(SchemaProbe.self, from: data),
           probe.schemaVersion > BackupDocument.currentSchemaVersion {
            throw BackupError.schemaTooNew(found: probe.schemaVersion,
                                           supported: BackupDocument.currentSchemaVersion)
        }
        do {
            let document = try decoder().decode(BackupDocument.self, from: data)
            guard document.schemaVersion <= BackupDocument.currentSchemaVersion else {
                throw BackupError.schemaTooNew(found: document.schemaVersion,
                                               supported: BackupDocument.currentSchemaVersion)
            }
            return document
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.malformed(String(describing: error))
        }
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }
}

/// バックアップの失敗 [ER-03]。
public enum BackupError: Error, Equatable, Sendable {
    /// この実装より新しい版で書かれている [IE-14]。
    case schemaTooNew(found: Int, supported: Int)
    /// JSON として読めない、または想定した形をしていない。
    case malformed(String)
    /// 取り込み先のライブラリが見つからない。
    case libraryNotFound(String)
}
