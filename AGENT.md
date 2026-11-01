# Repository Instructions

This repository is the standalone source and release package for the Phantom
Blade Zero LiveSplit auto splitter. Read `README.md` and the relevant file under
`docs/` before changing behavior.

## Runtime contract

- `Components/PBZ-AutoSplitter.asl` is the default LiveSplit entry point and is
  a memory-only Boss auto splitter.
- `Components/PBZ-AutoSplitter_BySave.asl` is the retained save-file variant.
- Both ASLs load `Components/asl-help` and a language-matched boss settings XML.
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
- `Components/PBZ-AutoSplitter.asl`: memory offsets, load detection, live Boss
  tags/health/actor tracking, and split queue.
- `Components/PBZ-AutoSplitter_BySave.asl`: prior save-backed Boss split
  implementation.

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

- `Components` is the packaged runtime source. Keep it in two-way sync with
  `D:\soft\e-game\LiveSplit_1.8.29\Components`.
- Before editing any ASL, settings XML, `asl-help`, `PBZSaveReader.dll`, or
  other runtime file, compare the repository copy with the runtime copy using
  both `LastWriteTime` and SHA-256. If the runtime copy differs or is newer,
  inspect and merge that change into the repository first; never overwrite a
  newer runtime change blindly.
- After validation, copy every changed runtime file to
  `D:\soft\e-game\LiveSplit_1.8.29\Components` and verify that both copies have
  the same SHA-256.

## Change rules

- Keep all changes scoped to the PBZ auto splitter.
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
2. Run the clean-room vector tests.
3. Verify both ASLs still parse in LiveSplit.
4. Smoke-test memory-only Boss detection and one enabled split.
5. Repeat the same split with the BySave variant when touching save parsing.
6. Update `Version` in `SaveReader.Api.cs`, `README.md`, and `CHANGELOG.md`.
7. Package only after the repository is clean.
