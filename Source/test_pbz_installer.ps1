$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$base = Join-Path ([IO.Path]::GetTempPath()) ("pbz-installer-test-" + [Guid]::NewGuid().ToString("N"))
$target = Join-Path $base "LiveSplit"
try {
    New-Item -ItemType Directory -Path (Join-Path $target "Components") -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $target "LiveSplit.exe"), [byte[]]@())

    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot "Installer\Install-PBZ.ps1") `
        -SourceRoot $repositoryRoot -InstallRoot $target -SkipLaunchPrompt
    if ($LASTEXITCODE -ne 0) {
        throw "Installer exited with code $LASTEXITCODE"
    }

    $required = @(
        "LiveSplit-PBZ.exe.lnk",
        "pbz.lsl",
        "pbz.lss",
        "Components\asl-help",
        "Components\PBZ-AutoSplitter.asl",
        "Components\PBZ.BossSettings.xml",
        "Components\PBZ.BossSettings.en.xml"
    )
    foreach ($relative in $required) {
        $path = Join-Path $target $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Installer did not create: $relative"
        }
    }
    foreach ($excluded in @("Components\PBZ-AutoSplitter_BySave.asl", "Components\PBZSaveReader.dll")) {
        if (Test-Path -LiteralPath (Join-Path $target $excluded)) {
            throw "Installer copied excluded file: $excluded"
        }
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $target "LiveSplit-PBZ.exe.lnk"))
    if ($shortcut.TargetPath -ne (Join-Path $target "LiveSplit.exe")) {
        throw "Unexpected shortcut target: $($shortcut.TargetPath)"
    }
    if ($shortcut.Arguments -ne "-l pbz.lsl") {
        throw "Unexpected shortcut arguments: $($shortcut.Arguments)"
    }
    if ($shortcut.WorkingDirectory -ne $target) {
        throw "Unexpected shortcut working directory: $($shortcut.WorkingDirectory)"
    }

    $installedAsl = Join-Path $target "Components\PBZ-AutoSplitter.asl"
    Add-Content -LiteralPath $installedAsl -Value "// user-marker"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot "Installer\Install-PBZ.ps1") `
        -SourceRoot $repositoryRoot -InstallRoot $target -SkipLaunchPrompt
    if ($LASTEXITCODE -ne 0) {
        throw "Second installer run exited with code $LASTEXITCODE"
    }
    $backup = Get-ChildItem -LiteralPath $target -Directory -Filter "PBZ_Install_Backup_*" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $backup) {
        throw "Installer did not create a backup directory"
    }
    $backedUpAsl = Join-Path $backup.FullName "Components\PBZ-AutoSplitter.asl"
    if (-not (Test-Path -LiteralPath $backedUpAsl -PathType Leaf)) {
        throw "Installer did not back up the existing ASL"
    }
    if (-not ((Get-Content -LiteralPath $backedUpAsl -Raw).Contains("// user-marker"))) {
        throw "Installer backup did not preserve the existing ASL"
    }

    Write-Output "PBZ_INSTALLER_TEST_OK"
}
finally {
    if (Test-Path -LiteralPath $base) {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}