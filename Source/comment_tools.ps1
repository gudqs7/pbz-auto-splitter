Set-StrictMode -Version Latest

<#
.SYNOPSIS
移除 C# 风格的行注释和块注释，同时保留字符串与字符字面量。

.PARAMETER Text
需要清理的源码文本。

.OUTPUTS
移除注释并保留换行符后的文本。
#>
function Remove-CSharpComments {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $builder = New-Object System.Text.StringBuilder ($Text.Length + 16)
    $state = "Normal"
    $index = 0

    while ($index -lt $Text.Length) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }

        switch ($state) {
            "Normal" {
                if ($character -eq '/' -and $next -eq '/') {
                    $state = "LineComment"
                    $index += 2
                    continue
                }
                if ($character -eq '/' -and $next -eq '*') {
                    $state = "BlockComment"
                    $index += 2
                    continue
                }
                if ($character -eq '@' -and $next -eq '"') {
                    [void]$builder.Append('@"')
                    $state = "VerbatimString"
                    $index += 2
                    continue
                }
                if ($character -eq '"') {
                    [void]$builder.Append($character)
                    $state = "String"
                    $index++
                    continue
                }
                if ($character -eq "'") {
                    [void]$builder.Append($character)
                    $state = "Character"
                    $index++
                    continue
                }

                [void]$builder.Append($character)
                $index++
            }
            "String" {
                [void]$builder.Append($character)
                if ($character -eq '\' -and $index + 1 -lt $Text.Length) {
                    [void]$builder.Append($Text[$index + 1])
                    $index += 2
                    continue
                }
                if ($character -eq '"') {
                    $state = "Normal"
                }
                $index++
            }
            "VerbatimString" {
                [void]$builder.Append($character)
                if ($character -eq '"' -and $next -eq '"') {
                    [void]$builder.Append($next)
                    $index += 2
                    continue
                }
                if ($character -eq '"') {
                    $state = "Normal"
                }
                $index++
            }
            "Character" {
                [void]$builder.Append($character)
                if ($character -eq '\' -and $index + 1 -lt $Text.Length) {
                    [void]$builder.Append($Text[$index + 1])
                    $index += 2
                    continue
                }
                if ($character -eq "'") {
                    $state = "Normal"
                }
                $index++
            }
            "LineComment" {
                if ($character -eq "`r" -or $character -eq "`n") {
                    [void]$builder.Append($character)
                    $state = "Normal"
                }
                $index++
            }
            "BlockComment" {
                if ($character -eq '*' -and $next -eq '/') {
                    $state = "Normal"
                    $index += 2
                    continue
                }
                if ($character -eq "`r" -or $character -eq "`n") {
                    [void]$builder.Append($character)
                }
                $index++
            }
            default {
                throw "Unknown comment scanner state: $state"
            }
        }
    }

    if ($state -eq "BlockComment") {
        throw "Unterminated block comment."
    }

    return $builder.ToString()
}

<#
.SYNOPSIS
从 XML 文本中移除所有 XML 注释。

.PARAMETER Text
需要清理的 XML 文本。

.OUTPUTS
不包含注释节点的 XML 文本。
#>
function Remove-XmlComments {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    return [regex]::Replace($Text, '(?s)<!--.*?-->', '')
}

<#
.SYNOPSIS
规范化移除注释后的运行时文本。

.PARAMETER Text
需要规范化的无注释文本。

.OUTPUTS
移除行尾空白、压缩连续空行，并在末尾保留一个换行符的文本。
#>
function Normalize-CommentStrippedText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $sourceLines = $normalized.Split("`n")
    $outputLines = New-Object System.Collections.Generic.List[string]
    $previousWasBlank = $false

    foreach ($line in $sourceLines) {
        $trimmed = $line.TrimEnd()
        if ($trimmed.Length -eq 0) {
            if (-not $previousWasBlank -and $outputLines.Count -gt 0) {
                $outputLines.Add("")
            }
            $previousWasBlank = $true
            continue
        }

        $outputLines.Add($trimmed)
        $previousWasBlank = $false
    }

    while ($outputLines.Count -gt 0 -and $outputLines[$outputLines.Count - 1].Length -eq 0) {
        $outputLines.RemoveAt($outputLines.Count - 1)
    }

    return ($outputLines -join [Environment]::NewLine) + [Environment]::NewLine
}

<#
.SYNOPSIS
移除 PowerShell 行注释、块注释和 here-string 内容之外的注释，
同时保留引号字符串内容。

.PARAMETER Text
需要清理的 PowerShell 源码文本。

