param(
    [string]$SourceRoot,
    [string]$InstallRoot,
    [switch]$SkipLaunchPrompt
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = $env:PBZ_INSTALL_SOURCE
}
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = $env:PBZ_INSTALL_ROOT
}
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    throw "安装器没有收到发布包目录。请直接运行发布包中的 Install-PBZ.bat。"
}
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)

function Get-FileSha256 {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}
function Resolve-PackageFile {
    param([string]$Name, [bool]$Required)
    $candidates = @(
        (Join-Path $SourceRoot $Name),
        (Join-Path $SourceRoot (Join-Path "lss-sample" $Name))
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    if ($Required) {
        throw "发布包缺少文件: $Name"
    }
    return $null
}

function Get-RequiredPackageFiles {
    $componentNames = @(
        "asl-help",
        "PBZ-AutoSplitter.asl",
        "PBZ.BossSettings.xml",
        "PBZ.BossSettings.en.xml"
    )
    $files = @{}
    foreach ($name in $componentNames) {
        $path = Join-Path $SourceRoot (Join-Path "Components" $name)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "发布包缺少文件: Components\$name"
        }
        $files[$name] = $path
    }
    $files["pbz.lsl"] = Resolve-PackageFile "pbz.lsl" $true
    $lss = Resolve-PackageFile "pbz.lss" $false
    if ($lss) {
        $files["pbz.lss"] = $lss
    }
    return $files
}

