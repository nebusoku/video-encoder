[CmdletBinding()]
param(
    [string]$ToolsRoot = "",
    [switch]$ForceRefresh,
    [string[]]$Components = @("FFmpeg","HandBrake","FileBot")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ToolsRoot) { $ToolsRoot = Join-Path (Split-Path -Parent $ScriptDir) "tools" }

$validComponents = @("FFmpeg","HandBrake","FileBot")
if (-not $Components -or $Components.Count -eq 0) {
    $Components = $validComponents
}
$invalidComponents = @($Components | Where-Object { $validComponents -notcontains $_ })
if ($invalidComponents.Count -gt 0) {
    throw ("Invalid component(s): " + ($invalidComponents -join ", ") + ". Valid values: " + ($validComponents -join ", "))
}
$Components = @($Components | Select-Object -Unique)

function Write-Info { param([string]$Message) Write-Host "[deps] $Message" -ForegroundColor Cyan }

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType Directory | Out-Null }
}

function Format-ByteSize {
    param([double]$Bytes)

    if ($Bytes -lt 1KB) { return ("{0:N0} B" -f $Bytes) }
    if ($Bytes -lt 1MB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    return ("{0:N2} GB" -f ($Bytes / 1GB))
}

function Format-DurationShort {
    param([TimeSpan]$Duration)

    if ($Duration.TotalHours -ge 1) {
        return ("{0}h {1}m {2}s" -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds)
    }
    if ($Duration.TotalMinutes -ge 1) {
        return ("{0}m {1}s" -f [int]$Duration.TotalMinutes, $Duration.Seconds)
    }
    return ("{0}s" -f [int][Math]::Max(0, [Math]::Round($Duration.TotalSeconds)))
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    Write-Info "Downloading: $Url"

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

    $response = $null
    $responseStream = $null
    $fileStream = $null

    try {
        $response = $request.GetResponse()
        $totalBytes = [int64]$response.ContentLength
        $responseStream = $response.GetResponseStream()

        $parent = Split-Path -Parent $DestinationPath
        if ($parent) { Ensure-Directory -Path $parent }

        $fileStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $buffer = New-Object byte[] 65536
        $downloaded = [int64]0
        $downloadStart = Get-Date
        $activity = "Downloading dependency"
        $statusLabel = [System.IO.Path]::GetFileName($DestinationPath)

        while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $downloaded += [int64]$read

            $elapsed = (Get-Date) - $downloadStart
            $elapsedSeconds = [Math]::Max(0.001, $elapsed.TotalSeconds)
            $speedBytesPerSec = $downloaded / $elapsedSeconds
            $speedLabel = (Format-ByteSize -Bytes $speedBytesPerSec) + "/s"

            if ($totalBytes -gt 0) {
                $percent = [int][Math]::Min(100, [Math]::Round(($downloaded * 100.0) / $totalBytes, 0))
                $remainingBytes = [Math]::Max(0, $totalBytes - $downloaded)
                $etaSeconds = if ($speedBytesPerSec -gt 0) { $remainingBytes / $speedBytesPerSec } else { 0 }
                $etaLabel = Format-DurationShort -Duration ([TimeSpan]::FromSeconds($etaSeconds))

                $status = "{0} of {1} ({2}%) | {3} | ETA {4}" -f (Format-ByteSize -Bytes $downloaded), (Format-ByteSize -Bytes $totalBytes), $percent, $speedLabel, $etaLabel
                Write-Progress -Activity $activity -Status ("{0} :: {1}" -f $statusLabel, $status) -PercentComplete $percent
            }
            else {
                $status = "{0} downloaded | {1}" -f (Format-ByteSize -Bytes $downloaded), $speedLabel
                Write-Progress -Activity $activity -Status ("{0} :: {1}" -f $statusLabel, $status) -PercentComplete -1
            }
        }

        Write-Progress -Activity $activity -Status "Completed" -Completed
        Write-Info ("Download complete: {0} ({1})" -f $statusLabel, (Format-ByteSize -Bytes $downloaded))
    }
    finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Expand-ZipTo {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )
    if (Test-Path -LiteralPath $DestinationPath) { Remove-Item -LiteralPath $DestinationPath -Recurse -Force }
    Expand-Archive -Path $ZipPath -DestinationPath $DestinationPath -Force
}

function Get-LatestGitHubRelease {
    param([Parameter(Mandatory)][string]$Repo)

    $headers = @{ "User-Agent" = "video-encoder-deps" }
    $latestApi = "https://api.github.com/repos/$Repo/releases/latest"

    try {
        return Invoke-RestMethod -Uri $latestApi -UseBasicParsing -Headers $headers
    }
    catch {
        Write-Info "Latest release API failed for $Repo. Falling back to releases list..."
        $releasesApi = "https://api.github.com/repos/$Repo/releases?per_page=25"
        $releases = Invoke-RestMethod -Uri $releasesApi -UseBasicParsing -Headers $headers
        $candidate = $releases | Where-Object { -not $_.draft -and -not $_.prerelease } | Select-Object -First 1
        if (-not $candidate) {
            throw "Could not determine a stable release for $Repo from GitHub API."
        }
        return $candidate
    }
}

