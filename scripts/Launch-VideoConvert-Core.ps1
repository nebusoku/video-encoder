# Parser-safe launcher for broad Windows PowerShell compatibility (no param()/CmdletBinding usage).

$ScriptSelf = $MyInvocation.MyCommand.Path
$ScriptVersion = "unknown"
$versionPath = Join-Path (Split-Path -Parent $PSScriptRoot) "VERSION"
if (Test-Path -LiteralPath $versionPath) {
    $ScriptVersion = ((Get-Content -LiteralPath $versionPath -ErrorAction SilentlyContinue | Select-Object -First 1) + "").Trim()
    if (-not $ScriptVersion) { $ScriptVersion = "unknown" }
}
$ScriptVersion = "2026.02.21.1"
$ScriptSelf = $MyInvocation.MyCommand.Path
Write-Host ("[launcher] Script: {0}" -f $ScriptSelf) -ForegroundColor DarkGray
Write-Host ("[launcher] Version: {0}" -f $ScriptVersion) -ForegroundColor DarkGray

# -----------------------------
# Defaults / args (parser-safe)
# -----------------------------
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

    if ($arg -eq "-RootPath" -and $i + 1 -lt $args.Count) { $RootPath = [string]$args[++$i]; continue }
    if ($arg -eq "-Mode" -and $i + 1 -lt $args.Count) { $Mode = [string]$args[++$i]; continue }
    if ($arg -eq "-FfprobePath" -and $i + 1 -lt $args.Count) { $FfprobePath = [string]$args[++$i]; continue }
    if ($arg -eq "-FfmpegPath" -and $i + 1 -lt $args.Count) { $FfmpegPath = [string]$args[++$i]; continue }
    if ($arg -eq "-HandBrakeCliPath" -and $i + 1 -lt $args.Count) { $HandBrakeCliPath = [string]$args[++$i]; continue }
    if ($arg -eq "-FileBotPath" -and $i + 1 -lt $args.Count) { $FileBotPath = [string]$args[++$i]; continue }
    if ($arg -eq "-CompletedCsvPath" -and $i + 1 -lt $args.Count) { $CompletedCsvPath = [string]$args[++$i]; continue }
    if ($arg -eq "-MaxTotalInputGB" -and $i + 1 -lt $args.Count) { $MaxTotalInputGB = [double]$args[++$i]; continue }
    if ($arg -eq "-ConcurrentJobs" -and $i + 1 -lt $args.Count) { $ConcurrentJobs = [int]$args[++$i]; continue }
    if ($arg -eq "-EncoderMode" -and $i + 1 -lt $args.Count) { $EncoderMode = [string]$args[++$i]; continue }
    if ($arg -eq "-Quality" -and $i + 1 -lt $args.Count) { $Quality = [int]$args[++$i]; continue }
    if ($arg -eq "-AudioBitrateKbps" -and $i + 1 -lt $args.Count) { $AudioBitrateKbps = [int]$args[++$i]; continue }

    if ($arg -eq "-BackupOriginal") { $BackupOriginal = $true; continue }
    if ($arg -eq "-DryRun") { $DryRun = $true; continue }
    if ($arg -eq "-EnableFileBotRename") { $EnableFileBotRename = $true; continue }
    if ($arg -eq "-FileBotTestRun") { $FileBotTestRun = $true; continue }
    if ($arg -eq "-EnsureDependencies") { $EnsureDependencies = $true; continue }
    if ($arg -eq "-RefreshDependencies") { $RefreshDependencies = $true; continue }
    if ($arg -eq "-ProbeHardwareOnly") { $ProbeHardwareOnly = $true; continue }
    if ($arg -eq "-RefreshHardwareCache") { $RefreshHardwareCache = $true; continue }

    if ($arg.StartsWith("-BackupOriginal:")) { if ($arg.Substring(16).ToLowerInvariant() -in @('true','1')) { $BackupOriginal = $true }; continue }
    if ($arg.StartsWith("-DryRun:")) { if ($arg.Substring(8).ToLowerInvariant() -in @('true','1')) { $DryRun = $true }; continue }
    if ($arg.StartsWith("-EnableFileBotRename:")) { if ($arg.Substring(21).ToLowerInvariant() -in @('true','1')) { $EnableFileBotRename = $true }; continue }
    if ($arg.StartsWith("-FileBotTestRun:")) { if ($arg.Substring(16).ToLowerInvariant() -in @('true','1')) { $FileBotTestRun = $true }; continue }
    if ($arg.StartsWith("-EnsureDependencies:")) { if ($arg.Substring(20).ToLowerInvariant() -in @('true','1')) { $EnsureDependencies = $true }; continue }
    if ($arg.StartsWith("-RefreshDependencies:")) { if ($arg.Substring(21).ToLowerInvariant() -in @('true','1')) { $RefreshDependencies = $true }; continue }
    if ($arg.StartsWith("-ProbeHardwareOnly:")) { if ($arg.Substring(19).ToLowerInvariant() -in @('true','1')) { $ProbeHardwareOnly = $true }; continue }
    if ($arg.StartsWith("-RefreshHardwareCache:")) { if ($arg.Substring(22).ToLowerInvariant() -in @('true','1')) { $RefreshHardwareCache = $true }; continue }
}

