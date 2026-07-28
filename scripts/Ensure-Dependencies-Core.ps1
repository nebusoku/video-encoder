[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [switch]$ForceRedownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info([string]$msg) { Write-Host $msg -ForegroundColor Gray }
function Write-Warn([string]$msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host $msg -ForegroundColor Red }
function Write-Ok([string]$msg)   { Write-Host $msg -ForegroundColor Green }
function Write-Cyan([string]$msg) { Write-Host $msg -ForegroundColor Cyan }

function Get-RepoRoot {
    if ($RepoRoot -and $RepoRoot.Trim()) {
        return (Resolve-Path -LiteralPath $RepoRoot).Path
    }
    return (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Remove-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ExcludeNames = @()
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($ExcludeNames -contains $_.Name) { return }
        try {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            throw "Failed clearing '$($_.FullName)': $($_.Exception.Message)"
        }
    }
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )

    Write-Cyan ("Downloading: " + $Url)
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing

    # Strip Mark-of-the-Web from the freshly downloaded file so that later
    # extraction/execution is not treated as running web content (a major
    # trigger for Defender/Bitdefender heuristics and SmartScreen prompts).
    try { Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue } catch {}
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-VendorSha256 {
    # Fetches a vendor-published ".sha256" sidecar and extracts the 64-char hash.
    param([Parameter(Mandatory)][string]$Sha256Url)

    $raw = (Invoke-WebRequest -Uri $Sha256Url -UseBasicParsing).Content
    $token = ($raw -split '\s+' | Where-Object { $_ -match '^[0-9A-Fa-f]{64}$' } | Select-Object -First 1)
    if (-not $token) {
        throw "Could not parse a SHA-256 value from sidecar: $Sha256Url"
    }
    return $token.ToLowerInvariant()
}

function Unblock-Tree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {}
    }
}

function Read-ChecksumStore {
    param([Parameter(Mandatory)][string]$Path)
    $store = @{}
    if (Test-Path -LiteralPath $Path) {
        try {
            $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $store[$p.Name] = [string]$p.Value }
        } catch {
            Write-Warn ("Could not read checksum store (ignoring): " + $_.Exception.Message)
        }
    }
    return $store
}

function Save-ChecksumStore {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Store
    )
    try {
        Ensure-Directory -Path (Split-Path -Parent $Path)
        ($Store | ConvertTo-Json) | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        Write-Warn ("Could not write checksum store: " + $_.Exception.Message)
    }
}

function Confirm-Download {
    <#
    Verifies a downloaded archive's SHA-256.
      - Sha256Url set  -> verify against vendor-published sidecar (hard fail on mismatch).
      - Sha256 set     -> verify against a pinned literal (hard fail on mismatch).
      - neither        -> trust-on-first-use: record on first download, verify on later
                          downloads and prompt before accepting a changed archive.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$ZipPath,
        [hashtable]$Store = @{},
        [string]$Sha256Url = "",
        [string]$Sha256 = ""
    )

    $actual = Get-FileSha256 -Path $ZipPath

    if ($Sha256Url) {
        $expected = Get-VendorSha256 -Sha256Url $Sha256Url
        if ($actual -ne $expected) {
            throw "SHA-256 mismatch for $Key. Expected $expected but downloaded $actual. Aborting."
        }
        Write-Ok "$Key checksum verified against vendor sidecar."
        $Store[$Key] = $actual
        return
    }

    if ($Sha256) {
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            throw "SHA-256 mismatch for $Key. Expected $Sha256 but downloaded $actual. Aborting."
        }
        Write-Ok "$Key checksum verified against pinned value."
        $Store[$Key] = $actual
        return
    }

    if ($Store.ContainsKey($Key) -and $Store[$Key]) {
        if ($actual -ne $Store[$Key]) {
            Write-Warn "$Key archive checksum differs from the previously recorded value:"
            Write-Warn ("  recorded : " + $Store[$Key])
            Write-Warn ("  now      : " + $actual)
            if (-not (Prompt-YesNo "Accept this new download and update the recorded checksum?" $false)) {
                throw "$Key checksum mismatch rejected."
            }
        }
        else {
            Write-Ok "$Key checksum matches the previously recorded value."
        }
    }
    else {
        Write-Info "$Key checksum recorded (trust-on-first-use): $actual"
    }
    $Store[$Key] = $actual
}

