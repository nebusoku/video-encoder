# Compatibility launcher wrapper. Prefer scripts/Launch-VideoConvert-Core.ps1.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$core = Join-Path $scriptDir "scripts\Launch-VideoConvert-Core.ps1"
if (-not (Test-Path -LiteralPath $core)) {
    throw "Missing launcher core script: $core"
}
& $core @args