# -----------------------------
# Paths / helpers
# -----------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
$InvokeScript = Join-Path $PSScriptRoot "Invoke-VideoConvert.ps1"
$EnsureCore = Join-Path $PSScriptRoot "Ensure-Dependencies-Core.ps1"

function Pause-ReturnMenu {
    Write-Host ""
    Read-Host "Press Enter to return to menu" | Out-Null
}

function Test-ToolsPresent {
    $toolsRoot = Join-Path $RepoRoot "tools"

    $hb = Join-Path $toolsRoot "handbrake\HandBrakeCLI.exe"
    $ff = Join-Path $toolsRoot "ffmpeg\bin\ffmpeg.exe"
    $fp = Join-Path $toolsRoot "ffmpeg\bin\ffprobe.exe"

    $fbCmd = Join-Path $toolsRoot "filebot\filebot.cmd"
    $fbExe = Join-Path $toolsRoot "filebot\FileBot.exe"

    $missing = @()
    foreach ($p in @($hb,$ff,$fp)) {
        if (-not (Test-Path -LiteralPath $p)) { $missing += $p }
    }
    if (-not (Test-Path -LiteralPath $fbCmd) -and -not (Test-Path -LiteralPath $fbExe)) {
        $missing += (Join-Path $toolsRoot "filebot\filebot.cmd (or FileBot.exe)")
    }

    return [pscustomobject]@{
        Ok      = ($missing.Count -eq 0)
        Missing = $missing
    }
}

function Test-HardwareProfilePresent {
    $profile = Join-Path (Join-Path $RepoRoot "Config") ("hardware-profile-" + $env:COMPUTERNAME + ".json")
    return [pscustomobject]@{
        Ok   = (Test-Path -LiteralPath $profile)
        Path = $profile
    }
}

function Invoke-VideoConvertCore {
    param([hashtable]$InvokeArgs)

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($InvokeScript, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $msg = ($errors | ForEach-Object { $_.Message + " (line " + $_.Extent.StartLineNumber + ", col " + $_.Extent.StartColumnNumber + ")" }) -join "; "
        throw "Script parse precheck failed for '$InvokeScript': $msg"
    }

    & $InvokeScript @InvokeArgs
}

