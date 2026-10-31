# Oodle Clean-Room Mermaid Decoder

This directory contains a clean-room implementation of the subset of Oodle LZ
needed to read Phantom Blade Zero `PBZS` records. The production save reader
uses this decoder first and keeps the game's embedded decoder as a compatibility
fallback.

## Scope

- Oodle LZ block and quantum framing used by PBZ saves
- Mermaid scalar decoding (no SIMD)
- The uncompressed terminator used by the Mermaid table
- Entropy modes exercised by PBZ `__Advanced__` records

Out of scope:

- Compression
- Kraken, Selkie, Leviathan, LZNA, and BitKnit
- Checksum computation

## Clean-room boundary

The implementation is derived from:

1. PBZS format observations in this repository.
2. Black-box input/output pairs obtained from `OodleLZ_Decompress`.
3. A written format specification in `docs/mermaid-format.md`.
4. Public, independently authored format documentation where available.

No pseudo-code from `oo2core_8_win64.dll` is copied, translated, or adapted
line by line into this project.

## Layout

- `docs/mermaid-format.md`: reproducible format specification
- `tools/extract_vectors.py`: extracts compressed/Expected vectors from PBZS
- `vectors/manifest.json`: fixture metadata and hashes
- `src/`: C# decoder source
- `tests/`: comparison and corruption tests

## Status

The scalar decoder is byte-exact on nine distinct PBZ fixtures: the current
save, six historical saves, a downloaded true-ending save, and one stored-block
boundary case. The production reader prefers this decoder and keeps the game
embedded Oodle bridge as a fallback.

Build and test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\OodleCleanRoom\build.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\OodleCleanRoom\test.ps1
```

Regenerate vectors from the user's saves and the official decoder:

```powershell
python .\Source\OodleCleanRoom\tools\extract_vectors.py `
  --output .\Source\OodleCleanRoom\vectors `
  --oodle-dll "C:\path\to\oo2core_8_win64.dll" `
  "C:\path\to\PBZSaveGame.sav"
```

Backend selection in `PBZ.SaveReader`:

- `PBZ_ODLE_BACKEND=auto` (default): C# decoder, then game bridge on failure
- `PBZ_ODLE_BACKEND=cleanroom`: C# decoder, game bridge fallback by default
- `PBZ_ODLE_BACKEND=game`: game embedded Oodle only
- `PBZ_ODLE_FALLBACK=none`: disable fallback for clean-room diagnostics
