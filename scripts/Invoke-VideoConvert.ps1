[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RootPath,

    [ValidateSet("TV","MOVIES")]
    [string]$Mode = "TV",

    [string]$OutputRoot = "",

    [switch]$EnableFileBotRename,
    [switch]$FileBotTestRun,
    [switch]$BackupOriginal,
    [switch]$DryRun,

    [double]$MaxTotalInputGB = 0,

    [ValidateRange(1,16)]
    [int]$ConcurrentJobs = 2,

    [ValidateSet("Auto","NVENC","AMDVCE","X264")]
    [string]$EncoderMode = "Auto",

    [ValidateRange(16,30)]
    [int]$Quality = 23,

    [ValidateRange(96,320)]
    [int]$AudioBitrateKbps = 160
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonCore = Join-Path $PSScriptRoot "lib\Common-Core.ps1"
if (-not (Test-Path -LiteralPath $commonCore)) {
    throw "Missing shared library: $commonCore"
}
. $commonCore

$repoRoot = Get-RepoRoot
$toolStatus = Assert-CoreToolsPresent -RepoRoot $repoRoot
$profilePath = Assert-HardwareProfilePresent -RepoRoot $repoRoot
$hardwareProfile = Read-HardwareProfile -RepoRoot $repoRoot

if (-not (Test-Path -LiteralPath $RootPath)) {
    throw "RootPath not found: $RootPath"
}

if ($OutputRoot -and $OutputRoot.Trim()) {
    Ensure-Directory -Path $OutputRoot | Out-Null
}

$logsRoot = Ensure-Directory -Path (Get-LogsRoot -RepoRoot $repoRoot)
$convertedRoot = Ensure-Directory -Path (Get-ConvertedRoot -RepoRoot $repoRoot)
$failedRoot = Ensure-Directory -Path (Get-FailedRoot -RepoRoot $repoRoot)

$runStamp = New-RunStamp
$logFile = Join-Path $logsRoot ("Invoke-VideoConvert-{0}.log" -f $runStamp)
$failedCsv = Join-Path $failedRoot ("Invoke-VideoConvert-Failed-{0}.csv" -f $runStamp)

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

switch ($Mode.ToUpperInvariant()) {
    "TV" {
        $ModeLabel = "TV-720p"
        $TargetMaxWidth  = 1280
        $TargetMaxHeight = 720
        $AllowMaxWidth   = 1280
        $AllowMaxHeight  = 720
        $FileBotDb       = "TheMovieDB::TV"
        $FileBotFormat   = "{n} - {s00e00} - {vf}{if(imdbid) ' ('+imdbid+')'}{'.'}{ext}"
    }
    "MOVIES" {
        $ModeLabel = "Movies-1080p"
        $TargetMaxWidth  = 1920
        $TargetMaxHeight = 1080
        $AllowMaxWidth   = 1920
        $AllowMaxHeight  = 1080
        $FileBotDb       = "TheMovieDB"
        $FileBotFormat   = "{n} ({y}) - {vf}{if(imdbid) ' ('+imdbid+')'}{'.'}{ext}"
    }
    default {
        throw "Unsupported mode: $Mode"
    }
}

$CompletedCsvPath = Join-Path $convertedRoot ("{0}-Completed.csv" -f $ModeLabel)

$FfmpegPath       = $toolStatus.Tools.Ffmpeg
$FfprobePath      = $toolStatus.Tools.Ffprobe
$HandBrakeCliPath = $toolStatus.Tools.HandBrakeCli
$FileBotPath      = $toolStatus.Tools.FileBot

if ($EnableFileBotRename -and -not $FileBotPath) {
    throw "FileBot rename was enabled but FileBot was not found."
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

    Ensure-CompletedCsvReady -Path $CompletedCsvPath
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
    Add-Content -Path $CompletedCsvPath -Value $csvLine -Encoding UTF8

    $script:CompletedIndex[$InputPath] = [pscustomobject]@{
        Status           = $Status
        FileSizeBytes    = [int64]$id.FileSizeBytes
        LastWriteTimeUtc = [string]$id.LastWriteTimeUtc
    }
}

function Invoke-FfprobeJson {
    param([Parameter(Mandatory)][string[]]$Args)
    $out = & $FfprobePath @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed (exit $LASTEXITCODE)" }
    return ($out | ConvertFrom-Json)
}

function Convert-TagDurationToSeconds {
    param([Parameter(Mandatory)][string]$TagDuration)

    if ($TagDuration -match '^(?<h>\d+):(?<m>\d+):(?<s>\d+)(\.(?<frac>\d+))?$') {
        $h = [int]$Matches.h
        $m = [int]$Matches.m
        $s = [int]$Matches.s
        $ms = 0
        if ($Matches.frac) {
            $ms = [int]($Matches.frac.Substring(0, [Math]::Min(3, $Matches.frac.Length)))
        }
        return ($h * 3600 + $m * 60 + $s + ($ms / 1000.0))
    }

    return 0.0
}

function Get-VideoInfo {
    param([Parameter(Mandatory)][string]$Path)

    $r = [ordered]@{
        Success           = $false
        Error             = ""
        Ext               = ([IO.Path]::GetExtension($Path)).ToLower()
        Width             = 0
        Height            = 0
        VideoCodec        = ""
        AudioStreams      = @()
        FormatDurationSec = 0
        VideoDurationSec  = 0
        TagDurationSec    = 0
        DurationSec       = 0
    }

    try {
        $vObj = Invoke-FfprobeJson @("-v","error","-print_format","json","-select_streams","v:0","-show_entries","stream=codec_name,width,height,duration:stream_tags=DURATION","--",$Path)
        if ($vObj.streams -and $vObj.streams.Count -gt 0) {
            $v = $vObj.streams[0]
            if ($v.width)      { $r.Width      = [int]$v.width }
            if ($v.height)     { $r.Height     = [int]$v.height }
            if ($v.codec_name) { $r.VideoCodec = [string]$v.codec_name }
            if ($v.duration) {
                try { $r.VideoDurationSec = [int][Math]::Round([double]$v.duration, 0) } catch {}
            }
            if ($v.tags -and $v.tags.DURATION) {
                $td = Convert-TagDurationToSeconds -TagDuration ([string]$v.tags.DURATION)
                if ($td -gt 0) { $r.TagDurationSec = [int][Math]::Round($td, 0) }
            }
        }

        $aObj = Invoke-FfprobeJson @("-v","error","-print_format","json","-select_streams","a","-show_entries","stream=codec_name,channels","--",$Path)
        $aud = @()
        if ($aObj.streams) {
            foreach ($a in $aObj.streams) {
                $aud += [pscustomobject]@{
                    Codec    = [string]$a.codec_name
                    Channels = [int]$(if ($null -ne $a.channels) { $a.channels } else { 0 })
                }
            }
        }
        $r.AudioStreams = $aud

        $fObj = Invoke-FfprobeJson @("-v","error","-print_format","json","-show_entries","format=duration:format_tags=DURATION","--",$Path)
        if ($fObj.format -and $fObj.format.duration) {
            try { $r.FormatDurationSec = [int][Math]::Round([double]$fObj.format.duration, 0) } catch {}
        }
        if ($r.TagDurationSec -le 0 -and $fObj.format -and $fObj.format.tags -and $fObj.format.tags.DURATION) {
            $td = Convert-TagDurationToSeconds -TagDuration ([string]$fObj.format.tags.DURATION)
            if ($td -gt 0) { $r.TagDurationSec = [int][Math]::Round($td, 0) }
        }

        if ($r.VideoDurationSec -gt 0)      { $r.DurationSec = $r.VideoDurationSec }
        elseif ($r.FormatDurationSec -gt 0) { $r.DurationSec = $r.FormatDurationSec }
        elseif ($r.TagDurationSec -gt 0)    { $r.DurationSec = $r.TagDurationSec }
        else                                { $r.DurationSec = 0 }

        $r.Success = $true
    }
    catch {
        $r.Error = $_.Exception.Message
    }

    return [pscustomobject]$r
}

function Has-AacStereo {
    param([Parameter(Mandatory)]$AudioStreams)
    foreach ($a in $AudioStreams) {
        if ($a.Codec -eq "aac" -and $a.Channels -eq 2) { return $true }
    }
    return $false
}

function Validate-ConvertedFile {
    param(
        [string]$OriginalPath,
        [Parameter(Mandatory)][string]$ConvertedPath
    )

    if (-not (Test-Path -LiteralPath $ConvertedPath)) { return $false }

    $newInfo = Get-VideoInfo -Path $ConvertedPath
    if (-not $newInfo.Success) { return $false }

    if ($OriginalPath -and (Test-Path -LiteralPath $OriginalPath)) {
        $origInfo = Get-VideoInfo -Path $OriginalPath
        if ($origInfo.Success -and $origInfo.DurationSec -gt 0 -and $newInfo.DurationSec -gt 0) {
            $delta = [Math]::Abs($origInfo.DurationSec - $newInfo.DurationSec)
            $allowed = [Math]::Max(30, [int][Math]::Ceiling($origInfo.DurationSec * 0.005))
            if ($delta -gt $allowed) { return $false }
        }
    }

    return $true
}

function Remux-TsToMkv {
    param([Parameter(Mandatory)][string]$TsPath)

    $dir = Split-Path -Parent $TsPath
    $name = [IO.Path]::GetFileNameWithoutExtension($TsPath)
    $out = Join-Path $dir ($name + ".tsremux.mkv")

    if ($DryRun) { return $out }

    if (Test-Path -LiteralPath $out) {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }

    & $FfmpegPath "-y" "-hide_banner" "-fflags" "+genpts" "-i" $TsPath "-map" "0:v:0" "-map" "0:a?" "-c" "copy" $out | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) {
        throw "TS remux failed (exit $LASTEXITCODE)"
    }

    return $out
}