# -----------------------------
# Diagnostics transcript
# -----------------------------
$LogRoot = Join-Path $PSScriptRoot "Logs"
if (-not (Test-Path -LiteralPath $LogRoot)) { New-Item -Path $LogRoot -ItemType Directory | Out-Null }
$DiagLog = Join-Path $LogRoot ("Session-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$TranscriptStarted = $false

try { Start-Transcript -Path $DiagLog -Append -ErrorAction Stop | Out-Null; $TranscriptStarted = $true }
catch { Write-Host "Could not start transcript log: $($_.Exception.Message)" -ForegroundColor Yellow }

try {

    # If Mode/ProbeHardwareOnly provided via CLI, run once (non-interactive)
    if ($Mode -or $ProbeHardwareOnly -or $EnsureDependencies -or $RefreshDependencies) {
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

        Invoke-VideoConvertCore -InvokeArgs $invokeArgs
        return
    }

    # Interactive menu loop
    while ($true) {
        Write-Host ""
        Write-Host "Select action:" -ForegroundColor Cyan
        Write-Host "  1) Download / Update Tools" -ForegroundColor Gray
        Write-Host "  2) Hardware Test (build/update machine hardware profile)" -ForegroundColor Gray
        Write-Host "  3) Encode TV Shows" -ForegroundColor Gray
        Write-Host "  4) Encode Movies" -ForegroundColor Gray
        Write-Host "  0) Exit" -ForegroundColor DarkGray
        $selection = Read-Host "Enter 0, 1, 2, 3, or 4"

        if ($selection -eq "0") { break }

        if ($selection -eq "1") {
            if (-not (Test-Path -LiteralPath $EnsureCore)) {
                Write-Host "Missing script: $EnsureCore" -ForegroundColor Red
                Pause-ReturnMenu
                continue
            }

            $refreshAns = Read-Host "Force re-download/refresh tools? (y/N)"
            $force = $false
            if ($refreshAns -and $refreshAns.Trim().ToLowerInvariant() -eq "y") { $force = $true }

            try {
                & $EnsureCore -ToolsRoot (Join-Path $RepoRoot "tools") -Components "FFmpeg,HandBrake,FileBot" -ForceRefresh:$force
                Write-Host "Tools are ready." -ForegroundColor Green
            }
            catch {
                Write-Host $_ -ForegroundColor Red
            }
            Pause-ReturnMenu
            continue
        }

        if ($selection -eq "2") {
            $tools = Test-ToolsPresent
            if (-not $tools.Ok) {
                Write-Host ""
                Write-Host "Missing required tools. Run option 1 first." -ForegroundColor Yellow
                $tools.Missing | ForEach-Object { Write-Host ("  - " + $_) -ForegroundColor DarkYellow }
                Pause-ReturnMenu
                continue
            }

            try {
                $invokeArgs = @{
                    Mode = "1"
                    ProbeHardwareOnly = $true
                    EnsureDependencies = $false
                    RefreshDependencies = $false
                    RefreshHardwareCache = $true
                    ConcurrentJobs = $ConcurrentJobs
                    EncoderMode = $EncoderMode
                    Quality = $Quality
                    AudioBitrateKbps = $AudioBitrateKbps
                    MaxTotalInputGB = $MaxTotalInputGB
                }
                Invoke-VideoConvertCore -InvokeArgs $invokeArgs
            }
            catch {
                Write-Host $_ -ForegroundColor Red
            }
            Pause-ReturnMenu
            continue
        }

        if ($selection -in @("3","4")) {

            $tools = Test-ToolsPresent
            if (-not $tools.Ok) {
                Write-Host ""
                Write-Host "Missing required tools. Run option 1 first." -ForegroundColor Yellow
                $tools.Missing | ForEach-Object { Write-Host ("  - " + $_) -ForegroundColor DarkYellow }
                Pause-ReturnMenu
                continue
            }

            $hp = Test-HardwareProfilePresent
            if (-not $hp.Ok) {
                Write-Host ""
                Write-Host "Hardware profile not found. Run option 2 first." -ForegroundColor Yellow
                Write-Host ("Expected profile: " + $hp.Path) -ForegroundColor DarkYellow
                Pause-ReturnMenu
                continue
            }

            # Ask FileBot rename on/off
            $fbAns = Read-Host "Enable FileBot rename? (y/N)"
            $useFileBot = $false
            if ($fbAns -and $fbAns.Trim().ToLowerInvariant() -eq "y") { $useFileBot = $true }

            # Ask root folder
            $promptLabel = if ($selection -eq "3") { "Enter TV root path to process" } else { "Enter Movies root path to process" }
            $path = Read-Host $promptLabel
            if (-not $path -or $path.Trim() -eq "") {
                Write-Host "No path provided. Returning to menu." -ForegroundColor Yellow
                Pause-ReturnMenu
                continue
            }

            $invokeArgs = @{}
            $invokeArgs.RootPath = $path

            # Mode mapping matches your existing script behavior (1=TV-720p, 2=Movies-1080p)
            if ($selection -eq "3") { $invokeArgs.Mode = "TV" }
			if ($selection -eq "4") { $invokeArgs.Mode = "MOVIES" }

            $invokeArgs.MaxTotalInputGB = $MaxTotalInputGB
            $invokeArgs.ConcurrentJobs = $ConcurrentJobs
            $invokeArgs.EncoderMode = $EncoderMode
            $invokeArgs.Quality = $Quality
            $invokeArgs.AudioBitrateKbps = $AudioBitrateKbps
            if ($BackupOriginal) { $invokeArgs.BackupOriginal = $true }
            if ($DryRun) { $invokeArgs.DryRun = $true }
            if ($useFileBot) { $invokeArgs.EnableFileBotRename = $true }

            try {
                Invoke-VideoConvertCore -InvokeArgs $invokeArgs
            }
            catch {
                Write-Host $_ -ForegroundColor Red
            }

            Pause-ReturnMenu
            continue
        }

        Write-Host "Invalid selection." -ForegroundColor Yellow
    }

}
finally {
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
    Write-Host "Diagnostic log: $DiagLog" -ForegroundColor DarkGray
}