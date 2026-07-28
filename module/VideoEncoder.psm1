<#
VideoEncoder.psm1
Command-line dispatcher for the portable video encoder.

Maps `video-encoder <command> [options]` onto the existing action scripts and
loads only the script a command needs, when it needs it. Options after the
command name are forwarded verbatim to the underlying script, so every
parameter that script accepts is available on the CLI unchanged.
#>

Set-StrictMode -Version Latest

function Get-VideoEncoderRoot {
    # This module lives in <repo>\module\; the repo root is its parent.
    return (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
}

function Get-VideoEncoderVersion {
    param([string]$RepoRoot = (Get-VideoEncoderRoot))

    $versionPath = Join-Path $RepoRoot "VERSION"
    if (Test-Path -LiteralPath $versionPath) {
        $v = ((Get-Content -LiteralPath $versionPath -ErrorAction SilentlyContinue | Select-Object -First 1) + "").Trim()
        if ($v) { return $v }
    }
    return "unknown"
}

# Command table: name -> action script, one-line summary, and readiness needs.
$script:VeCommands = @(
    [pscustomobject]@{ Name = "tools";         Script = "scripts\Ensure-Dependencies-Core.ps1"; Summary = "Download / update the encoder toolchain";     NeedsTools = $false; NeedsProfile = $false }
    [pscustomobject]@{ Name = "probe";         Script = "scripts\Probe-HardwareProfile.ps1";     Summary = "Build / refresh the machine hardware profile"; NeedsTools = $true;  NeedsProfile = $false }
    [pscustomobject]@{ Name = "encode-tv";     Script = "scripts\Start-TV.ps1";                  Summary = "Encode a TV library (720p profile)";          NeedsTools = $true;  NeedsProfile = $true  }
    [pscustomobject]@{ Name = "encode-movies"; Script = "scripts\Start-Movies.ps1";              Summary = "Encode a Movies library (1080p profile)";     NeedsTools = $true;  NeedsProfile = $true  }
    [pscustomobject]@{ Name = "dvd-tv";        Script = "scripts\Start-DVD-TV.ps1";              Summary = "Rip / encode a TV DVD (.iso/.img/VIDEO_TS)";   NeedsTools = $true;  NeedsProfile = $true  }
    [pscustomobject]@{ Name = "dvd-movies";    Script = "scripts\Start-DVD-Movies.ps1";          Summary = "Rip / encode a movie DVD (.iso/.img/VIDEO_TS)"; NeedsTools = $true; NeedsProfile = $true }
    [pscustomobject]@{ Name = "filebot";       Script = "scripts\Start-FileBot-Rename.ps1";      Summary = "Rename / stage files with FileBot";           NeedsTools = $true;  NeedsProfile = $false }
    [pscustomobject]@{ Name = "menu";          Script = "scripts\Menu-Core.ps1";                 Summary = "Launch the interactive menu";                 NeedsTools = $false; NeedsProfile = $false }
)

function Get-VideoEncoderCommands {
    return $script:VeCommands
}

function Test-VideoEncoderTools {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $tools = Join-Path $RepoRoot "tools"
    return (
        (Test-Path -LiteralPath (Join-Path $tools "handbrake\HandBrakeCLI.exe")) -and
        (Test-Path -LiteralPath (Join-Path $tools "ffmpeg\bin\ffmpeg.exe")) -and
        (Test-Path -LiteralPath (Join-Path $tools "ffmpeg\bin\ffprobe.exe"))
    )
}

function Test-VideoEncoderProfile {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return (Test-Path -LiteralPath (Join-Path $RepoRoot "config\hardware-profile.json"))
}

function Get-VideoEncoderHelp {
    $ver = Get-VideoEncoderVersion
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("Portable Video Encoder $ver")
    $lines.Add("")
    $lines.Add("Usage:")
    $lines.Add("  video-encoder <command> [options]")
    $lines.Add("  video-encoder                     (no command -> interactive menu)")
    $lines.Add("  video-encoder help | --help | -h")
    $lines.Add("")
    $lines.Add("Commands:")
    foreach ($c in $script:VeCommands) {
        $lines.Add(("  {0,-14} {1}" -f $c.Name, $c.Summary))
    }
    $lines.Add("")
    $lines.Add("Options after the command are passed straight through to the underlying")
    $lines.Add("script. Examples:")
    $lines.Add("  video-encoder tools -ForceRedownload")
    $lines.Add("  video-encoder probe -RequireTools")
    $lines.Add("  video-encoder encode-tv -RootPath 'Y:\TV Shows' -EnableFileBotRename")
    $lines.Add("  video-encoder encode-movies -RootPath 'Y:\Movies' -Quality 22")
    $lines.Add("  video-encoder dvd-movies -SourcePath 'D:\' -OutputRoot 'Y:\Movies'")
    $lines.Add("")
    $lines.Add("See a command's full parameter set with, e.g.:")
    $lines.Add("  Get-Help .\scripts\Start-TV.ps1 -Detailed")

    return ($lines -join [Environment]::NewLine)
}

function Resolve-VeParamName {
    # Resolve a user-typed parameter name to the target script's real parameter
    # name, allowing case-insensitive exact match and unambiguous prefixes
    # (so '-Root' maps to '-RootPath').
    param(
        [Parameter(Mandatory)]$Parameters,
        [Parameter(Mandatory)][string]$Name
    )

    foreach ($k in $Parameters.Keys) {
        if ($k -ieq $Name) { return $k }
    }

    $prefixHits = @($Parameters.Keys | Where-Object { $_ -ilike ($Name + "*") })
    if ($prefixHits.Count -eq 1) { return $prefixHits[0] }
    if ($prefixHits.Count -gt 1) {
        throw ("Ambiguous parameter '-" + $Name + "' matches: " + ($prefixHits -join ", "))
    }
    return $null
}

function ConvertTo-VeSplat {
    <#
    Parses a flat token list (as captured from the command line) into a
    hashtable suitable for splatting onto $ScriptPath. Uses the target script's
    own parameter metadata so switches, valued parameters, and '-Name:value'
    forms are all bound correctly. (Array splatting cannot do this; it binds
    positionally and mangles named arguments.)
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [object[]]$Tokens = @()
    )

    $parameters = (Get-Command -Name $ScriptPath -CommandType ExternalScript).Parameters
    $leaf = Split-Path -Leaf $ScriptPath
    $splat = @{}

    $i = 0
    while ($i -lt $Tokens.Count) {
        $tok = [string]$Tokens[$i]

        # -Name:value  (explicit form, common for switches like -Switch:$false)
        if ($tok -match '^-([A-Za-z][A-Za-z0-9]*):(.*)$') {
            $resolved = Resolve-VeParamName -Parameters $parameters -Name $Matches[1]
            if (-not $resolved) { throw ("Unknown parameter '-" + $Matches[1] + "' for " + $leaf + ".") }
            $val = $Matches[2]
            if ($parameters[$resolved].ParameterType -eq [switch]) {
                $splat[$resolved] = [System.Boolean]::Parse($val.TrimStart('$'))
            }
            else {
                $splat[$resolved] = $val
            }
            $i++
            continue
        }

        # -Name  (switch, or valued parameter that consumes the next token)
        if ($tok -match '^-([A-Za-z][A-Za-z0-9]*)$') {
            $resolved = Resolve-VeParamName -Parameters $parameters -Name $Matches[1]
            if (-not $resolved) { throw ("Unknown parameter '-" + $Matches[1] + "' for " + $leaf + ".") }

            if ($parameters[$resolved].ParameterType -eq [switch]) {
                $splat[$resolved] = $true
                $i++
                continue
            }

            if ($i + 1 -ge $Tokens.Count) { throw ("Missing value for parameter '-" + $resolved + "'.") }
            $splat[$resolved] = $Tokens[$i + 1]
            $i += 2
            continue
        }

        throw ("Unexpected argument '" + $tok + "'. All options must be named, e.g. -RootPath '...'.")
    }

    return $splat
}

