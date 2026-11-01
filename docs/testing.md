# Testing

## Clean-room decoder tests

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\OodleCleanRoom\test.ps1
```

The test discovers the real-save `.oodle` fixtures under
`Source/OodleCleanRoom/vectors`, decodes each one, and compares the result with
its matching `.expected` file. It also runs corruption and stored-block probes.
A successful run ends with:

```text
OODLE_CLEANROOM_TEST_OK
```

Raw save-derived vectors are intentionally excluded from the public repository
because they can contain Steam account IDs and personal game progress. Keep a
private local copy under the same directory when running the full suite. If no
vectors are present, the test reports
`OODLE_CLEANROOM_TEST_SKIPPED_NO_LOCAL_VECTORS`.

## Reader build and API test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_pbzsavareader.ps1
```

This rebuilds the production DLL, verifies the public `PBZ.SaveReader` API, and
runs the clean-room vector suite.

To benchmark against a local save:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_pbzsavareader.ps1 `
  -SavePath "C:\path\to\PBZSaveGame.sav"
```

The benchmark compares available backends and checks boss counts when the
legacy reader or running game is present.

## LiveSplit acceptance test

First regenerate and validate the comment-free runtime files:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbz_runtime.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_pbz_runtime.ps1
```

The test verifies that generated ASL/XML files contain no comments and compiles
both ASLs with the installed LiveSplit ASL parser.

After automated tests pass:

1. Copy the required runtime files into a test LiveSplit `Components` directory.
2. Load `PBZ-AutoSplitter.asl` and confirm the settings tree appears.
3. Confirm the script log selects the expected language-specific XML.
4. Start a new timer and confirm the game process/module binds successfully.
5. Enter a loading screen and confirm game time pauses.
6. Return to gameplay and confirm game time resumes.
7. Defeat one enabled test boss and confirm exactly one split is produced.
8. Verify a live Boss leaving combat without dying does not split.
9. Test a Boss death where the actor is destroyed in the same frame.
10. Reset and verify the pending queue and consumed-Boss set are cleared.

Save-backed variant:

1. Load `PBZ-AutoSplitter_BySave.asl`.
2. Start a new timer and confirm a Boss baseline is logged.
3. Defeat one enabled test Boss and confirm one split is produced.

## Compatibility evidence

Version 2.2.0 has been validated against game build
`CL-301524_JKS-17219`. The clean-room decoder was byte-exact on nine real-save
vectors. Last recorded local benchmark results:

| Backend | Approximate time |
| --- | ---: |
| Official `oo2core` DLL | 0.23 ms |
| Clean-room C# Mermaid | 0.28 ms |
| Game-process Oodle bridge | 24.04 ms |

These numbers are hardware-dependent and are not a runtime guarantee.
