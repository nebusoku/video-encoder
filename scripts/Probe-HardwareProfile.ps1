<#
Probe-HardwareProfile.ps1 (PowerShell 5.1 compatible)

Purpose:
- Build a machine-specific hardware + tool capability profile for the encoder pipeline.
- Filters to physical GPUs (avoids Remote Display / virtual adapters).
- Detects HandBrake & FFmpeg capabilities to guide encoder selection.

Default outputs:
- <RepoRoot>\config\hardware-profile.json

Exit codes:
- 0 success
- 1 failure
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$ToolsRoot = "",
    [string]$OutPath = "",

    # Optional: require tools to exist (if set, missing tools -> error)
    [switch]$RequireTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info([string]$msg) { Write-Host ("[probe] " + $msg) -ForegroundColor Gray }
function Write-Warn([string]$msg) { Write-Host ("[probe] " + $msg) -ForegroundColor Yellow }
function Write-Ok([string]$msg)   { Write-Host ("[probe] " + $msg) -ForegroundColor Green }

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-RepoRoot {
    if ($RepoRoot -and $RepoRoot.Trim()) { return (Resolve-Path -LiteralPath $RepoRoot).Path }

    # RepoRoot assumed to be parent of /scripts
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $parent = Split-Path -Parent $scriptDir
    return (Resolve-Path -LiteralPath $parent).Path
}

function Resolve-ToolsRoot([string]$resolvedRepoRoot) {
    if ($ToolsRoot -and $ToolsRoot.Trim()) { return (Resolve-Path -LiteralPath $ToolsRoot).Path }
    return (Join-Path $resolvedRepoRoot "tools")
}

function Resolve-OutPath([string]$resolvedRepoRoot) {
    if ($OutPath -and $OutPath.Trim()) { return $OutPath }
    return (Join-Path (Join-Path $resolvedRepoRoot "config") "hardware-profile.json")
}

function Get-DisplayAdaptersRaw {
    try {
        return Get-CimInstance Win32_VideoController -ErrorAction Stop
    } catch {
        return Get-WmiObject Win32_VideoController
    }
}

function Get-PhysicalGpuObjects {
    $adapters = Get-DisplayAdaptersRaw

    # Filter out common non-physical adapters
    $ignoreNameRegex = '(?i)Microsoft Remote Display Adapter|Remote Display|Basic Display Adapter|Hyper-V|Virtual|VMware|VirtualBox|Parallels|Citrix|DisplayLink|Miracast|RDP|Indirect Display|Mirror|Dameware|TeamViewer'

    $physical = @()

    foreach ($a in $adapters) {
        $name = [string]$a.Name
        $pnp  = [string]$a.PNPDeviceID
        $vendor = [string]$a.AdapterCompatibility

        if (-not $name) { continue }
        if ($name -match $ignoreNameRegex) { continue }

        # Prefer PCI devices (real GPUs)
        if ($pnp -and $pnp -match '^PCI\\VEN_') {
            $physical += $a
            continue
        }

        # Some systems don't populate PNPDeviceID consistently; keep only likely real vendors
        if ($vendor -match '(?i)NVIDIA|AMD|Advanced Micro Devices|Intel') {
            $physical += $a
        }
    }

    # De-dup by Name
    $seen = @{}
    $out = @()
    foreach ($p in $physical) {
        $n = [string]$p.Name
        if (-not $seen.ContainsKey($n)) {
            $seen[$n] = $true
            $out += $p
        }
    }
    return $out
}

function Invoke-NativeText {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Args
    )

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName = $FilePath
    $p.StartInfo.Arguments = ($Args -join " ")
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError  = $true
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true

    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    return @{
        ExitCode = $p.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Text     = ($stdout + "`n" + $stderr).Trim()
    }
}

function Get-HandBrakeCapabilities {
    param([string]$HandBrakeCliPath)

    $caps = [ordered]@{
        HandBrakePath = $HandBrakeCliPath
        Exists = $false
        EncodersText = ""
        SupportsNvencH264 = $false
        SupportsAmdVceH264 = $false
        SupportsIntelQsvH264 = $false
        # Common newer naming; keep for future use
        SupportsAmdAmfH264 = $false
        SelectedEncoder = "x264"
    }

    if (-not $HandBrakeCliPath -or -not (Test-Path -LiteralPath $HandBrakeCliPath)) { return $caps }
    $caps.Exists = $true

    $res = Invoke-NativeText -FilePath $HandBrakeCliPath -Args @("--help")
    $text = $res.Text
    $caps.EncodersText = $text

    # HandBrake encoder strings vary; use multiple patterns
    $caps.SupportsNvencH264     = ($text -match '(?i)\bnvenc_h264\b' -or $text -match '(?i)\bh264_nvenc\b')
    $caps.SupportsAmdVceH264    = ($text -match '(?i)\bvce_h264\b')
    $caps.SupportsAmdAmfH264    = ($text -match '(?i)\bamf_h264\b' -or $text -match '(?i)\bh264_amf\b')
    $caps.SupportsIntelQsvH264  = ($text -match '(?i)\bqsv_h264\b' -or $text -match '(?i)\bh264_qsv\b')

    return $caps
}

