Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    if ($PSScriptRoot) {
        return (Resolve-Path -LiteralPath (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).Path
    }
    return (Resolve-Path -LiteralPath (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))).Path
}

function Get-ToolsRoot {
    param([string]$RepoRoot = "")
    if (-not $RepoRoot -or -not $RepoRoot.Trim()) {
        $RepoRoot = Get-RepoRoot
    }
    return (Join-Path $RepoRoot "tools")
}

function Get-ConfigRoot {
    param([string]$RepoRoot = "")
    if (-not $RepoRoot -or -not $RepoRoot.Trim()) {
        $RepoRoot = Get-RepoRoot
    }
    return (Join-Path $RepoRoot "config")
}

function Get-LogsRoot {
    param([string]$RepoRoot = "")
    if (-not $RepoRoot -or -not $RepoRoot.Trim()) {
        $RepoRoot = Get-RepoRoot
    }
    return (Join-Path $RepoRoot "Logs")
}

function Get-ConvertedRoot {
    param([string]$RepoRoot = "")
    if (-not $RepoRoot -or -not $RepoRoot.Trim()) {
        $RepoRoot = Get-RepoRoot
    }
    return (Join-Path $RepoRoot "Converted")
}

function Get-FailedRoot {
    param([string]$RepoRoot = "")
    if (-not $RepoRoot -or -not $RepoRoot.Trim()) {
        $RepoRoot = Get-RepoRoot
    }
    return (Join-Path $RepoRoot "Failed")
}

function Get-HardwareProfilePath {
    param([string]$RepoRoot = "")
    if (-not $RepoRoot -or -not $RepoRoot.Trim()) {
        $RepoRoot = Get-RepoRoot
    }
    return (Join-Path (Get-ConfigRoot -RepoRoot $RepoRoot) "hardware-profile.json")
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-ProjectToolPath {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$Fallback = "",
        [string]$RepoRoot = ""
    )

    if (-not $RepoRoot -or -not $RepoRoot.Trim()) {
        $RepoRoot = Get-RepoRoot
    }

    $candidate = Join-Path $RepoRoot $RelativePath
    if (Test-Path -LiteralPath $candidate) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    if ($Fallback -and $Fallback.Trim() -and (Test-Path -LiteralPath $Fallback)) {
        return (Resolve-Path -LiteralPath $Fallback).Path
    }

    return $null
}

function Get-PortableToolPaths {
    param([string]$RepoRoot = "")

    if (-not $RepoRoot -or -not $RepoRoot.Trim()) {
        $RepoRoot = Get-RepoRoot
    }

    $fileBotCmd = Resolve-ProjectToolPath -RepoRoot $RepoRoot -RelativePath "tools\filebot\filebot.cmd"
    $fileBotExe = Resolve-ProjectToolPath -RepoRoot $RepoRoot -RelativePath "tools\filebot\FileBot.exe"

    [pscustomobject]@{
        RepoRoot     = $RepoRoot
        ToolsRoot    = Get-ToolsRoot -RepoRoot $RepoRoot
        Ffmpeg       = Resolve-ProjectToolPath -RepoRoot $RepoRoot -RelativePath "tools\ffmpeg\bin\ffmpeg.exe"
        Ffprobe      = Resolve-ProjectToolPath -RepoRoot $RepoRoot -RelativePath "tools\ffmpeg\bin\ffprobe.exe"
        HandBrakeCli = Resolve-ProjectToolPath -RepoRoot $RepoRoot -RelativePath "tools\handbrake\HandBrakeCLI.exe"
        FileBot      = $(if ($fileBotCmd) { $fileBotCmd } else { $fileBotExe })
        FileBotCmd   = $fileBotCmd
        FileBotExe   = $fileBotExe
    }
}

function Test-CoreToolsPresent {
    param([string]$RepoRoot = "")

    $tools = Get-PortableToolPaths -RepoRoot $RepoRoot
    return [pscustomobject]@{
        HasFfmpeg    = [bool]$tools.Ffmpeg
        HasFfprobe   = [bool]$tools.Ffprobe
        HasHandBrake = [bool]$tools.HandBrakeCli
        HasFileBot   = [bool]$tools.FileBot
        HasCoreTools = ([bool]$tools.Ffmpeg -and [bool]$tools.Ffprobe -and [bool]$tools.HandBrakeCli)
        Tools        = $tools
    }
}

function Assert-CoreToolsPresent {
    param([string]$RepoRoot = "")

    $status = Test-CoreToolsPresent -RepoRoot $RepoRoot
    $missing = @()

    if (-not $status.HasFfmpeg)    { $missing += "ffmpeg" }
    if (-not $status.HasFfprobe)   { $missing += "ffprobe" }
    if (-not $status.HasHandBrake) { $missing += "HandBrakeCLI" }

    if ($missing.Count -gt 0) {
        throw ("Missing core tools: " + ($missing -join ", "))
    }

    return $status
}

function Assert-HardwareProfilePresent {
    param([string]$RepoRoot = "")

    $profilePath = Get-HardwareProfilePath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Hardware profile not found: $profilePath"
    }

    return $profilePath
}

function Read-HardwareProfile {
    param([string]$RepoRoot = "")

    $profilePath = Assert-HardwareProfilePresent -RepoRoot $RepoRoot
    return (Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json)
}

function New-RunStamp {
    return (Get-Date -Format "yyyyMMdd-HHmmss")
}

function New-RunLogPath {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [string]$RepoRoot = ""
    )

    if (-not $RepoRoot -or -not $RepoRoot.Trim()) {
        $RepoRoot = Get-RepoRoot
    }

    $logsRoot = Ensure-Directory -Path (Get-LogsRoot -RepoRoot $RepoRoot)
    return (Join-Path $logsRoot ("{0}-{1}.log" -f $Prefix, (New-RunStamp)))
}

function New-FailedCsvPath {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [string]$RepoRoot = ""
    )

    if (-not $RepoRoot -or -not $RepoRoot.Trim()) {
        $RepoRoot = Get-RepoRoot
    }

    $failedRoot = Ensure-Directory -Path (Get-FailedRoot -RepoRoot $RepoRoot)
    return (Join-Path $failedRoot ("{0}-{1}.csv" -f $Prefix, (New-RunStamp)))
}

function Write-ConsoleInfo([string]$Message) { Write-Host $Message -ForegroundColor Gray }
function Write-ConsoleWarn([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-ConsoleError([string]$Message) { Write-Host $Message -ForegroundColor Red }
function Write-ConsoleOk([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-ConsoleCyan([string]$Message) { Write-Host $Message -ForegroundColor Cyan }