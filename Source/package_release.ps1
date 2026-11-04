<#
.SYNOPSIS
构建仅含内存版运行时的一键安装发布包。

.PARAMETER Version
用于默认压缩包名称的发布版本号。

.PARAMETER OutputPath
显式输出 zip 路径，默认是 dist\PBZ_AutoSplit_<Version>.zip。
#>
param(
    [string]$Version = "2.2.5",
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$sourceRoot = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $sourceRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repositoryRoot "dist\PBZ_AutoSplit_$Version.zip"
}

& (Join-Path $sourceRoot "build_pbz_runtime.ps1") -RepositoryRoot $repositoryRoot
& (Join-Path $sourceRoot "test_pbz_runtime.ps1") -RepositoryRoot $repositoryRoot
& (Join-Path $sourceRoot "build_pbz_installer.ps1") -OutputPath (Join-Path $repositoryRoot "Install-PBZ.bat")
& (Join-Path $sourceRoot "test_pbz_installer.ps1")
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ("pbz-auto-splitter-" + [Guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $repositoryRoot "Install-PBZ.bat") -Destination $stage
    foreach ($layoutName in @("pbz.lsl", "pbz.lss")) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot "lss-sample\$layoutName") -Destination $stage
    }

    $stagedComponents = Join-Path $stage "Components"
    New-Item -ItemType Directory -Path $stagedComponents -Force | Out-Null
    foreach ($runtimeName in @(
        "asl-help",
        "PBZ-AutoSplitter.asl",
        "PBZ.BossSettings.xml",
        "PBZ.BossSettings.en.xml"
    )) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot "Components\$runtimeName") `
            -Destination (Join-Path $stagedComponents $runtimeName)
    }

    $expected = @(
        "Install-PBZ.bat",
        "pbz.lsl",
        "pbz.lss",
        "Components\asl-help",
        "Components\PBZ-AutoSplitter.asl",
        "Components\PBZ.BossSettings.xml",
        "Components\PBZ.BossSettings.en.xml"
    ) | Sort-Object
    $actual = @(
        Get-ChildItem -LiteralPath $stage -Recurse -File |
            ForEach-Object { $_.FullName.Substring($stage.Length + 1) }
    ) | Sort-Object
    $missing = @($expected | Where-Object { $_ -notin $actual })
    $unexpected = @($actual | Where-Object { $_ -notin $expected })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
        throw "发布包内容不符合精简规则。缺失: $($missing -join ', ')；多余: $($unexpected -join ', ')"
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $OutputPath -CompressionLevel Optimal
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}

$archive = Get-Item -LiteralPath $OutputPath
Write-Output ("release zip " + $archive.FullName + " " + $archive.Length + " bytes")