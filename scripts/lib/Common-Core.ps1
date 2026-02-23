<#
scripts\lib\Common-Core.ps1  (PowerShell 5.1 compatible)

Shared functions for:
- Logging
- Path resolution (RepoRoot, ToolsRoot, Config)
- Prereq checks (tools/profile present)
- Native process capture
- Safe directory helpers

Usage (from any script under scripts\):
. "$PSScriptRoot\lib\Common-Core.ps1"

Usage (from repo root video-convert.ps1):
. "$PSScriptRoot\scripts\lib\Common-Core.ps1"
#>

Set-StrictMode -Version Latest

# ---------------------------------------
# Logging
# ---------------------------------------
function Write-Info { param([string]$Msg) Write-Host ("[info] " + $Msg) -ForegroundColor Gray }
function Write-Ok   { param([string]$Msg) Write-Host ("[ ok ] " + $Msg) -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host ("[warn] " + $Msg) -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host ("[err ] " + $Msg) -ForegroundColor Red }

function Pause-Menu {
    param([string]$Msg = "Press Enter to return to menu")
    Write-Host ""
    [void](Read-Host $Msg)
}

# ---------------------------------------
# Paths
# ---------------------------------------
function Get-ScriptPath {
    # Works inside dot-sourced contexts
    if ($MyInvocation.MyCommand.Path) { return $MyInvocation.MyCommand.Path }
    return $PSCommandPath
}

function Get-RepoRootFromScripts {
    # Assumes this file lives at: <repo>\scripts\lib\Common-Core.ps1
    $thisPath = Get-ScriptPath
    $libDir   = Split-Path -Parent $thisPath
    $scripts  = Split-Path -Parent $libDir
    return (Resolve-Path -LiteralPath (Split-Path -Parent $scripts)).Path
}

function Get-ToolsRoot {
    param([string]$RepoRoot)
    return (Join-Path $RepoRoot "tools")
}

function Get-ConfigDir {
    param([string]$RepoRoot)
    return (Join-Path $RepoRoot "config")
}

function Get-HardwareProfilePath {
    param([string]$RepoRoot)
    return (Join-Path (Get-ConfigDir -RepoRoot $RepoRoot) "hardware-profile.json")
}

# Canonical tool paths (so every script agrees)
function Get-HandBrakeCliPath {
    param([string]$ToolsRoot)
    return (Join-Path (Join-Path $ToolsRoot "handbrake") "HandBrakeCLI.exe")
}
function Get-FfmpegPath {
    param([string]$ToolsRoot)
    return (Join-Path (Join-Path (Join-Path $ToolsRoot "ffmpeg") "bin") "ffmpeg.exe")
}
function Get-FfprobePath {
    param([string]$ToolsRoot)
    return (Join-Path (Join-Path (Join-Path $ToolsRoot "ffmpeg") "bin") "ffprobe.exe")
}
function Get-FileBotPath {
    param([string]$ToolsRoot)
    return (Join-Path (Join-Path $ToolsRoot "filebot") "filebot.exe")
}

# ---------------------------------------
# Filesystem helpers
# ---------------------------------------
function Ensure-Directory {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# ---------------------------------------
# Prereq assertions (NO auto-bootstrap)
# ---------------------------------------
function Assert-ToolsPresent {
    param(
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [switch]$IncludeFileBot
    )

    $toolsRoot = Get-ToolsRoot -RepoRoot $RepoRoot

    $hb = Get-HandBrakeCliPath -ToolsRoot $toolsRoot
    $ff = Get-FfmpegPath -ToolsRoot $toolsRoot
    $fp = Get-FfprobePath -ToolsRoot $toolsRoot

    $missing = @()
    if (-not (Test-Path -LiteralPath $hb)) { $missing += "HandBrakeCLI" }
    if (-not (Test-Path -LiteralPath $ff)) { $missing += "FFmpeg" }
    if (-not (Test-Path -LiteralPath $fp)) { $missing += "FFprobe" }

    if ($IncludeFileBot) {
        $fb = Get-FileBotPath -ToolsRoot $toolsRoot
        if (-not (Test-Path -LiteralPath $fb)) { $missing += "FileBot" }
    }

    if ($missing.Count -gt 0) {
        throw ("Missing required tools: " + ($missing -join ", ") + ". Run option 1 (Download / Update Tools) first.")
    }
}

function Assert-HardwareProfilePresent {
    param([Parameter(Mandatory=$true)][string]$RepoRoot)

    $p = Get-HardwareProfilePath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $p)) {
        throw ("Hardware profile not found: $p. Run option 2 (Hardware Test) first.")
    }
}

# ---------------------------------------
# Native exec capture (PS 5.1 safe)
# ---------------------------------------
function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Args,
        [int]$TimeoutSeconds = 0
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Executable not found: $FilePath"
    }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName = $FilePath
    $p.StartInfo.Arguments = ($Args -join " ")
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError  = $true
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true

    [void]$p.Start()

    if ($TimeoutSeconds -gt 0) {
        $exited = $p.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try { $p.Kill() } catch {}
            throw "Process timeout after $TimeoutSeconds seconds: $FilePath $($Args -join ' ')"
        }
    } else {
        $p.WaitForExit()
    }

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()

    [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Text     = ($stdout + "`n" + $stderr).Trim()
        FilePath = $FilePath
        Args     = $Args
    }
}