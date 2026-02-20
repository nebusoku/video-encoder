<#
Portable Media Cleanup (PowerShell 5.1)

What this does
- One unified script with an interactive prompt:
  - Pick a root path
  - Pick mode: 1) TV (720p) or 2) Movies (1080p)
- Portable tool layout (relative to script folder):
  tools\ffmpeg\bin\ffmpeg.exe
  tools\ffmpeg\bin\ffprobe.exe
  tools\handbrake\HandBrakeCLI.exe
  tools\filebot\filebot.cmd   (preferred) OR tools\filebot\FileBot.exe
- Handles:
  - Regular video files: encode to MP4 when non-compliant
  - .ts: ffmpeg remux -> mkv -> HandBrake encode -> MP4
  - .iso/.img: mount -> HandBrake scan -> pick best title -> encode -> MP4
- Completed CSV “Mini DB” resume:
  - Writes a record for every file touched (Success/Skipped/Failed)
  - Skip items already terminal AND unchanged (Size + LastWriteTimeUtc)
- Validation:
  - Robust duration fallback using format.duration / stream.duration / tags.DURATION
  - Compares durations original vs converted with adaptive tolerance
- Optional FileBot renaming (portable):
  - Movies format (baked-in): {n} ({y}) - {vf} ({imdbid})   [implemented safely]
  - TV format (baked-in):     {n} - {s00e00} - {vf} ({imdbid}) [implemented safely]
- Optional multi-threading (runspace pool) for NON-disc-image files.
  - Disc images are processed sequentially to avoid mount collisions.

Notes
- GPU auto-detection chooses HandBrake encoder:
  - nvenc_h264 if available
  - vce_h264 if available
  - else x264 fallback
- You can override with -EncoderMode NVENC|AMDVCE|X264|Auto

#>

[CmdletBinding()]
param(
    # Root folder to process (if not specified, you will be prompted)
    [string]$RootPath = "",

    # Mode (if not specified, you will be prompted): 1=TV(720p), 2=Movies(1080p)
    [ValidateSet("","1","2")]
    [string]$Mode = "",

    # Portable tool paths (optional overrides)
    [string]$FfprobePath      = "",
    [string]$FfmpegPath       = "",
    [string]$HandBrakeCliPath = "",
    [string]$FileBotPath      = "",

    # Write completed CSV here (default under .\Converted\)
    [string]$CompletedCsvPath = "",

    # Keep originals instead of deleting after success?
    [switch]$BackupOriginal,

    # Max total input GB to process in this run (0 = unlimited)
    [double]$MaxTotalInputGB = 0,

    # Show what would happen, but make no changes
    [switch]$DryRun,

    # FileBot renaming
    [switch]$EnableFileBotRename,
    [switch]$FileBotTestRun,

    # Concurrency (applies to NON-disc-image files only)
    [ValidateRange(1, 16)]
    [int]$ConcurrentJobs = 2,

    # Encoder selection
    [ValidateSet("Auto","NVENC","AMDVCE","X264")]
    [string]$EncoderMode = "Auto",

    # Quality knobs (HandBrake RF-style):
    # lower = higher quality / larger file
    [ValidateRange(16, 30)]
    [int]$Quality = 23,

    # Audio target
    [ValidateRange(96, 320)]
    [int]$AudioBitrateKbps = 160
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Paths / folders
# -----------------------------
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$TimeStamp = Get-Date -Format "yyyyMMdd-HHmmss"

$LogsDir      = Join-Path $ScriptDir "Logs"
$FailedDir    = Join-Path $ScriptDir "Failed"
$ConvertedDir = Join-Path $ScriptDir "Converted"

foreach ($d in @($LogsDir, $FailedDir, $ConvertedDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -Path $d -ItemType Directory | Out-Null }
}

$LogFile   = Join-Path $LogsDir   ("Media-Cleanup-{0}.log" -f $TimeStamp)
$FailedCsv = Join-Path $FailedDir ("Media-Cleanup-Failed-{0}.csv" -f $TimeStamp)

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")] [string]$Level = "INFO",
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] [$Level] $Message"
    try { Write-Host $line -ForegroundColor $Color } catch { Write-Host $line }
    Add-Content -Path $LogFile -Value $line
}

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$Fallback = $null
    )
    $p = Join-Path $ScriptDir $RelativePath
    if (Test-Path -LiteralPath $p) { return $p }
    if ($Fallback -and (Test-Path -LiteralPath $Fallback)) { return $Fallback }
    return $null
}

# -----------------------------
# Prompt for RootPath + Mode if not provided
# -----------------------------
if (-not $RootPath -or $RootPath.Trim() -eq "") {
    $RootPath = Read-Host "Enter the root path to process (e.g. Y:\TV Shows or Y:\Movies)"
}
if (-not (Test-Path -LiteralPath $RootPath)) {
    throw "RootPath not found: $RootPath"
}

if (-not $Mode -or $Mode.Trim() -eq "") {
    while ($Mode -notin @("1","2")) {
        Write-Host ""
        Write-Host "Select mode:" -ForegroundColor Cyan
        Write-Host "  1) TV Shows (target 720p + TV FileBot rename)" -ForegroundColor Gray
        Write-Host "  2) Movies   (target 1080p + Movie FileBot rename)" -ForegroundColor Gray
        $Mode = Read-Host "Enter 1 or 2"
    }
}

# Mode-specific targets
switch ($Mode) {
    "1" {
        $TargetMaxWidth  = 1280
        $TargetMaxHeight = 720
        $AllowMaxWidth   = 1280
        $AllowMaxHeight  = 720
        $ModeLabel       = "TV-720p"
        $FileBotDb       = "TheMovieDB::TV"
        # Baked-in TV format (safe: only prints imdbid if present)
        $FileBotFormat   = "{n} - {s00e00} - {vf}{if(imdbid) ' ('+imdbid+')'}{'.'}{ext}"
    }
    "2" {
        $TargetMaxWidth  = 1920
        $TargetMaxHeight = 1080
        $AllowMaxWidth   = 1920
        $AllowMaxHeight  = 1080
        $ModeLabel       = "Movies-1080p"
        $FileBotDb       = "TheMovieDB"
        # Baked-in Movie format (safe: only prints imdbid if present)
        $FileBotFormat   = "{n} ({y}) - {vf}{if(imdbid) ' ('+imdbid+')'}{'.'}{ext}"
    }
}

# -----------------------------
# Tools: prefer portable structure
# -----------------------------
if (-not $FfprobePath)      { $FfprobePath      = Resolve-ToolPath "tools\ffmpeg\bin\ffprobe.exe" }
if (-not $FfmpegPath)       { $FfmpegPath       = Resolve-ToolPath "tools\ffmpeg\bin\ffmpeg.exe" }
if (-not $HandBrakeCliPath) { $HandBrakeCliPath = Resolve-ToolPath "tools\handbrake\HandBrakeCLI.exe" }

