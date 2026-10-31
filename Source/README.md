# Source overview

`PBZ.SaveReader` is the managed save decoder loaded by
`Components/PBZLoadRemover.asl`.

The production path reads only the `__Advanced__` record:

```text
PBZS index -> AES-256-GCM decrypt -> OodleCleanRoom Mermaid
-> stream BossRecord[*].Records[*].KillCount
```

`OodleCleanRoom` is compiled into the same `PBZSaveReader.dll`; it is not a
separate runtime assembly.

## Build

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbzsavareader.ps1
```

## Test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_pbzsavareader.ps1
```

See `../docs/development.md` and `../docs/testing.md` for details.
