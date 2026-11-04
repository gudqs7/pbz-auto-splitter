# Development

## Prerequisites

- Windows with .NET Framework 4.x.
- `csc.exe` from `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319`.
- LiveSplit for ASL integration testing.
- PowerShell 5.1 or PowerShell 7.

No proprietary Oodle DLL is required to build or run the production component.

## Build the reader

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbzsavareader.ps1
```

The script compiles the save-reader sources and every file under
`Source/OodleCleanRoom/src` into one x64 library:

```text
Components/PBZSaveReader.dll
```

To build elsewhere:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbzsavareader.ps1 `
  -OutPath .\dist\PBZSaveReader.dll
```

## Build the ASL runtime

Edit ASL and XML only under `Source/Runtime`. Generate comment-free runtime files
under `Components`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbz_runtime.ps1
```

To generate and synchronize the PBZ runtime files into the local LiveSplit
installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbz_runtime.ps1 -SyncLiveSplit
```

The generator removes C#/ASL and XML comments, verifies the generated files, and
compares SHA-256 hashes after synchronization. Release packaging validates the
comment-free runtime set and builds the one-click installer from its readable
source script.

## Build and test the decoder independently

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\OodleCleanRoom\build.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\OodleCleanRoom\test.ps1
```

Generated files go to `Source/OodleCleanRoom/bin` and are ignored by Git.

## Version updates

Update the version in:

- `Source/SaveReader.Api.cs`
- `Source/package_release.ps1`
- `CHANGELOG.md`

Update `README.md` and release commands when compatibility or installation
changes.

## Installer and packaging

Regenerate the one-click installer after changing `Source/Installer/Install-PBZ.ps1`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbz_installer.ps1
```

Create a versioned memory-only release ZIP after tests pass:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\package_release.ps1 -Version 2.2.6
```

The archive contains exactly:

```text
自动扫盘安装_介意勿点.bat
pbz.lsl
pbz.lss
Components/asl-help
Components/PBZ-AutoSplitter.asl
Components/PBZ.BossSettings.xml
Components/PBZ.BossSettings.en.xml
```

The save-backed ASL, `PBZSaveReader.dll`, `Source`, `docs`, README, and changelog
are intentionally excluded.

## Source hygiene

- Use relative paths in scripts and documentation.
- Keep comments in `Source/Runtime`, never in generated `Components` files.
- Do not commit save files, logs, crash dumps, Steam account directories, game
  executables, or Oodle DLLs.
- Keep compiled release files limited to `Components`.
- Do not edit generated files under ignored `bin` directories.
