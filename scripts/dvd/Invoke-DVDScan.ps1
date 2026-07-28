<#
Invoke-DVDScan.ps1
Scans a DVD source (.iso, .img, or VIDEO_TS folder) and returns its titles.

STATUS: stub / not yet implemented. Tracked in GitHub issue #24.
Today the DVD flow is handled end-to-end by scripts\Start-DVD-TV.ps1 and
scripts\Start-DVD-Movies.ps1; this helper is where that scan logic should be
factored out to.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

throw "Invoke-DVDScan is not implemented yet (see issue #24). Use Start-DVD-TV.ps1 / Start-DVD-Movies.ps1."
