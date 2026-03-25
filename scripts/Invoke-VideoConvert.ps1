[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RootPath,

    [ValidateSet("1","2","TV","MOVIES","TV-720P","MOVIES-1080P")]
    [string]$Mode = "TV",

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

# ------------------------------------------------------------
# Paths / setup
# ------------------------------------------------------------
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$RepoRoot  = Split-Path -Parent $ScriptDir

$LogsDir      = Join-Path $RepoRoot "Logs"
$FailedDir    = Join-Path $RepoRoot "Failed"
$ConvertedDir = Join-Path $RepoRoot "Converted"
$ToolsDir     = Join-Path $RepoRoot "tools"

foreach ($d in @($LogsDir, $FailedDir, $ConvertedDir, $ToolsDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -Path $d -ItemType Directory | Out-Null
    }
}

$TimeStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile   = Join-Path $LogsDir ("Video-Convert-{0}.log" -f $TimeStamp)
$FailedCsv = Join-Path $FailedDir ("Video-Convert-Failed-{0}.csv" -f $TimeStamp)

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO",
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message
    try { Write-Host $line -ForegroundColor $Color } catch { Write-Host $line }
    Add-Content -Path $LogFile -Value $line
}

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$Fallback = $null
    )
    $p = Join-Path $RepoRoot $RelativePath
    if (Test-Path -LiteralPath $p) { return $p }
    if ($Fallback -and (Test-Path -LiteralPath $Fallback)) { return $Fallback }
    return $null
}

if (-not $FfprobePath)      { $FfprobePath      = Resolve-ToolPath "tools\ffmpeg\bin\ffprobe.exe" }
if (-not $FfmpegPath)       { $FfmpegPath       = Resolve-ToolPath "tools\ffmpeg\bin\ffmpeg.exe" }
if (-not $HandBrakeCliPath) { $HandBrakeCliPath = Resolve-ToolPath "tools\handbrake\HandBrakeCLI.exe" }
if (-not $FileBotPath) {
    $FileBotPath = Resolve-ToolPath "tools\filebot\filebot.cmd"
    if (-not $FileBotPath) { $FileBotPath = Resolve-ToolPath "tools\filebot\FileBot.exe" }
}

if (-not (Test-Path -LiteralPath $RootPath)) { throw "RootPath not found: $RootPath" }
foreach ($p in @($FfprobePath,$FfmpegPath,$HandBrakeCliPath)) {
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { throw "Missing required tool: $p" }
}
if ($EnableFileBotRename -and (-not $FileBotPath -or -not (Test-Path -LiteralPath $FileBotPath))) {
    throw "FileBot rename enabled but FileBot was not found under tools\filebot\"
}

# ------------------------------------------------------------
# Mode normalization
# ------------------------------------------------------------
$modeRaw = $Mode.Trim().ToUpperInvariant()
switch ($modeRaw) {
    "1" { $Mode = "TV" }
    "TV" { $Mode = "TV" }
    "TV-720P" { $Mode = "TV" }
    "2" { $Mode = "MOVIES" }
    "MOVIES" { $Mode = "MOVIES" }
    "MOVIES-1080P" { $Mode = "MOVIES" }
    default { throw "Invalid Mode: $Mode" }
}

if ($Mode -eq "TV") {
    $TargetMaxWidth  = 1280
    $TargetMaxHeight = 720
    $AllowMaxWidth   = 1280
    $AllowMaxHeight  = 720
    $ModeLabel       = "TV-720p"
    $FileBotDb       = "TheMovieDB::TV"
    $FileBotFormat   = "{n} - {s00e00} - {vf}{if(imdbid) ' ('+imdbid+')'}{'.'}{ext}"
}
else {
    $TargetMaxWidth  = 1920
    $TargetMaxHeight = 1080
    $AllowMaxWidth   = 1920
    $AllowMaxHeight  = 1080
    $ModeLabel       = "Movies-1080p"
    $FileBotDb       = "TheMovieDB"
    $FileBotFormat   = "{n} ({y}) - {vf}{if(imdbid) ' ('+imdbid+')'}{'.'}{ext}"
}

if (-not $CompletedCsvPath -or $CompletedCsvPath.Trim() -eq "") {
    $CompletedCsvPath = Join-Path $ConvertedDir ("{0}-Completed.csv" -f $ModeLabel)
}