if (-not $FileBotPath) {
    $FileBotPath = Resolve-ToolPath "tools\filebot\filebot.cmd"
    if (-not $FileBotPath) { $FileBotPath = Resolve-ToolPath "tools\filebot\FileBot.exe" }
}

if (-not $CompletedCsvPath -or $CompletedCsvPath.Trim() -eq "") {
    $CompletedCsvPath = Join-Path $ConvertedDir ("{0}-Completed.csv" -f $ModeLabel)
}

foreach ($p in @($FfprobePath,$FfmpegPath,$HandBrakeCliPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Tool not found: $p" }
}
if ($EnableFileBotRename) {
    if (-not $FileBotPath -or -not (Test-Path -LiteralPath $FileBotPath)) {
        throw "EnableFileBotRename is set, but FileBot not found. Put it in tools\filebot\ or set -FileBotPath."
    }
}

Write-Log "=== Media Cleanup START ===" "INFO" "Cyan"
Write-Log "Mode: $ModeLabel" "INFO" "Cyan"
Write-Log "RootPath: $RootPath" "INFO" "Gray"
Write-Log "Target cap: ${TargetMaxWidth}x${TargetMaxHeight}" "INFO" "Gray"
Write-Log "CompletedCsv: $CompletedCsvPath" "INFO" "Gray"
Write-Log "BackupOriginal: $BackupOriginal" "INFO" "Gray"
Write-Log "DryRun: $DryRun" "INFO" "Gray"
Write-Log "ConcurrentJobs (non-disc): $ConcurrentJobs" "INFO" "Gray"
Write-Log "EncoderMode: $EncoderMode" "INFO" "Gray"
Write-Log "Quality: $Quality" "INFO" "Gray"
Write-Log "AudioBitrateKbps: $AudioBitrateKbps" "INFO" "Gray"
Write-Log "EnableFileBotRename: $EnableFileBotRename (TestRun=$FileBotTestRun)" "INFO" "Gray"
if ($EnableFileBotRename) {
    Write-Log "FileBot DB: $FileBotDb" "INFO" "Gray"
    Write-Log "FileBot format: $FileBotFormat" "INFO" "Gray"
}

# -----------------------------
# Completed CSV “Mini DB”
# -----------------------------
$TerminalStatuses = @("Success","Skipped")
$script:CompletedIndex = New-Object 'System.Collections.Generic.Dictionary[string, object]' ([StringComparer]::OrdinalIgnoreCase)

function Ensure-CompletedCsvReady {
    param([Parameter(Mandatory)][string]$Path)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        "Timestamp,InputPath,OutputPath,Status,Notes,FileSizeBytes,LastWriteTimeUtc" | Out-File -FilePath $Path -Encoding UTF8
    }
}

function Update-CompletedIndexEntry {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][long]$FileSizeBytes,
        [Parameter(Mandatory)][string]$LastWriteTimeUtc
    )
    $script:CompletedIndex[$InputPath] = [pscustomobject]@{
        Status           = $Status
        FileSizeBytes    = $FileSizeBytes
        LastWriteTimeUtc = $LastWriteTimeUtc
    }
}

function Load-CompletedIndex {
    param([Parameter(Mandatory)][string]$Path)

    Ensure-CompletedCsvReady -Path $Path

    try {
        $rows = Import-Csv -Path $Path
        foreach ($r in $rows) {
            if (-not $r.InputPath) { continue }

            $size = 0L
            if ($r.FileSizeBytes) { try { $size = [long]$r.FileSizeBytes } catch { $size = 0L } }

            Update-CompletedIndexEntry `
                -InputPath ([string]$r.InputPath) `
                -Status ([string]$r.Status) `
                -FileSizeBytes $size `
                -LastWriteTimeUtc ([string]$r.LastWriteTimeUtc)
        }

        Write-Log ("Loaded Completed DB index: {0} unique paths" -f $script:CompletedIndex.Count) "INFO" "DarkGray"
    }
    catch {
        $bad = "$Path.bad-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
        try {
            Copy-Item -LiteralPath $Path -Destination $bad -Force
            Write-Log "Completed CSV couldn't be read; copied to $bad and starting new." "WARN" "Yellow"
        } catch {
            Write-Log "Completed CSV couldn't be read and couldn't be copied. Starting new anyway." "WARN" "Yellow"
        }

        "Timestamp,InputPath,OutputPath,Status,Notes,FileSizeBytes,LastWriteTimeUtc" | Out-File -FilePath $Path -Encoding UTF8 -Force
        $script:CompletedIndex.Clear()
    }
}

function Get-FileIdentity {
    param([Parameter(Mandatory)][string]$Path)

    $len = 0L
    $lwt = ""

    if (Test-Path -LiteralPath $Path) {
        $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($fi) {
            $len = [long]$fi.Length
            $lwt = $fi.LastWriteTimeUtc.ToString("o")
        }
    }

    [pscustomobject]@{
        FileSizeBytes    = $len
        LastWriteTimeUtc = $lwt
    }
}

function Is-CompletedTerminal {
    param([Parameter(Mandatory)][string]$InputPath)

    if (-not $script:CompletedIndex.ContainsKey($InputPath)) { return $false }

    $rec = $script:CompletedIndex[$InputPath]
    if (-not ($TerminalStatuses -contains $rec.Status)) { return $false }

    if (-not (Test-Path -LiteralPath $InputPath)) { return $true }

    $fi = Get-Item -LiteralPath $InputPath -ErrorAction SilentlyContinue
    if (-not $fi) { return $true }

    $currSize = [long]$fi.Length
    $currLwt  = $fi.LastWriteTimeUtc.ToString("o")

    return ($currSize -eq [long]$rec.FileSizeBytes -and $currLwt -eq [string]$rec.LastWriteTimeUtc)
}

function Add-CompletedRecord {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [string]$OutputPath,
        [Parameter(Mandatory)][string]$Status,
        [string]$Notes
    )

    if ($DryRun) {
        Write-Log "  [DRYRUN] Would write DB record: $Status :: $InputPath" "INFO" "Magenta"
        return
    }

    Ensure-CompletedCsvReady -Path $CompletedCsvPath
    $id = Get-FileIdentity -Path $InputPath

    $rowObj = [pscustomobject]@{
        Timestamp        = (Get-Date).ToString("s")
        InputPath        = $InputPath
        OutputPath       = $OutputPath
        Status           = $Status
        Notes            = $Notes
        FileSizeBytes    = [long]$id.FileSizeBytes
        LastWriteTimeUtc = [string]$id.LastWriteTimeUtc
    }

    $csvLine = ($rowObj | ConvertTo-Csv -NoTypeInformation)[1]

    $maxTry = 5
    for ($i = 1; $i -le $maxTry; $i++) {
        try {
            Add-Content -Path $CompletedCsvPath -Value $csvLine -Encoding UTF8
            break
        }
        catch {
            if ($i -eq $maxTry) { throw }
            Start-Sleep -Milliseconds (200 * $i)
        }
    }

    Update-CompletedIndexEntry -InputPath $InputPath -Status $Status -FileSizeBytes ([long]$id.FileSizeBytes) -LastWriteTimeUtc ([string]$id.LastWriteTimeUtc)
}

