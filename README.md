# PBZ Auto Splitter

Unofficial LiveSplit auto splitter for Phantom Blade Zero. It pauses game time
while the game is loading, starts the timer when gameplay begins, and creates
boss splits directly from live game memory. A save-backed variant remains
available for comparison and fallback.

> Compatibility: version 2.2.3 targets game build
> `CL-301524_JKS-17219`. Game updates can change the memory layout used for
> loading detection and memory-only boss tracking. Save-file boss tracking and
> the clean-room decoder are independent of those offsets.

## Features

- Load removal and game-time pause for menus, front-end worlds, and loading.
- Memory-only boss kill tracking in the default auto splitter.
- An `AutoSplitEnabled` master switch that can disable split triggering while
  keeping Boss detection and logging active.
- Logging for Boss candidates that are present in combat but missing from the
  settings XML, without queuing a split.
- A legacy save-file variant retained as `PBZ-AutoSplitter_BySave.asl`.
- Boss split groups with individual toggles in the LiveSplit settings.
- Chinese and English boss settings selected automatically from the Windows UI
  language.
- AES-256-GCM save container decryption.
- Pure C# Oodle Mermaid decoding, with no external Oodle DLL required.
- Automatic fallback to the Oodle decoder embedded in `PBZ.exe` when a future
  save uses an unsupported Mermaid branch.

## Requirements

- Windows.
- LiveSplit 1.8.x or a compatible release.
- Phantom Blade Zero installed through Steam.
- .NET Framework 4.x for running the prebuilt component.

## Installation

1. Close LiveSplit.
2. Copy the following items from `Components` into the LiveSplit `Components`
   directory:
   - `PBZ-AutoSplitter.asl` (memory-only, recommended)
   - `PBZ-AutoSplitter_BySave.asl` (save-file variant, optional)
   - `PBZ.BossSettings.xml`
   - `PBZ.BossSettings.en.xml`
   - `asl-help`
   - `PBZSaveReader.dll` only when using the BySave variant
3. Start LiveSplit.
4. Add `PBZ-AutoSplitter.asl` as a Scriptable Auto Splitter.
5. Enable the desired bosses under the auto splitter settings.

All Boss toggles are enabled by default. Use `AutoSplitEnabled` to disable
automatic split triggering without disabling Boss detection or logging.
The Boss toggles are loaded as soon as the auto splitter script starts, whether
or not the game is running.

`PBZ-AutoSplitter.asl` reads live Boss actors, active combat tags, health, and
death/destruction edges directly from the game process. It does not load
`PBZSaveReader.dll`, inspect save files, or wait for a file write.

`PBZ-AutoSplitter_BySave.asl` is the previous save-file implementation. Select
it manually if you prefer save-backed kill tracking or need it as a comparison.

The script first looks for a settings file matching the full Windows UI culture,
then the base language, such as `PBZ.BossSettings.en.xml`. If neither exists, it
loads `PBZ.BossSettings.xml`. Keep both XML files next to the ASL and DLL.

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

The save reader supports these environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `PBZ_ODLE_BACKEND` | `auto` | `auto`, `cleanroom`, or `game`. |
| `PBZ_ODLE_FALLBACK` | enabled for `auto` | Set to `none` to disable fallback or `game` to force it. |
| `OO2CORE_DLL` | unset | Optional development-only path to an Oodle DLL. |

Production use requires no Oodle DLL.

## Repository layout

```text
Components/                 Runtime files copied into LiveSplit
Source/Runtime/             Commented ASL and settings source
Source/                     Runtime generator and rebuildable save-reader source
Source/OodleCleanRoom/      Mermaid decoder, tests, and real-save vectors
docs/                       Architecture, development, testing, and support
AGENT.md                    Repository instructions for coding agents
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

This project reads local game save files only. It does not upload saves, game
binaries, telemetry, or personal data. Do not commit save files, crash dumps,
logs containing account paths, or game executables to this repository.