function Find-LiveSplitRoots {
    $hits = New-Object System.Collections.Generic.List[string]
    $drives = [IO.DriveInfo]::GetDrives() | Where-Object {
        $_.DriveType -eq [IO.DriveType]::Fixed -and
        $_.Name -notmatch '^C:'
    }
    foreach ($drive in $drives) {
        Write-Host ("正在扫描 {0} ..." -f $drive.RootDirectory.FullName) -ForegroundColor Cyan
        try {
            Get-ChildItem -LiteralPath $drive.RootDirectory.FullName `
                -Filter "LiveSplit.exe" -File -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $root = $_.Directory.FullName
                    if (-not ($hits | Where-Object { $_.Equals($root, [StringComparison]::OrdinalIgnoreCase) })) {
                        $hits.Add($root)
                    }
                }
        }
        catch {}
    }
    return @($hits | Sort-Object)
}

function Select-InstallRoot {
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        return [IO.Path]::GetFullPath($InstallRoot)
    }

    $roots = @(Find-LiveSplitRoots)
    if ($roots.Count -eq 0) {
        Write-Host "未在非 C 盘找到 LiveSplit.exe。" -ForegroundColor Yellow
        $manual = Read-Host "请输入 LiveSplit 所在目录；直接回车退出"
        if ([string]::IsNullOrWhiteSpace($manual)) {
            return $null
        }
        return [IO.Path]::GetFullPath($manual.Trim('"'))
    }

    if ($roots.Count -eq 1) {
        Write-Host ("已找到 LiveSplit: {0}" -f $roots[0]) -ForegroundColor Green
        return $roots[0]
    }

    Write-Host "找到多个 LiveSplit，请选择要安装到的目录:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $roots.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $roots[$i])
    }
    while ($true) {
        $answer = Read-Host "输入序号"
        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $roots.Count) {
            return $roots[$index - 1]
        }
        Write-Host "序号无效，请重新输入。" -ForegroundColor Red
    }
}

function Install-PBZ {
    $files = Get-RequiredPackageFiles
    $target = Select-InstallRoot
    if (-not $target) {
        Write-Host "已取消安装。" -ForegroundColor Yellow
        return $false
    }

    $liveSplitExe = Join-Path $target "LiveSplit.exe"
    if (-not (Test-Path -LiteralPath $liveSplitExe -PathType Leaf)) {
        throw "目标目录中没有 LiveSplit.exe: $target"
    }

    $running = Get-Process -Name "LiveSplit" -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.Equals($liveSplitExe, [StringComparison]::OrdinalIgnoreCase) }
        catch { $false }
    }
    if ($running) {
        Write-Host "检测到 LiveSplit 正在运行。" -ForegroundColor Yellow
        Read-Host "请先关闭 LiveSplit，完成后按回车继续" | Out-Null
        for ($i = 0; $i -lt 30; $i++) {
            $running = Get-Process -Name "LiveSplit" -ErrorAction SilentlyContinue | Where-Object {
                try { $_.Path -and $_.Path.Equals($liveSplitExe, [StringComparison]::OrdinalIgnoreCase) }
                catch { $false }
            }
            if (-not $running) { break }
            Start-Sleep -Milliseconds 250
        }
        if ($running) {
            throw "LiveSplit 仍在运行，无法替换组件。"
        }
    }

    $targetComponents = Join-Path $target "Components"
    if (-not (Test-Path -LiteralPath $targetComponents -PathType Container)) {
        New-Item -ItemType Directory -Path $targetComponents | Out-Null
    }

    $backupRoot = Join-Path $target ("PBZ_Install_Backup_" + (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
    $backupCreated = $false
    function Backup-ExistingFile {
        param([string]$Path, [string]$RelativeDirectory)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return
        }
        $backupDirectory = Join-Path $backupRoot $RelativeDirectory
        if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        }
        Copy-Item -LiteralPath $Path -Destination (Join-Path $backupDirectory (Split-Path -Leaf $Path)) -Force
        $script:backupCreated = $true
    }

    $componentNames = @(
        "asl-help",
        "PBZ-AutoSplitter.asl",
        "PBZ.BossSettings.xml",
        "PBZ.BossSettings.en.xml"
    )
    foreach ($name in $componentNames) {
        $destination = Join-Path $targetComponents $name
        Backup-ExistingFile $destination "Components"
        Copy-Item -LiteralPath $files[$name] -Destination $destination -Force
        if ((Get-FileSha256 $files[$name]) -ne
            (Get-FileSha256 $destination)) {
            throw "复制后校验失败: $destination"
        }
    }

    foreach ($name in @("pbz.lsl", "pbz.lss")) {
        if (-not $files.ContainsKey($name)) {
            continue
        }
        $destination = Join-Path $target $name
        Backup-ExistingFile $destination ""
        Copy-Item -LiteralPath $files[$name] -Destination $destination -Force
        if ((Get-FileSha256 $files[$name]) -ne
            (Get-FileSha256 $destination)) {
            throw "复制后校验失败: $destination"
        }
    }

    $shortcutPath = Join-Path $target "LiveSplit-PBZ.exe.lnk"
    Backup-ExistingFile $shortcutPath ""
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $liveSplitExe
    $shortcut.Arguments = "-l pbz.lsl"
    $shortcut.WorkingDirectory = $target
    $shortcut.IconLocation = "$liveSplitExe,0"
    $shortcut.Description = "Phantom Blade Zero LiveSplit"
    $shortcut.WindowStyle = 1
    $shortcut.Save()

    Write-Host ""
    Write-Host "安装完成。" -ForegroundColor Green
    Write-Host ("LiveSplit: {0}" -f $target)
    Write-Host ("快捷方式: {0}" -f $shortcutPath)
    if ($script:backupCreated) {
        Write-Host ("旧文件备份: {0}" -f $backupRoot)
    }

    if (-not $SkipLaunchPrompt -and $env:PBZ_INSTALL_SKIP_LAUNCH -ne "1") {
        $launch = Read-Host "现在启动 LiveSplit-PBZ 吗？[Y/n]"
        if ([string]::IsNullOrWhiteSpace($launch) -or $launch -match '^(?i)y(es)?$') {
            Start-Process -FilePath $shortcutPath
        }
    }
    return $true
}

try {
    Install-PBZ | Out-Null
}
catch {
    Write-Host ""
    Write-Host ("安装失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
exit 0