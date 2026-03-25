function Invoke-FileBotRename {
    param(
        [string]$FileBotPath,
        [string]$InputPath,
        [string]$OutputPath,
        [string]$Format,
        [string]$Db
    )

    if (-not (Test-Path $FileBotPath)) {
        Write-Host "FileBot not found: $FileBotPath" -ForegroundColor Yellow
        return
    }

    Write-Host "Running FileBot rename on $InputPath" -ForegroundColor Cyan

    & $FileBotPath `
        -rename $InputPath `
        --output $OutputPath `
        --format $Format `
        --db $Db `
        --action move `
        --non-strict
}