function Remux-FileToMkv {
    param([Parameter(Mandatory)][string]$InputPath)

    $dir = Split-Path -Parent $InputPath
    $name = [IO.Path]::GetFileNameWithoutExtension($InputPath)
    $out = Join-Path $dir ($name + ".fixremux.mkv")

    if ($DryRun) { return $out }

    if (Test-Path -LiteralPath $out) {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }

    & $FfmpegPath "-y" "-hide_banner" "-fflags" "+genpts" "-err_detect" "ignore_err" "-i" $InputPath "-map" "0" "-c" "copy" $out | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) {
        throw "Remux failed (exit $LASTEXITCODE)"
    }

    return $out
}

function Replace-WithBackup {
    param(
        [Parameter(Mandatory)][string]$OriginalPath,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][string]$NewFilePath,
        [Parameter(Mandatory)][bool]$BackupOriginal
    )

    $backupPath = $null

    try {
        if (-not (Test-Path -LiteralPath $NewFilePath)) {
            throw "New file missing: $NewFilePath"
        }

        $origDir = Split-Path -Parent $OriginalPath
        $origName = Split-Path -Leaf $OriginalPath
        $backupDir = Join-Path $origDir "Originals"

        if (-not (Test-Path -LiteralPath $backupDir)) {
            New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
        }

        if (Test-Path -LiteralPath $OriginalPath) {
            $backupPath = Join-Path $backupDir $origName
            if (Test-Path -LiteralPath $backupPath) {
                $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $base = [IO.Path]::GetFileNameWithoutExtension($origName)
                $ext = [IO.Path]::GetExtension($origName)
                $backupPath = Join-Path $backupDir ("{0}-{1}{2}" -f $base, $stamp, $ext)
            }
            Move-Item -LiteralPath $OriginalPath -Destination $backupPath -Force
        }

        if (Test-Path -LiteralPath $FinalPath) {
            Remove-Item -LiteralPath $FinalPath -Force -ErrorAction SilentlyContinue
        }

        $targetParent = Split-Path -Parent $FinalPath
        if ($targetParent -and -not (Test-Path -LiteralPath $targetParent)) {
            New-Item -Path $targetParent -ItemType Directory -Force | Out-Null
        }

        Move-Item -LiteralPath $NewFilePath -Destination $FinalPath -Force

        if ($backupPath -and -not $BackupOriginal) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }

        return $true
    }
    catch {
        if ($backupPath -and (Test-Path -LiteralPath $backupPath) -and -not (Test-Path -LiteralPath $OriginalPath)) {
            try { Move-Item -LiteralPath $backupPath -Destination $OriginalPath -Force } catch {}
        }
        return $false
    }
}

