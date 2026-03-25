[CmdletBinding()]
param(
    [string]$SourcePath = "",
    [string]$OutputRoot = "",
    [int]$SeasonNumber = -1,
    [switch]$EnableFileBotRename,
    [switch]$FileBotTestRun,
    [switch]$BackupOriginal,
    [switch]$DryRun,
    [ValidateSet("Auto","NVENC","AMDVCE","X264")]
    [string]$EncoderMode = "Auto",
    [ValidateRange(16,30)]
    [int]$Quality = 23,
    [ValidateRange(96,320)]
    [int]$AudioBitrateKbps = 160,
    [ValidateRange(60,3600)]
    [int]$SkipUnderSeconds = 300,
    [ValidateRange(60,3600)]
    [int]$EpisodeMinSeconds = 1200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonCore = Join-Path $PSScriptRoot "lib\Common-Core.ps1"
if (-not (Test-Path -LiteralPath $commonCore)) {
    throw "Missing shared library: $commonCore"
}
. $commonCore

$repoRoot     = Get-RepoRoot
$toolStatus   = Assert-CoreToolsPresent -RepoRoot $repoRoot
$profilePath  = Assert-HardwareProfilePresent -RepoRoot $repoRoot
$profile      = Read-HardwareProfile -RepoRoot $repoRoot

$logsRoot      = Ensure-Directory -Path (Get-LogsRoot -RepoRoot $repoRoot)
$convertedRoot = Ensure-Directory -Path (Get-ConvertedRoot -RepoRoot $repoRoot)
$failedRoot    = Ensure-Directory -Path (Get-FailedRoot -RepoRoot $repoRoot)

$runStamp         = New-RunStamp
$logFile          = Join-Path $logsRoot ("Start-DVD-TV-{0}.log" -f $runStamp)
$failedCsv        = Join-Path $failedRoot ("Start-DVD-TV-Failed-{0}.csv" -f $runStamp)
$completedCsvPath = Join-Path $convertedRoot "DVD-TV-Completed.csv"

$FfprobePath      = $toolStatus.Tools.Ffprobe
$HandBrakeCliPath = $toolStatus.Tools.HandBrakeCli
$FileBotPath      = $toolStatus.Tools.FileBot

if ($EnableFileBotRename -and -not $FileBotPath) {
    throw "FileBot rename was enabled but FileBot was not found."
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO",
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message
    try { Write-Host $line -ForegroundColor $Color } catch { Write-Host $line }
    Add-Content -Path $logFile -Value $line
}

function Read-NonEmptyValue([string]$Prompt) {
    while ($true) {
        $v = Read-Host $Prompt
        if ($v -and $v.Trim()) { return $v.Trim() }
    }
}

function Ensure-CompletedCsvReady {
    param([Parameter(Mandatory)][string]$Path)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        "Timestamp,InputPath,OutputPath,Status,Notes,FileSizeBytes,LastWriteTimeUtc" | Out-File -FilePath $Path -Encoding UTF8
    }
}

$script:CompletedIndex = @{}

function Load-CompletedIndex {
    param([Parameter(Mandatory)][string]$Path)

    Ensure-CompletedCsvReady -Path $Path
    try {
        $rows = Import-Csv -Path $Path
        foreach ($r in $rows) {
            if (-not $r.InputPath) { continue }
            $script:CompletedIndex[$r.InputPath] = [pscustomobject]@{
                Status           = [string]$r.Status
                FileSizeBytes    = [int64]$r.FileSizeBytes
                LastWriteTimeUtc = [string]$r.LastWriteTimeUtc
            }
        }
        Write-Log ("Loaded Completed DB: {0} entries" -f $script:CompletedIndex.Count) "INFO" "DarkGray"
    }
    catch {
        Write-Log ("Could not read Completed DB: {0}" -f $_.Exception.Message) "WARN" "Yellow"
    }
}

