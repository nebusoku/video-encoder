# Compatibility syntax-check wrapper. Prefer Test-PowerShellSyntax-Core.ps1.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$versionPath = Join-Path (Split-Path -Parent $scriptDir) "VERSION"
$wrapperVersion = "unknown"
if (Test-Path -LiteralPath $versionPath) {
    $wrapperVersion = ((Get-Content -LiteralPath $versionPath -ErrorAction SilentlyContinue | Select-Object -First 1) + "").Trim()
    if (-not $wrapperVersion) { $wrapperVersion = "unknown" }
}
Write-Host ("[syntax-wrapper] Script: {0}" -f $MyInvocation.MyCommand.Path) -ForegroundColor DarkGray
Write-Host ("[syntax-wrapper] Version: {0}" -f $wrapperVersion) -ForegroundColor DarkGray
$core = Join-Path $scriptDir "Test-PowerShellSyntax-Core.ps1"
if (-not (Test-Path -LiteralPath $core)) {
    throw "Missing syntax-check core script: $core"
}
& $core @args; exit $LASTEXITCODE
& $core @args
# Parser-safe syntax checker for broad Windows PowerShell compatibility.

$ScriptVersion = "2026.02.21.1"
$ScriptSelf = $MyInvocation.MyCommand.Path
Write-Host ("[syntax-check] Script: {0}" -f $ScriptSelf) -ForegroundColor DarkGray
Write-Host ("[syntax-check] Version: {0}" -f $ScriptVersion) -ForegroundColor DarkGray

$Root = ""
$IncludeLegacyShims = $false

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]
    switch -Regex ($arg) {
        '^-Root$' { if ($i + 1 -lt $args.Count) { $Root = [string]$args[++$i] }; continue }
        '^-IncludeLegacyShims$' { $IncludeLegacyShims = $true; continue }
        '^-IncludeLegacyShims:(?i:true|1)$' { $IncludeLegacyShims = $true; continue }
        '^-IncludeLegacyShims:(?i:false|0)$' { $IncludeLegacyShims = $false; continue }
    }
}
[CmdletBinding()]
param(
    [string]$Root = "",
    [switch]$IncludeLegacyShims
    [string]$Root = ""
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
Write-Host "PowerShell parse check passed for all .ps1 files." -ForegroundColor Cyan