function Get-FfmpegCapabilities {
    param([string]$FfmpegPath)

    $caps = [ordered]@{
        FfmpegPath = $FfmpegPath
        Exists = $false
        HwAccels = @()
        InterestingEncoders = @()
        SupportsNvencH264 = $false
        SupportsAmdAmfH264 = $false
        SupportsIntelQsvH264 = $false
    }

    if (-not $FfmpegPath -or -not (Test-Path -LiteralPath $FfmpegPath)) { return $caps }
    $caps.Exists = $true

    $hw = Invoke-NativeText -FilePath $FfmpegPath -Args @("-hide_banner","-hwaccels")
    if ($hw.ExitCode -eq 0 -and $hw.Text) {
        $caps.HwAccels = @(
            $hw.Text -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '(?i)^Hardware acceleration methods' }
        )
    }

    $enc = Invoke-NativeText -FilePath $FfmpegPath -Args @("-hide_banner","-encoders")
    if ($enc.ExitCode -eq 0 -and $enc.Text) {
        $caps.SupportsNvencH264    = ($enc.Text -match '(?m)^\s*[A-Z\.]{6}\s+h264_nvenc\b')
        $caps.SupportsAmdAmfH264   = ($enc.Text -match '(?m)^\s*[A-Z\.]{6}\s+h264_amf\b')
        $caps.SupportsIntelQsvH264 = ($enc.Text -match '(?m)^\s*[A-Z\.]{6}\s+h264_qsv\b')

        $interesting = @("h264_nvenc","hevc_nvenc","h264_amf","hevc_amf","h264_qsv","hevc_qsv","libx264","libx265")
        $found = @()
        foreach ($e in $interesting) {
            if ($enc.Text -match ("(?m)^\s*[A-Z\.]{6}\s+" + [regex]::Escape($e) + "\b")) { $found += $e }
        }
        $caps.InterestingEncoders = $found
    }

    return $caps
}

