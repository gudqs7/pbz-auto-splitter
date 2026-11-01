# Changelog

## 2.2.2 - 2026-11-02

- Deferred Boss settings XML loading until a supported PBZ game process is
  matched, and added bounded process-discovery retries for Steam bootstrap
  races.
- Added an immediate low-health removal split when an armed Boss leaves
  `BeHatredList` at or below 2% health, using current or last known health.
- Retained a sixty-second observation window for other removal edges that may
  expose a delayed death tag or zero-health signal.
- Excluded local runtime logs from release archives.
- Updated Boss removal diagnostics, runtime documentation, and maintenance
  guidance.

## 2.2.1 - 2026-11-01

- Moved commented ASL/XML source under `Source/Runtime` and added a runtime
  generator that removes every comment from generated files, release archives,
  and synchronized local LiveSplit components.
- Renamed the save-file implementation to `PBZ-AutoSplitter_BySave.asl`.
- Added `PBZ-AutoSplitter.asl`, a memory-only Boss auto splitter using active
  combat actors, gameplay tags, health, and actor destruction.
- Added transition-only file logging for Boss appearance, health milestones,
  death, and split events.
- Added logs for unconfigured Boss candidates when they appear and when they
  remain removed from `BeHatredList`, without entering the split queue.
- Added an `AutoSplitEnabled` master switch, enabled by default. Boss detection
  and logging continue while automatic split triggering is disabled.
- Enabled all Boss settings by default at the user's request; the per-Boss
  toggles remain available for narrowing a run.
- Fixed memory Boss detection when `BeHatredList` becomes empty and its array
  pointer is cleared in the same update.
- Reduced active-combat memory reads by caching UClass names, player/component
  pointers, and boss Actor child pointers with world/Dest invalidation.
- Batched GameplayTag reads for Dead and ExcludeFromBossRecord, corrected the
  tag-entry stride to `0x10`, and limited running combat scans to 50 ms.
- Added exact module-size and file-version gating for the validated PBZ build.
- Added English boss settings selected automatically from the Windows UI
  language, with the existing XML as the fallback.
- Grouped bosses by map and ordered them by the save-record kill and encounter
  sequence.

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