Load-CompletedIndex -Path $CompletedCsvPath

# -----------------------------
# ffprobe helpers (Option 1)
# -----------------------------
function Invoke-FfprobeJson {
    param(
        [Parameter(Mandatory)][string]$ArgsLine,
        [Parameter(Mandatory)][string]$TargetPath
    )

    $args = @("-v","error","-print_format","json") + ($ArgsLine -split "\s+") + @("--", $TargetPath)
    $out = & $FfprobePath @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("ffprobe failed (exit {0}): {1}" -f $LASTEXITCODE, ($out | Out-String)) }

    try { return ($out | ConvertFrom-Json) }
    catch { throw ("ffprobe JSON parse failed: {0}" -f $_.Exception.Message) }
}

function Convert-TagDurationToSeconds {
    param([Parameter(Mandatory)][string]$TagDuration)

    if ($TagDuration -match '^(?<h>\d+):(?<m>\d+):(?<s>\d+)(\.(?<frac>\d+))?$') {
        $h = [int]$Matches.h
        $m = [int]$Matches.m
        $s = [int]$Matches.s
        $ms = 0
        if ($Matches.frac) {
            $frac = $Matches.frac
            $ms = [int]($frac.Substring(0, [Math]::Min(3, $frac.Length)))
        }
        return ($h*3600 + $m*60 + $s + ($ms/1000.0))
    }
    return 0.0
}

function Get-VideoInfo {
    param([Parameter(Mandatory)][string]$FilePath)

    $result = [ordered]@{
        Success           = $false
        Error             = ""
        Width             = 0
        Height            = 0
        VideoCodec        = ""
        ContainerExt      = ([System.IO.Path]::GetExtension($FilePath)).ToLower()
        AudioStreams      = @()
        FormatDurationSec = 0
        VideoDurationSec  = 0
        TagDurationSec    = 0
        DurationSec       = 0
        BitrateBps        = 0
    }

    try {
        # Video stream
        $vObj = Invoke-FfprobeJson -ArgsLine "-select_streams v:0 -show_entries stream=codec_name,width,height,duration,bit_rate:stream_tags=DURATION" -TargetPath $FilePath
        $v = $null
        if ($vObj -and $vObj.streams -and $vObj.streams.Count -gt 0) { $v = $vObj.streams[0] }

        if ($v) {
            if ($null -ne $v.PSObject.Properties['width']  -and $null -ne $v.width)  { $result.Width  = [int]$v.width }
            if ($null -ne $v.PSObject.Properties['height'] -and $null -ne $v.height) { $result.Height = [int]$v.height }
            if ($null -ne $v.PSObject.Properties['codec_name'] -and $v.codec_name)   { $result.VideoCodec = [string]$v.codec_name }

            if ($null -ne $v.PSObject.Properties['duration'] -and $v.duration) {
                try { $result.VideoDurationSec = [int][Math]::Round([double]$v.duration, 0) } catch {}
            }
            if ($null -ne $v.PSObject.Properties['bit_rate'] -and $v.bit_rate) {
                try { $result.BitrateBps = [int64]$v.bit_rate } catch {}
            }

            if ($v.tags -and ($null -ne $v.tags.PSObject.Properties['DURATION']) -and $v.tags.DURATION) {
                try {
                    $td  = Convert-TagDurationToSeconds -TagDuration ([string]$v.tags.DURATION)
                    if ($td -gt 0) { $result.TagDurationSec = [int][Math]::Round($td, 0) }
                } catch {}
            }
        }

        # Audio streams
        $aObj = Invoke-FfprobeJson -ArgsLine "-select_streams a -show_entries stream=codec_name,channels:stream_tags=language" -TargetPath $FilePath
        $aud = @()
        if ($aObj -and $aObj.streams) {
            foreach ($a in $aObj.streams) {
                $channels = 0
                if (($null -ne $a.PSObject.Properties['channels']) -and ($null -ne $a.channels)) { $channels = [int]$a.channels }

                $lang = ""
                if ($a.tags -and ($null -ne $a.tags.PSObject.Properties['language']) -and $a.tags.language) { $lang = [string]$a.tags.language }

                $codec = ""
                if ($null -ne $a.PSObject.Properties['codec_name'] -and $a.codec_name) { $codec = [string]$a.codec_name }

                $aud += [pscustomobject]@{
                    Codec    = $codec
                    Channels = $channels
                    Language = $lang
                }
            }
        }
        $result.AudioStreams = $aud

        # Format duration + bitrate fallback
        $fObj = Invoke-FfprobeJson -ArgsLine "-show_entries format=duration,bit_rate:format_tags=DURATION" -TargetPath $FilePath
        if ($fObj -and $fObj.format) {
            if (($null -ne $fObj.format.PSObject.Properties['duration']) -and $fObj.format.duration) {
                try { $result.FormatDurationSec = [int][Math]::Round([double]$fObj.format.duration, 0) } catch {}
            }
            if ($result.BitrateBps -le 0 -and ($null -ne $fObj.format.PSObject.Properties['bit_rate']) -and $fObj.format.bit_rate) {
                try { $result.BitrateBps = [int64]$fObj.format.bit_rate } catch {}
            }

            if ($result.TagDurationSec -le 0 -and $fObj.format.tags -and ($null -ne $fObj.format.tags.PSObject.Properties['DURATION']) -and $fObj.format.tags.DURATION) {
                try {
                    $td  = Convert-TagDurationToSeconds -TagDuration ([string]$fObj.format.tags.DURATION)
                    if ($td -gt 0) { $result.TagDurationSec = [int][Math]::Round($td, 0) }
                } catch {}
            }
        }

        if ($result.VideoDurationSec -gt 0)      { $result.DurationSec = $result.VideoDurationSec }
        elseif ($result.FormatDurationSec -gt 0) { $result.DurationSec = $result.FormatDurationSec }
        elseif ($result.TagDurationSec -gt 0)    { $result.DurationSec = $result.TagDurationSec }
        else { $result.DurationSec = 0 }

        $result.Success = $true
    }
    catch { $result.Error = $_.Exception.Message }

    [pscustomobject]$result
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
        [string]$OriginalPath,     # optional
        [Parameter(Mandatory)][string]$ConvertedPath
    )

    if (-not (Test-Path -LiteralPath $ConvertedPath)) { return $false }

    $c = Get-VideoInfo -FilePath $ConvertedPath
    if (-not $c.Success) { return $false }

    if ($OriginalPath -and (Test-Path -LiteralPath $OriginalPath)) {
        $o = Get-VideoInfo -FilePath $OriginalPath
        if ($o.Success -and $o.DurationSec -gt 0 -and $c.DurationSec -gt 0) {

            $origMetaGap = 0
            if ($o.VideoDurationSec -gt 0 -and $o.FormatDurationSec -gt 0) {
                $origMetaGap = [Math]::Abs($o.VideoDurationSec - $o.FormatDurationSec)
            }

            $diff = [Math]::Abs($o.DurationSec - $c.DurationSec)

            # adaptive tolerance: at least 30s or 0.5% of original, whichever larger
            $allowed = [Math]::Max(30, [int][Math]::Ceiling($o.DurationSec * 0.005))
            if ($origMetaGap -ge 20) { $allowed = [Math]::Max($allowed, 90) }

            if ($diff -gt $allowed) {
                return $false
            }
        }
    }

    return $true
}

