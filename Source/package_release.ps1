param(
    [string]$Version = "2.2.0",
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$sourceRoot = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $sourceRoot

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repositoryRoot "dist\PBZ_AutoSplit_$Version.zip"
}

& (Join-Path $sourceRoot "test_pbzsavareader.ps1") -Root $repositoryRoot
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$stage = Join-Path ([IO.Path]::GetTempPath()) (
    "pbz-auto-splitter-" + [Guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "README.md") `
        -Destination $stage
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "CHANGELOG.md") `
        -Destination $stage
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "docs") `
        -Destination $stage -Recurse
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "Components") `
        -Destination $stage -Recurse

    $stagedSource = Join-Path $stage "Source"
    New-Item -ItemType Directory -Force -Path $stagedSource | Out-Null
    Copy-Item -Path (Join-Path $sourceRoot "*") `
        -Destination $stagedSource -Recurse -Force

    $generatedDirectories = @(
        (Join-Path $stagedSource "bin"),
        (Join-Path $stagedSource "OodleCleanRoom\bin"),
        (Join-Path $stagedSource "OodleCleanRoom\vectors")
    )
    foreach ($directory in $generatedDirectories) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }
    Compress-Archive -Path (Join-Path $stage "*") `
        -DestinationPath $OutputPath -CompressionLevel Optimal
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}

$archive = Get-Item -LiteralPath $OutputPath
Write-Output ("release zip " + $archive.FullName + " " + $archive.Length + " bytes")
