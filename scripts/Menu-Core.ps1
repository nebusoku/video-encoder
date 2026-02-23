<#
Menu-Core.ps1 (PowerShell 5.1 compatible)
Central controller for menu + decision tree.

Responsibilities:
- Show menu
- Enforce prerequisites
- Dispatch to action scripts
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info([string]$msg) { Write-Host $msg -ForegroundColor Gray }
function Write-Warn([string]$msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err ([string]$msg) { Write-Host $msg -ForegroundColor Red }
function Write-Ok  ([string]$msg) { Write-Host $msg -ForegroundColor Green }

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

function Get-ProfilePath([string]$repoRoot) {
    return (Join-Path (Join-Path $repoRoot "config") "hardware-profile.json")
}

function Assert-ToolsPresent {
    param([string]$repoRoot)

    $toolsRoot = Get-ToolsRoot $repoRoot

    $handBrake = Join-Path $toolsRoot "handbrake\HandBrakeCLI.exe"
    $ffmpeg    = Join-Path $toolsRoot "ffmpeg\bin\ffmpeg.exe"
    $ffprobe   = Join-Path $toolsRoot "ffmpeg\bin\ffprobe.exe"

    $missing = @()
    if (-not (Test-Path -LiteralPath $handBrake)) { $missing += "HandBrakeCLI" }
    if (-not (Test-Path -LiteralPath $ffmpeg))    { $missing += "FFmpeg" }
    if (-not (Test-Path -LiteralPath $ffprobe))   { $missing += "FFprobe" }

    if ($missing.Count -gt 0) {
        throw ("Missing required tools: " + ($missing -join ", ") + ". Run option 1 first.")
    }
}

function Assert-ProfilePresent {
    param([string]$repoRoot)

    $profile = Get-ProfilePath $repoRoot
    if (-not (Test-Path -LiteralPath $profile)) {
        throw ("Hardware profile not found: $profile. Run option 2 first.")
    }
}

function Invoke-ActionScript {
    param(
        [string]$repoRoot,
        [string]$relativePath,
        [hashtable]$args = @{}
    )

    $scriptPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Missing script: $scriptPath"
    }

    & $scriptPath @args
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        Write-Warn "Action returned exit code: $LASTEXITCODE"
    }
}

$repoRoot = Get-RepoRoot
$scriptDir = Join-Path $repoRoot "scripts"

while ($true) {
    Clear-Host
    Write-Host "Select action:" -ForegroundColor Cyan
    Write-Host "  1) Download / Update Tools"
    Write-Host "  2) Hardware Test (build/update machine hardware profile)"
    Write-Host "  3) Encode TV Shows"
    Write-Host "  4) Encode Movies"
    Write-Host "  0) Exit"
    Write-Host ""

    $choice = Read-Host "Enter 0, 1, 2, 3, or 4"

    try {
        switch ($choice) {
            "0" { return }

            "1" {
                Invoke-ActionScript -repoRoot $repoRoot -relativePath "scripts\Ensure-Dependencies-Core.ps1" -args @{}
                Write-Ok "Tools are ready."
                Pause-Menu
            }

            "2" {
                Assert-ToolsPresent -repoRoot $repoRoot
                Invoke-ActionScript -repoRoot $repoRoot -relativePath "scripts\Probe-HardwareProfile.ps1" -args @{ RepoRoot = $repoRoot; RequireTools = $true }
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