function Get-FileIdentity {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($fi) {
            return [pscustomobject]@{
                FileSizeBytes    = [int64]$fi.Length
                LastWriteTimeUtc = $fi.LastWriteTimeUtc.ToString("o")
            }
        }
    }

    return [pscustomobject]@{
        FileSizeBytes    = 0L
        LastWriteTimeUtc = ""
    }
}

function Is-CompletedTerminal {
    param([Parameter(Mandatory)][string]$InputPath)

    if (-not $script:CompletedIndex.ContainsKey($InputPath)) { return $false }

    $rec = $script:CompletedIndex[$InputPath]
    if ($rec.Status -notin @("Success","Skipped")) { return $false }

    if (-not (Test-Path -LiteralPath $InputPath)) { return $true }

    $id = Get-FileIdentity -Path $InputPath
    return ($id.FileSizeBytes -eq [int64]$rec.FileSizeBytes -and $id.LastWriteTimeUtc -eq [string]$rec.LastWriteTimeUtc)
}

function Add-CompletedRecord {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [string]$OutputPath,
        [Parameter(Mandatory)][string]$Status,
        [string]$Notes
    )

    if ($DryRun) { return }

    Ensure-CompletedCsvReady -Path $completedCsvPath
    $id = Get-FileIdentity -Path $InputPath

    $row = [pscustomobject]@{
        Timestamp        = (Get-Date).ToString("s")
        InputPath        = $InputPath
        OutputPath       = $OutputPath
        Status           = $Status
        Notes            = $Notes
        FileSizeBytes    = [int64]$id.FileSizeBytes
        LastWriteTimeUtc = [string]$id.LastWriteTimeUtc
    }

    $csvLine = ($row | ConvertTo-Csv -NoTypeInformation)[1]
    Add-Content -Path $completedCsvPath -Value $csvLine -Encoding UTF8

    $script:CompletedIndex[$InputPath] = [pscustomobject]@{
        Status           = $Status
        FileSizeBytes    = [int64]$id.FileSizeBytes
        LastWriteTimeUtc = [string]$id.LastWriteTimeUtc
    }
}

function Get-MountedDriveLetter {
    param([Parameter(Mandatory)][string]$ImagePath)

    $vols = Get-DiskImage -ImagePath $ImagePath | Get-Volume -ErrorAction SilentlyContinue
    if ($vols -and $vols.DriveLetter) { return ($vols.DriveLetter + ":") }
    return $null
}

function Parse-HandBrakeScanTitles {
    param([Parameter(Mandatory)][string[]]$ScanLines)

    $titles = @()
    $current = $null

    foreach ($line in $ScanLines) {
        if ($line -match "title\s+(\d+):") {
            if ($current) { $titles += $current }
            $current = [ordered]@{
                Title       = [int]$Matches[1]
                DurationSec = 0
            }
            continue
        }

        if ($current -and $line -match "duration:\s+(\d+):(\d+):(\d+)") {
            $h = [int]$Matches[1]
            $m = [int]$Matches[2]
            $s = [int]$Matches[3]
            $current.DurationSec = ($h * 3600) + ($m * 60) + $s
        }
    }

    if ($current) { $titles += $current }
    return $titles
}

function Get-HandBrakeEncoder {
    param(
        [Parameter(Mandatory)][string]$HandBrakeCliPath,
        [Parameter(Mandatory)][string]$Mode
    )

    switch ($Mode) {
        "X264"   { return "x264" }
        "NVENC"  { return "nvenc_h264" }
        "AMDVCE" { return "vce_h264" }
    }

    if ($profile -and $profile.Recommendations -and $profile.Recommendations.PreferredEncoderMode) {
        switch ([string]$profile.Recommendations.PreferredEncoderMode) {
            "NVENC"  { return "nvenc_h264" }
            "AMDVCE" { return "vce_h264" }
            "X264"   { return "x264" }
        }
    }

    $help = & $HandBrakeCliPath --help 2>&1 | Out-String
    if ($help -match "nvenc_h264") { return "nvenc_h264" }
    if ($help -match "vce_h264")   { return "vce_h264" }
    return "x264"
}