# -----------------------------
# ffmpeg helpers
# -----------------------------
function Remux-TsToMkv {
    param([Parameter(Mandatory)][string]$TsPath)

    $dir  = Split-Path -Parent $TsPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($TsPath)
    $remuxPath = Join-Path $dir ($name + ".tsremux.mkv")

    if ($DryRun) { return $remuxPath }

    if (Test-Path -LiteralPath $remuxPath) { Remove-Item -LiteralPath $remuxPath -Force -ErrorAction SilentlyContinue }

    $args = @(
        "-y","-hide_banner",
        "-fflags","+genpts",
        "-i", $TsPath,
        "-map","0:v:0",
        "-map","0:a?",
        "-c","copy",
        $remuxPath
    )

    & $FfmpegPath @args | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $remuxPath)) {
        throw "TS remux failed (exit $LASTEXITCODE)"
    }

    return $remuxPath
}

function Remux-FileToMkv {
    param([Parameter(Mandatory)][string]$InputPath)

    $dir  = Split-Path -Parent $InputPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $out  = Join-Path $dir ($name + ".fixremux.mkv")

    if ($DryRun) { return $out }

    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }

    $args = @(
        "-y","-hide_banner",
        "-fflags","+genpts",
        "-err_detect","ignore_err",
        "-i", $InputPath,
        "-map","0",
        "-c","copy",
        $out
    )

    & $FfmpegPath @args | Out-Null
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
        if (-not (Test-Path -LiteralPath $NewFilePath)) { throw "New file '$NewFilePath' does not exist." }

        $origDir   = Split-Path -Parent $OriginalPath
        $origName  = Split-Path -Leaf $OriginalPath
        $backupDir = Join-Path $origDir "Originals"

        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -Path $backupDir -ItemType Directory | Out-Null }
        $backupPath = Join-Path $backupDir $origName

        if (Test-Path -LiteralPath $OriginalPath) {
            Move-Item -LiteralPath $OriginalPath -Destination $backupPath -Force
        }

        if (Test-Path -LiteralPath $FinalPath) { Remove-Item -LiteralPath $FinalPath -Force }
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

# -----------------------------
# HandBrake encoder auto-detect
# -----------------------------
function Get-HandBrakeEncodersText {
    $out = & $HandBrakeCliPath "--help" 2>&1 | Out-String
    return $out
}

function Select-HandBrakeEncoder {
    param(
        [ValidateSet("Auto","NVENC","AMDVCE","X264")]
        [string]$Mode
    )

    if ($Mode -eq "X264")  { return "x264" }
    if ($Mode -eq "NVENC") { return "nvenc_h264" }
    if ($Mode -eq "AMDVCE"){ return "vce_h264" }

    # Auto: prefer NVENC if supported, else VCE, else x264
    $help = Get-HandBrakeEncodersText
    $hasNvenc = ($help -match "nvenc_h264")
    $hasVce   = ($help -match "vce_h264")

    if ($hasNvenc) { return "nvenc_h264" }
    if ($hasVce)   { return "vce_h264" }
    return "x264"
}

$SelectedHbEncoder = Select-HandBrakeEncoder -Mode $EncoderMode
Write-Log "HandBrake encoder selected: $SelectedHbEncoder" "INFO" "Cyan"

# -----------------------------
# HandBrake encode wrapper
# -----------------------------
function Encode-WithHandBrake {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$TempOut,
        [int]$TitleNumber = 0
    )

    $hbArgs = @("-i", $InputPath, "-o", $TempOut)

    if ($TitleNumber -gt 0) { $hbArgs += @("--title", "$TitleNumber") }

    $hbArgs += @(
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

    if ($DryRun) { return 0 }

    $stdoutLog = Join-Path $env:TEMP ("hb-" + [guid]::NewGuid().ToString() + ".out.log")
    $stderrLog = Join-Path $env:TEMP ("hb-" + [guid]::NewGuid().ToString() + ".err.log")

    try {
        $p = Start-Process -FilePath $HandBrakeCliPath `
            -ArgumentList $hbArgs `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError  $stderrLog

        $hbOut = ""; $hbErr = ""
        try { if (Test-Path -LiteralPath $stdoutLog) { $hbOut = Get-Content -LiteralPath $stdoutLog -Raw -ErrorAction SilentlyContinue } } catch {}
        try { if (Test-Path -LiteralPath $stderrLog) { $hbErr = Get-Content -LiteralPath $stderrLog -Raw -ErrorAction SilentlyContinue } } catch {}

        if ($hbOut.Trim()) { Add-Content -Path $LogFile -Value $hbOut }
        if ($hbErr.Trim()) { Add-Content -Path $LogFile -Value $hbErr }

        return [int]$p.ExitCode
    }
    finally {
        try { if (Test-Path -LiteralPath $stdoutLog) { Remove-Item -LiteralPath $stdoutLog -Force -ErrorAction SilentlyContinue } } catch {}
        try { if (Test-Path -LiteralPath $stderrLog) { Remove-Item -LiteralPath $stderrLog -Force -ErrorAction SilentlyContinue } } catch {}
    }
}

# -----------------------------
# Disc image handling
# -----------------------------
$DvdMinTitleSeconds = 600

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
            $current = [ordered]@{ Title=[int]$Matches[1]; DurationSec=0 }
            continue
        }
        if ($current -and $line -match "duration:\s+(\d+):(\d+):(\d+)") {
            $h=[int]$Matches[1]; $m=[int]$Matches[2]; $s=[int]$Matches[3]
            $current.DurationSec = ($h*3600)+($m*60)+$s
        }
    }
    if ($current) { $titles += $current }
    return $titles
}

