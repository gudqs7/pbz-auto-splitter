param(
    [string]$OutDir = "$PSScriptRoot\bin"
)

$ErrorActionPreference = "Stop"
$cscCandidates = @(
    "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
if (-not $csc) {
    throw "csc.exe not found"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$sources = Get-ChildItem -LiteralPath "$PSScriptRoot\src" -Filter *.cs |
    ForEach-Object { $_.FullName }

& $csc /nologo /target:library /platform:x64 /optimize+ `
    /out:"$OutDir\OodleCleanRoom.dll" @sources
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $csc /nologo /target:exe /platform:x64 /optimize+ `
    /r:"$OutDir\OodleCleanRoom.dll" `
    /out:"$OutDir\OodleCleanRoom.Probe.exe" `
    "$PSScriptRoot\tests\Probe.cs"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $csc /nologo /target:exe /platform:x64 /optimize+ `
    /r:"$OutDir\OodleCleanRoom.dll" `
    /out:"$OutDir\OodleCleanRoom.FailureProbe.exe" `
    "$PSScriptRoot\tests\FailureProbe.cs"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Output "built $OutDir\OodleCleanRoom.dll"