.OUTPUTS
移除注释后的 PowerShell 文本。
#>
function Remove-PowerShellComments {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $builder = New-Object System.Text.StringBuilder ($Text.Length + 16)
    $state = "Normal"
    $index = 0

    while ($index -lt $Text.Length) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }

        switch ($state) {
            "Normal" {
                if ($character -eq '<' -and $next -eq '#') {
                    $state = "BlockComment"
                    $index += 2
                    continue
                }
                if ($character -eq '#') {
                    $state = "LineComment"
                    $index++
                    continue
                }
                if ($character -eq '@' -and $next -eq "'") {
                    [void]$builder.Append("@'")
                    $state = "SingleHereString"
                    $index += 2
                    continue
                }
                if ($character -eq '@' -and $next -eq '"') {
                    [void]$builder.Append('@"')
                    $state = "DoubleHereString"
                    $index += 2
                    continue
                }
                if ($character -eq "'") {
                    [void]$builder.Append($character)
                    $state = "SingleQuoted"
                    $index++
                    continue
                }
                if ($character -eq '"') {
                    [void]$builder.Append($character)
                    $state = "DoubleQuoted"
                    $index++
                    continue
                }

                [void]$builder.Append($character)
                $index++
            }
            "SingleQuoted" {
                [void]$builder.Append($character)
                if ($character -eq "'" -and $next -eq "'") {
                    [void]$builder.Append($next)
                    $index += 2
                    continue
                }
                if ($character -eq "'") {
                    $state = "Normal"
                }
                $index++
            }
            "DoubleQuoted" {
                [void]$builder.Append($character)
                if ($character -eq '`' -and $index + 1 -lt $Text.Length) {
                    [void]$builder.Append($Text[$index + 1])
                    $index += 2
                    continue
                }
                if ($character -eq '"') {
                    $state = "Normal"
                }
                $index++
            }
            "SingleHereString" {
                [void]$builder.Append($character)
                if (($index -eq 0 -or $Text[$index - 1] -eq "`n") -and
                    $character -eq "'" -and $next -eq '@') {
                    [void]$builder.Append($next)
                    $state = "Normal"
                    $index += 2
                    continue
                }
                $index++
            }
            "DoubleHereString" {
                [void]$builder.Append($character)
                if (($index -eq 0 -or $Text[$index - 1] -eq "`n") -and
                    $character -eq '"' -and $next -eq '@') {
                    [void]$builder.Append($next)
                    $state = "Normal"
                    $index += 2
                    continue
                }
                $index++
            }
            "LineComment" {
                if ($character -eq "`r" -or $character -eq "`n") {
                    [void]$builder.Append($character)
                    $state = "Normal"
                }
                $index++
            }
            "BlockComment" {
                if ($character -eq '#' -and $next -eq '>') {
                    $state = "Normal"
                    $index += 2
                    continue
                }
                if ($character -eq "`r" -or $character -eq "`n") {
                    [void]$builder.Append($character)
                }
                $index++
            }
            default {
                throw "Unknown PowerShell comment scanner state: $state"
            }
        }
    }

    if ($state -eq "BlockComment" -or
        $state -eq "SingleHereString" -or
        $state -eq "DoubleHereString") {
        throw "Unterminated PowerShell comment or here-string."
    }

    return $builder.ToString()
}

<#
.SYNOPSIS
写入不带字节顺序标记的 UTF-8 文本。

.PARAMETER Path
目标文件路径。

.PARAMETER Text
需要写入的文本。

.OUTPUTS
无返回值。
#>
function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

<#
.SYNOPSIS
验证 C#/ASL 文件移除注释后不会再发生变化。

.PARAMETER Path
需要检查的生成后 C#/ASL 文件。

.OUTPUTS
无返回值；仍有注释时抛出异常。
#>
function Assert-CSharpCommentsRemoved {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = [IO.File]::ReadAllText($Path)
    $sanitized = Remove-CSharpComments -Text $text
    if ($sanitized -cne $text) {
        throw "Comments remain after sanitization: $Path"
    }
}

<#
.SYNOPSIS
验证 XML 文件中不存在注释节点。

.PARAMETER Path
需要检查的生成后 XML 文件。

.OUTPUTS
无返回值；仍有 XML 注释时抛出异常。
#>
function Assert-XmlCommentsRemoved {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = [IO.File]::ReadAllText($Path)
    if ($text -match '(?s)<!--.*?-->') {
        throw "XML comments remain after sanitization: $Path"
    }
}

<#
.SYNOPSIS
验证 PowerShell 文件移除注释后不会再发生变化。

.PARAMETER Path
需要检查的生成后 PowerShell 文件。

.OUTPUTS
无返回值；仍有注释时抛出异常。
#>
function Assert-PowerShellCommentsRemoved {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = [IO.File]::ReadAllText($Path)
    $sanitized = Remove-PowerShellComments -Text $text
    if ($sanitized -cne $text) {
        throw "PowerShell comments remain after sanitization: $Path"
    }
}