function Select-BestDvdTitle {
    param([Parameter(Mandatory)]$Titles,[Parameter(Mandatory)][int]$MinSeconds)
    if (-not $Titles -or $Titles.Count -eq 0) { return $null }

    $candidates = $Titles | Where-Object { $_.DurationSec -ge $MinSeconds }
    if ($candidates -and $candidates.Count -gt 0) {
        return ($candidates | Sort-Object DurationSec -Descending | Select-Object -First 1)
    }
    return ($Titles | Sort-Object DurationSec -Descending | Select-Object -First 1)
}

# -----------------------------
# FileBot rename
# -----------------------------
function Invoke-FileBotRename {
    param(
        [Parameter(Mandatory)][string]$TargetPath
    )

    if (-not $EnableFileBotRename) { return }
    if ($DryRun) { return }

    $action = if ($FileBotTestRun) { "test" } else { "rename" }

    $args = @(
        "-rename", $TargetPath,
        "--db", $FileBotDb,
        "--format", $FileBotFormat,
        "--action", $action,
        "--conflict", "auto",
        "--log", "all",
        "-non-strict"
    )

    & $FileBotPath @args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "FileBot failed (exit $LASTEXITCODE)" }
}

# -----------------------------
# Compliance rules
# -----------------------------
$AllowedVideoCodecs = @("h264")
$RequireAacStereo   = $true

# Extensions
$VideoExtensions     = @(".mp4", ".mkv", ".mov", ".m4v", ".avi", ".wmv", ".ts")
$DiscImageExtensions = @(".iso", ".img")

# -----------------------------
# Build file list
# -----------------------------
$allFiles = Get-ChildItem -LiteralPath $RootPath -Recurse -Force -ErrorAction Continue |
    Where-Object { -not $_.PSIsContainer } |
    Where-Object {
        $ext = $_.Extension.ToLower()
        ($VideoExtensions -contains $ext) -or ($DiscImageExtensions -contains $ext)
    } |
    Where-Object {
        ($_.FullName -notmatch "\\Originals\\") -and
        ($_.FullName -notmatch "\\Failed\\") -and
        ($_.FullName -notmatch "\\Converted\\") -and
        ($_.Name -notmatch "\.tmp\.mp4$")
    }

Write-Log ("Found {0} candidate files" -f $allFiles.Count) "INFO" "Cyan"

$failedList   = New-Object System.Collections.Generic.List[object]
$failedCount  = 0
$totalInputGB = 0.0

# Split disc images (sequential) vs others (can run in parallel)
$discImages = @($allFiles | Where-Object { $DiscImageExtensions -contains $_.Extension.ToLower() })
$others     = @($allFiles | Where-Object { -not ($DiscImageExtensions -contains $_.Extension.ToLower()) })

# -----------------------------
# Process disc images sequentially
# -----------------------------
foreach ($f in $discImages) {
    $filePath = $f.FullName

    try {
        if (Is-CompletedTerminal -InputPath $filePath) {
            Write-Log "SKIP (db terminal+unchanged): $filePath" "INFO" "DarkGray"
            continue
        }

        $inGB = [Math]::Round(($f.Length / 1GB), 4)
        if ($MaxTotalInputGB -gt 0 -and ($totalInputGB + $inGB) -gt $MaxTotalInputGB) {
            Write-Log "MaxTotalInputGB reached. Stopping. Total so far: $totalInputGB GB" "INFO" "Yellow"
            break
        }
        $totalInputGB += $inGB

        $dir  = Split-Path -Parent $filePath
        $name = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
        $finalOut = Join-Path $dir ($name + ".mp4")
        $tempOut  = Join-Path $dir ($name + ".tmp.mp4")

        if (Test-Path -LiteralPath $finalOut) {
            Write-Log "  SKIP (mp4 exists): $finalOut" "INFO" "DarkGreen"
            Add-CompletedRecord -InputPath $filePath -OutputPath $finalOut -Status "Skipped" -Notes "DiscImage mp4 exists"
            continue
        }

        if (Test-Path -LiteralPath $tempOut) { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }

        Write-Log "Disc image detected: $filePath" "INFO" "Cyan"

        $mounted = $false
        try {
            if (-not $DryRun) {
                Mount-DiskImage -ImagePath $filePath -ErrorAction Stop | Out-Null
                $mounted = $true
                Start-Sleep -Milliseconds 750
            }

            $drive = if ($DryRun) { "X:" } else { (Get-MountedDriveLetter -ImagePath $filePath) }
            if (-not $drive) { throw "Could not determine mounted drive letter." }

            $videoTs = Join-Path $drive "VIDEO_TS"
            $hbInput = if ($DryRun) { "$drive\VIDEO_TS" } elseif (Test-Path -LiteralPath $videoTs) { $videoTs } else { $drive }

            $bestTitle = $null
            if ($DryRun) {
                $bestTitle = [pscustomobject]@{ Title=1; DurationSec=3600 }
            } else {
                $scanLines = & $HandBrakeCliPath -i $hbInput --scan 2>&1
                $titles = Parse-HandBrakeScanTitles -ScanLines $scanLines
                if (-not $titles -or $titles.Count -eq 0) { throw "No titles found in scan output." }
                $bestTitle = Select-BestDvdTitle -Titles $titles -MinSeconds $DvdMinTitleSeconds
                if (-not $bestTitle) { throw "Failed to select best title." }
            }

            Write-Log "  Selected DVD title: $($bestTitle.Title) (dur=$($bestTitle.DurationSec)s)" "INFO" "Cyan"

            $exit = Encode-WithHandBrake -InputPath $hbInput -TempOut $tempOut -TitleNumber $bestTitle.Title
            if (-not $DryRun -and ($exit -ne 0 -or -not (Test-Path -LiteralPath $tempOut))) {
                throw "HandBrake failed for disc image (exit $exit)."
            }

            if (-not $DryRun) {
                if (-not (Validate-ConvertedFile -OriginalPath "" -ConvertedPath $tempOut)) {
                    throw "Validation failed for disc-image encode."
                }

                Move-Item -LiteralPath $tempOut -Destination $finalOut -Force
                Write-Log "  Created: $finalOut" "INFO" "Green"

                if ($BackupOriginal) {
                    $backupDir = Join-Path $dir "Originals"
                    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -Path $backupDir -ItemType Directory | Out-Null }
                    $dest = Join-Path $backupDir (Split-Path -Leaf $filePath)
                    Move-Item -LiteralPath $filePath -Destination $dest -Force
                } else {
                    Remove-Item -LiteralPath $filePath -Force
                }

                # Optional FileBot rename
                try { Invoke-FileBotRename -TargetPath $finalOut } catch { Write-Log ("  ! FileBot rename failed: {0}" -f $_.Exception.Message) "WARN" "Yellow" }
            }

            Add-CompletedRecord -InputPath $filePath -OutputPath $finalOut -Status "Success" -Notes "DiscImage converted"
        }
        finally {
            if ($mounted -and -not $DryRun) {
                Dismount-DiskImage -ImagePath $filePath -ErrorAction SilentlyContinue | Out-Null
            }
            if (Test-Path -LiteralPath $tempOut) { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }
        }
    }
    catch {
        $msg = $_.Exception.Message
        Write-Log "FAILED (disc): $filePath :: $msg" "ERROR" "Red"
        $failedList.Add([pscustomobject]@{ File=$filePath; Reason=$msg; Log=$LogFile }) | Out-Null
        $failedCount++
        try { Add-CompletedRecord -InputPath $filePath -OutputPath "" -Status "Failed" -Notes $msg } catch {}
    }
}

