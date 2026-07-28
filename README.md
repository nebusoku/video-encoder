# Portable Video Encoder

A self-contained Windows PowerShell toolkit for batch-transcoding video for Plex.
Everything runs from the repo folder using a portable toolchain (HandBrakeCLI,
FFmpeg/FFprobe, and optionally FileBot) that the scripts download on demand into
a gitignored `tools\` folder — nothing is installed system-wide.

Current version: see [`VERSION`](VERSION).

## Quick start

Run with no arguments to get the interactive menu:

```bat
run-video-convert.cmd
```

or, from a PowerShell prompt in the repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\video-convert.ps1
```

Do **not** wrap the command in backticks — in PowerShell backticks are escape
characters, not quotes. From an already-open prompt you can also use
`& ".\video-convert.ps1"`.

## Command-line interface

`video-encoder` runs any step directly from one entry point, loading only the
script that command needs. Run it with no command to get the interactive menu.

```bat
video-encoder.cmd <command> [options]
```

or in PowerShell:

```powershell
.\video-encoder.ps1 <command> [options]
# or import the module and use the command/alias:
Import-Module .\module\VideoEncoder.psd1
video-encoder <command> [options]
```

Commands:

| Command | Does | Needs |
|---------|------|-------|
| `tools` | Download / update the toolchain | — |
| `probe` | Build / refresh the hardware profile | tools |
| `encode-tv` | Encode a TV library (720p) | tools + profile |
| `encode-movies` | Encode a Movies library (1080p) | tools + profile |
| `dvd-tv` | Rip / encode a TV DVD | tools + profile |
| `dvd-movies` | Rip / encode a movie DVD | tools + profile |
| `filebot` | Rename / stage with FileBot | tools |
| `menu` | Launch the interactive menu | — |
| `help` | Show usage (`--help`, `-h` too) | — |

Options after the command are forwarded to the underlying script, so every
parameter that script accepts works on the CLI (names may be abbreviated if
unambiguous). Missing tools/profile, unknown parameters, and missing values are
reported before anything runs. Examples:

```powershell
.\video-encoder.ps1 tools -ForceRedownload
.\video-encoder.ps1 probe
.\video-encoder.ps1 encode-tv -RootPath "Y:\TV Shows" -EnableFileBotRename
.\video-encoder.ps1 encode-movies -RootPath "Y:\Movies" -Quality 22
.\video-encoder.ps1 dvd-movies -SourcePath "D:\" -OutputRoot "Y:\Movies"
```

## Interactive menu

`video-convert.ps1` launches `scripts\Menu-Core.ps1`, which shows a readiness
header (core tools / hardware profile / FileBot) and these options:

| # | Action | Script |
|---|--------|--------|
| 1 | Download / update tools | `scripts\Ensure-Dependencies-Core.ps1` |
| 2 | Hardware test (build/update machine profile) | `scripts\Probe-HardwareProfile.ps1` |
| 3 | Encode TV shows | `scripts\Start-TV.ps1` |
| 4 | Encode movies | `scripts\Start-Movies.ps1` |
| 5 | DVD movie disc / import | `scripts\Start-DVD-Movies.ps1` |
| 6 | DVD TV disc / import | `scripts\Start-DVD-TV.ps1` |
| 7 | FileBot rename / staging | `scripts\Start-FileBot-Rename.ps1` |
| 8 | Open repo root | — |
| 9 | Open tools folder | — |
| 0 | Exit | — |

Options 3–7 prompt for the relevant paths and run options (root path, FileBot
rename, backup originals, dry run, encoder mode, quality, etc.) before starting.

## Running steps directly

Each action can also be invoked on its own, which is useful for scripting:

```powershell
# Download / update the toolchain
powershell -ExecutionPolicy Bypass -File .\scripts\Ensure-Dependencies-Core.ps1

# Hardware probe (build the machine profile before first encode)
powershell -ExecutionPolicy Bypass -File .\scripts\Probe-HardwareProfile.ps1

# TV pass
powershell -ExecutionPolicy Bypass -File .\scripts\Start-TV.ps1 -RootPath "Y:\TV Shows" -EnableFileBotRename

# Movies pass
powershell -ExecutionPolicy Bypass -File .\scripts\Start-Movies.ps1 -RootPath "Y:\Movies" -EnableFileBotRename
```

A hardware profile is required before encoding (menu option 2). It is cached
under `config\hardware-profile.json` and reused by `-EncoderMode Auto`.

## Layout

```
video-convert.ps1              Entry point -> Menu-Core.ps1
run-video-convert.cmd          Windows launcher wrapper
VERSION                        Single-line version string
scripts\
  Menu-Core.ps1                Interactive menu + prompts + dispatch
  Ensure-Dependencies-Core.ps1 Download/verify the toolchain into tools\
  Probe-HardwareProfile.ps1    GPU/encoder capability probe + cache
  Invoke-VideoConvert.ps1      Core encode engine
  Start-TV.ps1 / Start-Movies.ps1
  Start-DVD-TV.ps1 / Start-DVD-Movies.ps1
  Start-FileBot-Rename.ps1
  Test-PowerShellSyntax-Core.ps1   Parser precheck for all *.ps1
  Validate-PowerShellStatic.py     Static token/balance sanity check
  lib\Common-Core.ps1          Shared helpers
  dvd\ , pipeline\             DVD + staging helpers (some still stubs — issue #24)
tools\                         Downloaded toolchain (gitignored)
config\                        Machine-specific profiles/logs (gitignored)
```

## Behavior notes

- **Backups:** `Originals` folders are created only when `-BackupOriginal` is
  enabled. Otherwise originals are removed after a successful replacement, with
  no empty backup folders left behind.
- **Resume / completed tracking:** completed records store full input/output
  paths; at the end of a run the completed CSV is rewritten as a clean snapshot
  (one latest row per input) to avoid re-processing.
- **Hardware cache:** `config\hardware-profile.json`, refreshed by menu option 2.

## Diagnostics

- Pre-check parser errors before a run:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\Test-PowerShellSyntax-Core.ps1
  ```

  Add `-IncludeLegacyShims` to also check the legacy `Ensure-Dependencies.ps1` shim.

- Static token/balance check (unclosed braces, merge markers, etc.):

  ```powershell
  python .\scripts\Validate-PowerShellStatic.py
  ```

## Releases

Releases are published automatically by `.github/workflows/release.yml` when a
version tag is pushed. To cut a release:

1. Bump the version in both [`VERSION`](VERSION) and
   [`module/VideoEncoder.psd1`](module/VideoEncoder.psd1) (`ModuleVersion`).
2. Commit the bump.
3. Tag and push:

   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```

The workflow verifies the tag matches both version strings, builds
`video-encoder-<version>.zip` from the tracked files (via `git archive`, so no
`tools\`, downloads, or machine config are included), and publishes a GitHub
Release with auto-generated notes.

## Antivirus (Defender / Bitdefender)

Because the tool downloads real encoder binaries and then runs them, security
software may flag the dependency step. See [`docs/antivirus.md`](docs/antivirus.md)
for why this happens, the integrity checks the downloader performs, and how to
allowlist the `tools\` folder. Tracked in issue #21.