function Expand-ZipToTemp {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$TempRoot
    )

    Ensure-Directory -Path $TempRoot
    $extractPath = Join-Path $TempRoot ([IO.Path]::GetFileNameWithoutExtension($ZipPath))
    if (Test-Path -LiteralPath $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractPath -Force
    return $extractPath
}

function Find-ParentContainingFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$FileName
    )

    $hit = Get-ChildItem -LiteralPath $Root -Recurse -Filter $FileName -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hit) { return $null }
    return $hit.Directory.FullName
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$TargetDir
    )

    Ensure-Directory -Path $TargetDir
    Copy-Item -Path (Join-Path $SourceDir '*') -Destination $TargetDir -Recurse -Force
}

function Prompt-YesNo {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $resp = Read-Host "$Prompt $suffix"
    if (-not $resp -or -not $resp.Trim()) { return $DefaultYes }

    switch ($resp.Trim().ToLowerInvariant()) {
        "y" { return $true }
        "yes" { return $true }
        "n" { return $false }
        "no" { return $false }
        default { return $DefaultYes }
    }
}

$root = Get-RepoRoot
$toolsRoot = Join-Path $root "tools"
$tempRoot = Join-Path $root "_downloads"
$configRoot = Join-Path $root "config"
$checksumStorePath = Join-Path $configRoot "tool-checksums.json"
$checksumStore = Read-ChecksumStore -Path $checksumStorePath

$ffmpegDir    = Join-Path $toolsRoot "ffmpeg"
$handBrakeDir = Join-Path $toolsRoot "handbrake"
$fileBotDir   = Join-Path $toolsRoot "filebot"

$ffmpegExe    = Join-Path $ffmpegDir "bin\ffmpeg.exe"
$ffprobeExe   = Join-Path $ffmpegDir "bin\ffprobe.exe"
$handBrakeExe = Join-Path $handBrakeDir "HandBrakeCLI.exe"
$fileBotCmd   = Join-Path $fileBotDir "filebot.cmd"
$fileBotExe   = Join-Path $fileBotDir "FileBot.exe"

Ensure-Directory -Path $toolsRoot
Ensure-Directory -Path $tempRoot
Ensure-Directory -Path $ffmpegDir
Ensure-Directory -Path $handBrakeDir
Ensure-Directory -Path $fileBotDir

# Current URLs / versions
# HandBrake current version shown on official downloads pages: 1.11.1
# FileBot current Windows portable ZIP shown on official download page: 5.2.1-portable.zip
# FFmpeg current release page lists ffmpeg-release-essentials.zip
$downloads = [pscustomobject]@{
    FFmpeg = [pscustomobject]@{
        Label = "FFmpeg Essentials"
        Url   = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
        # gyan.dev publishes a matching .sha256 sidecar that tracks each rolling
        # release, so the download is verifiable without pinning a fixed hash.
        Sha256Url = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip.sha256"
        Sha256 = ""
        Zip   = Join-Path $tempRoot "ffmpeg-release-essentials.zip"
        TargetDir = $ffmpegDir
    }
    HandBrake = [pscustomobject]@{
        Label = "HandBrakeCLI"
        Url   = "https://handbrake.fr/rotation.php?file=HandBrakeCLI-1.11.1-win-x86_64.zip"
        # No vendor sidecar; verified trust-on-first-use. To pin, paste the
        # known-good hash here (Sha256 = "...") after confirming it.
        Sha256Url = ""
        Sha256 = ""
        Zip   = Join-Path $tempRoot "HandBrakeCLI-1.11.1-win-x86_64.zip"
        TargetDir = $handBrakeDir
    }
    FileBot = [pscustomobject]@{
        Label = "FileBot Portable"
        Url   = "https://get.filebot.net/filebot/FileBot_5.2.1/FileBot_5.2.1-portable.zip"
        Sha256Url = ""
        Sha256 = ""
        Zip   = Join-Path $tempRoot "FileBot_5.2.1-portable.zip"
        TargetDir = $fileBotDir
    }
}

