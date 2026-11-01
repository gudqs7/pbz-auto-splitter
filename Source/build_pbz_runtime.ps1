<#
.SYNOPSIS
生成已去除注释的 PBZ 运行时 ASL/XML 文件。

.PARAMETER RepositoryRoot
PBZ_Release 仓库根目录，默认是本脚本目录的上级目录。

.PARAMETER OutputDirectory
目标 Components 目录，默认是仓库中的 Components 目录。

.PARAMETER LiveSplitComponentsPath
指定 -SyncLiveSplit 时使用的本机 LiveSplit Components 目录。

.PARAMETER SyncLiveSplit
生成完成后复制 ASL/XML 和必需二进制依赖到本机 LiveSplit 目录。

.OUTPUTS
输出已生成和已同步文件的路径。
#>
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory,
    [string]$LiveSplitComponentsPath = "D:\soft\e-game\LiveSplit_1.8.29\Components",
    [switch]$SyncLiveSplit
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "comment_tools.ps1")

$runtimeSourceRoot = Join-Path $PSScriptRoot "Runtime"
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot "Components"
}

$runtimeAssets = @(
    [pscustomobject]@{
        SourceName = "PBZ-AutoSplitter.asl"
        TargetName = "PBZ-AutoSplitter.asl"
        CommentType = "CSharp"
    },
    [pscustomobject]@{
        SourceName = "PBZ-AutoSplitter_BySave.asl"
        TargetName = "PBZ-AutoSplitter_BySave.asl"
        CommentType = "CSharp"
    },
    [pscustomobject]@{
        SourceName = "PBZ.BossSettings.xml"
        TargetName = "PBZ.BossSettings.xml"
        CommentType = "Xml"
    },
    [pscustomobject]@{
        SourceName = "PBZ.BossSettings.en.xml"
        TargetName = "PBZ.BossSettings.en.xml"
        CommentType = "Xml"
    }
)

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

foreach ($asset in $runtimeAssets) {
    $sourcePath = Join-Path $runtimeSourceRoot $asset.SourceName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Runtime source file is missing: $sourcePath"
    }

    $sourceText = [IO.File]::ReadAllText($sourcePath)
    if ($asset.CommentType -eq "CSharp") {
        $runtimeText = Remove-CSharpComments -Text $sourceText
    }
    else {
        $runtimeText = Remove-XmlComments -Text $sourceText
    }
    $runtimeText = Normalize-CommentStrippedText -Text $runtimeText

    $targetPath = Join-Path $OutputDirectory $asset.TargetName
    Write-Utf8NoBom -Path $targetPath -Text $runtimeText

    if ($asset.CommentType -eq "CSharp") {
        Assert-CSharpCommentsRemoved -Path $targetPath
    }
    else {
        Assert-XmlCommentsRemoved -Path $targetPath
    }

    Write-Output "runtime generated: $targetPath"
}

if (-not $SyncLiveSplit) {
    return
}

if (-not (Test-Path -LiteralPath $LiveSplitComponentsPath -PathType Container)) {
    throw "LiveSplit Components directory is missing: $LiveSplitComponentsPath"
}

$syncNames = @(
    "PBZ-AutoSplitter.asl",
    "PBZ-AutoSplitter_BySave.asl",
    "PBZ.BossSettings.xml",
    "PBZ.BossSettings.en.xml",
    "asl-help",
    "PBZSaveReader.dll"
)

foreach ($name in $syncNames) {
    $repositoryPath = Join-Path $OutputDirectory $name
    if (-not (Test-Path -LiteralPath $repositoryPath -PathType Leaf)) {
        throw "Runtime file is missing from generated output: $repositoryPath"
    }

    $liveSplitPath = Join-Path $LiveSplitComponentsPath $name
    if (Test-Path -LiteralPath $liveSplitPath -PathType Leaf) {
        $repositoryItem = Get-Item -LiteralPath $repositoryPath
        $liveSplitItem = Get-Item -LiteralPath $liveSplitPath
        $repositoryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $repositoryPath).Hash
        $liveSplitHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $liveSplitPath).Hash

        if ($repositoryHash -ne $liveSplitHash -and
            $liveSplitItem.LastWriteTimeUtc -gt $repositoryItem.LastWriteTimeUtc.AddSeconds(1)) {
            throw "LiveSplit runtime file is newer and differs; inspect and merge it first: $liveSplitPath"
        }
    }

    Copy-Item -LiteralPath $repositoryPath -Destination $liveSplitPath -Force
    $repositoryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $repositoryPath).Hash
    $liveSplitHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $liveSplitPath).Hash
    if ($repositoryHash -ne $liveSplitHash) {
        throw "Runtime synchronization hash mismatch: $liveSplitPath"
    }

    Write-Output "runtime synchronized: $liveSplitPath"
}
