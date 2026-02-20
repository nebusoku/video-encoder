[CmdletBinding()]
param(
    [string]$ToolsRoot = "",
    [switch]$ForceRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ToolsRoot) { $ToolsRoot = Join-Path (Split-Path -Parent $ScriptDir) "tools" }

function Write-Info { param([string]$Message) Write-Host "[deps] $Message" -ForegroundColor Cyan }

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType Directory | Out-Null }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath
    )
    Write-Info "Downloading: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing
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
    $api = "https://api.github.com/repos/$Repo/releases/latest"
    return Invoke-RestMethod -Uri $api -UseBasicParsing
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
Ensure-Ffmpeg -Root $ToolsRoot
Ensure-HandBrake -Root $ToolsRoot
Ensure-FileBot -Root $ToolsRoot

Write-Info "Dependencies are ready under: $ToolsRoot"
