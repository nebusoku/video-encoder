# Compatibility launcher wrapper. Prefer scripts/Launch-VideoConvert-Core.ps1.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$versionPath = Join-Path $scriptDir "VERSION"
$wrapperVersion = "unknown"
if (Test-Path -LiteralPath $versionPath) {
    $wrapperVersion = ((Get-Content -LiteralPath $versionPath -ErrorAction SilentlyContinue | Select-Object -First 1) + "").Trim()
    if (-not $wrapperVersion) { $wrapperVersion = "unknown" }
}
Write-Host ("[launcher-wrapper] Script: {0}" -f $MyInvocation.MyCommand.Path) -ForegroundColor DarkGray
Write-Host ("[launcher-wrapper] Version: {0}" -f $wrapperVersion) -ForegroundColor DarkGray
$core = Join-Path $scriptDir "scripts\Launch-VideoConvert-Core.ps1"
if (-not (Test-Path -LiteralPath $core)) {
    throw "Missing launcher core script: $core"
}
& $core @args
exit $LASTEXITCODE