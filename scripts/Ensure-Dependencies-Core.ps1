# NOTE: intentionally avoid param(...) to maximize compatibility with older Windows PowerShell hosts.
$ToolsRoot = ""
$ForceRefresh = $false
$Components = ""

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]

    if ($arg -eq "-ToolsRoot" -and $i + 1 -lt $args.Count) { $ToolsRoot = [string]$args[++$i]; continue }
    if ($arg.StartsWith("-ToolsRoot:")) { $ToolsRoot = [string]$arg.Substring(11); continue }

    if ($arg -eq "-ForceRefresh") { $ForceRefresh = $true; continue }
    if ($arg.StartsWith("-ForceRefresh:")) {
        $v = $arg.Substring(14).ToLowerInvariant()
        if ($v -in @('true','1')) { $ForceRefresh = $true }
        elseif ($v -in @('false','0')) { $ForceRefresh = $false }
        continue
    }

    if ($arg -eq "-Components" -and $i + 1 -lt $args.Count) { $Components = [string]$args[++$i]; continue }
    if ($arg.StartsWith("-Components:")) { $Components = [string]$arg.Substring(12); continue }
    switch -Regex ($arg) {
        '^-ToolsRoot$' {
            if ($i + 1 -lt $args.Count) { $ToolsRoot = [string]$args[$i + 1]; $i++ }
            continue
        }
        '^-ToolsRoot:(.+)$' {
            $ToolsRoot = [string]$Matches[1]
            continue
        }
        '^-ForceRefresh$' {
            $ForceRefresh = $true
            continue
        }
        '^-ForceRefresh:(?i:true|1)$' {
            $ForceRefresh = $true
            continue
        }
        '^-ForceRefresh:(?i:false|0)$' {
            $ForceRefresh = $false
            continue
        }
        '^-Components$' {
            if ($i + 1 -lt $args.Count) { $Components = [string]$args[$i + 1]; $i++ }
            continue
        }
        '^-Components:(.+)$' {
            $Components = [string]$Matches[1]
            continue
        }
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ToolsRoot) { $ToolsRoot = Join-Path (Split-Path -Parent $ScriptDir) "tools" }

$validComponents = @("FFmpeg","HandBrake","FileBot")
$componentList = @()

if (-not $Components -or $Components.Trim() -eq "") {
    $componentList = @("FFmpeg","HandBrake","FileBot")
}
else {
    $componentList = @($Components -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

$invalidComponents = @($componentList | Where-Object { $validComponents -notcontains $_ })
if ($invalidComponents.Count -gt 0) {
    throw ("Invalid component(s): " + ($invalidComponents -join ", ") + ". Valid values: " + ($validComponents -join ", "))
}
$Components = @($componentList | Select-Object -Unique)

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

    $allowedHosts = @(
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "codeload.github.com",
        "www.gyan.dev",
        "www.filebot.net",
        "get.filebot.net"
    )

    $uri = [Uri]$Url
    if ($allowedHosts -notcontains $uri.Host.ToLowerInvariant()) {
        throw "Blocked download host: $($uri.Host). Not in allowlist."
    }

    $parent = Split-Path -Parent $DestinationPath
    if ($parent) { Ensure-Directory -Path $parent }

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
    }

    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        Start-BitsTransfer -Source $Url -Destination $DestinationPath -DisplayName "video-encoder dependency download" -ErrorAction Stop
    }
    else {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $DestinationPath -ErrorAction Stop
    }

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        throw "Download failed; file not found after transfer: $DestinationPath"
    }

    $size = (Get-Item -LiteralPath $DestinationPath).Length
    $hash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash

    Write-Info ("Download complete: {0} ({1})" -f (Split-Path -Leaf $DestinationPath), (Format-ByteSize -Bytes $size))
    Write-Info ("SHA256: {0}" -f $hash)
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

