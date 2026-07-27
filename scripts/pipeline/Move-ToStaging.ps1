<#
Move-ToStaging.ps1
Moves a finished encode from an _incoming location into the _staging tree
resolved by pipeline\Resolve-PipelinePaths.ps1, ready for FileBot rename.

STATUS: stub / not yet implemented. Tracked in GitHub issue #24.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$PipelineRoot,
    [Parameter(Mandatory)][ValidateSet("TV", "Movies")][string]$Kind
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

throw "Move-ToStaging is not implemented yet (see issue #24)."
