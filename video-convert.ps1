# Parser-safe launcher for broad Windows PowerShell compatibility (no param()/CmdletBinding usage).

$RootPath = ""
$Mode = ""
$FfprobePath = ""
$FfmpegPath = ""
$HandBrakeCliPath = ""
$FileBotPath = ""
$CompletedCsvPath = ""
$BackupOriginal = $false
$MaxTotalInputGB = 0
$DryRun = $false
$EnableFileBotRename = $false
$FileBotTestRun = $false
$ConcurrentJobs = 2
$EncoderMode = "Auto"
$Quality = 23
$AudioBitrateKbps = 160
$EnsureDependencies = $false
$RefreshDependencies = $false
$ProbeHardwareOnly = $false
$RefreshHardwareCache = $false

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]

    switch -Regex ($arg) {
        '^-RootPath$' { if ($i + 1 -lt $args.Count) { $RootPath = [string]$args[++$i] }; continue }
        '^-Mode$' { if ($i + 1 -lt $args.Count) { $Mode = [string]$args[++$i] }; continue }
        '^-FfprobePath$' { if ($i + 1 -lt $args.Count) { $FfprobePath = [string]$args[++$i] }; continue }
        '^-FfmpegPath$' { if ($i + 1 -lt $args.Count) { $FfmpegPath = [string]$args[++$i] }; continue }
        '^-HandBrakeCliPath$' { if ($i + 1 -lt $args.Count) { $HandBrakeCliPath = [string]$args[++$i] }; continue }
        '^-FileBotPath$' { if ($i + 1 -lt $args.Count) { $FileBotPath = [string]$args[++$i] }; continue }
        '^-CompletedCsvPath$' { if ($i + 1 -lt $args.Count) { $CompletedCsvPath = [string]$args[++$i] }; continue }
        '^-MaxTotalInputGB$' { if ($i + 1 -lt $args.Count) { $MaxTotalInputGB = [double]$args[++$i] }; continue }
        '^-ConcurrentJobs$' { if ($i + 1 -lt $args.Count) { $ConcurrentJobs = [int]$args[++$i] }; continue }
        '^-EncoderMode$' { if ($i + 1 -lt $args.Count) { $EncoderMode = [string]$args[++$i] }; continue }
        '^-Quality$' { if ($i + 1 -lt $args.Count) { $Quality = [int]$args[++$i] }; continue }
        '^-AudioBitrateKbps$' { if ($i + 1 -lt $args.Count) { $AudioBitrateKbps = [int]$args[++$i] }; continue }

        '^-BackupOriginal$' { $BackupOriginal = $true; continue }
        '^-DryRun$' { $DryRun = $true; continue }
        '^-EnableFileBotRename$' { $EnableFileBotRename = $true; continue }
        '^-FileBotTestRun$' { $FileBotTestRun = $true; continue }
        '^-EnsureDependencies$' { $EnsureDependencies = $true; continue }
        '^-RefreshDependencies$' { $RefreshDependencies = $true; continue }
        '^-ProbeHardwareOnly$' { $ProbeHardwareOnly = $true; continue }
        '^-RefreshHardwareCache$' { $RefreshHardwareCache = $true; continue }

        '^-BackupOriginal:(?i:true|1)$' { $BackupOriginal = $true; continue }
        '^-DryRun:(?i:true|1)$' { $DryRun = $true; continue }
        '^-EnableFileBotRename:(?i:true|1)$' { $EnableFileBotRename = $true; continue }
        '^-FileBotTestRun:(?i:true|1)$' { $FileBotTestRun = $true; continue }
        '^-EnsureDependencies:(?i:true|1)$' { $EnsureDependencies = $true; continue }
        '^-RefreshDependencies:(?i:true|1)$' { $RefreshDependencies = $true; continue }
        '^-ProbeHardwareOnly:(?i:true|1)$' { $ProbeHardwareOnly = $true; continue }
        '^-RefreshHardwareCache:(?i:true|1)$' { $RefreshHardwareCache = $true; continue }
    }
}
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

