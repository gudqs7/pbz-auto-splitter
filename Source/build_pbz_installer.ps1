param(
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repositoryRoot "Install-PBZ.bat"
}

$sourcePath = Join-Path $PSScriptRoot "Installer\Install-PBZ.ps1"
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Installer source not found: $sourcePath"
}

$scriptText = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8)
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
$bat = @"
@echo off
setlocal
chcp 65001 >nul
title PBZ Auto Splitter Installer
set "PBZ_INSTALL_SOURCE=%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -EncodedCommand $encoded
set "PBZ_INSTALL_RESULT=%ERRORLEVEL%"
echo.
pause
endlocal & exit /b %PBZ_INSTALL_RESULT%
"@

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
[IO.File]::WriteAllText($OutputPath, $bat, (New-Object Text.ASCIIEncoding))
Write-Output ("installer generated: " + $OutputPath)