# -----------------------------
# Worker for non-disc files (regular + ts)
# Returns a result object; main thread writes Completed CSV and runs FileBot rename.
# -----------------------------
$Worker = {
    param(
        [string]$FilePath,
        [string]$FfprobePath,
        [string]$FfmpegPath,
        [string]$HandBrakeCliPath,
        [bool]$BackupOriginal,
        [bool]$DryRun,
        [int]$AllowMaxWidth,
        [int]$AllowMaxHeight,
        [int]$TargetMaxWidth,
        [int]$TargetMaxHeight,
        [int]$Quality,
        [int]$AudioBitrateKbps,
        [string]$SelectedHbEncoder
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"

    function Invoke-FfprobeJson {
        param([string]$ArgsLine,[string]$TargetPath)
        $args = @("-v","error","-print_format","json") + ($ArgsLine -split "\s+") + @("--", $TargetPath)
        $out = & $FfprobePath @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ffprobe failed (exit $LASTEXITCODE)" }
        return ($out | ConvertFrom-Json)
    }

    function Convert-TagDurationToSeconds {
        param([string]$TagDuration)
        if ($TagDuration -match '^(?<h>\d+):(?<m>\d+):(?<s>\d+)(\.(?<frac>\d+))?$') {
            $h=[int]$Matches.h; $m=[int]$Matches.m; $s=[int]$Matches.s
            $ms=0
            if ($Matches.frac) {
                $frac=$Matches.frac
                $ms=[int]($frac.Substring(0, [Math]::Min(3, $frac.Length)))
            }
            return ($h*3600 + $m*60 + $s + ($ms/1000.0))
        }
        return 0.0
    }

    function Get-VideoInfo {
        param([string]$Path)
        $r = [ordered]@{ Success=$false; Error=""; Width=0; Height=0; VideoCodec=""; Audio=@(); FormatDur=0; VideoDur=0; TagDur=0; Dur=0 }
        try {
            $vObj = Invoke-FfprobeJson "-select_streams v:0 -show_entries stream=codec_name,width,height,duration:stream_tags=DURATION" $Path
            $v = $null; if ($vObj.streams -and $vObj.streams.Count -gt 0) { $v = $vObj.streams[0] }
            if ($v) {
                if ($v.width)  { $r.Width  = [int]$v.width }
                if ($v.height) { $r.Height = [int]$v.height }
                if ($v.codec_name) { $r.VideoCodec = [string]$v.codec_name }
                if ($v.duration) { try { $r.VideoDur = [int][Math]::Round([double]$v.duration,0) } catch {} }
                if ($v.tags -and $v.tags.DURATION) {
                    $td = Convert-TagDurationToSeconds ([string]$v.tags.DURATION)
                    if ($td -gt 0) { $r.TagDur = [int][Math]::Round($td,0) }
                }
            }

            $aObj = Invoke-FfprobeJson "-select_streams a -show_entries stream=codec_name,channels" $Path
            $aud = @()
            if ($aObj.streams) {
                foreach ($a in $aObj.streams) {
                    $aud += [pscustomobject]@{ Codec=([string]$a.codec_name); Channels=([int]($a.channels ? $a.channels : 0)) }
                }
            }
            $r.Audio = $aud

            $fObj = Invoke-FfprobeJson "-show_entries format=duration:format_tags=DURATION" $Path
            if ($fObj.format -and $fObj.format.duration) { try { $r.FormatDur = [int][Math]::Round([double]$fObj.format.duration,0) } catch {} }
            if ($r.TagDur -le 0 -and $fObj.format -and $fObj.format.tags -and $fObj.format.tags.DURATION) {
                $td = Convert-TagDurationToSeconds ([string]$fObj.format.tags.DURATION)
                if ($td -gt 0) { $r.TagDur = [int][Math]::Round($td,0) }
            }

            if ($r.VideoDur -gt 0) { $r.Dur = $r.VideoDur }
            elseif ($r.FormatDur -gt 0) { $r.Dur = $r.FormatDur }
            elseif ($r.TagDur -gt 0) { $r.Dur = $r.TagDur }
            else { $r.Dur = 0 }

            $r.Success = $true
        } catch { $r.Error = $_.Exception.Message }
        return [pscustomobject]$r
    }

    function Has-AacStereo {
        param($Audio)
        foreach ($a in $Audio) { if ($a.Codec -eq "aac" -and $a.Channels -eq 2) { return $true } }
        return $false
    }

    function Validate-ConvertedFile {
        param([string]$Orig,[string]$Conv)
        if (-not (Test-Path -LiteralPath $Conv)) { return $false }
        $c = Get-VideoInfo $Conv
        if (-not $c.Success) { return $false }

        if ($Orig -and (Test-Path -LiteralPath $Orig)) {
            $o = Get-VideoInfo $Orig
            if ($o.Success -and $o.Dur -gt 0 -and $c.Dur -gt 0) {
                $diff = [Math]::Abs($o.Dur - $c.Dur)
                $allowed = [Math]::Max(30, [int][Math]::Ceiling($o.Dur * 0.005))
                if ($diff -gt $allowed) { return $false }
            }
        }
        return $true
    }

    function Remux-TsToMkv {
        param([string]$TsPath)
        $dir = Split-Path -Parent $TsPath
        $name = [System.IO.Path]::GetFileNameWithoutExtension($TsPath)
        $out = Join-Path $dir ($name + ".tsremux.mkv")
        if ($DryRun) { return $out }
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
        & $FfmpegPath "-y" "-hide_banner" "-fflags" "+genpts" "-i" $TsPath "-map" "0:v:0" "-map" "0:a?" "-c" "copy" $out | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw "TS remux failed (exit $LASTEXITCODE)" }
        return $out
    }

    function Remux-FileToMkv {
        param([string]$InputPath)
        $dir = Split-Path -Parent $InputPath
        $name = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
        $out = Join-Path $dir ($name + ".fixremux.mkv")
        if ($DryRun) { return $out }
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
        & $FfmpegPath "-y" "-hide_banner" "-fflags" "+genpts" "-err_detect" "ignore_err" "-i" $InputPath "-map" "0" "-c" "copy" $out | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw "Remux failed (exit $LASTEXITCODE)" }
        return $out
    }

    function Replace-WithBackup {
        param([string]$OriginalPath,[string]$FinalPath,[string]$NewFilePath,[bool]$BackupOriginal)
        $backupPath = $null
        try {
            if (-not (Test-Path -LiteralPath $NewFilePath)) { throw "New file missing: $NewFilePath" }
            $origDir   = Split-Path -Parent $OriginalPath
            $origName  = Split-Path -Leaf $OriginalPath
            $backupDir = Join-Path $origDir "Originals"
            if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -Path $backupDir -ItemType Directory | Out-Null }
            $backupPath = Join-Path $backupDir $origName
            if (Test-Path -LiteralPath $OriginalPath) { Move-Item -LiteralPath $OriginalPath -Destination $backupPath -Force }
            if (Test-Path -LiteralPath $FinalPath) { Remove-Item -LiteralPath $FinalPath -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $NewFilePath -Destination $FinalPath -Force
            if ($backupPath -and -not $BackupOriginal) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
            return $true
        } catch {
            if ($backupPath -and (Test-Path -LiteralPath $backupPath) -and -not (Test-Path -LiteralPath $OriginalPath)) {
                try { Move-Item -LiteralPath $backupPath -Destination $OriginalPath -Force } catch {}
            }
            return $false
        }
    }

    function Encode-WithHandBrake {
        param([string]$Input,[string]$OutTemp)
        $hbArgs = @(
            "-i",$Input,"-o",$OutTemp,
            "--encoder",$SelectedHbEncoder,
            "--quality","$Quality",
            "--maxWidth","$TargetMaxWidth",
            "--maxHeight","$TargetMaxHeight",
            "--cfr",
            "-E","av_aac",
            "-B","$AudioBitrateKbps",
            "--mixdown","stereo",
            "--optimize"
        )
        if ($DryRun) { return 0 }
        & $HandBrakeCliPath @hbArgs 2>&1 | Out-Null
        return $LASTEXITCODE
    }

    # ---- Do work ----
    $file = Get-Item -LiteralPath $FilePath -ErrorAction Stop
    $ext  = $file.Extension.ToLower()
    $dir  = $file.DirectoryName
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

    $finalOut = Join-Path $dir ($name + ".mp4")
    $tempOut  = Join-Path $dir ($name + ".tmp.mp4")

    if ($ext -eq ".ts") {
        if (Test-Path -LiteralPath $finalOut) {
            return [pscustomobject]@{ Input=$FilePath; Output=$finalOut; Status="Skipped"; Notes="TS mp4 exists"; RenamedPath=$null }
        }

        $remux = $null
        try {
            $remux = Remux-TsToMkv $FilePath
            $exit = Encode-WithHandBrake -Input $remux -OutTemp $tempOut
            if (-not $DryRun -and ($exit -ne 0 -or -not (Test-Path -LiteralPath $tempOut))) {
                throw "HandBrake failed for TS (exit $exit)"
            }

            if (-not $DryRun) {
                if (-not (Validate-ConvertedFile -Orig $remux -Conv $tempOut)) { throw "Validation failed for TS conversion" }
                $ok = Replace-WithBackup -OriginalPath $FilePath -FinalPath $finalOut -NewFilePath $tempOut -BackupOriginal:$BackupOriginal
                if (-not $ok) { throw "Replace-WithBackup failed for TS" }
                if ($remux -and (Test-Path -LiteralPath $remux)) { Remove-Item -LiteralPath $remux -Force -ErrorAction SilentlyContinue }
            }

            return [pscustomobject]@{ Input=$FilePath; Output=$finalOut; Status="Success"; Notes="TS remux+converted"; RenamedPath=$finalOut }
        }
        finally {
            try {
                if ($remux -and (Test-Path -LiteralPath $remux) -and $DryRun) { }
            } catch {}
        }
    }

    # Regular files
    if (Test-Path -LiteralPath $finalOut -and $ext -ne ".mp4") {
        # existing mp4 sibling doesn't automatically mean skip; we still assess input file itself
    }

    $info = Get-VideoInfo $FilePath
    if (-not $info.Success) {
        return [pscustomobject]@{ Input=$FilePath; Output=""; Status="Failed"; Notes=("ffprobe error: " + $info.Error); RenamedPath=$null }
    }

    $hasAac = Has-AacStereo $info.Audio
    $isCompliantVideo = (($info.VideoCodec -eq "h264") -and ($info.Width -le $AllowMaxWidth) -and ($info.Height -le $AllowMaxHeight))
    $isCompliantAudio = $hasAac

    if ($info.ContainerExt -eq ".mp4" -and $isCompliantVideo -and $isCompliantAudio) {
        return [pscustomobject]@{ Input=$FilePath; Output=$FilePath; Status="Skipped"; Notes="Already compliant"; RenamedPath=$FilePath }
    }

    if (Test-Path -LiteralPath $tempOut -and -not $DryRun) { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }

    $exit1 = Encode-WithHandBrake -Input $FilePath -OutTemp $tempOut
    if (-not $DryRun -and ($exit1 -ne 0 -or -not (Test-Path -LiteralPath $tempOut))) {
        return [pscustomobject]@{ Input=$FilePath; Output=""; Status="Failed"; Notes=("HandBrake failed (exit " + $exit1 + ")"); RenamedPath=$null }
    }

    if (-not $DryRun) {
        $validated = Validate-ConvertedFile -Orig $FilePath -Conv $tempOut
        if (-not $validated) {
            # repair path: remux -> re-encode
            try {
                $keepDir = Join-Path (Split-Path -Parent $FilePath) "Failed"
                if (-not (Test-Path -LiteralPath $keepDir)) { New-Item -Path $keepDir -ItemType Directory | Out-Null }
                $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
                $keep1 = Join-Path $keepDir ("FAILED-FIRSTPASS-{0}-{1}.tmp.mp4" -f $stamp, $name)
                try { Move-Item -LiteralPath $tempOut -Destination $keep1 -Force } catch { }
            } catch {}

            $remux2 = $null
            try {
                $remux2 = Remux-FileToMkv $FilePath
                if (Test-Path -LiteralPath $tempOut) { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }

                $exit2 = Encode-WithHandBrake -Input $remux2 -OutTemp $tempOut
                if ($exit2 -ne 0 -or -not (Test-Path -LiteralPath $tempOut)) {
                    return [pscustomobject]@{ Input=$FilePath; Output=""; Status="Failed"; Notes=("Repair encode failed (exit " + $exit2 + ")"); RenamedPath=$null }
                }
                if (-not (Validate-ConvertedFile -Orig $remux2 -Conv $tempOut)) {
                    return [pscustomobject]@{ Input=$FilePath; Output=""; Status="Failed"; Notes="Validation failed after repair pass"; RenamedPath=$null }
                }
            }
            finally {
                try { if ($remux2 -and (Test-Path -LiteralPath $remux2)) { Remove-Item -LiteralPath $remux2 -Force -ErrorAction SilentlyContinue } } catch {}
            }
        }

        $ok2 = Replace-WithBackup -OriginalPath $FilePath -FinalPath $finalOut -NewFilePath $tempOut -BackupOriginal:$BackupOriginal
        if (-not $ok2) {
            return [pscustomobject]@{ Input=$FilePath; Output=""; Status="Failed"; Notes="Replace-WithBackup failed"; RenamedPath=$null }
        }
    }

    return [pscustomobject]@{ Input=$FilePath; Output=$finalOut; Status="Success"; Notes="Converted"; RenamedPath=$finalOut }
}

