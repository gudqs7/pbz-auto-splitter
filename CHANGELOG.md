# Changelog

## 2.2.6 - 2026-11-04

- Renamed the one-click installer to `自动扫盘安装_介意勿点.bat`.
- Rebuilt the memory-only release package with the renamed installer.

## 2.2.5 - 2026-11-04

- Updated the supported game build from `CL-301524_JKS-17219` to
  `CL-302256_JKS-17280` and changed the module build gate to `0x1E0BB000`.
- Relocated the live `GEngine`, Unreal name pool, and destination class slots for
  the new executable layout.
- Updated the `CharacterState.Dead` and
  `CharacterType.AI.ExcludeFromBossRecord` FName ids and moved the ability-system
  gameplay-tag count container to the new class layout.
- Revalidated the loading, game-instance, player, character, attribute-set, and
  boss tracking pointer offsets against the running game process.
- Applied the exact build-version gate to the save-backed runtime variant as
  well.
- Added `Install-PBZ.bat`: it scans fixed non-C drives for LiveSplit, prompts
  when multiple installations are present, backs up replaced files, copies the
  memory-only components and layout files, and creates
  `LiveSplit-PBZ.exe.lnk`.
- Changed release ZIPs to memory-only packages containing the splitter, Boss
  settings, `asl-help`, `pbz.lsl`, `pbz.lss`, and the installer. The save-backed
  variant, save reader DLL, source tree, and documentation are excluded.

## 2.2.4 - 2026-11-04

- Changed automatic start to trigger when transitioning from
  `PBZ_StartMenu_CE_WP` into either `PBZ_WP_ZhuLinGuWu` or `PBZ_Xigu_WP`.
- Applied the same start rule to both runtime variants while leaving Boss
  detection and split behavior unchanged.

## 2.2.3 - 2026-11-03

- Loaded Boss settings XML immediately during ASL startup instead of waiting
  for a supported PBZ game process to be matched.
- Added one build-gate log for every successful or failed PBZ process match in
  both runtime variants.
- Added runtime checks that prevent settings loading from moving back into
  `init`.

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
