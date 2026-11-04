# Source overview

`PBZ.SaveReader` is the optional managed save decoder loaded only by the
development `Components/PBZ-AutoSplitter_BySave.asl` variant. Release packages
use the memory-only splitter and exclude this DLL.

Editable splitter source lives in `Runtime/`. Generate comment-free files under
`../Components` with `build_pbz_runtime.ps1`; generated runtime files must not be
edited directly.

The save-backed development path reads only the `__Advanced__` record:

```text
PBZS index -> AES-256-GCM decrypt -> OodleCleanRoom Mermaid
-> stream BossRecord[*].Records[*].KillCount
```

`OodleCleanRoom` is compiled into the same `PBZSaveReader.dll`; it is not a
separate runtime assembly.

## Build

Generate the PBZ ASL/XML runtime files and one-click installer:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbz_runtime.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbz_installer.ps1
```

Build the memory-only release ZIP:

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\package_release.ps1 -Version 2.2.6
```

Build the optional save reader for development:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbzsavareader.ps1
```

## Test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_pbz_runtime.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_pbz_installer.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_pbzsavareader.ps1
```

See `../docs/development.md` and `../docs/testing.md` for details.
