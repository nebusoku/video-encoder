[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    if ($PSScriptRoot) {
        return (Resolve-Path -LiteralPath $PSScriptRoot).Path
    }
    return (Resolve-Path -LiteralPath (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
}

function Resolve-MenuScriptPath {
    param([string]$RepoRoot)

    $menuPath = Join-Path $RepoRoot "scripts\Menu-Core.ps1"
    if (-not (Test-Path -LiteralPath $menuPath)) {
        throw "Menu script not found: $menuPath"
    }

    return $menuPath
}

$repoRoot = Get-RepoRoot
$menuScript = Resolve-MenuScriptPath -RepoRoot $repoRoot

& $menuScript