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
& $core @args
