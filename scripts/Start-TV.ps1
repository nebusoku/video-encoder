[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RootPath,
    [switch]$EnableFileBotRename,
    [switch]$EnsureDependencies,
    [switch]$RefreshDependencies,
    [switch]$ProbeHardwareOnly,
    [switch]$RefreshHardwareCache
)

$entry = Join-Path (Split-Path -Parent $PSScriptRoot) "video-convert.ps1"
& $entry -RootPath $RootPath -Mode 1 -EnableFileBotRename:$EnableFileBotRename -EnsureDependencies:$EnsureDependencies -RefreshDependencies:$RefreshDependencies -ProbeHardwareOnly:$ProbeHardwareOnly -RefreshHardwareCache:$RefreshHardwareCache
