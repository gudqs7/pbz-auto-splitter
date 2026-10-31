# PBZ Auto Splitter

Unofficial LiveSplit auto splitter for Phantom Blade Zero. It pauses game time
while the game is loading, starts the timer when gameplay begins, and creates
boss splits from the game's save file.

> Compatibility: version 2.2.0 was validated against game build
> `CL-301524_JKS-17219`. Game updates can change the memory layout used for
> loading detection. Save-file boss tracking and the clean-room decoder are
> independent of those offsets.

## Features

- Load removal and game-time pause for menus, front-end worlds, and loading.
- Boss kill tracking from `PBZSaveGame.sav`, independent of live boss memory.
- Boss split groups with individual toggles in the LiveSplit settings.
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
   - `PBZLoadRemover.asl`
   - `PBZ.BossSettings.xml`
   - `PBZSaveReader.dll`
   - `asl-help`
3. Start LiveSplit.
4. Add `PBZLoadRemover.asl` as a Scriptable Auto Splitter.
5. Enable the desired bosses under the auto splitter settings.

The script loads boss settings from `Components\PBZ.BossSettings.xml`. Keep the
XML next to the ASL and DLL.

## Usage

Start the LiveSplit timer before beginning a run. The script:

1. Finds the newest `PBZSaveGame.sav` beneath
   `ProjectPBZ\Saved\SaveGames`.
2. Captures the current boss counters when the timer starts.
3. Watches for changed counters after the save file is updated.
4. Queues an enabled boss setting when its kill count increases.
5. Splits on the next LiveSplit update cycle.

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
Source/                     Rebuildable save-reader source
Source/OodleCleanRoom/      Mermaid decoder, tests, and real-save vectors
docs/                       Architecture, development, testing, and support
AGENT.md                    Repository instructions for coding agents
```

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
