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
compares SHA-256 hashes after synchronization. The packaging script applies the
same sanitizer to every distributable ASL, C#, PowerShell, and XML file.

## Build and test the decoder independently

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\OodleCleanRoom\build.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\OodleCleanRoom\test.ps1
```

Generated files go to `Source/OodleCleanRoom/bin` and are ignored by Git.

## Version updates

Update the version in both places:

- `Source/SaveReader.Api.cs`
- `CHANGELOG.md`

Update `README.md` when compatibility or installation changes.

## Packaging

Create a versioned zip after tests pass:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\package_release.ps1 -Version 2.2.4
```

The archive contains `Components`, `Source`, and top-level documentation.

## Source hygiene

- Use relative paths in scripts and documentation.
- Keep comments in `Source/Runtime`, never in generated `Components` files.
- Do not commit save files, logs, crash dumps, Steam account directories, game
  executables, or Oodle DLLs.
- Keep compiled release files limited to `Components`.
- Do not edit generated files under ignored `bin` directories.
