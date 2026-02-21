# Compatibility syntax-check wrapper. Prefer Test-PowerShellSyntax-Core.ps1.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$core = Join-Path $scriptDir "Test-PowerShellSyntax-Core.ps1"
if (-not (Test-Path -LiteralPath $core)) {
    throw "Missing syntax-check core script: $core"
}
& $core @args
