[CmdletBinding()]
param(
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

$commonCore = Join-Path $PSScriptRoot "lib\Common-Core.ps1"
if (-not (Test-Path -LiteralPath $commonCore)) {
    throw "Missing shared library: $commonCore"
}
. $commonCore

function Read-NonEmptyValue([string]$Prompt) {
    while ($true) {
        $v = Read-Host $Prompt
        if ($v -and $v.Trim()) { return $v.Trim() }
    }
}

$repoRoot = Get-RepoRoot
Assert-CoreToolsPresent -RepoRoot $repoRoot | Out-Null
Assert-HardwareProfilePresent -RepoRoot $repoRoot | Out-Null

if (-not $RootPath -or $RootPath.Trim() -eq "") {
    $RootPath = Read-NonEmptyValue "Enter TV root path"
}

if (-not (Test-Path -LiteralPath $RootPath)) {
    throw "TV root path not found: $RootPath"
}

$invoke = Join-Path $PSScriptRoot "Invoke-VideoConvert.ps1"
if (-not (Test-Path -LiteralPath $invoke)) {
    throw "Missing script: $invoke"
}

Write-ConsoleCyan "Starting TV conversion..."
Write-ConsoleInfo ("RootPath             : " + $RootPath)
Write-ConsoleInfo ("EnableFileBotRename  : " + $EnableFileBotRename)
Write-ConsoleInfo ("FileBotTestRun       : " + $FileBotTestRun)
Write-ConsoleInfo ("BackupOriginal       : " + $BackupOriginal)
Write-ConsoleInfo ("DryRun               : " + $DryRun)
Write-ConsoleInfo ("MaxTotalInputGB      : " + $MaxTotalInputGB)
Write-ConsoleInfo ("ConcurrentJobs       : " + $ConcurrentJobs)
Write-ConsoleInfo ("EncoderMode          : " + $EncoderMode)
Write-ConsoleInfo ("Quality              : " + $Quality)
Write-ConsoleInfo ("AudioBitrateKbps     : " + $AudioBitrateKbps)
Write-Host ""

& $invoke `
    -RootPath $RootPath `
    -Mode "TV" `
    -EnableFileBotRename:$EnableFileBotRename `
    -FileBotTestRun:$FileBotTestRun `
    -BackupOriginal:$BackupOriginal `
    -DryRun:$DryRun `
    -MaxTotalInputGB $MaxTotalInputGB `
    -ConcurrentJobs $ConcurrentJobs `
    -EncoderMode $EncoderMode `
    -Quality $Quality `
    -AudioBitrateKbps $AudioBitrateKbps