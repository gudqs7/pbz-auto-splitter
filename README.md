# PBZ Auto Splitter

Unofficial LiveSplit auto splitter for Phantom Blade Zero. It pauses game time
while the game is loading, starts the timer when gameplay begins, and creates
boss splits directly from live game memory. Release packages are memory-only;
the save-backed variant remains in the source repository for legacy comparison.

> Compatibility: version 2.2.5 targets game build
> `CL-302256_JKS-17280`. Game updates can change the memory layout used for
> loading detection and memory-only boss tracking. Save-file boss tracking and
> the clean-room decoder are independent of those offsets.

## Features

- Load removal and game-time pause for menus, front-end worlds, and loading.
- Memory-only boss kill tracking in the default auto splitter.
- An `AutoSplitEnabled` master switch that can disable split triggering while
  keeping Boss detection and logging active.
- Logging for Boss candidates that are present in combat but missing from the
  settings XML, without queuing a split.
- A one-click Windows installer that scans non-C drives, handles multiple
  LiveSplit installations, copies the layout, and creates a launch shortcut.
- Boss split groups with individual toggles in the LiveSplit settings.
- Chinese and English boss settings selected automatically from the Windows UI
  language.

The source repository also retains the optional save-backed variant, including
AES-256-GCM container decryption and pure C# Oodle Mermaid decoding. Those files
are intentionally excluded from release packages.

## Requirements

- Windows.
- LiveSplit 1.8.x or a compatible release.
- Phantom Blade Zero installed through Steam.
- .NET Framework 4.x for running the prebuilt component.

## Installation

1. Download and extract the release ZIP.
2. Close LiveSplit.
3. Run `Install-PBZ.bat`.
4. The installer scans fixed drives other than C for `LiveSplit.exe`. If several
   installations are found, choose the required one from the numbered list.
5. The installer backs up files it will replace, copies the memory-only
   components, `pbz.lsl`, and `pbz.lss`, then creates `LiveSplit-PBZ.exe.lnk` in
   the selected LiveSplit directory.
6. Start LiveSplit through the new shortcut and enable the desired Bosses.

The release ZIP contains only the memory splitter, both Boss settings files,
`asl-help`, the layout/run files, and the installer. It does not contain the
save-backed variant, `PBZSaveReader.dll`, source code, or documentation.

All Boss toggles are enabled by default. Use `AutoSplitEnabled` to disable
automatic split triggering without disabling Boss detection or logging.
The Boss toggles are loaded as soon as the auto splitter script starts, whether
or not the game is running.

`PBZ-AutoSplitter.asl` reads live Boss actors, active combat tags, health, and
death/destruction edges directly from the game process. It does not load
`PBZSaveReader.dll`, inspect save files, or wait for a file write.

`PBZ-AutoSplitter_BySave.asl` remains in the repository for save-backed
development and comparison, but is not included in release packages.

The script first looks for a settings file matching the full Windows UI culture,
then the base language, such as `PBZ.BossSettings.en.xml`. If neither exists, it
loads `PBZ.BossSettings.xml`. Keep both XML files next to the ASL.

## Usage

Start the LiveSplit timer before beginning a run. The default script:

1. Resolves the local player through fixed UE object pointers.
2. Reads the player's active `BeHatredList`.
3. Matches active Boss actor classes against the enabled settings.
4. Tracks `CharacterState.Dead`, health, and actor destruction.
5. Queues a split immediately when a watched Boss dies, reaches zero health,
   or leaves `BeHatredList` at or below 2% health.

Main-story and side-boss groups in the default XML are heuristics. Adjust the
toggles to match the run category.

## Configuration

The optional save-backed development variant supports these environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `PBZ_ODLE_BACKEND` | `auto` | `auto`, `cleanroom`, or `game`. |
| `PBZ_ODLE_FALLBACK` | enabled for `auto` | Set to `none` to disable fallback or `game` to force it. |
| `OO2CORE_DLL` | unset | Optional development-only path to an Oodle DLL. |

Production use requires no Oodle DLL.

## Repository layout

```text
Install-PBZ.bat             Generated one-click installer
lss-sample/pbz.lsl           Release layout
lss-sample/pbz.lss           Optional starter split file
Components/                  Generated runtime files
Source/Runtime/              Commented ASL and settings source
Source/Installer/            Installer source and package-time generator
Source/                      Runtime generator and save-reader source
Source/OodleCleanRoom/       Mermaid decoder, tests, and real-save vectors
docs/                        Architecture, development, testing, and support
AGENT.md                     Repository instructions for coding agents
```

The files shipped under `Components`, including release archives and the local
LiveSplit `Components` copy, are generated without comments. Edit
`Source/Runtime` and run `Source/build_pbz_runtime.ps1` instead of changing the
generated ASL or XML directly.

## Documentation

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [Testing](docs/testing.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Changelog](CHANGELOG.md)

## Scope and privacy

The default splitter reads local game process memory. The optional development
variant can read local save files. The project does not upload saves, game
binaries, telemetry, or personal data. Do not commit save files, crash dumps,
logs containing account paths, or game executables to this repository.