function Select-HandBrakeEncoder {
    param([Parameter(Mandatory)][string]$Mode)

    switch ($Mode) {
        "X264"   { return "x264" }
        "NVENC"  { return "nvenc_h264" }
        "AMDVCE" { return "vce_h264" }
    }

    if ($hardwareProfile -and $hardwareProfile.Recommendations -and $hardwareProfile.Recommendations.PreferredEncoderMode) {
        switch ([string]$hardwareProfile.Recommendations.PreferredEncoderMode) {
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

$SelectedHbEncoder = Select-HandBrakeEncoder -Mode $EncoderMode

function Encode-WithHandBrake {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$TempOut
    )

    if ($DryRun) { return 0 }

    $args = @(
        "-i", $InputPath,
        "-o", $TempOut,
        "--encoder", $SelectedHbEncoder,
        "--quality", "$Quality",
        "--maxWidth", "$TargetMaxWidth",
        "--maxHeight", "$TargetMaxHeight",
        "--cfr",
        "-E", "av_aac",
        "-B", "$AudioBitrateKbps",
        "--mixdown", "stereo",
        "--optimize"
    )

    & $HandBrakeCliPath @args 2>&1 | Out-Null
    return $LASTEXITCODE
}

function Invoke-FileBotRename {
    param([Parameter(Mandatory)][string]$TargetPath)

    if (-not $EnableFileBotRename) { return }
    if ($DryRun) { return }

    $action = if ($FileBotTestRun) { "test" } else { "rename" }

    & $FileBotPath `
        -rename $TargetPath `
        --db $FileBotDb `
        --format $FileBotFormat `
        --action $action `
        --conflict auto `
        --log all `
        -non-strict | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "FileBot failed (exit $LASTEXITCODE)"
    }
}

function Get-RelativeSubPath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$ChildPath
    )

    $baseFull  = [IO.Path]::GetFullPath($BasePath)
    $childFull = [IO.Path]::GetFullPath($ChildPath)

    if ($childFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $childFull.Substring($baseFull.Length).TrimStart('\')
        return $relative
    }

    return (Split-Path -Leaf $ChildPath)
}

function Get-FinalOutputPath {
    param(
        [Parameter(Mandatory)][string]$InputFilePath,
        [Parameter(Mandatory)][string]$BaseRoot,
        [string]$OutRoot,
        [Parameter(Mandatory)][string]$Mode
    )

    $sourceDir = Split-Path -Parent $InputFilePath
    $name = [IO.Path]::GetFileNameWithoutExtension($InputFilePath) + ".mp4"

    if (-not $OutRoot -or -not $OutRoot.Trim()) {
        return (Join-Path $sourceDir $name)
    }

    $rel = Get-RelativeSubPath -BasePath $BaseRoot -ChildPath $sourceDir
    $targetDir = if ($rel) { Join-Path $OutRoot $rel } else { $OutRoot }

    Ensure-Directory -Path $targetDir | Out-Null
    return (Join-Path $targetDir $name)
}

Load-CompletedIndex -Path $CompletedCsvPath

Write-Log "=== START ===" "INFO" "Cyan"
Write-Log ("RootPath: {0}" -f $RootPath) "INFO" "Gray"
Write-Log ("Mode: {0}" -f $Mode) "INFO" "Gray"
Write-Log ("Profile: {0}" -f $profilePath) "INFO" "Gray"
Write-Log ("OutputRoot: {0}" -f $(if ($OutputRoot) { $OutputRoot } else { "[in-place]" })) "INFO" "Gray"
Write-Log ("Target: {0}x{1}" -f $TargetMaxWidth, $TargetMaxHeight) "INFO" "Gray"
Write-Log ("Encoder: {0}" -f $SelectedHbEncoder) "INFO" "Gray"
Write-Log ("DryRun: {0}" -f $DryRun) "INFO" "Gray"
Write-Log ("BackupOriginal: {0}" -f $BackupOriginal) "INFO" "Gray"
Write-Log ("EnableFileBotRename: {0}" -f $EnableFileBotRename) "INFO" "Gray"

$VideoExtensions = @(".mp4",".mkv",".mov",".m4v",".avi",".wmv",".ts")

$allFiles = Get-ChildItem -LiteralPath $RootPath -Recurse -Force -ErrorAction Continue |
    Where-Object { -not $_.PSIsContainer } |
    Where-Object { $VideoExtensions -contains $_.Extension.ToLower() } |
    Where-Object {
        ($_.FullName -notmatch "\\Originals\\") -and
        ($_.FullName -notmatch "\\Failed\\") -and
        ($_.FullName -notmatch "\\Converted\\") -and
        ($_.Name -notmatch "\.tmp\.mp4$") -and
        ($_.Name -notmatch "\.tsremux\.mkv$") -and
        ($_.Name -notmatch "\.fixremux\.mkv$")
    }

Write-Log ("Found {0} candidate files" -f $allFiles.Count) "INFO" "Cyan"

$processedInputGB = 0.0
$convertedCount = 0
$skippedCount = 0
$failedCount = 0
$failedList = @()

foreach ($file in $allFiles) {
    $filePath = $file.FullName
    $sourceDir = $file.DirectoryName
    $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $ext = $file.Extension.ToLower()

    try {
        if (Is-CompletedTerminal -InputPath $filePath) {
            Write-Log ("SKIP (db): {0}" -f $filePath) "INFO" "DarkGray"
            continue
        }

        $inputGB = [Math]::Round(($file.Length / 1GB), 3)
        if ($MaxTotalInputGB -gt 0 -and ($processedInputGB + $inputGB) -gt $MaxTotalInputGB) {
            Write-Log ("Reached MaxTotalInputGB limit ({0}). Stopping." -f $MaxTotalInputGB) "INFO" "Yellow"
            break
        }

        Write-Log ("Checking: {0}" -f $filePath) "INFO" "DarkGray"

        $finalOut = Get-FinalOutputPath -InputFilePath $filePath -BaseRoot $RootPath -OutRoot $OutputRoot -Mode $Mode
        $tempOutDir = Split-Path -Parent $finalOut
        $tempOut = Join-Path $tempOutDir ($name + ".tmp.mp4")

        if ($ext -eq ".ts") {
            if (Test-Path -LiteralPath $tempOut) {
                Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
            }

            $remux = Remux-TsToMkv -TsPath $filePath
            $exit = Encode-WithHandBrake -InputPath $remux -TempOut $tempOut

            if (-not $DryRun -and ($exit -ne 0 -or -not (Test-Path -LiteralPath $tempOut))) {
                throw "HandBrake failed for TS (exit $exit)"
            }

            if (-not $DryRun) {
                if (-not (Validate-ConvertedFile -OriginalPath $remux -ConvertedPath $tempOut)) {
                    throw "Validation failed for TS"
                }

                $ok = Replace-WithBackup -OriginalPath $filePath -FinalPath $finalOut -NewFilePath $tempOut -BackupOriginal:$BackupOriginal
                if (-not $ok) { throw "Replace-WithBackup failed for TS" }

                if (Test-Path -LiteralPath $remux) {
                    Remove-Item -LiteralPath $remux -Force -ErrorAction SilentlyContinue
                }

                try { Invoke-FileBotRename -TargetPath $finalOut } catch { Write-Log ("FileBot rename failed: {0}" -f $_.Exception.Message) "WARN" "Yellow" }
            }

            Add-CompletedRecord -InputPath $filePath -OutputPath $finalOut -Status "Success" -Notes "TS remux+convert"
            $processedInputGB += $inputGB
            $convertedCount++
            continue
        }

        $info = Get-VideoInfo -Path $filePath
        if (-not $info.Success) {
            throw ("ffprobe error: " + $info.Error)
        }

        $isCompliantVideo = ($info.VideoCodec -eq "h264" -and $info.Width -le $AllowMaxWidth -and $info.Height -le $AllowMaxHeight)
        $isCompliantAudio = Has-AacStereo -AudioStreams $info.AudioStreams
        $isCompliantMp4   = ($ext -eq ".mp4" -and $isCompliantVideo -and $isCompliantAudio)

        if ($isCompliantMp4) {
            Write-Log "  -> Already compliant, skipping" "INFO" "Green"

            if ($OutputRoot -and $OutputRoot.Trim()) {
                if (-not $DryRun) {
                    Ensure-Directory -Path (Split-Path -Parent $finalOut) | Out-Null
                    Copy-Item -LiteralPath $filePath -Destination $finalOut -Force
                    try { Invoke-FileBotRename -TargetPath $finalOut } catch { Write-Log ("FileBot rename failed: {0}" -f $_.Exception.Message) "WARN" "Yellow" }
                }
                Add-CompletedRecord -InputPath $filePath -OutputPath $finalOut -Status "Skipped" -Notes "Already compliant, copied to output root"
            }
            else {
                Add-CompletedRecord -InputPath $filePath -OutputPath $filePath -Status "Skipped" -Notes "Already compliant"
                if (-not $DryRun) {
                    try { Invoke-FileBotRename -TargetPath $filePath } catch { Write-Log ("FileBot rename failed: {0}" -f $_.Exception.Message) "WARN" "Yellow" }
                }
            }

            $processedInputGB += $inputGB
            $skippedCount++
            continue
        }

        if (Test-Path -LiteralPath $tempOut) {
            Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
        }

        $exit1 = Encode-WithHandBrake -InputPath $filePath -TempOut $tempOut
        if (-not $DryRun -and ($exit1 -ne 0 -or -not (Test-Path -LiteralPath $tempOut))) {
            throw "HandBrake failed (exit $exit1)"
        }

        if (-not $DryRun) {
            $validated = Validate-ConvertedFile -OriginalPath $filePath -ConvertedPath $tempOut

            if (-not $validated) {
                Write-Log "  -> Direct encode validation failed, trying remux repair" "WARN" "Yellow"

                $remux2 = $null
                try {
                    $remux2 = Remux-FileToMkv -InputPath $filePath
                    if (Test-Path -LiteralPath $tempOut) {
                        Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
                    }

                    $exit2 = Encode-WithHandBrake -InputPath $remux2 -TempOut $tempOut
                    if ($exit2 -ne 0 -or -not (Test-Path -LiteralPath $tempOut)) {
                        throw "Repair encode failed (exit $exit2)"
                    }

                    if (-not (Validate-ConvertedFile -OriginalPath $remux2 -ConvertedPath $tempOut)) {
                        throw "Validation failed after repair pass"
                    }
                }
                finally {
                    if ($remux2 -and (Test-Path -LiteralPath $remux2)) {
                        Remove-Item -LiteralPath $remux2 -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            $ok = Replace-WithBackup -OriginalPath $filePath -FinalPath $finalOut -NewFilePath $tempOut -BackupOriginal:$BackupOriginal
            if (-not $ok) { throw "Replace-WithBackup failed" }

            try { Invoke-FileBotRename -TargetPath $finalOut } catch { Write-Log ("FileBot rename failed: {0}" -f $_.Exception.Message) "WARN" "Yellow" }
        }

        Add-CompletedRecord -InputPath $filePath -OutputPath $finalOut -Status "Success" -Notes "Converted"
        $processedInputGB += $inputGB
        $convertedCount++
    }
    catch {
        $msg = $_.Exception.Message
        Write-Log ("FAILED: {0} :: {1}" -f $filePath, $msg) "ERROR" "Red"
        $failedList += [pscustomobject]@{
            File   = $filePath
            Reason = $msg
            Log    = $logFile
        }
        $failedCount++
        try { Add-CompletedRecord -InputPath $filePath -OutputPath "" -Status "Failed" -Notes $msg } catch {}
    }
}

Write-Log "=== COMPLETE ===" "INFO" "Cyan"
Write-Log ("Total input GB processed : {0}" -f $processedInputGB) "INFO" "Gray"
Write-Log ("Files converted          : {0}" -f $convertedCount) "INFO" "Gray"
Write-Log ("Files skipped            : {0}" -f $skippedCount) "INFO" "Gray"
Write-Log ("Files failed             : {0}" -f $failedCount) "INFO" "Gray"

if ($failedList.Count -gt 0) {
    $failedList | Export-Csv -Path $failedCsv -NoTypeInformation -Encoding UTF8
    Write-Log ("Failed file list written to: {0}" -f $failedCsv) "WARN" "Yellow"
}