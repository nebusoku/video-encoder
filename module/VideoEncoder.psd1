@{
    RootModule        = 'VideoEncoder.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = 'a8e05e9d-e15d-4c5f-a47c-783b22e226fc'
    Author            = 'nebusoku'
    Description       = 'Portable video encoder CLI: a subcommand dispatcher over the HandBrake/FFmpeg/FileBot action scripts.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Invoke-VideoEncoder',
        'Get-VideoEncoderHelp',
        'Get-VideoEncoderVersion',
        'Get-VideoEncoderCommands',
        'Test-VideoEncoderTools',
        'Test-VideoEncoderProfile'
    )
    AliasesToExport   = @('video-encoder')
    CmdletsToExport   = @()
    VariablesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('video', 'encoding', 'handbrake', 'ffmpeg', 'plex', 'cli')
            ProjectUri = 'https://github.com/nebusoku/video-encoder'
        }
    }
}
