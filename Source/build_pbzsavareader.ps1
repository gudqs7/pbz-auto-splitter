param(
    [string]$OutPath
)

$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $src

if (-not (Test-Path -LiteralPath $src -PathType Container)) {
    throw "Source directory not found: $src"
}

if ([string]::IsNullOrWhiteSpace($OutPath)) {
    $OutPath = Join-Path $repositoryRoot "Components\PBZSaveReader.dll"
}

$cleanRoomSrc = Join-Path $src "OodleCleanRoom\src"
if (-not (Test-Path -LiteralPath $cleanRoomSrc -PathType Container)) {
    throw "OodleCleanRoom source directory not found"
}

$cscCandidates = @(
    "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
if (-not $csc) {
    throw "csc.exe not found"
}

$outDirectory = Split-Path -Parent $OutPath
if (-not (Test-Path -LiteralPath $outDirectory -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $outDirectory | Out-Null
}

& $csc /nologo /target:library /platform:x64 /optimize+ /out:$OutPath `
    (Join-Path $src "SaveReader.Api.cs") `
    (Join-Path $src "SaveReader.Container.cs") `
    (Join-Path $src "SaveReader.Crypto.cs") `
    (Join-Path $src "SaveReader.Json.cs") `
    (Join-Path $src "GameOodleDecompressor.cs") `
    (Get-ChildItem -LiteralPath $cleanRoomSrc -Filter *.cs |
        ForEach-Object { $_.FullName })

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$info = Get-Item -LiteralPath $OutPath
Write-Output ("built " + $info.FullName + " " + $info.Length + " bytes")
