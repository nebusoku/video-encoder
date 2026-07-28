<#
video-encoder.ps1
Command-line entry point for the portable video encoder.

  video-encoder.ps1                      -> interactive menu
  video-encoder.ps1 <command> [options]  -> run a command directly

Options after the command are forwarded verbatim to the underlying action
script. Run `video-encoder.ps1 help` for the command list.
#>

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $repoRoot "module\VideoEncoder.psd1") -Force

$all = @($args)

if ($all.Count -eq 0) {
    # No command: fall back to the interactive menu.
    & (Join-Path $repoRoot "scripts\Menu-Core.ps1")
    return
}

$command = [string]$all[0]
$rest = @()
if ($all.Count -gt 1) { $rest = $all[1..($all.Count - 1)] }

Invoke-VideoEncoder $command @rest

$code = 0
$lec = Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue
if ($null -ne $lec) { $code = [int]$lec }
exit $code
