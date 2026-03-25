function Resolve-PipelinePaths {
    param(
        [string]$Root
    )

    return [pscustomobject]@{
        IncomingMovies = Join-Path $Root "_incoming\movies"
        IncomingTV     = Join-Path $Root "_incoming\tv"

        StagingMovies  = Join-Path $Root "_staging\movies"
        StagingTV      = Join-Path $Root "_staging\tv"

        FinalMovies    = Join-Path $Root "movies"
        FinalTV        = Join-Path $Root "tv"

        Failed         = Join-Path $Root "_failed"
    }
}