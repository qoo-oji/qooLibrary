// QooUnrarBridge — minimal C surface over the UnRAR "RARDLL" API.
//
// This code uses portions of the UnRAR source (Sources/QooUnrarBridge/
// dll.hpp, raros.hpp — see ThirdParty/unrar/license.txt). Per the UnRAR
// source license: this code may not be used to develop a RAR (WinRAR)
// compatible archiver, and this paragraph must be retained in any
// redistribution of this file. [LC-26][B-04]
//
// Swift never sees UnRAR's own headers directly (no wchar_t, no PASCAL
// calling convention, no fixed-size C structs) — only this narrow,
// Swift-friendly surface. The actual UnRAR calls happen in
// QooUnrarBridge.mm [B-03].
//
// This is a technical-verification-grade API (T-13 RAR half): enough to
// list and extract an archive. It is not yet the final `ArchiveReading`
// conformance described in 09_インフラ_アーカイブと画像.md §9.1 — that
// belongs to a later phase once QooKit/QooInfrastructure's archive
// abstractions exist.

#ifndef QOO_UNRAR_BRIDGE_H
#define QOO_UNRAR_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *utf8Path;   // entry path, UTF-8, archive-relative
    uint64_t unpackedSize;
    int isDirectory;         // 0 / 1
} QooUnrarEntry;

// Invoked once per entry. Return 0 to continue, non-zero to abort the
// walk — the enclosing call then returns QOO_UNRAR_ERROR_CANCELLED.
//
// This is how callers stop a long extraction: UnRAR's RARProcessFileW is
// blocking and has no cancellation of its own, so the earliest a walk can
// be stopped is at an entry boundary. (Callers can also block inside the
// callback to pause the walk — it runs on the caller's own thread.)
typedef int (*QooUnrarEntryCallback)(const QooUnrarEntry *entry, void *context);

// Lists all entries in the archive, invoking `callback` once per entry.
// Returns 0 on success, or a QOO_UNRAR_ERROR_* / UnRAR ERAR_* code on
// failure. On failure, a human-readable message is written into
// `errorBuffer` (if non-NULL and errorBufferSize > 0).
int qoo_unrar_list(const char *archivePathUTF8,
                    QooUnrarEntryCallback callback,
                    void *context,
                    char *errorBuffer,
                    int errorBufferSize);

// Extracts every entry to `destinationDirUTF8`, creating intermediate
// directories as needed. `callback` is invoked once per entry actually
// written (directories included, matching `qoo_unrar_list`), which is
// what callers use for progress, pausing and cancellation.
int qoo_unrar_extract_all(const char *archivePathUTF8,
                           const char *destinationDirUTF8,
                           QooUnrarEntryCallback callback,
                           void *context,
                           char *errorBuffer,
                           int errorBufferSize);

// Extracts exactly one entry (matched byte-for-byte against the path
// qoo_unrar_list reports) to `destinationFileUTF8` (an exact file path,
// not a directory — parent directories are created as needed). Unlike
// qoo_unrar_extract_all this does not invoke a callback and stops
// scanning the archive as soon as the entry is found, since callers
// (thumbnail generation) only need one entry and archives can be large.
// Returns QOO_UNRAR_ERROR_ENTRY_NOT_FOUND if no entry with that exact
// path exists.
int qoo_unrar_extract_one(const char *archivePathUTF8,
                           const char *entryPathUTF8,
                           const char *destinationFileUTF8,
                           char *errorBuffer,
                           int errorBufferSize);

// Synthetic error codes distinct from UnRAR's own ERAR_* range (which
// starts at 0/10+), so callers can tell "UnRAR reported an error" apart
// from "the bridge itself failed before calling into UnRAR".
#define QOO_UNRAR_ERROR_OPEN_FAILED     -1
#define QOO_UNRAR_ERROR_HEADER_FAILED   -2
#define QOO_UNRAR_ERROR_PROCESS_FAILED  -3
#define QOO_UNRAR_ERROR_ENTRY_NOT_FOUND -4
// The callback asked to stop (returned non-zero). Not a failure of the
// archive: whatever was written so far is left in place for the caller
// to discard.
#define QOO_UNRAR_ERROR_CANCELLED       -5

#ifdef __cplusplus
}
#endif

#endif