Write-Cyan "Dependency Setup / Update"
Write-Info ("Repo Root : " + $root)
Write-Info ("Tools Root: " + $toolsRoot)
Write-Host ""

Write-Info ("FFmpeg    : " + $(if (Test-Path -LiteralPath $ffmpegExe) { "Present" } else { "Missing" }))
Write-Info ("FFprobe   : " + $(if (Test-Path -LiteralPath $ffprobeExe) { "Present" } else { "Missing" }))
Write-Info ("HandBrake : " + $(if (Test-Path -LiteralPath $handBrakeExe) { "Present" } else { "Missing" }))
Write-Info ("FileBot   : " + $(if ((Test-Path -LiteralPath $fileBotCmd) -or (Test-Path -LiteralPath $fileBotExe)) { "Present" } else { "Missing" }))
Write-Host ""

$doFFmpeg = $ForceRedownload -or (-not (Test-Path -LiteralPath $ffmpegExe)) -or (-not (Test-Path -LiteralPath $ffprobeExe))
$doHandBrake = $ForceRedownload -or (-not (Test-Path -LiteralPath $handBrakeExe))
$doFileBot = $ForceRedownload -or (-not (Test-Path -LiteralPath $fileBotCmd) -and -not (Test-Path -LiteralPath $fileBotExe))

if (-not $doFFmpeg)    { $doFFmpeg = Prompt-YesNo "FFmpeg already exists. Download/update anyway?" $false }
if (-not $doHandBrake) { $doHandBrake = Prompt-YesNo "HandBrakeCLI already exists. Download/update anyway?" $false }
if (-not $doFileBot)   { $doFileBot = Prompt-YesNo "FileBot already exists. Download/update anyway?" $false }