function Get-VideoInfo {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$FfprobePath
    )

    $result = [ordered]@{
        Success         = $false
        Error           = ""
        Width           = 0
        Height          = 0
        DurationSeconds = 0.0
    }

    try {
        $json = & $FfprobePath -v error -show_entries stream=width,height:format=duration -of json -- $FilePath 2>$null | ConvertFrom-Json
        $video = $json.streams | Select-Object -First 1
        if ($video) {
            if ($video.width)  { $result.Width = [int]$video.width }
            if ($video.height) { $result.Height = [int]$video.height }
        }
        if ($json.format -and $json.format.duration) {
            $result.DurationSeconds = [double]$json.format.duration
        }
        $result.Success = $true
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Invoke-FileBotTvRename {
    param(
        [Parameter(Mandatory)][string]$FileBotPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [switch]$TestRun
    )

    $action = if ($TestRun) { "test" } else { "rename" }
    $format = "{n} - {s00e00} - {vf}{if(imdbid) ' ('+imdbid+')'}{'.'}{ext}"

    & $FileBotPath `
        -rename $TargetPath `
        --db "TheMovieDB::TV" `
        --format $format `
        --action $action `
        --conflict auto `
        --log all `
        -non-strict | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "FileBot failed (exit $LASTEXITCODE)"
    }
}

function Get-TitleBucket {
    param(
        [Parameter(Mandatory)][int]$DurationSec,
        [Parameter(Mandatory)][int]$SkipUnderSeconds,
        [Parameter(Mandatory)][int]$EpisodeMinSeconds
    )

    if ($DurationSec -lt $SkipUnderSeconds) { return "SKIP" }
    if ($DurationSec -lt $EpisodeMinSeconds) { return "SPECIAL" }
    return "EPISODE"
}

Load-CompletedIndex -Path $completedCsvPath

if (-not $SourcePath -or $SourcePath.Trim() -eq "") {
    $SourcePath = Read-NonEmptyValue "Enter DVD source path (.iso, .img, or VIDEO_TS folder)"
}
if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Source path not found: $SourcePath"
}

if (-not $OutputRoot -or $OutputRoot.Trim() -eq "") {
    $OutputRoot = Read-NonEmptyValue "Enter TV show output root (show folder)"
}
Ensure-Directory -Path $OutputRoot | Out-Null

if ($SeasonNumber -lt 0) {
    $SeasonNumber = [int](Read-NonEmptyValue "Enter season number for regular episodes")
}

$sourceItem = Get-Item -LiteralPath $SourcePath
$isFolder = $sourceItem.PSIsContainer
$isDiscImage = ($sourceItem.Extension.ToLower() -in @(".iso", ".img"))
$isVideoTsFolder = $false

if ($isFolder) {
    $videoTsSub = Join-Path $SourcePath "VIDEO_TS"
    if (Test-Path -LiteralPath $videoTsSub) {
        $isVideoTsFolder = $true
    }
    else {
        $ifo = Get-ChildItem -LiteralPath $SourcePath -Filter "*.IFO" -ErrorAction SilentlyContinue
        if ($ifo | Select-Object -First 1) { $isVideoTsFolder = $true }
    }
}

if (-not $isDiscImage -and -not $isVideoTsFolder) {
    throw "Source must be an .iso, .img, or a VIDEO_TS-style folder."
}

if (Is-CompletedTerminal -InputPath $SourcePath) {
    Write-Log ("SKIP (db): {0}" -f $SourcePath) "INFO" "DarkGray"
    return
}

$hbEncoder = Get-HandBrakeEncoder -HandBrakeCliPath $HandBrakeCliPath -Mode $EncoderMode

$seasonFolder   = Join-Path $OutputRoot ("Season {0:D2}" -f $SeasonNumber)
$specialsFolder = Join-Path $OutputRoot "Season 00"
$reviewFolder   = Join-Path $OutputRoot "_NeedsReview"

Ensure-Directory -Path $seasonFolder | Out-Null
Ensure-Directory -Path $specialsFolder | Out-Null
Ensure-Directory -Path $reviewFolder | Out-Null

Write-Log "=== START DVD TV IMPORT ===" "INFO" "Cyan"
Write-Log ("SourcePath: {0}" -f $SourcePath) "INFO" "Gray"
Write-Log ("OutputRoot: {0}" -f $OutputRoot) "INFO" "Gray"
Write-Log ("SeasonNumber: {0}" -f $SeasonNumber) "INFO" "Gray"
Write-Log ("Profile: {0}" -f $profilePath) "INFO" "Gray"
Write-Log ("Encoder: {0}" -f $hbEncoder) "INFO" "Gray"
Write-Log ("Quality: {0}" -f $Quality) "INFO" "Gray"
Write-Log ("AudioBitrateKbps: {0}" -f $AudioBitrateKbps) "INFO" "Gray"
Write-Log ("SkipUnderSeconds: {0}" -f $SkipUnderSeconds) "INFO" "Gray"
Write-Log ("EpisodeMinSeconds: {0}" -f $EpisodeMinSeconds) "INFO" "Gray"
Write-Log ("DryRun: {0}" -f $DryRun) "INFO" "Gray"
Write-Log ("EnableFileBotRename: {0}" -f $EnableFileBotRename) "INFO" "Gray"

$mounted = $false
$hbInput = $null
$createdFiles = @()
$failedList = @()

try {
    if ($isVideoTsFolder) {
        $hbInput = $SourcePath
    }
    else {
        if (-not $DryRun) {
            Mount-DiskImage -ImagePath $SourcePath -ErrorAction Stop | Out-Null
            $mounted = $true
            Start-Sleep -Milliseconds 750
        }

        $drive = if ($DryRun) { "X:" } else { Get-MountedDriveLetter -ImagePath $SourcePath }
        if (-not $drive) { throw "Could not determine mounted drive letter." }

        $videoTs = Join-Path $drive "VIDEO_TS"
        $hbInput = if (Test-Path -LiteralPath $videoTs) { $videoTs } else { $drive }
    }

    Write-Log ("Scan Input: {0}" -f $hbInput) "INFO" "Gray"

    $titles = @()
    if ($DryRun) {
        $titles = @(
            [pscustomobject]@{ Title = 1; DurationSec = 1440 },
            [pscustomobject]@{ Title = 2; DurationSec = 1460 },
            [pscustomobject]@{ Title = 3; DurationSec = 620 }
        )
    }
    else {
        $scanLines = & $HandBrakeCliPath -i $hbInput --scan 2>&1
        $titles = Parse-HandBrakeScanTitles -ScanLines $scanLines
    }

    if (-not $titles -or $titles.Count -eq 0) {
        throw "No titles found in HandBrake scan."
    }

    foreach ($t in $titles) {
        $bucket = Get-TitleBucket -DurationSec $t.DurationSec -SkipUnderSeconds $SkipUnderSeconds -EpisodeMinSeconds $EpisodeMinSeconds
        Write-Log ("Detected title {0}: {1} sec -> {2}" -f $t.Title, $t.DurationSec, $bucket) "INFO" "DarkGray"
    }

    $episodeIndex = 1
    $specialIndex = 1

    foreach ($title in $titles) {
        $bucket = Get-TitleBucket -DurationSec $title.DurationSec -SkipUnderSeconds $SkipUnderSeconds -EpisodeMinSeconds $EpisodeMinSeconds

        if ($bucket -eq "SKIP") {
            Write-Log ("Skipping short title {0} ({1} sec)" -f $title.Title, $title.DurationSec) "WARN" "Yellow"
            continue
        }

        $targetFolder = if ($bucket -eq "SPECIAL") { $specialsFolder } else { $seasonFolder }
        if ($title.DurationSec -ge 5400) {
            $targetFolder = $reviewFolder
        }

        $baseName = if ($bucket -eq "SPECIAL") {
            "title-special-{0:D2}" -f $specialIndex
        }
        else {
            "title-episode-{0:D2}" -f $episodeIndex
        }

        $tempOut  = Join-Path $targetFolder ($baseName + ".tmp.mp4")
        $finalOut = Join-Path $targetFolder ($baseName + ".mp4")

        if ($DryRun) {
            Write-Log ("[DRYRUN] Would encode title {0} -> {1}" -f $title.Title, $finalOut) "INFO" "Magenta"
        }
        else {
            if (Test-Path -LiteralPath $tempOut)  { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $finalOut) { Remove-Item -LiteralPath $finalOut -Force -ErrorAction SilentlyContinue }

            $hbArgs = @(
                "-i", $hbInput,
                "-o", $tempOut,
                "--title", "$($title.Title)",
                "--encoder", $hbEncoder,
                "--quality", "$Quality",
                "--maxWidth", "1280",
                "--maxHeight", "720",
                "--cfr",
                "-E", "av_aac",
                "-B", "$AudioBitrateKbps",
                "--mixdown", "stereo",
                "--optimize"
            )

            & $HandBrakeCliPath @hbArgs 2>&1 | Out-Null
            $exit = $LASTEXITCODE

            if ($exit -ne 0 -or -not (Test-Path -LiteralPath $tempOut)) {
                throw ("HandBrake encode failed for title {0} (exit {1})" -f $title.Title, $exit)
            }

            $probe = Get-VideoInfo -FilePath $tempOut -FfprobePath $FfprobePath
            if (-not $probe.Success -or -not $probe.Width -or -not $probe.Height) {
                throw ("Encoded file validation failed for title {0}" -f $title.Title)
            }

            Move-Item -LiteralPath $tempOut -Destination $finalOut -Force
            Write-Log ("Created: {0}" -f $finalOut) "INFO" "Green"
            $createdFiles += $finalOut

            if ($bucket -eq "SPECIAL") { $specialIndex++ } else { $episodeIndex++ }
        }
    }

    if ($EnableFileBotRename -and -not $DryRun -and $createdFiles.Count -gt 0) {
        try {
            Invoke-FileBotTvRename -FileBotPath $FileBotPath -TargetPath $OutputRoot -TestRun:$FileBotTestRun
            Write-Log "FileBot TV rename completed." "INFO" "Green"
        }
        catch {
            Write-Log ("FileBot rename failed: {0}" -f $_.Exception.Message) "WARN" "Yellow"
        }
    }

    if ($BackupOriginal -and -not $DryRun -and -not $isVideoTsFolder) {
        $origDir = Join-Path (Split-Path -Parent $SourcePath) "Originals"
        Ensure-Directory -Path $origDir | Out-Null
        Move-Item -LiteralPath $SourcePath -Destination (Join-Path $origDir (Split-Path -Leaf $SourcePath)) -Force
        Write-Log "Original source moved to Originals folder." "INFO" "DarkGray"
    }

    Add-CompletedRecord -InputPath $SourcePath -OutputPath $OutputRoot -Status "Success" -Notes "DVD TV import complete"
}
catch {
    $msg = $_.Exception.Message
    Write-Log ("FAILED: {0} :: {1}" -f $SourcePath, $msg) "ERROR" "Red"
    $failedList += [pscustomobject]@{
        File   = $SourcePath
        Reason = $msg
        Log    = $logFile
    }
    try { Add-CompletedRecord -InputPath $SourcePath -OutputPath "" -Status "Failed" -Notes $msg } catch {}
}
finally {
    if ($mounted -and -not $DryRun) {
        try {
            Dismount-DiskImage -ImagePath $SourcePath -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }

    if (Test-Path -LiteralPath $OutputRoot) {
        Get-ChildItem -LiteralPath $OutputRoot -Recurse -Filter "*.tmp.mp4" -ErrorAction SilentlyContinue |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
            }
    }

    if ($failedList.Count -gt 0) {
        $failedList | Export-Csv -Path $failedCsv -NoTypeInformation -Encoding UTF8
        Write-Log ("Failed file list written to: {0}" -f $failedCsv) "WARN" "Yellow"
    }

    Write-Log "=== COMPLETE DVD TV IMPORT ===" "INFO" "Cyan"
}