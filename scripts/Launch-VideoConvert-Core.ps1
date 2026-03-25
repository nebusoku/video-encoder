[CmdletBinding()]
param(
    [ValidateSet("TV","MOVIES")]
    [string]$Mode,

    [string]$RootPath = "",

    [switch]$EnableFileBotRename,
    [switch]$FileBotTestRun,
    [switch]$BackupOriginal,
    [switch]$DryRun,

    [double]$MaxTotalInputGB = 0,

    [ValidateRange(1,16)]
    [int]$ConcurrentJobs = 2,

    [ValidateSet("Auto","NVENC","AMDVCE","X264")]
    [string]$EncoderMode = "Auto",

    [ValidateRange(16,30)]
    [int]$Quality = 23,

    [ValidateRange(96,320)]
    [int]$AudioBitrateKbps = 160
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-LaunchInfo([string]$Message) {
    Write-Host $Message -ForegroundColor Cyan
}

function Get-RepoRoot {
    return (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
}

function Get-ProfilePath([string]$RepoRoot) {
    return (Join-Path $RepoRoot "config\hardware-profile.json")
}

function Assert-ProfilePresent([string]$RepoRoot) {
    $profilePath = Get-ProfilePath $RepoRoot
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Hardware profile not found: $profilePath. Run the hardware test first."
    }
}

function Resolve-TargetScript([string]$ModeValue) {
    switch ($ModeValue.ToUpperInvariant()) {
        "TV"     { return (Join-Path $PSScriptRoot "Start-TV.ps1") }
        "MOVIES" { return (Join-Path $PSScriptRoot "Start-Movies.ps1") }
        default  { throw "Unsupported mode: $ModeValue" }
    }
}

if (-not $Mode -or -not $Mode.Trim()) {
    throw "Mode is required. Use TV or MOVIES."
}

$RepoRoot = Get-RepoRoot
Assert-ProfilePresent -RepoRoot $RepoRoot

$targetScript = Resolve-TargetScript -ModeValue $Mode
if (-not (Test-Path -LiteralPath $targetScript)) {
    throw "Target script not found: $targetScript"
}

Write-LaunchInfo "Launching mode: $Mode"
if ($RootPath -and $RootPath.Trim()) {
    Write-LaunchInfo "RootPath: $RootPath"
}

$invokeArgs = @{
    EnableFileBotRename = [bool]$EnableFileBotRename
    FileBotTestRun      = [bool]$FileBotTestRun
    BackupOriginal      = [bool]$BackupOriginal
    DryRun              = [bool]$DryRun
    MaxTotalInputGB     = [double]$MaxTotalInputGB
    ConcurrentJobs      = [int]$ConcurrentJobs
    EncoderMode         = [string]$EncoderMode
    Quality             = [int]$Quality
    AudioBitrateKbps    = [int]$AudioBitrateKbps
}

if ($RootPath -and $RootPath.Trim()) {
    $invokeArgs.RootPath = $RootPath
}

& $targetScript @invokeArgs