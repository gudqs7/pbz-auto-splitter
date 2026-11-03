# Repository Instructions

This repository is the standalone source and release package for the Phantom
Blade Zero LiveSplit auto splitter. Read `README.md` and the relevant file under
`docs/` before changing behavior. For generation, comments, Boss caches,
GameplayTags, synchronization, or release work, read
`docs/maintenance-lessons.md` first.

## Runtime contract

- `Components/PBZ-AutoSplitter.asl` is the generated default LiveSplit entry
  point and is a memory-only Boss auto splitter.
- `Components/PBZ-AutoSplitter_BySave.asl` is the generated save-file variant.
- Editable ASL and XML source lives under `Source/Runtime`. Repository
  `Components`, release archives, and the local LiveSplit `Components` directory
  are generated without comments.
- Both ASLs load `Components/asl-help` and a language-matched boss settings XML.
- Both ASLs load their settings XML during `startup`; `init` only performs and
  logs the PBZ process build gate.
  They check the full culture name, then the base language, before falling back
  to `Components/PBZ.BossSettings.xml`.
- Only the BySave variant loads `Components/PBZSaveReader.dll`.
- `PBZSaveReader.dll` exposes `PBZ.SaveReader` and must remain compatible with
  the reflection calls made by the ASL.
- `OodleCleanRoom` is compiled into `PBZSaveReader.dll`; it is not a separate
  runtime dependency.
- The default save reader path uses the clean-room decoder. The game-process
  bridge is only a compatibility fallback.

## Source map

- `Source/SaveReader.Api.cs`: public API and save-file discovery.
- `Source/SaveReader.Container.cs`: PBZS parsing, backend selection, fallback.
- `Source/SaveReader.Crypto.cs`: AES-256-GCM record decryption.
- `Source/SaveReader.Json.cs`: minimal boss-counter JSON parser.
- `Source/GameOodleDecompressor.cs`: game-process Oodle fallback.
- `Source/OodleCleanRoom/src`: clean-room Mermaid decoder.
- `Source/Runtime/PBZ-AutoSplitter.asl`: commented memory splitter source.
- `Source/Runtime/PBZ-AutoSplitter_BySave.asl`: commented save-backed source.
- `Source/Runtime/PBZ.BossSettings*.xml`: commented settings source.
- `Source/build_pbz_runtime.ps1`: generates comment-free runtime files.
- `docs/maintenance-lessons.md`: accumulated maintenance rules and technical
  pitfalls from PBZ implementation sessions.
- `Components/*.asl` and `Components/PBZ.BossSettings*.xml`: generated runtime
  files. Do not edit them directly.

## Build

Run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbzsavareader.ps1
```

The command rebuilds `Components/PBZSaveReader.dll`.

## Verification

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\OodleCleanRoom\test.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_pbzsavareader.ps1
```

For an end-to-end benchmark, pass a save path and, when needed, the game
executable and an Oodle DLL path to `PBZSaveReader.Benchmark.exe`.

## Runtime synchronization

- `Source/Runtime` is the editable source for ASL and settings XML.
  Repository `Components` and the local LiveSplit `Components` directory are
  generated outputs and must remain comment-free.
- Run `Source/build_pbz_runtime.ps1 -SyncLiveSplit` to regenerate repository
  runtime files and synchronize the PBZ files into
  `D:\soft\e-game\LiveSplit_1.8.29\Components`.
- Before synchronization, compare existing local runtime copies with the
  repository copies. A newer differing local file must be inspected and merged
  back into `Source/Runtime` before regeneration; never overwrite it blindly.
- `asl-help` and `PBZSaveReader.dll` are binary runtime dependencies. Compare
  them by SHA-256 before synchronization and verify matching hashes afterward.

## Change rules

- Keep all changes scoped to the PBZ auto splitter.
- Edit ASL/XML under `Source/Runtime`, then regenerate runtime files with
  `Source/build_pbz_runtime.ps1`. Never add comments directly under
  `Components`.
- Re-read `docs/maintenance-lessons.md` before changing Boss cache keys,
  GameplayTag masks, runtime encoding, or release packaging.
- Do not add game binaries, `oo2core_*.dll`, save files, logs, crash dumps, or
  machine-specific absolute paths.
- Do not change the default boss toggles without checking the XML against a
  real save and documenting the reason.
- Memory offsets in both ASLs are tied to build `CL-301524_JKS-17219`.
  Update them only with fresh validation and a build-version note.
- Preserve the `PBZ.SaveReader` public API used by the ASL unless the ASL is
  updated in the same change.
- Keep the clean-room decoder independent from decompiled Oodle source.
- Do not commit generated build output under `Source/OodleCleanRoom/bin` or
  `Source/bin`.

## Release checklist

1. Build `Components/PBZSaveReader.dll`.
2. Run `Source/build_pbz_runtime.ps1`.
3. Run the clean-room vector tests.
4. Verify both generated ASLs contain no comments and still parse in LiveSplit.
5. Smoke-test memory-only Boss detection and one enabled split.
6. Repeat the same split with the BySave variant when touching save parsing.
7. Update `Version` in `SaveReader.Api.cs`, `README.md`, and `CHANGELOG.md`.
8. Package only after the repository is clean.
