<#
.SYNOPSIS
验证生成的 PBZ 运行时文件没有注释，并编译解析两份 ASL。

.PARAMETER RepositoryRoot
PBZ_Release 仓库根目录，默认是本脚本目录的上级目录。

.PARAMETER LiveSplitRoot
包含 LiveSplit.Core.dll 和 Scriptable Auto Splitter 组件的 LiveSplit
安装目录，默认是 D:\soft\e-game\LiveSplit_1.8.37。

.OUTPUTS
输出 ASL_PARSE_OK 行，最后输出 PBZ_RUNTIME_TEST_OK。
#>
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LiveSplitRoot = "D:\soft\e-game\LiveSplit_1.8.37"
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

# 设置 XML 必须随脚本启动加载，不能重新放回受游戏进程门禁保护的 init。
foreach ($aslPath in $aslFiles) {
    $text = [IO.File]::ReadAllText($aslPath)
    $startupIndex = $text.IndexOf("`nstartup", [StringComparison]::Ordinal)
    $initIndex = $text.IndexOf("`ninit", [StringComparison]::Ordinal)
    if ($startupIndex -lt 0 -or $initIndex -le $startupIndex) {
        throw "Could not locate startup/init lifecycle blocks: $aslPath"
    }

    $startupText = $text.Substring($startupIndex, $initIndex - $startupIndex)
    $initText = $text.Substring($initIndex)
    $loadInvocation = "((Action)vars.LoadSettings)();"
    if (-not $startupText.Contains($loadInvocation)) {
        throw "Settings are not loaded during startup: $aslPath"
    }
    if ($initText.Contains($loadInvocation)) {
        throw "Settings must not be loaded during init: $aslPath"
    }
    if (-not $initText.Contains("build gate: matched PBZ process")) {
        throw "Missing build-gate success log: $aslPath"
    }
    if (-not $initText.Contains("build gate: no matching PBZ process")) {
        throw "Missing build-gate failure log: $aslPath"
    }
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
