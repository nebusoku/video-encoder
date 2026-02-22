# Parser-safe syntax checker for broad Windows PowerShell compatibility.

$ScriptSelf = $MyInvocation.MyCommand.Path
$ScriptVersion = "unknown"
$versionPath = Join-Path (Split-Path -Parent $PSScriptRoot) "VERSION"
if (Test-Path -LiteralPath $versionPath) {
    $ScriptVersion = ((Get-Content -LiteralPath $versionPath -ErrorAction SilentlyContinue | Select-Object -First 1) + "").Trim()
    if (-not $ScriptVersion) { $ScriptVersion = "unknown" }
}
Write-Host ("[syntax-check] Script: {0}" -f $ScriptSelf) -ForegroundColor DarkGray
Write-Host ("[syntax-check] Version: {0}" -f $ScriptVersion) -ForegroundColor DarkGray

$Root = ""
$IncludeLegacyShims = $false

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]

    if ($arg -eq "-Root" -and $i + 1 -lt $args.Count) { $Root = [string]$args[++$i]; continue }
    if ($arg -eq "-IncludeLegacyShims") { $IncludeLegacyShims = $true; continue }
    if ($arg.StartsWith("-IncludeLegacyShims:")) {
        $v = $arg.Substring(20).ToLowerInvariant()
        if ($v -in @('true','1')) { $IncludeLegacyShims = $true }
        elseif ($v -in @('false','0')) { $IncludeLegacyShims = $false }
        continue
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }


$hashTargets = @(
    (Join-Path $Root "video-convert.ps1"),
    (Join-Path $Root "scripts\Test-PowerShellSyntax.ps1"),
    (Join-Path $Root "scripts\Invoke-VideoConvert.ps1")
)
foreach ($hashTarget in $hashTargets) {
    if (Test-Path -LiteralPath $hashTarget) {
        try {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $hashTarget).Hash
            Write-Host ("[syntax-check] SHA256 {0} {1}" -f (Split-Path -Leaf $hashTarget), $hash) -ForegroundColor DarkGray
        }
        catch {
            Write-Host ("[syntax-check] Could not hash {0}: {1}" -f $hashTarget, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}
$skipFiles = @(
    (Join-Path $Root "video-convert.ps1"),
    (Join-Path $Root "scripts\Test-PowerShellSyntax.ps1")
)
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
