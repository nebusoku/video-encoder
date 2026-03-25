<#
Menu-Core.ps1 (PowerShell 5.1 compatible)
Central controller for menu + decision tree.

Responsibilities:
- Show menu
- Show current readiness status
- Enforce prerequisites
- Dispatch to action scripts
- Reserve clean menu slots for future pipeline/DVD work
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info([string]$msg) { Write-Host $msg -ForegroundColor Gray }
function Write-Warn([string]$msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err ([string]$msg) { Write-Host $msg -ForegroundColor Red }
function Write-Ok  ([string]$msg) { Write-Host $msg -ForegroundColor Green }
function Write-Cyan([string]$msg) { Write-Host $msg -ForegroundColor Cyan }

function Pause-Menu([string]$msg = "Press Enter to return to menu") {
    Write-Host ""
    [void](Read-Host $msg)
}

function Get-RepoRoot {
    # scripts\Menu-Core.ps1 -> repo root is parent of scripts\
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    return (Resolve-Path -LiteralPath (Split-Path -Parent $scriptDir)).Path
}

function Get-ToolsRoot([string]$repoRoot) {
    return (Join-Path $repoRoot "tools")
}

function Get-ConfigRoot([string]$repoRoot) {
    return (Join-Path $repoRoot "config")
}

function Get-ProfilePath([string]$repoRoot) {
    return (Join-Path (Get-ConfigRoot $repoRoot) "hardware-profile.json")
}

function Get-FileBotPath([string]$repoRoot) {
    $toolsRoot = Get-ToolsRoot $repoRoot

    $cmd = Join-Path $toolsRoot "filebot\filebot.cmd"
    if (Test-Path -LiteralPath $cmd) { return $cmd }

    $exe = Join-Path $toolsRoot "filebot\FileBot.exe"
    if (Test-Path -LiteralPath $exe) { return $exe }

    return $null
}

function Get-ToolStatus {
    param([string]$repoRoot)

    $toolsRoot = Get-ToolsRoot $repoRoot

    $handBrake = Join-Path $toolsRoot "handbrake\HandBrakeCLI.exe"
    $ffmpeg    = Join-Path $toolsRoot "ffmpeg\bin\ffmpeg.exe"
    $ffprobe   = Join-Path $toolsRoot "ffmpeg\bin\ffprobe.exe"
    $fileBot   = Get-FileBotPath $repoRoot

    return [pscustomobject]@{
        HandBrakePath    = $handBrake
        FfmpegPath       = $ffmpeg
        FfprobePath      = $ffprobe
        FileBotPath      = $fileBot
        HasHandBrake     = (Test-Path -LiteralPath $handBrake)
        HasFfmpeg        = (Test-Path -LiteralPath $ffmpeg)
        HasFfprobe       = (Test-Path -LiteralPath $ffprobe)
        HasFileBot       = [bool]$fileBot
        HasCoreTools     = (
            (Test-Path -LiteralPath $handBrake) -and
            (Test-Path -LiteralPath $ffmpeg) -and
            (Test-Path -LiteralPath $ffprobe)
        )
    }
}

function Assert-ToolsPresent {
    param([string]$repoRoot)

    $status = Get-ToolStatus $repoRoot
    $missing = @()

    if (-not $status.HasHandBrake) { $missing += "HandBrakeCLI" }
    if (-not $status.HasFfmpeg)    { $missing += "FFmpeg" }
    if (-not $status.HasFfprobe)   { $missing += "FFprobe" }

    if ($missing.Count -gt 0) {
        throw ("Missing required tools: " + ($missing -join ", ") + ". Run option 1 first.")
    }
}

function Assert-ProfilePresent {
    param([string]$repoRoot)

    $profile = Get-ProfilePath $repoRoot
    if (-not (Test-Path -LiteralPath $profile)) {
        throw ("Hardware profile not found: " + $profile + ". Run option 2 first.")
    }
}

function Resolve-ActionScriptPath {
    param(
        [string]$repoRoot,
        [string]$relativePath
    )

    $scriptPath = Join-Path $repoRoot $relativePath
    if (Test-Path -LiteralPath $scriptPath) {
        return $scriptPath
    }

    return $null
}

function Invoke-ActionScript {
    param(
        [string]$repoRoot,
        [string]$relativePath,
        [hashtable]$args = @{}
    )

    $scriptPath = Resolve-ActionScriptPath -repoRoot $repoRoot -relativePath $relativePath
    if (-not $scriptPath) {
        throw "Missing script: $relativePath"
    }

    & $scriptPath @args

    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Warn ("Action returned exit code: " + $LASTEXITCODE)
    }
}

function Invoke-OptionalActionScript {
    param(
        [string]$repoRoot,
        [string]$relativePath,
        [hashtable]$args = @{},
        [string]$NotReadyMessage = "This menu option is not wired yet in this build."
    )

    $scriptPath = Resolve-ActionScriptPath -repoRoot $repoRoot -relativePath $relativePath
    if (-not $scriptPath) {
        Write-Warn $NotReadyMessage
        return
    }

    & $scriptPath @args

    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Warn ("Action returned exit code: " + $LASTEXITCODE)
    }
}

function Get-ReadinessSummary {
    param([string]$repoRoot)

    $toolStatus = Get-ToolStatus $repoRoot
    $profilePath = Get-ProfilePath $repoRoot

    return [pscustomobject]@{
        ToolsReady     = $toolStatus.HasCoreTools
        ProfileReady   = (Test-Path -LiteralPath $profilePath)
        FileBotReady   = $toolStatus.HasFileBot
        ProfilePath    = $profilePath
        ToolStatus     = $toolStatus
    }
}

