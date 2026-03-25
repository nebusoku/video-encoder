[CmdletBinding()]
param(
    [string]$RootPath = "",
    [switch]$EnableFileBotRename,
    [switch]$FileBotTestRun,
    [switch]$BackupOriginal,
    [switch]$DryRun,
    [double]$MaxTotalInputGB = 0,
    [int]$ConcurrentJobs = 2,
    [ValidateSet("Auto","NVENC","AMDVCE","X264")]
    [string]$EncoderMode = "Auto",
    [int]$Quality = 23,
    [int]$AudioBitrateKbps = 160
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $RootPath -or $RootPath.Trim() -eq "") {
    $RootPath = Read-Host "Enter TV root path"
}

if (-not (Test-Path -LiteralPath $RootPath)) {
    throw "TV root path not found: $RootPath"
}

$invoke = Join-Path $PSScriptRoot "Invoke-VideoConvert.ps1"
if (-not (Test-Path -LiteralPath $invoke)) {
    throw "Missing script: $invoke"
}

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