Write-Log "=== START ===" "INFO" "Cyan"
Write-Log "RootPath: $RootPath" "INFO" "Gray"
Write-Log "Mode: $Mode" "INFO" "Gray"
Write-Log "Target: ${TargetMaxWidth}x${TargetMaxHeight}" "INFO" "Gray"
Write-Log "DryRun: $DryRun" "INFO" "Gray"
Write-Log "BackupOriginal: $BackupOriginal" "INFO" "Gray"
Write-Log "EnableFileBotRename: $EnableFileBotRename" "INFO" "Gray"

# ------------------------------------------------------------
# Completed DB
# ------------------------------------------------------------
$script:CompletedIndex = @{}

function Ensure-CompletedCsvReady {
    param([string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        "Timestamp,InputPath,OutputPath,Status,Notes,FileSizeBytes,LastWriteTimeUtc" | Out-File -FilePath $Path -Encoding UTF8
    }
}

function Load-CompletedIndex {
    param([string]$Path)
    Ensure-CompletedCsvReady -Path $Path
    try {
        $rows = Import-Csv -Path $Path
        foreach ($r in $rows) {
            if (-not $r.InputPath) { continue }
            $script:CompletedIndex[$r.InputPath] = [pscustomobject]@{
                Status = $r.Status
                FileSizeBytes = [int64]$r.FileSizeBytes
                LastWriteTimeUtc = $r.LastWriteTimeUtc
            }
        }
    } catch {
        Write-Log ("Warning: failed to load Completed DB: " + $_.Exception.Message) "WARN" "Yellow"
    }
}

function Get-FileIdentity {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($fi) {
            return [pscustomobject]@{
                FileSizeBytes = [int64]$fi.Length
                LastWriteTimeUtc = $fi.LastWriteTimeUtc.ToString("o")
            }
        }
    }
    return [pscustomobject]@{
        FileSizeBytes = 0L
        LastWriteTimeUtc = ""
    }
}

function Is-CompletedTerminal {
    param([string]$InputPath)

    if (-not $script:CompletedIndex.ContainsKey($InputPath)) { return $false }
    $rec = $script:CompletedIndex[$InputPath]

    if ($rec.Status -notin @("Success","Skipped")) { return $false }
    if (-not (Test-Path -LiteralPath $InputPath)) { return $true }

    $id = Get-FileIdentity -Path $InputPath
    return ($id.FileSizeBytes -eq [int64]$rec.FileSizeBytes -and $id.LastWriteTimeUtc -eq [string]$rec.LastWriteTimeUtc)
}

function Add-CompletedRecord {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [string]$Status,
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
        Status = $Status
        FileSizeBytes = [int64]$id.FileSizeBytes
        LastWriteTimeUtc = [string]$id.LastWriteTimeUtc
    }
}

Load-CompletedIndex -Path $CompletedCsvPath

# ------------------------------------------------------------
# ffprobe helpers
# ------------------------------------------------------------
function Invoke-FfprobeJson {
    param([string[]]$Args)
    $out = & $FfprobePath @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed (exit $LASTEXITCODE)" }
    return ($out | ConvertFrom-Json)
}

function Convert-TagDurationToSeconds {
    param([string]$TagDuration)
    if ($TagDuration -match '^(?<h>\d+):(?<m>\d+):(?<s>\d+)(\.(?<frac>\d+))?$') {
        $h=[int]$Matches.h; $m=[int]$Matches.m; $s=[int]$Matches.s
        $ms=0
        if ($Matches.frac) { $ms=[int]($Matches.frac.Substring(0,[Math]::Min(3,$Matches.frac.Length))) }
        return ($h*3600 + $m*60 + $s + ($ms/1000.0))
    }
    return 0.0
}

