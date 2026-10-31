param(
    [string]$Root
)

$ErrorActionPreference = "Stop"
$sourceRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $sourceRoot
}

$readerDll = Join-Path $Root "Components\PBZSaveReader.dll"

& (Join-Path $sourceRoot "build_pbzsavareader.ps1") -OutPath $readerDll
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$assembly = [Reflection.Assembly]::LoadFrom($readerDll)
$readerType = $assembly.GetType("PBZ.SaveReader", $true)

$versionProperty = $readerType.GetProperty("Version")
if ($null -eq $versionProperty) {
    throw "PBZ.SaveReader.Version is missing"
}

$findSaveMethod = $readerType.GetMethod("FindSaveFile")
$readSnapshotMethod = $readerType.GetMethod(
    "ReadSnapshotText",
    [Type[]]@([string]))
if ($null -eq $findSaveMethod -or $null -eq $readSnapshotMethod) {
    throw "PBZ.SaveReader public API is incomplete"
}

$version = [string]$versionProperty.GetValue($null, $null)
if ([string]::IsNullOrWhiteSpace($version)) {
    throw "PBZ.SaveReader.Version is empty"
}

Write-Output ("READER_API_OK v" + $version)

& (Join-Path $sourceRoot "OodleCleanRoom\test.ps1")
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Output "PBZ_SAVE_READER_TEST_OK"
