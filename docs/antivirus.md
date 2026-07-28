# Antivirus (Windows Defender / Bitdefender)

## Why security software flags this tool

The dependency step (`scripts\Ensure-Dependencies-Core.ps1`, menu option 1)
**downloads real encoder binaries from the internet and then runs them**:

1. `Invoke-WebRequest` pulls ZIP archives (FFmpeg, HandBrakeCLI, FileBot),
2. the archives are extracted into `tools\`,
3. those `.exe` files are executed during encoding.

"A PowerShell script downloads an executable and runs it" is the exact
behavioral pattern that **Microsoft Defender Attack Surface Reduction (ASR)**
rules and **Bitdefender Advanced Threat Defense** treat as a trojan-downloader.
The detection is *heuristic / behavioral* — it is reacting to the shape of the
activity, not to any actual malware in this repository or in the downloaded
tools. FFmpeg, HandBrake and FileBot are well-known, legitimate projects.

## What the tool now does to reduce this

- **Pinned, reputable HTTPS sources** for every download.
- **SHA-256 verification** before anything is extracted:
  - FFmpeg is verified against the vendor's published `.sha256` sidecar
    (`ffmpeg-release-essentials.zip.sha256`), which tracks each rolling build.
  - HandBrake and FileBot use **trust-on-first-use**: the hash is recorded to
    `config\tool-checksums.json` on first download and verified on every later
    download, warning you if the archive bytes ever change. You can also pin a
    known-good hash directly in the download manifest.
- **Mark-of-the-Web removal** (`Unblock-File`) on the downloaded archives and on
  every extracted file, so Windows no longer treats the tools as "downloaded
  from the internet" when they run — this alone removes a lot of SmartScreen and
  Defender friction.

These measures make the activity verifiable and cleaner, but they cannot
guarantee a heuristic engine won't still flag the download step. If it does, use
an allowlist as described below.

## Allowlisting (recommended)

The safest, most reliable fix is to exclude the tool's **`tools\` folder** (and
optionally the repo folder) from real-time scanning. Only do this for a repo you
trust and control.

### Windows Defender (UI)

Settings → **Privacy & security** → **Windows Security** → **Virus & threat
protection** → *Manage settings* → *Exclusions* → **Add or remove exclusions** →
*Add an exclusion* → **Folder**, then select the repo's `tools\` folder.

### Windows Defender (PowerShell, run as Administrator)

```powershell
# Adjust the path to your clone location
Add-MpPreference -ExclusionPath "C:\Users\<you>\Documents\GitHub\video-encoder\tools"
```

To remove it later:

```powershell
Remove-MpPreference -ExclusionPath "C:\Users\<you>\Documents\GitHub\video-encoder\tools"
```

### Bitdefender

Open Bitdefender → **Protection** → **Antivirus** → *Settings* →
**Manage exceptions** → *Add an exception* → add the repo's `tools\` folder path
and enable it for **On-access (real-time)** and **Advanced Threat Defense**.
(Exact wording varies by Bitdefender edition/version.)

## If a download is quarantined

1. Confirm the SHA-256 check passed in the script output (it verifies integrity).
2. Restore the file from your AV's quarantine and add the folder exclusion above.
3. Re-run menu option 1 (Download / update tools).

## Note on execution policy

The launchers use `-ExecutionPolicy Bypass` so the scripts run without changing
your machine's global policy. This is scoped to the single invocation and does
not lower system-wide protection. Authenticode code-signing of the scripts is
tracked separately (issue #21 follow-up) and would remove policy prompts on
machines that trust the signing certificate.
