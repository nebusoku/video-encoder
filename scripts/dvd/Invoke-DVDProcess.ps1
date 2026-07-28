<#
Invoke-DVDProcess.ps1
Rips/encodes a single DVD title selected from Invoke-DVDScan output.

STATUS: stub / not yet implemented. Tracked in GitHub issue #24.
Today the DVD flow is handled end-to-end by scripts\Start-DVD-TV.ps1 and
scripts\Start-DVD-Movies.ps1; this helper is where the per-title rip/encode
logic should be factored out to.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][int]$TitleIndex,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

throw "Invoke-DVDProcess is not implemented yet (see issue #24). Use Start-DVD-TV.ps1 / Start-DVD-Movies.ps1."