$LogRoot = Join-Path $PSScriptRoot "Logs"
if (-not (Test-Path -LiteralPath $LogRoot)) { New-Item -Path $LogRoot -ItemType Directory | Out-Null }
$DiagLog = Join-Path $LogRoot ("Session-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$TranscriptStarted = $false

try { Start-Transcript -Path $DiagLog -Append -ErrorAction Stop | Out-Null; $TranscriptStarted = $true }
catch { Write-Host "Could not start transcript log: $($_.Exception.Message)" -ForegroundColor Yellow }
try {
    Start-Transcript -Path $DiagLog -Append -ErrorAction Stop | Out-Null
    $TranscriptStarted = $true
}
catch {
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

    if ($selection -eq "1") {
        $ProbeHardwareOnly = $true
        $EnsureDependencies = $true
        if (-not $Mode) { $Mode = "1" }
    }
    elseif ($selection -eq "2") {
        $Mode = "1"
        if (-not $RootPath -or $RootPath.Trim() -eq "") { $RootPath = Read-Host "Enter TV root path to process" }
    }
    elseif ($selection -eq "3") {
        $Mode = "2"
        if (-not $RootPath -or $RootPath.Trim() -eq "") { $RootPath = Read-Host "Enter Movies root path to process" }
    }
}

$invokeArgs = @{}
if ($RootPath) { $invokeArgs.RootPath = $RootPath }
if ($Mode) { $invokeArgs.Mode = $Mode }
if ($FfprobePath) { $invokeArgs.FfprobePath = $FfprobePath }
if ($FfmpegPath) { $invokeArgs.FfmpegPath = $FfmpegPath }
if ($HandBrakeCliPath) { $invokeArgs.HandBrakeCliPath = $HandBrakeCliPath }
if ($FileBotPath) { $invokeArgs.FileBotPath = $FileBotPath }
if ($CompletedCsvPath) { $invokeArgs.CompletedCsvPath = $CompletedCsvPath }
$invokeArgs.MaxTotalInputGB = $MaxTotalInputGB
$invokeArgs.ConcurrentJobs = $ConcurrentJobs
$invokeArgs.EncoderMode = $EncoderMode
$invokeArgs.Quality = $Quality
$invokeArgs.AudioBitrateKbps = $AudioBitrateKbps
if ($BackupOriginal) { $invokeArgs.BackupOriginal = $true }
if ($DryRun) { $invokeArgs.DryRun = $true }
if ($EnableFileBotRename) { $invokeArgs.EnableFileBotRename = $true }
if ($FileBotTestRun) { $invokeArgs.FileBotTestRun = $true }
if ($EnsureDependencies) { $invokeArgs.EnsureDependencies = $true }
if ($RefreshDependencies) { $invokeArgs.RefreshDependencies = $true }
if ($ProbeHardwareOnly) { $invokeArgs.ProbeHardwareOnly = $true }
if ($RefreshHardwareCache) { $invokeArgs.RefreshHardwareCache = $true }

        if (-not $RootPath -or $RootPath.Trim() -eq "") {
            $RootPath = Read-Host "Enter TV root path to process"
        }
    }
    elseif ($selection -eq "3") {
        $Mode = "2"
        if (-not $RootPath -or $RootPath.Trim() -eq "") {
            $RootPath = Read-Host "Enter Movies root path to process"
        }
    }
}

if ($Mode) { $PSBoundParameters["Mode"] = $Mode }
if ($RootPath) { $PSBoundParameters["RootPath"] = $RootPath }
if ($ProbeHardwareOnly) { $PSBoundParameters["ProbeHardwareOnly"] = $true }
if ($EnsureDependencies) { $PSBoundParameters["EnsureDependencies"] = $true }
if ($RefreshDependencies) { $PSBoundParameters["RefreshDependencies"] = $true }

# Keep parse check simple: only verify main worker script to avoid false-positives on host-specific dependency paths.
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    $msg = ($errors | ForEach-Object { $_.Message + " (line " + $_.Extent.StartLineNumber + ", col " + $_.Extent.StartColumnNumber + ")" }) -join "; "
    throw "Script parse precheck failed for '$scriptPath': $msg"
}

try { & $scriptPath @invokeArgs }
finally {
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
    Write-Host "Diagnostic log: $DiagLog" -ForegroundColor DarkGray
}
try {
    & $scriptPath @PSBoundParameters
}
finally {
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
    Write-Host "Diagnostic log: $DiagLog" -ForegroundColor DarkGray
}
function Get-ScriptParseErrorText {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        return (($errors | ForEach-Object { "{0} (line {1}, col {2})" -f $_.Message, $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber }) -join "; ")
    }
    return ""
}

function Assert-ScriptParseable {
    param([Parameter(Mandatory)][string]$Path)

    $errText = Get-ScriptParseErrorText -Path $Path
    if ($errText) {
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

function Resolve-DependencyScriptPath {
    param([Parameter(Mandatory)][string]$ScriptsRoot)

    $corePath = Join-Path $ScriptsRoot "Ensure-Dependencies-Core.ps1"
    $legacyPath = Join-Path $ScriptsRoot "Ensure-Dependencies.ps1"

    if (Test-Path -LiteralPath $corePath) {
        $coreErr = Get-ScriptParseErrorText -Path $corePath
        if (-not $coreErr) { return $corePath }
    }

    if (Test-Path -LiteralPath $legacyPath) {
        $legacyErr = Get-ScriptParseErrorText -Path $legacyPath
        if (-not $legacyErr) { return $legacyPath }
    }

    if (Test-Path -LiteralPath $corePath) {
        $coreErr = Get-ScriptParseErrorText -Path $corePath
        throw "No parseable dependency bootstrap script found. Core errors: $coreErr"
    }

    throw "No dependency bootstrap script found under: $ScriptsRoot"
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
    $depScriptPath = Resolve-DependencyScriptPath -ScriptsRoot (Join-Path $PSScriptRoot "scripts")
    Assert-ScriptParseable -Path $depScriptPath
    $depScriptPath = Join-Path $PSScriptRoot "scripts\Ensure-Dependencies-Core.ps1"
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
& $scriptPath @PSBoundParameters
