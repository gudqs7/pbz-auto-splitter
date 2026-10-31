param(
    [string]$VectorDir = "$PSScriptRoot\vectors"
)

$ErrorActionPreference = "Stop"
& "$PSScriptRoot\build.ps1" | Out-Null

$vectors = Get-ChildItem -LiteralPath $VectorDir -Filter *.oodle |
    Sort-Object Name
if ($vectors.Count -eq 0) {
    Write-Output "OODLE_CLEANROOM_TEST_SKIPPED_NO_LOCAL_VECTORS"
    exit 0
}

$primary = $null
foreach ($vector in $vectors) {
    $expected = $vector.FullName -replace '\.oodle$', '.expected'
    if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) {
        throw "missing expected output: $expected"
    }

    Write-Output ("VECTOR " + $vector.Name)
    & "$PSScriptRoot\bin\OodleCleanRoom.Probe.exe" `
        $vector.FullName $expected
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    if ($null -eq $primary -and $vector.Name -like "PBZSaveGame-7400*") {
        $primary = @($vector.FullName, $expected)
    }
}

if ($null -eq $primary) {
    $first = $vectors[0]
    $primary = @(
        $first.FullName,
        ($first.FullName -replace '\.oodle$', '.expected')
    )
}

& "$PSScriptRoot\bin\OodleCleanRoom.FailureProbe.exe" `
    $primary[0] $primary[1]
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Output "OODLE_CLEANROOM_TEST_OK"