try {
    $resolvedRepoRoot = Resolve-RepoRoot
    $resolvedToolsRoot = Resolve-ToolsRoot -resolvedRepoRoot $resolvedRepoRoot
    $resolvedOutPath = Resolve-OutPath -resolvedRepoRoot $resolvedRepoRoot

    $resolvedOutDir = Split-Path -Parent $resolvedOutPath
    Ensure-Directory -Path $resolvedOutDir

    # Canonical tool paths
    $handBrakeCli = Join-Path (Join-Path $resolvedToolsRoot "handbrake") "HandBrakeCLI.exe"
    $ffmpegExe    = Join-Path (Join-Path (Join-Path $resolvedToolsRoot "ffmpeg") "bin") "ffmpeg.exe"
    $ffprobeExe   = Join-Path (Join-Path (Join-Path $resolvedToolsRoot "ffmpeg") "bin") "ffprobe.exe"
    $filebotExe   = Join-Path (Join-Path $resolvedToolsRoot "filebot") "filebot.exe"

    Write-Info ("RepoRoot : " + $resolvedRepoRoot)
    Write-Info ("ToolsRoot: " + $resolvedToolsRoot)
    Write-Info ("OutPath  : " + $resolvedOutPath)

    # Probe physical GPUs
    $gpuObjs = @(Get-PhysicalGpuObjects)
    $gpuNames = @($gpuObjs | ForEach-Object { [string]$_.Name } | Select-Object -Unique)

    if ($gpuNames.Count -eq 0) {
        Write-Warn "No physical GPUs detected after filtering. Falling back to raw adapter list (still excluding Remote/Basic)."
        $rawNames = @((Get-DisplayAdaptersRaw | Select-Object -ExpandProperty Name) | Where-Object { $_ -and $_ -notmatch '(?i)Microsoft Remote Display Adapter|Basic Display Adapter' } | Select-Object -Unique)
        $gpuNames = $rawNames
    }

    # Identify vendor presence
    $hasNvidia = ($gpuNames | Where-Object { $_ -match '(?i)\bNVIDIA\b|GeForce|Quadro' }).Count -gt 0
    $hasAmd    = ($gpuNames | Where-Object { $_ -match '(?i)\bAMD\b|Radeon|Advanced Micro Devices' }).Count -gt 0
    $hasIntel  = ($gpuNames | Where-Object { $_ -match '(?i)\bIntel\b' }).Count -gt 0

    # Probe tools
    $hbCaps = Get-HandBrakeCapabilities -HandBrakeCliPath $handBrakeCli
    $ffCaps = Get-FfmpegCapabilities -FfmpegPath $ffmpegExe

    # Select a preferred HandBrake encoder based on vendor + support
    $selected = "x264"
    if ($hasNvidia -and $hbCaps.SupportsNvencH264) { $selected = "nvenc_h264" }
    elseif ($hasAmd -and ($hbCaps.SupportsAmdVceH264 -or $hbCaps.SupportsAmdAmfH264)) {
        $selected = $(if ($hbCaps.SupportsAmdVceH264) { "vce_h264" } else { "amf_h264" })
    }
    elseif ($hasIntel -and $hbCaps.SupportsIntelQsvH264) { $selected = "qsv_h264" }
    $hbCaps.SelectedEncoder = $selected

    # FileBot presence (no probing needed)
    $filebotExists = (Test-Path -LiteralPath $filebotExe)

    # RequireTools enforcement (optional)
    if ($RequireTools) {
        $missing = @()
        if (-not (Test-Path -LiteralPath $handBrakeCli)) { $missing += $handBrakeCli }
        if (-not (Test-Path -LiteralPath $ffmpegExe))    { $missing += $ffmpegExe }
        if (-not (Test-Path -LiteralPath $ffprobeExe))   { $missing += $ffprobeExe }
        if (-not $filebotExists)                         { $missing += $filebotExe }

        if ($missing.Count -gt 0) {
            throw ("Missing required tools: " + ($missing -join ", "))
        }
    }

    $profile = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        ProbedAtUtc  = (Get-Date).ToUniversalTime().ToString("o")

        # GPUs
        GpuNames = $gpuNames
        HasNvidia = $hasNvidia
        HasAmd    = $hasAmd
        HasIntel  = $hasIntel

        # Tools (canonical)
        ToolsRoot = $resolvedToolsRoot
        HandBrakePath = $handBrakeCli
        FfmpegPath    = $ffmpegExe
        FfprobePath   = $ffprobeExe
        FileBotPath   = $filebotExe

        # HandBrake support flags
        HandBrakeExists = $hbCaps.Exists
        SupportsHandBrakeNvencH264 = $hbCaps.SupportsNvencH264
        SupportsHandBrakeAmdVceH264 = $hbCaps.SupportsAmdVceH264
        SupportsHandBrakeAmdAmfH264 = $hbCaps.SupportsAmdAmfH264
        SupportsHandBrakeIntelQsvH264 = $hbCaps.SupportsIntelQsvH264
        SelectedHandBrakeEncoder = $hbCaps.SelectedEncoder

        # FFmpeg support flags
        FfmpegExists = $ffCaps.Exists
        FfmpegHwAccels = $ffCaps.HwAccels
        SupportsFfmpegNvencH264 = $ffCaps.SupportsNvencH264
        SupportsFfmpegAmfH264   = $ffCaps.SupportsAmdAmfH264
        SupportsFfmpegQsvH264   = $ffCaps.SupportsIntelQsvH264
        FfmpegInterestingEncoders = $ffCaps.InterestingEncoders

        # FileBot
        FileBotExists = $filebotExists
    }

    # Write JSON (readable)
    $json = $profile | ConvertTo-Json -Depth 6
    $json | Set-Content -LiteralPath $resolvedOutPath -Encoding UTF8

    Write-Ok ("Hardware profile written: " + $resolvedOutPath)
    Write-Info ("Physical GPUs: " + ($gpuNames -join "; "))
    Write-Info ("Selected HandBrake encoder: " + $hbCaps.SelectedEncoder)
    if ($ffCaps.Exists) {
        Write-Info ("FFmpeg hwaccels: " + ($ffCaps.HwAccels -join ", "))
        Write-Info ("FFmpeg encoders: " + ($ffCaps.InterestingEncoders -join ", "))
    } else {
        Write-Warn "FFmpeg not found; profile recorded Exists=false."
    }

    exit 0
}
catch {
    Write-Host ("[probe] ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}