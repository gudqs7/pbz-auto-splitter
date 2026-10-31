# Changelog

## 2.2.0 - 2026-10-31

- Added a pure C# clean-room Oodle Mermaid decoder.
- Switched production save reads to the clean-room decoder by default.
- Retained the game-process Oodle bridge as a compatibility fallback.
- Verified byte-exact output against nine real-save vectors.
- Added source, tests, vectors, and end-user documentation to the release
  repository.

## 2.1.0

- Added save-file based boss kill tracking.
- Added grouped boss settings and independent split toggles.
- Added `PBZSaveReader.dll` and removed the old `PBZBossReader.dll` dependency.
