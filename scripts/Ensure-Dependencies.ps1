# Compatibility wrapper. Prefer Ensure-Dependencies-Core.ps1.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$core = Join-Path $scriptDir "Ensure-Dependencies-Core.ps1"
if (-not (Test-Path -LiteralPath $core)) {
    throw "Missing dependency bootstrap core script: $core"
}
& $core @args