function Get-VideoInfo {
    param([string]$Path)

    $r = [ordered]@{
        Success=$false; Error=""
        Ext=([IO.Path]::GetExtension($Path)).ToLower()
        Width=0; Height=0; VideoCodec=""
        AudioStreams=@()
        FormatDurationSec=0; VideoDurationSec=0; TagDurationSec=0; DurationSec=0
    }

    try {
        $vObj = Invoke-FfprobeJson @("-v","error","-print_format","json","-select_streams","v:0","-show_entries","stream=codec_name,width,height,duration:stream_tags=DURATION","--",$Path)
        if ($vObj.streams -and $vObj.streams.Count -gt 0) {
            $v = $vObj.streams[0]
            if ($v.width)  { $r.Width = [int]$v.width }
            if ($v.height) { $r.Height = [int]$v.height }
            if ($v.codec_name) { $r.VideoCodec = [string]$v.codec_name }
            if ($v.duration) { try { $r.VideoDurationSec = [int][Math]::Round([double]$v.duration,0) } catch {} }
            if ($v.tags -and $v.tags.DURATION) {
                $td = Convert-TagDurationToSeconds -TagDuration ([string]$v.tags.DURATION)
                if ($td -gt 0) { $r.TagDurationSec = [int][Math]::Round($td,0) }
            }
        }

        $aObj = Invoke-FfprobeJson @("-v","error","-print_format","json","-select_streams","a","-show_entries","stream=codec_name,channels","--",$Path)
        $aud = @()
        if ($aObj.streams) {
            foreach ($a in $aObj.streams) {
                $aud += [pscustomobject]@{
                    Codec = [string]$a.codec_name
                    Channels = [int]($a.channels ? $a.channels : 0)
                }
            }
        }
        $r.AudioStreams = $aud

        $fObj = Invoke-FfprobeJson @("-v","error","-print_format","json","-show_entries","format=duration:format_tags=DURATION","--",$Path)
        if ($fObj.format -and $fObj.format.duration) {
            try { $r.FormatDurationSec = [int][Math]::Round([double]$fObj.format.duration,0) } catch {}
        }
        if ($r.TagDurationSec -le 0 -and $fObj.format -and $fObj.format.tags -and $fObj.format.tags.DURATION) {
            $td = Convert-TagDurationToSeconds -TagDuration ([string]$fObj.format.tags.DURATION)
            if ($td -gt 0) { $r.TagDurationSec = [int][Math]::Round($td,0) }
        }

        if ($r.VideoDurationSec -gt 0)      { $r.DurationSec = $r.VideoDurationSec }
        elseif ($r.FormatDurationSec -gt 0) { $r.DurationSec = $r.FormatDurationSec }
        elseif ($r.TagDurationSec -gt 0)    { $r.DurationSec = $r.TagDurationSec }

        $r.Success = $true
    }
    catch {
        $r.Error = $_.Exception.Message
    }

    return [pscustomobject]$r
}

function Has-AacStereo {
    param($AudioStreams)
    foreach ($a in $AudioStreams) {
        if ($a.Codec -eq "aac" -and $a.Channels -eq 2) { return $true }
    }
    return $false
}

function Validate-ConvertedFile {
    param(
        [string]$OriginalPath,
        [string]$ConvertedPath
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

# ------------------------------------------------------------
# ffmpeg / replace helpers
# ------------------------------------------------------------
function Remux-TsToMkv {
    param([string]$TsPath)

    $dir  = Split-Path -Parent $TsPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($TsPath)
    $out  = Join-Path $dir ($name + ".tsremux.mkv")

    if ($DryRun) { return $out }

    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }

    & $FfmpegPath "-y" "-hide_banner" "-fflags" "+genpts" "-i" $TsPath "-map" "0:v:0" "-map" "0:a?" "-c" "copy" $out | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) {
        throw "TS remux failed (exit $LASTEXITCODE)"
    }

    return $out
}

function Remux-FileToMkv {
    param([string]$InputPath)

    $dir  = Split-Path -Parent $InputPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $out  = Join-Path $dir ($name + ".fixremux.mkv")

    if ($DryRun) { return $out }

    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }

    & $FfmpegPath "-y" "-hide_banner" "-fflags" "+genpts" "-err_detect" "ignore_err" "-i" $InputPath "-map" "0" "-c" "copy" $out | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) {
        throw "Remux failed (exit $LASTEXITCODE)"
    }

    return $out
}

