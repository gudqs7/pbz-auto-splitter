<#
.SYNOPSIS
构建并验证无注释的 PBZ 发布压缩包。

.PARAMETER Version
用于默认压缩包名称的发布版本号。

.PARAMETER OutputPath
显式输出 zip 路径，默认是 dist\PBZ_AutoSplit_<Version>.zip。

.OUTPUTS
输出最终压缩包路径和字节数。
#>
param(
    [string]$Version = "2.2.1",
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$sourceRoot = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $sourceRoot
. (Join-Path $sourceRoot "comment_tools.ps1")

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repositoryRoot "dist\PBZ_AutoSplit_$Version.zip"
}

& (Join-Path $sourceRoot "build_pbz_runtime.ps1") -RepositoryRoot $repositoryRoot
& (Join-Path $sourceRoot "test_pbz_runtime.ps1") -RepositoryRoot $repositoryRoot

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

    # 直接在暂存 Components 目录中重新生成运行时文件。
    # 发布包中的 ASL 和 XML 绝不能包含注释。
    & (Join-Path $sourceRoot "build_pbz_runtime.ps1") -RepositoryRoot $repositoryRoot -OutputDirectory (Join-Path $stage "Components")

    # 清理所有发布代码和配置文件中的注释。这样即使发布包包含 Source，
    # 其中也只有无注释版本；仓库源码仍保留开发注释。
    $stagedCodeFiles = foreach ($candidate in Get-ChildItem -LiteralPath $stage -Recurse -File) {
        if ($candidate.Extension -in @(".asl", ".cs", ".ps1", ".xml")) {
            $candidate
        }
    }
    foreach ($file in $stagedCodeFiles) {
        $text = [IO.File]::ReadAllText($file.FullName)
        if ($file.Extension.Equals(".xml", [StringComparison]::OrdinalIgnoreCase)) {
            $sanitized = Remove-XmlComments -Text $text
        }
        elseif ($file.Extension.Equals(".ps1", [StringComparison]::OrdinalIgnoreCase)) {
            $sanitized = Remove-PowerShellComments -Text $text
        }
        else {
            $sanitized = Remove-CSharpComments -Text $text
        }
        $sanitized = Normalize-CommentStrippedText -Text $sanitized
        Write-Utf8NoBom -Path $file.FullName -Text $sanitized

        if ($file.Extension.Equals(".xml", [StringComparison]::OrdinalIgnoreCase)) {
            Assert-XmlCommentsRemoved -Path $file.FullName
        }
        elseif ($file.Extension.Equals(".ps1", [StringComparison]::OrdinalIgnoreCase)) {
            Assert-PowerShellCommentsRemoved -Path $file.FullName
        }
        else {
            Assert-CSharpCommentsRemoved -Path $file.FullName
        }
    }

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