function Install-FromZipRoot {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][ScriptBlock]$Locator
    )

    $extractRoot = Join-Path ([System.IO.Path]::GetDirectoryName($ZipPath)) ("extract-" + [System.Guid]::NewGuid().ToString("N"))
    Expand-ZipTo -ZipPath $ZipPath -DestinationPath $extractRoot

    $sourcePath = & $Locator $extractRoot
    if (-not $sourcePath -or -not (Test-Path -LiteralPath $sourcePath)) {
        throw "Could not locate extracted dependency content in $extractRoot"
    }

    if (Test-Path -LiteralPath $InstallPath) { Remove-Item -LiteralPath $InstallPath -Recurse -Force }
    New-Item -Path $InstallPath -ItemType Directory | Out-Null
    Copy-Item -Path (Join-Path $sourcePath '*') -Destination $InstallPath -Recurse -Force

    Remove-Item -LiteralPath $extractRoot -Recurse -Force
}

function Ensure-Ffmpeg {
    param([string]$Root)
    $bin = Join-Path $Root "ffmpeg\bin"
    $ffmpeg = Join-Path $bin "ffmpeg.exe"
    $ffprobe = Join-Path $bin "ffprobe.exe"

    if (-not $ForceRefresh -and (Test-Path -LiteralPath $ffmpeg) -and (Test-Path -LiteralPath $ffprobe)) {
        Write-Info "FFmpeg already present."
        return
    }

    Ensure-Directory -Path $Root
    $zip = Join-Path $env:TEMP "ffmpeg-release-essentials.zip"
    Invoke-DownloadFile -Url "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -DestinationPath $zip

    Install-FromZipRoot -ZipPath $zip -InstallPath (Join-Path $Root "ffmpeg") -Locator {
        param($extractRoot)
        Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1 -ExpandProperty FullName
    }

    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
}

function Ensure-HandBrake {
    param([string]$Root)
    $installPath = Join-Path $Root "handbrake"
    $exe = Join-Path $installPath "HandBrakeCLI.exe"

    if (-not $ForceRefresh -and (Test-Path -LiteralPath $exe)) {
        Write-Info "HandBrakeCLI already present."
        return
    }

    Ensure-Directory -Path $Root
    $release = Get-LatestGitHubRelease -Repo "HandBrake/HandBrake"
    $asset = $release.assets | Where-Object { $_.name -match '^HandBrakeCLI-.*-win-x86_64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "Could not find HandBrakeCLI win-x86_64 zip in latest release." }

    $zip = Join-Path $env:TEMP $asset.name
    Invoke-DownloadFile -Url $asset.browser_download_url -DestinationPath $zip

    Install-FromZipRoot -ZipPath $zip -InstallPath $installPath -Locator {
        param($extractRoot)
        $dir = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
        if ($dir) { return $dir.FullName }
        return $extractRoot
    }

    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
}

function Ensure-FileBot {
    param([string]$Root)
    $installPath = Join-Path $Root "filebot"
    $cmdPath = Join-Path $installPath "filebot.cmd"
    $exePath = Join-Path $installPath "FileBot.exe"

    if (-not $ForceRefresh -and ((Test-Path -LiteralPath $cmdPath) -or (Test-Path -LiteralPath $exePath))) {
        Write-Info "FileBot already present."
        return
    }

    Ensure-Directory -Path $Root

    $release = Get-LatestGitHubRelease -Repo "filebot/filebot"
    $asset = $release.assets | Where-Object { $_.name -match '(?i)portable.*\.zip$' -or $_.name -match '(?i)FileBot.*win.*\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "Could not find portable/windows zip for FileBot in latest release." }

    $zip = Join-Path $env:TEMP $asset.name
    Invoke-DownloadFile -Url $asset.browser_download_url -DestinationPath $zip

    Install-FromZipRoot -ZipPath $zip -InstallPath $installPath -Locator {
        param($extractRoot)
        $cmd = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "filebot.cmd" | Select-Object -First 1
        if ($cmd) { return $cmd.Directory.FullName }

        $exe = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "FileBot.exe" | Select-Object -First 1
        if ($exe) { return $exe.Directory.FullName }

        Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1 -ExpandProperty FullName
    }

    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
}

Ensure-Directory -Path $ToolsRoot

if ($Components -contains "FFmpeg") { Ensure-Ffmpeg -Root $ToolsRoot }
if ($Components -contains "HandBrake") { Ensure-HandBrake -Root $ToolsRoot }
if ($Components -contains "FileBot") { Ensure-FileBot -Root $ToolsRoot }

Write-Info ("Dependencies are ready under: {0} (components: {1})" -f $ToolsRoot, ($Components -join ", "))