function Replace-WithBackup {
    param(
        [string]$OriginalPath,
        [string]$FinalPath,
        [string]$NewFilePath,
        [bool]$BackupOriginal
    )

    $backupPath = $null
    try {
        if (-not (Test-Path -LiteralPath $NewFilePath)) { throw "New file missing: $NewFilePath" }

        $origDir   = Split-Path -Parent $OriginalPath
        $origName  = Split-Path -Leaf $OriginalPath
        $backupDir = Join-Path $origDir "Originals"

        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -Path $backupDir -ItemType Directory | Out-Null }

        if (Test-Path -LiteralPath $OriginalPath) {
            $backupPath = Join-Path $backupDir $origName
            if (Test-Path -LiteralPath $backupPath) {
                $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $base  = [IO.Path]::GetFileNameWithoutExtension($origName)
                $ext   = [IO.Path]::GetExtension($origName)
                $backupPath = Join-Path $backupDir ("{0}-{1}{2}" -f $base,$stamp,$ext)
            }
            Move-Item -LiteralPath $OriginalPath -Destination $backupPath -Force
        }

        if (Test-Path -LiteralPath $FinalPath) { Remove-Item -LiteralPath $FinalPath -Force -ErrorAction SilentlyContinue }
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

# ------------------------------------------------------------
# HandBrake encoder selection
# ------------------------------------------------------------
function Select-HandBrakeEncoder {
    param([string]$Mode)

    if ($Mode -eq "X264")  { return "x264" }
    if ($Mode -eq "NVENC") { return "nvenc_h264" }
    if ($Mode -eq "AMDVCE"){ return "vce_h264" }

    $help = & $HandBrakeCliPath "--help" 2>&1 | Out-String
    if ($help -match "nvenc_h264") { return "nvenc_h264" }
    if ($help -match "vce_h264")   { return "vce_h264" }
    return "x264"
}

$SelectedHbEncoder = Select-HandBrakeEncoder -Mode $EncoderMode
Write-Log "Selected HandBrake encoder: $SelectedHbEncoder" "INFO" "Cyan"

function Encode-WithHandBrake {
    param(
        [string]$InputPath,
        [string]$TempOut
    )

    if ($DryRun) { return 0 }

    $args = @(
        "-i",$InputPath,
        "-o",$TempOut,
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

    & $HandBrakeCliPath @args 2>&1 | Out-Null
    return $LASTEXITCODE
}

# ------------------------------------------------------------
# FileBot rename
# ------------------------------------------------------------
function Invoke-FileBotRename {
    param([string]$TargetPath)

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

# ------------------------------------------------------------
# Processing loop
# ------------------------------------------------------------
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
$convertedCount   = 0
$skippedCount     = 0
$failedCount      = 0
$failedList       = @()

foreach ($file in $allFiles) {
    $filePath = $file.FullName
    $dir      = $file.DirectoryName
    $name     = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $ext      = $file.Extension.ToLower()

    try {
        if (Is-CompletedTerminal -InputPath $filePath) {
            Write-Log "SKIP (db): $filePath" "INFO" "DarkGray"
            continue
        }

        $inputGB = [Math]::Round(($file.Length / 1GB), 3)
        if ($MaxTotalInputGB -gt 0 -and ($processedInputGB + $inputGB) -gt $MaxTotalInputGB) {
            Write-Log "Reached MaxTotalInputGB limit ($MaxTotalInputGB). Stopping." "INFO" "Yellow"
            break
        }

        Write-Log "Checking: $filePath" "INFO" "DarkGray"

        $finalOut = Join-Path $dir ($name + ".mp4")
        $tempOut  = Join-Path $dir ($name + ".tmp.mp4")

        if ($ext -eq ".ts") {
            if (Test-Path -LiteralPath $tempOut) { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }

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

                if (Test-Path -LiteralPath $remux) { Remove-Item -LiteralPath $remux -Force -ErrorAction SilentlyContinue }
                try { Invoke-FileBotRename -TargetPath $finalOut } catch { Write-Log ("FileBot rename failed: " + $_.Exception.Message) "WARN" "Yellow" }
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
            Add-CompletedRecord -InputPath $filePath -OutputPath $filePath -Status "Skipped" -Notes "Already compliant"
            if (-not $DryRun) {
                try { Invoke-FileBotRename -TargetPath $filePath } catch { Write-Log ("FileBot rename failed: " + $_.Exception.Message) "WARN" "Yellow" }
            }
            $processedInputGB += $inputGB
            $skippedCount++
            continue
        }

        if (Test-Path -LiteralPath $tempOut) { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }

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
                    if (Test-Path -LiteralPath $tempOut) { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }

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

            try { Invoke-FileBotRename -TargetPath $finalOut } catch { Write-Log ("FileBot rename failed: " + $_.Exception.Message) "WARN" "Yellow" }
        }

        Add-CompletedRecord -InputPath $filePath -OutputPath $finalOut -Status "Success" -Notes "Converted"
        $processedInputGB += $inputGB
        $convertedCount++
    }
    catch {
        $msg = $_.Exception.Message
        Write-Log ("FAILED: {0} :: {1}" -f $filePath, $msg) "ERROR" "Red"
        $failedList += [pscustomobject]@{ File=$filePath; Reason=$msg; Log=$LogFile }
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
    $failedList | Export-Csv -Path $FailedCsv -NoTypeInformation -Encoding UTF8
    Write-Log ("Failed file list written to: {0}" -f $FailedCsv) "WARN" "Yellow"
}