function Invoke-VideoEncoder {
    <#
    .SYNOPSIS
    Dispatch a video-encoder subcommand to its action script.

    .EXAMPLE
    Invoke-VideoEncoder encode-tv -RootPath "Y:\TV Shows" -EnableFileBotRename

    .EXAMPLE
    video-encoder tools -ForceRedownload
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Command = "",

        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$Arguments = @()
    )

    $repoRoot = Get-VideoEncoderRoot

    if (-not $Command -or ($Command -in @("help", "--help", "-h", "/?"))) {
        Write-Host (Get-VideoEncoderHelp)
        return
    }

    $name = $Command.ToLowerInvariant()
    $cmd = $script:VeCommands | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $cmd) {
        Write-Host ("Unknown command: " + $Command) -ForegroundColor Red
        Write-Host ""
        Write-Host (Get-VideoEncoderHelp)
        throw ("Unknown command '" + $Command + "'. Run 'video-encoder help'.")
    }

    $scriptPath = Join-Path $repoRoot $cmd.Script
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw ("Command script not found: " + $scriptPath)
    }

    if ($cmd.NeedsTools -and -not (Test-VideoEncoderTools -RepoRoot $repoRoot)) {
        throw "Encoder tools are missing. Run 'video-encoder tools' first."
    }
    if ($cmd.NeedsProfile -and -not (Test-VideoEncoderProfile -RepoRoot $repoRoot)) {
        throw "Hardware profile is missing. Run 'video-encoder probe' first."
    }

    $splat = ConvertTo-VeSplat -ScriptPath $scriptPath -Tokens @($Arguments)

    # Menu-Core takes no parameters; forwarding anything is a mistake.
    if ($cmd.Name -eq "menu" -and $splat.Count -gt 0) {
        throw "The 'menu' command takes no options."
    }

    # Probe-HardwareProfile expects -RepoRoot; inject it when not supplied so the
    # CLI form 'video-encoder probe' works with no extra arguments.
    if ($cmd.Name -eq "probe" -and -not $splat.ContainsKey("RepoRoot")) {
        $splat["RepoRoot"] = $repoRoot
    }

    Write-Verbose ("Dispatching '{0}' -> {1}" -f $cmd.Name, $scriptPath)
    & $scriptPath @splat
}

Set-Alias -Name video-encoder -Value Invoke-VideoEncoder

Export-ModuleMember `
    -Function Invoke-VideoEncoder, Get-VideoEncoderHelp, Get-VideoEncoderVersion, Get-VideoEncoderCommands, Test-VideoEncoderTools, Test-VideoEncoderProfile `
    -Alias video-encoder
