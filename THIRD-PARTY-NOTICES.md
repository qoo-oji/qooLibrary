# Third-Party Notices

qooLibrary vendors the following third-party components. Each is isolated
under `ThirdParty/<name>/` and is **not** covered by qooLibrary's MIT license
(see `LICENSE`). [LC-04][LC-24]

This file must be updated whenever a dependency is added, upgraded, or
removed (PR checklist item). [LC-05][B-05]

---

## libarchive

- **Used for**: reading/writing zip, 7z, tar.gz (and, in
  `PERMISSIVE_ONLY_BUILD` configurations, rar) archives. [LC-14]
- **License**: BSD 2-Clause (New BSD) — see individual file headers in the
  vendored source; a copy of the license is included by the upstream project.
- **Source**: https://github.com/libarchive/libarchive
- **Vendoring method**: built from an official release tarball via
  `Scripts/build-libarchive.sh` into a static library under
  `ThirdParty/libarchive/`. qooLibrary does **not** link against the system
  `libarchive.dylib`. [LC-15][B-02]
- **Modifications**: none. Unmodified upstream source.

## UnRAR

- **Status**: **not yet vendored.** Planned for a later development session
  (technical verification T-13/T-12, see `docs/Specifications/16_テスト戦略.md`
  §16.6 and `docs/Specifications/17_実装ロードマップ.md` §17.2 item 0-1/0-2).
- **Used for**: reading `.rar`/`.cbr` archives in the default (non-permissive)
  build configuration. [LC-11][AR-01b]
- **License**: RARLAB's UnRAR source license, which is **not** MIT/BSD-style
  and explicitly prohibits using the code to develop a RAR (WinRAR)
  compatible archiver. [LC-20][LC-26] When vendored, the full license text
  will be included verbatim at `ThirdParty/unrar/license.txt`. [LC-24]
- **Isolation**: once added, all calls into UnRAR will be confined to an
  Objective-C++ wrapper (`QooUnrarBridge.mm`) carrying the non-use notice
  required by the license at the top of the file. [B-03][B-04]
- **`PERMISSIVE_ONLY_BUILD`**: a build configuration that excludes UnRAR
  entirely and falls back to libarchive's RAR reader for `.rar`/`.cbr`
  files (with reduced format coverage). [LC-12][LC-13]

---

## Adding a new dependency

Before adding any third-party dependency, confirm its license is compatible
with permissive redistribution (MIT/BSD/Apache-2.0/zlib-class licenses are
preferred; UnRAR is a deliberate, isolated exception — see above). Then:

1. Vendor the unmodified source under `ThirdParty/<name>/`.
2. Add a section to this file following the format above.
3. If the dependency is required for the default build, also update
   `README.md`'s build instructions.
