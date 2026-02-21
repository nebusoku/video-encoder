[CmdletBinding()]
param(
    [string]$Root = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$files = Get-ChildItem -Path $Root -Recurse -Filter "*.ps1" | Sort-Object FullName
$hadError = $false

foreach ($file in $files) {
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

Write-Host "PowerShell parse check passed for all .ps1 files." -ForegroundColor Cyan
