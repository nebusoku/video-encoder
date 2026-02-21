[CmdletBinding()]
param(
    [string]$Root = "",
    [switch]$IncludeLegacyShims
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$skipFiles = @()
if (-not $IncludeLegacyShims) {
    $skipFiles += (Join-Path $Root "scripts\Ensure-Dependencies.ps1")
}
$skipLookup = @{}
foreach ($s in $skipFiles) { $skipLookup[$s.ToLowerInvariant()] = $true }

$files = Get-ChildItem -Path $Root -Recurse -Filter "*.ps1" | Sort-Object FullName
$hadError = $false

foreach ($file in $files) {
    if ($skipLookup.ContainsKey($file.FullName.ToLowerInvariant())) {
        Write-Host "[SKIP] $($file.FullName) (legacy shim)" -ForegroundColor DarkYellow
        continue
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        $hadError = $true
        Write-Host "[FAIL] $($file.FullName)" -ForegroundColor Red
        foreach ($err in $errors) {
            Write-Host ("  - {0} (line {1}, col {2})" -f $err.Message, $err.Extent.StartLineNumber, $err.Extent.StartColumnNumber) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[OK]   $($file.FullName)" -ForegroundColor Green
    }
}

if ($hadError) {
    throw "PowerShell parse check failed. See errors above."
}

Write-Host "PowerShell parse check passed for selected .ps1 files." -ForegroundColor Cyan