function Ensure-FFmpeg {
    param([string]$Root)

    $installPath = Join-Path $Root "ffmpeg"
    $binPath = Join-Path $installPath "bin"
    $ffmpegExe = Join-Path $binPath "ffmpeg.exe"
    $ffprobeExe = Join-Path $binPath "ffprobe.exe"

    if (-not $ForceRefresh -and (Test-Path -LiteralPath $ffmpegExe) -and (Test-Path -LiteralPath $ffprobeExe)) {
        Write-Info "FFmpeg already present."
        return
    }

    Ensure-Directory -Path $Root
    Ensure-Directory -Path $installPath
    Ensure-Directory -Path $binPath

    $zipUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
    $zip = Join-Path $env:TEMP "ffmpeg-release-essentials.zip"
    Invoke-DownloadFile -Url $zipUrl -DestinationPath $zip

    $extractRoot = Join-Path ([System.IO.Path]::GetDirectoryName($zip)) ("extract-" + [System.Guid]::NewGuid().ToString("N"))
    Expand-ZipTo -ZipPath $zip -DestinationPath $extractRoot

    try {
        # Find ffmpeg.exe anywhere, then treat its directory as the "bin" folder
        $ffmpegHit = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue |
                     Select-Object -First 1
        if (-not $ffmpegHit) {
            throw "Could not locate ffmpeg.exe in extracted archive."
        }

        $srcBin = $ffmpegHit.Directory.FullName
        $srcFfprobe = Join-Path $srcBin "ffprobe.exe"
        if (-not (Test-Path -LiteralPath $srcFfprobe)) {
            # Some builds still include ffprobe in same bin; if not, search for it
            $ffprobeHit = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "ffprobe.exe" -ErrorAction SilentlyContinue |
                          Select-Object -First 1
            if (-not $ffprobeHit) { throw "Could not locate ffprobe.exe in extracted archive." }
            $srcBin = $ffprobeHit.Directory.FullName
        }

        # Normalize: wipe target bin, then copy ALL runtime files into tools\ffmpeg\bin
        if (Test-Path -LiteralPath $binPath) {
            Remove-Item -LiteralPath $binPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $binPath -Force | Out-Null

        Copy-Item -Path (Join-Path $srcBin "*") -Destination $binPath -Recurse -Force

        if (-not (Test-Path -LiteralPath $ffmpegExe)) { throw "FFmpeg normalization failed: missing $ffmpegExe" }
        if (-not (Test-Path -LiteralPath $ffprobeExe)) { throw "FFmpeg normalization failed: missing $ffprobeExe" }
    }
    finally {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
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
    Ensure-Directory -Path $installPath

    $release = Get-LatestGitHubRelease -Repo "HandBrake/HandBrake"
    $asset = $release.assets | Where-Object { $_.name -match '^HandBrakeCLI-.*-win-x86_64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "Could not find HandBrakeCLI win-x86_64 zip in latest release." }

    $zip = Join-Path $env:TEMP $asset.name
    Invoke-DownloadFile -Url $asset.browser_download_url -DestinationPath $zip

    # Extract to temp and locate the exe anywhere in the archive
    $extractRoot = Join-Path ([System.IO.Path]::GetDirectoryName($zip)) ("extract-" + [System.Guid]::NewGuid().ToString("N"))
    Expand-ZipTo -ZipPath $zip -DestinationPath $extractRoot

    try {
        $hb = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "HandBrakeCLI.exe" | Select-Object -First 1
        if (-not $hb) {
            throw "Could not locate HandBrakeCLI.exe in extracted archive at $extractRoot"
        }

        # Normalize to canonical path
        Copy-Item -LiteralPath $hb.FullName -Destination $exe -Force
    }
    finally {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-FileBot {
    param([string]$Root)

    $installPath = Join-Path $Root "filebot"
    $portableExe = Join-Path $installPath "filebot.exe"
	$ps1Path     = Join-Path $installPath "filebot.ps1"
	$jarPath     = Join-Path $installPath "FileBot.jar"
    $cmdPath     = Join-Path $installPath "filebot.cmd"
    $exePath     = Join-Path $installPath "FileBot.exe"

    if (-not $ForceRefresh -and (
        (Test-Path -LiteralPath $portableExe) -or
        (Test-Path -LiteralPath $cmdPath) -or
        (Test-Path -LiteralPath $exePath) -or
        (Test-Path -LiteralPath $ps1Path) -or
        (Test-Path -LiteralPath $jarPath)
    )) {
        Write-Info "FileBot already present."
        return
    }

    Ensure-Directory -Path $Root
    Ensure-Directory -Path $installPath

    # Resolve official portable ZIP
    $dl = Invoke-WebRequest -UseBasicParsing -Uri "https://www.filebot.net/download.html"
    $href = $null
    foreach ($l in $dl.Links) {
        if ($l.href -and $l.href -match '(?i)(^|/).*portable.*\.zip$') { $href = [string]$l.href; break }
    }
    if (-not $href) { throw "Could not find FileBot portable ZIP link on filebot.net/download.html" }
    if ($href -notmatch '^https?://') {
        $href = ([Uri]::new([Uri]::new("https://www.filebot.net/download.html"), $href)).AbsoluteUri
    }

    $zipName = Split-Path -Leaf $href
    if (-not $zipName) { $zipName = "FileBot-portable.zip" }

    $zip = Join-Path $env:TEMP $zipName
    Invoke-DownloadFile -Url $href -DestinationPath $zip

    $extractRoot = Join-Path ([System.IO.Path]::GetDirectoryName($zip)) ("extract-" + [System.Guid]::NewGuid().ToString("N"))
    Expand-ZipTo -ZipPath $zip -DestinationPath $extractRoot
	Write-Info "FileBot ZIP extracted to: $extractRoot"

	$topItems = Get-ChildItem -LiteralPath $extractRoot -Recurse -ErrorAction SilentlyContinue | Select-Object -First 20
	Write-Info "First 20 extracted items:"
	foreach ($i in $topItems) {
		Write-Info ("  " + $i.FullName)
	}

    try {
        # Locate runtime folder (prefer portable exe)
$hitExe = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "filebot.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
$hitCmd = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "filebot.cmd" -ErrorAction SilentlyContinue | Select-Object -First 1
$hitGui = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "FileBot.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
$hitPs1 = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "filebot.ps1" -ErrorAction SilentlyContinue | Select-Object -First 1
$hitJar = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "FileBot.jar" -ErrorAction SilentlyContinue | Select-Object -First 1

Write-Info "Entry point detection results:"
Write-Info ("  filebot.exe : " + ($(if ($hitExe) { $hitExe.FullName } else { "NOT FOUND" })))
Write-Info ("  filebot.cmd : " + ($(if ($hitCmd) { $hitCmd.FullName } else { "NOT FOUND" })))
Write-Info ("  FileBot.exe : " + ($(if ($hitGui) { $hitGui.FullName } else { "NOT FOUND" })))
Write-Info ("  filebot.ps1 : " + ($(if ($hitPs1) { $hitPs1.FullName } else { "NOT FOUND" })))
Write-Info ("  FileBot.jar : " + ($(if ($hitJar) { $hitJar.FullName } else { "NOT FOUND" })))

$runtimeDir = $null
if ($hitExe) { $runtimeDir = $hitExe.Directory.FullName }
elseif ($hitCmd) { $runtimeDir = $hitCmd.Directory.FullName }
elseif ($hitGui) { $runtimeDir = $hitGui.Directory.FullName }
elseif ($hitPs1) { $runtimeDir = $hitPs1.Directory.FullName }
elseif ($hitJar) { $runtimeDir = $hitJar.Directory.FullName }

if (-not $runtimeDir) {
    throw "Could not locate FileBot entrypoint in extracted archive. See log output above."
}

# If entrypoint is under a nested folder, copy that folder’s contents;
# but if it looks like it's inside a deep 'bin' subdir, copy one level up.
$copySource = $runtimeDir
$parent = Split-Path -Parent $runtimeDir
if ($parent -and (
        (Test-Path -LiteralPath (Join-Path $parent "lib")) -or
        (Test-Path -LiteralPath (Join-Path $parent "jre"))
    )) {
    $copySource = $parent
}

Write-Info ("FileBot copy source resolved to: " + $copySource)

        # Normalize: wipe tools\filebot and copy runtime folder contents directly into it
        if (Test-Path -LiteralPath $installPath) {
            Remove-Item -LiteralPath $installPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $installPath -Force | Out-Null
		$itemsToCopy = Get-ChildItem -LiteralPath $copySource -Force -ErrorAction SilentlyContinue
		Write-Info ("FileBot items to copy: " + $itemsToCopy.Count)
		
        Copy-Item -Path (Join-Path $copySource "*") -Destination $installPath -Recurse -Force
		Write-Info ("FileBot install contents count: " + ((Get-ChildItem -LiteralPath $installPath -Recurse -Force -ErrorAction SilentlyContinue).Count))

        if (-not (Test-Path -LiteralPath $portableExe) -and
    -not (Test-Path -LiteralPath $cmdPath) -and
    -not (Test-Path -LiteralPath $exePath) -and
    -not (Test-Path -LiteralPath $ps1Path) -and
    -not (Test-Path -LiteralPath $jarPath)) {
    throw "FileBot normalization failed: no entrypoint found under $installPath"
}
    }
    finally {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

Ensure-Directory -Path $ToolsRoot

if ($Components -contains "FFmpeg") { Ensure-Ffmpeg -Root $ToolsRoot }
if ($Components -contains "HandBrake") { Ensure-HandBrake -Root $ToolsRoot }
if ($Components -contains "FileBot") { Ensure-FileBot -Root $ToolsRoot }

Write-Info ("Dependencies are ready under: {0} (components: {1})" -f $ToolsRoot, ($Components -join ", "))
