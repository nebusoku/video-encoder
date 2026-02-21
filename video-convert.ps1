[CmdletBinding()]
param(
    [string]$RootPath = "",
    [ValidateSet("","1","2")]
    [string]$Mode = "",
    [string]$FfprobePath = "",
    [string]$FfmpegPath = "",
    [string]$HandBrakeCliPath = "",
    [string]$FileBotPath = "",
    [string]$CompletedCsvPath = "",
    [switch]$BackupOriginal,
    [double]$MaxTotalInputGB = 0,
    [switch]$DryRun,
    [switch]$EnableFileBotRename,
    [switch]$FileBotTestRun,
    [ValidateRange(1, 16)]
    [int]$ConcurrentJobs = 2,
    [ValidateSet("Auto","NVENC","AMDVCE","X264")]
    [string]$EncoderMode = "Auto",
    [ValidateRange(16, 30)]
    [int]$Quality = 23,
    [ValidateRange(96, 320)]
    [int]$AudioBitrateKbps = 160,
    [switch]$EnsureDependencies,
    [switch]$RefreshDependencies,
    [switch]$ProbeHardwareOnly,
    [switch]$RefreshHardwareCache
)

$scriptPath = Join-Path $PSScriptRoot "scripts\Invoke-VideoConvert.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing script: $scriptPath"
}

function Assert-ScriptParseable {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $errText = ($errors | ForEach-Object { "{0} (line {1}, col {2})" -f $_.Message, $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber }) -join "; "
        throw "Script parse precheck failed for '$Path': $errText"
    }
}

$LogRoot = Join-Path $PSScriptRoot "Logs"
if (-not (Test-Path -LiteralPath $LogRoot)) { New-Item -Path $LogRoot -ItemType Directory | Out-Null }
$DiagLog = Join-Path $LogRoot ("Session-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$TranscriptStarted = $false
try {
    Start-Transcript -Path $DiagLog -Append -ErrorAction Stop | Out-Null
    $TranscriptStarted = $true
} catch {
    Write-Host "Could not start transcript log: $($_.Exception.Message)" -ForegroundColor Yellow
}

if (-not $Mode -and -not $ProbeHardwareOnly) {
    $selection = ""
    while ($selection -notin @("1","2","3")) {
        Write-Host ""
        Write-Host "Select action:" -ForegroundColor Cyan
        Write-Host "  1) Hardware Test (build/update machine hardware profile)" -ForegroundColor Gray
        Write-Host "  2) Encode TV Show" -ForegroundColor Gray
        Write-Host "  3) Encode Movies" -ForegroundColor Gray
        $selection = Read-Host "Enter 1, 2, or 3"
    }

    switch ($selection) {
        "1" {
            $ProbeHardwareOnly = $true
            $EnsureDependencies = $true
            if (-not $Mode) { $Mode = "1" }
        }
        "2" {
            $Mode = "1"
            if (-not $RootPath -or $RootPath.Trim() -eq "") {
                $RootPath = Read-Host "Enter TV root path to process"
            }
        }
        "3" {
            $Mode = "2"
            if (-not $RootPath -or $RootPath.Trim() -eq "") {
                $RootPath = Read-Host "Enter Movies root path to process"
            }
        }
    }
}

if ($Mode) { $PSBoundParameters["Mode"] = $Mode }
if ($RootPath) { $PSBoundParameters["RootPath"] = $RootPath }
if ($ProbeHardwareOnly) { $PSBoundParameters["ProbeHardwareOnly"] = $true }
if ($EnsureDependencies) { $PSBoundParameters["EnsureDependencies"] = $true }

if ($EnsureDependencies -or $RefreshDependencies) {
    $depScriptPath = Join-Path $PSScriptRoot "scripts\Ensure-Dependencies.ps1"
    if (Test-Path -LiteralPath $depScriptPath) { Assert-ScriptParseable -Path $depScriptPath }
}
Assert-ScriptParseable -Path $scriptPath

try {
    & $scriptPath @PSBoundParameters
}
finally {
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
    Write-Host "Diagnostic log: $DiagLog" -ForegroundColor DarkGray
}
