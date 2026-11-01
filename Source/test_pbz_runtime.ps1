<#
.SYNOPSIS
验证生成的 PBZ 运行时文件没有注释，并编译解析两份 ASL。

.PARAMETER RepositoryRoot
PBZ_Release 仓库根目录，默认是本脚本目录的上级目录。

.PARAMETER LiveSplitRoot
包含 LiveSplit.Core.dll 和 Scriptable Auto Splitter 组件的 LiveSplit
安装目录，默认是 RepositoryRoot 的上级目录。

.OUTPUTS
输出 ASL_PARSE_OK 行，最后输出 PBZ_RUNTIME_TEST_OK。
#>
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LiveSplitRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "comment_tools.ps1")

$components = Join-Path $RepositoryRoot "Components"
$aslFiles = @(
    (Join-Path $components "PBZ-AutoSplitter.asl"),
    (Join-Path $components "PBZ-AutoSplitter_BySave.asl")
)
$xmlFiles = @(
    (Join-Path $components "PBZ.BossSettings.xml"),
    (Join-Path $components "PBZ.BossSettings.en.xml")
)

foreach ($aslPath in $aslFiles) {
    Assert-CSharpCommentsRemoved -Path $aslPath
}
foreach ($xmlPath in $xmlFiles) {
    Assert-XmlCommentsRemoved -Path $xmlPath
}

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
    throw "C# compiler was not found: $csc"
}

$probeName = "_pbz_asl_parse_probe_" + [Guid]::NewGuid().ToString("N") + ".exe"
$probePath = Join-Path $LiveSplitRoot $probeName

try {
    & $csc /nologo /optimize+ "/out:$probePath" (Join-Path $PSScriptRoot "AslParseProbe.cs")
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile the ASL parse probe."
    }

    & $probePath @aslFiles
    if ($LASTEXITCODE -ne 0) {
        throw "Generated ASL failed to parse."
    }
}
finally {
    if (Test-Path -LiteralPath $probePath -PathType Leaf) {
        Remove-Item -LiteralPath $probePath -Force
    }
}

Write-Output "PBZ_RUNTIME_TEST_OK"
