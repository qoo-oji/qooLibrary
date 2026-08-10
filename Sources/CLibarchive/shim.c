// CLibarchive has no C sources of its own — it only vendors headers
// (include/archive.h, include/archive_entry.h) and links the
// libarchiveBinary xcframework. Xcode's build system (unlike plain
// `swift build`) expects every target to produce a compiled object file;
// without this empty translation unit it fails with "Build input file
// cannot be found: .../CLibarchive.o".
