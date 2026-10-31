# Repository Instructions

This repository is the standalone source and release package for the Phantom
Blade Zero LiveSplit auto splitter. Read `README.md` and the relevant file under
`docs/` before changing behavior.

## Runtime contract

- `Components/PBZLoadRemover.asl` is the LiveSplit entry point.
- The ASL loads `Components/asl-help`, a language-matched boss settings XML,
  and `Components/PBZSaveReader.dll`. It checks the full culture name, then the
  base language, before falling back to `Components/PBZ.BossSettings.xml`.
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
- `Components/PBZLoadRemover.asl`: memory offsets, load detection, split queue.

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

## Change rules

- Keep all changes scoped to the PBZ auto splitter.
- Do not add game binaries, `oo2core_*.dll`, save files, logs, crash dumps, or
  machine-specific absolute paths.
- Do not change the default boss toggles without checking the XML against a
  real save and documenting the reason.
- Memory offsets in `PBZLoadRemover.asl` are tied to a specific game build.
  Update them only with fresh validation and a build-version note.
- Preserve the `PBZ.SaveReader` public API used by the ASL unless the ASL is
  updated in the same change.
- Keep the clean-room decoder independent from decompiled Oodle source.
- Do not commit generated build output under `Source/OodleCleanRoom/bin` or
  `Source/bin`.

## Release checklist

1. Build `Components/PBZSaveReader.dll`.
2. Run the clean-room vector tests.
3. Verify the ASL still parses in LiveSplit.
4. Smoke-test timer start, loading pause, boss baseline, and one enabled split.
5. Update `Version` in `SaveReader.Api.cs`, `README.md`, and `CHANGELOG.md`.
6. Package only after the repository is clean.