# -----------------------------
# Run parallel processing for non-disc files
# -----------------------------
Write-Log ("Processing non-disc files: {0}" -f $others.Count) "INFO" "Cyan"

# Pre-filter terminal skip + MaxTotalInputGB gate is handled in main loop when scheduling
$queue = New-Object System.Collections.Generic.Queue[System.IO.FileInfo]
foreach ($f in $others) { $queue.Enqueue($f) }

$pool = [RunspaceFactory]::CreateRunspacePool(1, $ConcurrentJobs)
$pool.Open()
$pending = New-Object System.Collections.Generic.List[object]

function Start-WorkItem {
    param([System.IO.FileInfo]$File)

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool

    [void]$ps.AddScript($Worker).
        AddArgument($File.FullName).
        AddArgument($FfprobePath).
        AddArgument($FfmpegPath).
        AddArgument($HandBrakeCliPath).
        AddArgument([bool]$BackupOriginal).
        AddArgument([bool]$DryRun).
        AddArgument([int]$AllowMaxWidth).
        AddArgument([int]$AllowMaxHeight).
        AddArgument([int]$TargetMaxWidth).
        AddArgument([int]$TargetMaxHeight).
        AddArgument([int]$Quality).
        AddArgument([int]$AudioBitrateKbps).
        AddArgument([string]$SelectedHbEncoder)

    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ PS=$ps; Handle=$handle; File=$File }
}