function Show-Header {
    param([string]$repoRoot)

    $summary = Get-ReadinessSummary $repoRoot

    Clear-Host
    Write-Cyan "========================================"
    Write-Cyan " Portable Video Encoder"
    Write-Cyan "========================================"
    Write-Host ""

    Write-Host "Repo Root :" -NoNewline
    Write-Host (" " + $repoRoot) -ForegroundColor DarkGray

    Write-Host "Core Tools:" -NoNewline
    if ($summary.ToolsReady) { Write-Host " Ready" -ForegroundColor Green }
    else { Write-Host " Missing" -ForegroundColor Yellow }

    Write-Host "Hardware :" -NoNewline
    if ($summary.ProfileReady) { Write-Host " Profile Present" -ForegroundColor Green }
    else { Write-Host " Profile Missing" -ForegroundColor Yellow }

    Write-Host "FileBot  :" -NoNewline
    if ($summary.FileBotReady) { Write-Host " Detected" -ForegroundColor Green }
    else { Write-Host " Not Found (optional today)" -ForegroundColor DarkYellow }

    Write-Host ""
}

function Show-Menu {
    Write-Cyan "Select action:"
    Write-Host "  1) Download / Update Tools"
    Write-Host "  2) Hardware Test (build / update machine hardware profile)"
    Write-Host "  3) Encode TV Shows"
    Write-Host "  4) Encode Movies"
    Write-Host "  5) DVD Movie Disc / Import"
    Write-Host "  6) DVD TV Disc / Import"
    Write-Host "  7) FileBot Rename / Staging"
    Write-Host "  8) Open Repo Root"
    Write-Host "  9) Open Tools Folder"
    Write-Host "  0) Exit"
    Write-Host ""
}

function Open-FolderIfExists {
    param([string]$path)

    if (-not (Test-Path -LiteralPath $path)) {
        throw ("Path not found: " + $path)
    }

    Start-Process explorer.exe -ArgumentList "`"$path`"" | Out-Null
}

$repoRoot = Get-RepoRoot

while ($true) {
    Show-Header -repoRoot $repoRoot
    Show-Menu

    $choice = Read-Host "Enter 0, 1, 2, 3, 4, 5, 6, 7, 8, or 9"

    try {
        switch ($choice) {
            "0" {
                return
            }

            "1" {
                Invoke-ActionScript -repoRoot $repoRoot -relativePath "scripts\Ensure-Dependencies-Core.ps1" -args @{}
                Write-Ok "Tools are ready."
                Pause-Menu
            }

            "2" {
                Assert-ToolsPresent -repoRoot $repoRoot
                Invoke-ActionScript -repoRoot $repoRoot -relativePath "scripts\Probe-HardwareProfile.ps1" -args @{
                    RepoRoot     = $repoRoot
                    RequireTools = $true
                }
                Write-Ok "Hardware profile updated."
                Pause-Menu
            }

            "3" {
                Assert-ToolsPresent -repoRoot $repoRoot
                Assert-ProfilePresent -repoRoot $repoRoot
                Invoke-ActionScript -repoRoot $repoRoot -relativePath "scripts\Start-TV.ps1" -args @{}
                Pause-Menu
            }

            "4" {
                Assert-ToolsPresent -repoRoot $repoRoot
                Assert-ProfilePresent -repoRoot $repoRoot
                Invoke-ActionScript -repoRoot $repoRoot -relativePath "scripts\Start-Movies.ps1" -args @{}
                Pause-Menu
            }

            "5" {
                Assert-ToolsPresent -repoRoot $repoRoot
                Assert-ProfilePresent -repoRoot $repoRoot
                Invoke-OptionalActionScript -repoRoot $repoRoot `
                    -relativePath "scripts\Start-DVD-Movies.ps1" `
                    -args @{} `
                    -NotReadyMessage "DVD Movie import is not wired yet. Add scripts\Start-DVD-Movies.ps1 when ready."
                Pause-Menu
            }

            "6" {
                Assert-ToolsPresent -repoRoot $repoRoot
                Assert-ProfilePresent -repoRoot $repoRoot
                Invoke-OptionalActionScript -repoRoot $repoRoot `
                    -relativePath "scripts\Start-DVD-TV.ps1" `
                    -args @{} `
                    -NotReadyMessage "DVD TV import is not wired yet. Add scripts\Start-DVD-TV.ps1 when ready."
                Pause-Menu
            }

            "7" {
                Assert-ToolsPresent -repoRoot $repoRoot
                Invoke-OptionalActionScript -repoRoot $repoRoot `
                    -relativePath "scripts\Start-FileBot-Rename.ps1" `
                    -args @{} `
                    -NotReadyMessage "Standalone FileBot rename is not wired yet. Add scripts\Start-FileBot-Rename.ps1 when ready."
                Pause-Menu
            }

            "8" {
                Open-FolderIfExists -path $repoRoot
                Pause-Menu
            }

            "9" {
                Open-FolderIfExists -path (Get-ToolsRoot $repoRoot)
                Pause-Menu
            }

            default {
                Write-Warn "Invalid selection."
                Pause-Menu
            }
        }
    }
    catch {
        Write-Err $_.Exception.Message
        Pause-Menu
    }
}