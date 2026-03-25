[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [switch]$RequireTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info([string]$msg) { Write-Host $msg -ForegroundColor Gray }
function Write-Warn([string]$msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Ok([string]$msg)   { Write-Host $msg -ForegroundColor Green }
function Write-Cyan([string]$msg) { Write-Host $msg -ForegroundColor Cyan }

function Get-RepoRoot {
    if ($RepoRoot -and $RepoRoot.Trim()) {
        return (Resolve-Path -LiteralPath $RepoRoot).Path
    }
    return (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
}

function Get-ConfigRoot([string]$root) {
    return (Join-Path $root "config")
}

function Get-ProfilePath([string]$root) {
    return (Join-Path (Get-ConfigRoot $root) "hardware-profile.json")
}

function Resolve-ToolPath {
    param(
        [string]$RepoRoot,
        [string]$RelativePath
    )
    $p = Join-Path $RepoRoot $RelativePath
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Get-HandBrakeHelpText {
    param([string]$HandBrakePath)

    if (-not $HandBrakePath -or -not (Test-Path -LiteralPath $HandBrakePath)) {
        return ""
    }

    try {
        return (& $HandBrakePath --help 2>&1 | Out-String)
    } catch {
        return ""
    }
}

function Test-EncoderAvailable {
    param(
        [string]$HelpText,
        [string]$EncoderName
    )
    if (-not $HelpText) { return $false }
    return ($HelpText -match [regex]::Escape($EncoderName))
}

function Get-GpuSummary {
    $gpus = @()

    try {
        $videoControllers = Get-CimInstance Win32_VideoController -ErrorAction Stop
        foreach ($gpu in $videoControllers) {
            $gpus += [pscustomobject]@{
                Name           = [string]$gpu.Name
                AdapterRAMGB   = if ($gpu.AdapterRAM) { [math]::Round(([double]$gpu.AdapterRAM / 1GB), 2) } else { $null }
                DriverVersion  = [string]$gpu.DriverVersion
                VideoProcessor = [string]$gpu.VideoProcessor
            }
        }
    } catch {}

    return $gpus
}

function Get-CpuSummary {
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{
            Name            = [string]$cpu.Name
            Cores           = [int]$cpu.NumberOfCores
            Logical         = [int]$cpu.NumberOfLogicalProcessors
            MaxClockMHz     = [int]$cpu.MaxClockSpeed
        }
    } catch {
        return [pscustomobject]@{
            Name        = ""
            Cores       = 0
            Logical     = 0
            MaxClockMHz = 0
        }
    }
}

function Get-MemorySummary {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        return [pscustomobject]@{
            TotalMemoryGB = [math]::Round(([double]$cs.TotalPhysicalMemory / 1GB), 2)
        }
    } catch {
        return [pscustomobject]@{
            TotalMemoryGB = 0
        }
    }
}

function Get-Recommendations {
    param(
        [pscustomobject]$Cpu,
        [object[]]$Gpus,
        [bool]$HasNvenc,
        [bool]$HasVce,
        [bool]$HasX264
    )

    $encoderMode = "X264"
    if ($HasNvenc) { $encoderMode = "NVENC" }
    elseif ($HasVce) { $encoderMode = "AMDVCE" }
    elseif ($HasX264) { $encoderMode = "X264" }

    $concurrency = 1
    if ($encoderMode -in @("NVENC","AMDVCE")) {
        if ($Cpu.Logical -ge 16) { $concurrency = 3 }
        elseif ($Cpu.Logical -ge 8) { $concurrency = 2 }
        else { $concurrency = 1 }
    } else {
        if ($Cpu.Logical -ge 16) { $concurrency = 2 }
        else { $concurrency = 1 }
    }

    return [pscustomobject]@{
        PreferredEncoderMode = $encoderMode
        RecommendedConcurrentJobs = $concurrency
        RecommendedQualityTV = 23
        RecommendedQualityMovies = 23
        RecommendedAudioBitrateKbps = 160
    }
}

$root = Get-RepoRoot
$configRoot = Get-ConfigRoot $root
$profilePath = Get-ProfilePath $root

if (-not (Test-Path -LiteralPath $configRoot)) {
    New-Item -Path $configRoot -ItemType Directory | Out-Null
}

$handBrakePath = Resolve-ToolPath -RepoRoot $root -RelativePath "tools\handbrake\HandBrakeCLI.exe"
$ffmpegPath    = Resolve-ToolPath -RepoRoot $root -RelativePath "tools\ffmpeg\bin\ffmpeg.exe"
$ffprobePath   = Resolve-ToolPath -RepoRoot $root -RelativePath "tools\ffmpeg\bin\ffprobe.exe"
$fileBotCmd    = Resolve-ToolPath -RepoRoot $root -RelativePath "tools\filebot\filebot.cmd"
$fileBotExe    = Resolve-ToolPath -RepoRoot $root -RelativePath "tools\filebot\FileBot.exe"

if ($RequireTools) {
    $missing = @()
    if (-not $handBrakePath) { $missing += "HandBrakeCLI" }
    if (-not $ffmpegPath)    { $missing += "ffmpeg" }
    if (-not $ffprobePath)   { $missing += "ffprobe" }

    if ($missing.Count -gt 0) {
        throw ("Missing required tools: " + ($missing -join ", ") + ". Run dependency setup first.")
    }
}

Write-Cyan "Building hardware profile..."
Write-Info ("Repo Root   : " + $root)
Write-Info ("Profile Path: " + $profilePath)

$hbHelp = Get-HandBrakeHelpText -HandBrakePath $handBrakePath

$hasNvenc = Test-EncoderAvailable -HelpText $hbHelp -EncoderName "nvenc_h264"
$hasVce   = Test-EncoderAvailable -HelpText $hbHelp -EncoderName "vce_h264"
$hasX264  = Test-EncoderAvailable -HelpText $hbHelp -EncoderName "x264"

$cpu = Get-CpuSummary
$mem = Get-MemorySummary
$gpus = Get-GpuSummary
$rec = Get-Recommendations -Cpu $cpu -Gpus $gpus -HasNvenc $hasNvenc -HasVce $hasVce -HasX264 $hasX264

$profile = [pscustomobject]@{
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    ComputerName   = $env:COMPUTERNAME
    RepoRoot       = $root

    Tools = [pscustomobject]@{
        HandBrakeCli = $handBrakePath
        Ffmpeg       = $ffmpegPath
        Ffprobe      = $ffprobePath
        FileBot      = $(if ($fileBotCmd) { $fileBotCmd } else { $fileBotExe })
    }

    Hardware = [pscustomobject]@{
        Cpu    = $cpu
        Memory = $mem
        Gpus   = $gpus
    }

    Encoders = [pscustomobject]@{
        NvencH264 = $hasNvenc
        VceH264   = $hasVce
        X264      = $hasX264
    }

    Recommendations = $rec
}

$profile | ConvertTo-Json -Depth 8 | Out-File -FilePath $profilePath -Encoding UTF8 -Force

Write-Ok "Hardware profile written successfully."
Write-Info ("Preferred Encoder Mode      : " + $profile.Recommendations.PreferredEncoderMode)
Write-Info ("Recommended ConcurrentJobs  : " + $profile.Recommendations.RecommendedConcurrentJobs)
Write-Info ("Detected GPUs               : " + $(if ($gpus.Count -gt 0) { $gpus.Count } else { 0 }))