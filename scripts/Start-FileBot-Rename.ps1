[CmdletBinding()]
param(
    [string]$InputPath = "",
    [string]$OutputPath = "",
    [ValidateSet("TV","MOVIES")]
    [string]$Mode = "",
    [switch]$TestRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonCore = Join-Path $PSScriptRoot "lib\Common-Core.ps1"
if (-not (Test-Path -LiteralPath $commonCore)) {
    throw "Missing shared library: $commonCore"
}
. $commonCore

function Read-NonEmptyValue([string]$Prompt) {
    while ($true) {
        $v = Read-Host $Prompt
        if ($v -and $v.Trim()) { return $v.Trim() }
    }
}

function Resolve-ModeConfig {
    param([Parameter(Mandatory)][string]$SelectedMode)

    switch ($SelectedMode.ToUpperInvariant()) {
        "TV" {
            return [pscustomobject]@{
                Label  = "TV"
                Db     = "TheMovieDB::TV"
                Format = "{n} - {s00e00} - {vf}{if(imdbid) ' ('+imdbid+')'}{'.'}{ext}"
            }
        }
        "MOVIES" {
            return [pscustomobject]@{
                Label  = "Movies"
                Db     = "TheMovieDB"
                Format = "{n} ({y}) - {vf}{if(imdbid) ' ('+imdbid+')'}{'.'}{ext}"
            }
        }
        default {
            throw "Unsupported mode: $SelectedMode"
        }
    }
}

$repoRoot = Get-RepoRoot
$toolStatus = Test-CoreToolsPresent -RepoRoot $repoRoot
if (-not $toolStatus.HasFileBot) {
    throw "FileBot not found. Put portable FileBot in tools\filebot\"
}

if (-not $Mode -or -not $Mode.Trim()) {
    Write-ConsoleCyan "Select FileBot rename mode:"
    Write-Host "  1) TV"
    Write-Host "  2) Movies"
    $modeChoice = Read-Host "Enter 1 or 2"

    switch ($modeChoice) {
        "1" { $Mode = "TV" }
        "2" { $Mode = "MOVIES" }
        default { throw "Invalid selection." }
    }
}

if (-not $InputPath -or -not $InputPath.Trim()) {
    $InputPath = Read-NonEmptyValue "Enter input path to rename (file or folder)"
}
if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input path not found: $InputPath"
}

if (-not $OutputPath -or -not $OutputPath.Trim()) {
    $OutputPath = Read-Host "Enter output path (leave blank to rename in place)"
    if (-not $OutputPath) { $OutputPath = "" }
}

if ($OutputPath -and $OutputPath.Trim()) {
    Ensure-Directory -Path $OutputPath | Out-Null
}

$config = Resolve-ModeConfig -SelectedMode $Mode
$action = if ($TestRun) { "test" } else { "move" }

Write-ConsoleCyan "Starting FileBot rename..."
Write-ConsoleInfo ("Mode       : " + $config.Label)
Write-ConsoleInfo ("Input      : " + $InputPath)
if ($OutputPath -and $OutputPath.Trim()) {
    Write-ConsoleInfo ("Output     : " + $OutputPath)
} else {
    Write-ConsoleInfo "Output     : rename in place"
}
Write-ConsoleInfo ("Action     : " + $action)
Write-ConsoleInfo ("Database   : " + $config.Db)
Write-ConsoleInfo ("Format     : " + $config.Format)
Write-ConsoleInfo ("FileBot    : " + $toolStatus.Tools.FileBot)
Write-Host ""

$args = @(
    "-rename", $InputPath,
    "--db", $config.Db,
    "--format", $config.Format,
    "--action", $action,
    "--conflict", "auto",
    "--log", "all",
    "-non-strict"
)

if ($OutputPath -and $OutputPath.Trim()) {
    $args += @("--output", $OutputPath)
}

& $toolStatus.Tools.FileBot @args

if ($LASTEXITCODE -ne 0) {
    throw "FileBot rename failed with exit code $LASTEXITCODE"
}

Write-ConsoleOk "FileBot rename completed successfully."