while ($queue.Count -gt 0 -or $pending.Count -gt 0) {

    while ($queue.Count -gt 0 -and $pending.Count -lt $ConcurrentJobs) {
        $next = $queue.Dequeue()
        $filePath = $next.FullName

        if (Is-CompletedTerminal -InputPath $filePath) {
            Write-Log "SKIP (db terminal+unchanged): $filePath" "INFO" "DarkGray"
            continue
        }

        $inGB = [Math]::Round(($next.Length / 1GB), 4)
        if ($MaxTotalInputGB -gt 0 -and ($totalInputGB + $inGB) -gt $MaxTotalInputGB) {
            Write-Log "MaxTotalInputGB reached. Stopping new work. Total so far: $totalInputGB GB" "INFO" "Yellow"
            $queue.Clear()
            break
        }
        $totalInputGB += $inGB

        $pending.Add((Start-WorkItem -File $next)) | Out-Null
        Write-Log "QUEUE -> $filePath" "INFO" "DarkGray"
    }

    for ($i = $pending.Count - 1; $i -ge 0; $i--) {
        $p = $pending[$i]
        if ($p.Handle.IsCompleted) {
            $result = $null
            try { $result = $p.PS.EndInvoke($p.Handle) }
            catch {
                $result = [pscustomobject]@{ Input=$p.File.FullName; Output=""; Status="Failed"; Notes=("Runspace error: " + $_.Exception.Message); RenamedPath=$null }
            }
            finally { $p.PS.Dispose() }

            $pending.RemoveAt($i)

            # Worker returns as a single object or array of 1
            if ($result -is [System.Array] -and $result.Count -gt 0) { $result = $result[0] }

            $input = [string]$result.Input
            $out   = [string]$result.Output
            $st    = [string]$result.Status
            $notes = [string]$result.Notes
            $ren   = [string]$result.RenamedPath

            if ($st -eq "Success") {
                Write-Log ("OK    -> {0}" -f $input) "INFO" "Green"
                try { Add-CompletedRecord -InputPath $input -OutputPath $out -Status "Success" -Notes $notes } catch {}
                if ($EnableFileBotRename -and $ren) {
                    try { Invoke-FileBotRename -TargetPath $ren; Write-Log "  -> FileBot rename complete" "INFO" "Green" }
                    catch { Write-Log ("  ! FileBot rename failed: {0}" -f $_.Exception.Message) "WARN" "Yellow" }
                }
            }
            elseif ($st -eq "Skipped") {
                Write-Log ("SKIP  -> {0} ({1})" -f $input, $notes) "INFO" "DarkGreen"
                try { Add-CompletedRecord -InputPath $input -OutputPath $out -Status "Skipped" -Notes $notes } catch {}
                if ($EnableFileBotRename -and $ren) {
                    try { Invoke-FileBotRename -TargetPath $ren; Write-Log "  -> FileBot rename complete" "INFO" "Green" }
                    catch { Write-Log ("  ! FileBot rename failed: {0}" -f $_.Exception.Message) "WARN" "Yellow" }
                }
            }
            else {
                Write-Log ("FAIL  -> {0} | {1}" -f $input, $notes) "ERROR" "Red"
                $failedList.Add([pscustomobject]@{ File=$input; Reason=$notes; Log=$LogFile }) | Out-Null
                $failedCount++
                try { Add-CompletedRecord -InputPath $input -OutputPath "" -Status "Failed" -Notes $notes } catch {}
            }
        }
    }

    Start-Sleep -Milliseconds 200
}

$pool.Close()
$pool.Dispose()

# -----------------------------
# Wrap up
# -----------------------------
if ($failedList.Count -gt 0) {
    $failedList | Export-Csv -Path $FailedCsv -NoTypeInformation -Encoding UTF8
    Write-Log "Wrote failures to: $FailedCsv" "WARN" "Yellow"
}

Write-Log "=== Media Cleanup END (Failed=$failedCount) ===" "INFO" "Cyan"