try {
    if ($doFFmpeg) {
        Download-File -Url $downloads.FFmpeg.Url -Destination $downloads.FFmpeg.Zip
        Confirm-Download -Key "FFmpeg" -ZipPath $downloads.FFmpeg.Zip -Store $checksumStore -Sha256Url $downloads.FFmpeg.Sha256Url -Sha256 $downloads.FFmpeg.Sha256
        $extract = Expand-ZipToTemp -ZipPath $downloads.FFmpeg.Zip -TempRoot $tempRoot

        # Locate extracted folder that contains bin\ffmpeg.exe
        $ffmpegBinDir = Find-ParentContainingFile -Root $extract -FileName "ffmpeg.exe"
        if (-not $ffmpegBinDir) { throw "Could not find ffmpeg.exe in extracted FFmpeg archive." }

        # Copy the whole build root (parent of bin)
        $buildRoot = Split-Path -Parent $ffmpegBinDir
        Remove-DirectoryContents -Path $ffmpegDir
        Copy-DirectoryContents -SourceDir $buildRoot -TargetDir $ffmpegDir
        Unblock-Tree -Path $ffmpegDir

        if (-not (Test-Path -LiteralPath $ffmpegExe) -or -not (Test-Path -LiteralPath $ffprobeExe)) {
            throw "FFmpeg install incomplete after extraction."
        }

        Write-Ok "FFmpeg updated successfully."
    }

    if ($doHandBrake) {
        Download-File -Url $downloads.HandBrake.Url -Destination $downloads.HandBrake.Zip
        Confirm-Download -Key "HandBrake" -ZipPath $downloads.HandBrake.Zip -Store $checksumStore -Sha256Url $downloads.HandBrake.Sha256Url -Sha256 $downloads.HandBrake.Sha256
        $extract = Expand-ZipToTemp -ZipPath $downloads.HandBrake.Zip -TempRoot $tempRoot

        $hbParent = Find-ParentContainingFile -Root $extract -FileName "HandBrakeCLI.exe"
        if (-not $hbParent) { throw "Could not find HandBrakeCLI.exe in extracted archive." }

        Remove-DirectoryContents -Path $handBrakeDir -ExcludeNames @("presets")
        Copy-DirectoryContents -SourceDir $hbParent -TargetDir $handBrakeDir
        Unblock-Tree -Path $handBrakeDir

        if (-not (Test-Path -LiteralPath $handBrakeExe)) {
            throw "HandBrakeCLI install incomplete after extraction."
        }

        Write-Ok "HandBrakeCLI updated successfully."
    }

    if ($doFileBot) {
        Download-File -Url $downloads.FileBot.Url -Destination $downloads.FileBot.Zip
        Confirm-Download -Key "FileBot" -ZipPath $downloads.FileBot.Zip -Store $checksumStore -Sha256Url $downloads.FileBot.Sha256Url -Sha256 $downloads.FileBot.Sha256
        $extract = Expand-ZipToTemp -ZipPath $downloads.FileBot.Zip -TempRoot $tempRoot

        $fbParent = Find-ParentContainingFile -Root $extract -FileName "filebot.cmd"
        if (-not $fbParent) {
            $fbParent = Find-ParentContainingFile -Root $extract -FileName "FileBot.exe"
        }
        if (-not $fbParent) { throw "Could not find FileBot portable files in extracted archive." }

        # Preserve portable FileBot data folder if present
        $preserveData = Test-Path -LiteralPath (Join-Path $fileBotDir "data")
        $dataTemp = $null
        if ($preserveData) {
            $dataTemp = Join-Path $tempRoot "filebot-data-backup"
            if (Test-Path -LiteralPath $dataTemp) {
                Remove-Item -LiteralPath $dataTemp -Recurse -Force -ErrorAction SilentlyContinue
            }
            Copy-Item -LiteralPath (Join-Path $fileBotDir "data") -Destination $dataTemp -Recurse -Force
        }

        Remove-DirectoryContents -Path $fileBotDir -ExcludeNames @("data")
        Copy-DirectoryContents -SourceDir $fbParent -TargetDir $fileBotDir

        if ($preserveData -and $dataTemp -and (Test-Path -LiteralPath $dataTemp)) {
            if (-not (Test-Path -LiteralPath (Join-Path $fileBotDir "data"))) {
                Copy-Item -LiteralPath $dataTemp -Destination (Join-Path $fileBotDir "data") -Recurse -Force
            }
        }

        if (-not (Test-Path -LiteralPath $fileBotCmd) -and -not (Test-Path -LiteralPath $fileBotExe)) {
            throw "FileBot install incomplete after extraction."
        }

        Unblock-Tree -Path $fileBotDir
        Write-Ok "FileBot updated successfully."
    }

    Write-Host ""
    Write-Cyan "Dependency Summary"
    Write-Info ("FFmpeg    : " + $(if (Test-Path -LiteralPath $ffmpegExe) { $ffmpegExe } else { "Missing" }))
    Write-Info ("FFprobe   : " + $(if (Test-Path -LiteralPath $ffprobeExe) { $ffprobeExe } else { "Missing" }))
    Write-Info ("HandBrake : " + $(if (Test-Path -LiteralPath $handBrakeExe) { $handBrakeExe } else { "Missing" }))
    Write-Info ("FileBot   : " + $(if (Test-Path -LiteralPath $fileBotCmd) { $fileBotCmd } elseif (Test-Path -LiteralPath $fileBotExe) { $fileBotExe } else { "Missing" }))

    Write-Host ""
    Write-Ok "Dependency setup complete."
}
finally {
    Save-ChecksumStore -Path $checksumStorePath -Store $checksumStore
    if (Test-Path -LiteralPath $tempRoot) {
        try {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}