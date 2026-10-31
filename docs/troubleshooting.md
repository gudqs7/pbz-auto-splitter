# Troubleshooting

## The auto splitter does not appear

- Confirm the required files from `Components` are present in LiveSplit's
  `Components` directory.
- Load `PBZ-AutoSplitter.asl` through LiveSplit's Scriptable Auto Splitter editor.
- Check that `asl-help` and the matching `PBZ.BossSettings*.xml` files are next
  to the ASL.

To use the previous save-backed implementation, select
`PBZ-AutoSplitter_BySave.asl` manually and keep `PBZSaveReader.dll` installed.

## `save reader load failed`

`PBZSaveReader.dll` could not be loaded. Reinstall the copy from this release and
check whether antivirus software quarantined it. The component targets x64
.NET Framework 4.x.

## `boss save=(not found)`

The script could not find `PBZSaveGame.sav`.

- Start the game at least once so it creates
  `ProjectPBZ\Saved\SaveGames`.
- Confirm the game process is the full `PBZ.exe`, not the small bootstrap
  process.
- Keep the save directory readable by the LiveSplit process.

## No boss splits

Memory-only variant:

- The process must be the full `PBZ.exe` with module size `0x1EC54000`.
- The Boss must appear in the player's `BeHatredList`.
- The Boss class must have a matching enabled `Boss_BP_Monster_*` setting.
- Check `Logs/PBZ-AutoSplitter.log` for `boss appeared`, `boss died`, and
  `boss split`.

`boss removal not confirmed` can appear after a successful split when the dead
Boss actor remains alive in memory for more than the two-second grace period.
It does not undo a death or split that was already logged.

Save-backed variant:

- Start the timer before killing the boss. The first read establishes a
  baseline, and the split requires a later kill-count increase.
- Enable the individual boss under the auto splitter settings.
- Some boss categories are grouped heuristically. Check the matching XML entry.
- Inspect LiveSplit's script log for `[PBZ] boss kill`, `enabled=`, and
  `[PBZ] split ->` messages.

## Game time never pauses

The live loading detection is build-specific. Version 2.2.0 was validated
against build `CL-301524_JKS-17219`. A game update may require new module offsets
and a pointer-chain validation pass.

## Decode error after a game update

The clean-room decoder supports the Mermaid subset used by validated PBZ saves.
The default `auto` backend falls back to the decoder embedded in `PBZ.exe`. If
both fail:

1. Record the exact `[PBZ] boss save read failed` text.
2. Preserve a copy of the affected save in a private test directory.
3. Add a sanitized `.oodle`/`.expected` regression vector if redistribution is
   permitted.
4. Do not publish the original save unless all personal/account data has been
   removed.

## Reducing diagnostics

Set `PBZ_ODLE_BACKEND=cleanroom` and `PBZ_ODLE_FALLBACK=none` only when debugging
the C# decoder. The normal user configuration is `auto`.
