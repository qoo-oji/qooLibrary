import CLibarchive
import Foundation

/// テスト用の zip アーカイブを libarchive の書き込み API で直接組み立てる
/// ヘルパー。`archive_entry_set_pathname` はエントリ名をサニタイズしない
/// ため、パストラバーサル等の意図的に不正なエントリも作れる
/// （`zip` コマンド経由だと正規化されてしまい再現できない）。
enum ArchiveFixtureBuilder {
    struct Entry {
        let pathname: String
        let contents: Data
        let isSymlink: Bool
        let symlinkTarget: String?

        static func file(_ pathname: String, contents: Data) -> Entry {
            Entry(pathname: pathname, contents: contents, isSymlink: false, symlinkTarget: nil)
        }

        static func symlink(_ pathname: String, target: String) -> Entry {
            Entry(pathname: pathname, contents: Data(), isSymlink: true, symlinkTarget: target)
        }
    }

    private static let modeTypeRegularFile: mode_t = 0o100000
    private static let modeTypeSymlink: mode_t = 0o120000

    static func makeZip(at url: URL, entries: [Entry]) throws {
        guard let writer = archive_write_new() else {
            throw SetupError.failed("archive_write_new returned NULL")
        }
        defer { archive_write_free(writer) }

        archive_write_set_format_zip(writer)
        guard archive_write_open_filename(writer, url.path) == ARCHIVE_OK else {
            throw SetupError.failed(String(cString: archive_error_string(writer)))
        }

        for entry in entries {
            guard let entryPtr = archive_entry_new() else {
                throw SetupError.failed("archive_entry_new returned NULL")
            }
            defer { archive_entry_free(entryPtr) }

            archive_entry_set_pathname(entryPtr, entry.pathname)
            archive_entry_set_perm(entryPtr, 0o644)

            if entry.isSymlink {
                archive_entry_set_filetype(entryPtr, UInt32(modeTypeSymlink))
                archive_entry_set_symlink(entryPtr, entry.symlinkTarget ?? "")
                archive_entry_set_size(entryPtr, 0)
                guard archive_write_header(writer, entryPtr) == ARCHIVE_OK else {
                    throw SetupError.failed(String(cString: archive_error_string(writer)))
                }
            } else {
                archive_entry_set_filetype(entryPtr, UInt32(modeTypeRegularFile))
                archive_entry_set_size(entryPtr, la_int64_t(entry.contents.count))
                guard archive_write_header(writer, entryPtr) == ARCHIVE_OK else {
                    throw SetupError.failed(String(cString: archive_error_string(writer)))
                }
                entry.contents.withUnsafeBytes { ptr in
                    _ = archive_write_data(writer, ptr.baseAddress, entry.contents.count)
                }
                archive_write_finish_entry(writer)
            }
        }

        guard archive_write_close(writer) == ARCHIVE_OK else {
            throw SetupError.failed(String(cString: archive_error_string(writer)))
        }
    }

    enum SetupError: Error, CustomStringConvertible {
        case failed(String)
        var description: String {
            switch self {
            case .failed(let message): return "fixture setup failed: \(message)"
            }
        }
    }
}
