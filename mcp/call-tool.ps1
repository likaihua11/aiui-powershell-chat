<#
.SYNOPSIS
    本地 MCP 外部工具的命令行调度器（未挂载工具的调用入口）

.DESCRIPTION
    本地 MCP 只挂载少数几个常用工具（省 token），其余工具虽然不在 MCP 的
    tools/list 里，但脚本仍在 tools\ 或 tools\_disabled\ 中，可用本脚本直接调用。

    本脚本复刻服务端 Invoke-ExternalTool 的调用契约：
      · 参数 JSON 以 **UTF-8 字节** 写入子进程 stdin（不经过控制台代码页，中文不乱码）
      · 子进程 stdout 原样透传，stderr 附加在末尾
      · 子进程退出码非 0 时本脚本也返回非 0

.USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 list
    powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 schema <工具名>
    powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 run <工具名> <k=v>...
    powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 run <工具名> '<JSON>'
    powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 <工具名> <k=v>...   # 省略 run

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 run sys_info action=disk
    powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 run log_query action=crash source=adb
    powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 run git_summary '{"action":"status","repo":"C:\\path\\to\\repo"}'
    powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 run pdf2txt -ArgsFile args.json

.PARAMETER 引号陷阱（务必知道）
    powershell.exe 的 -File 模式会 **吃掉参数里的双引号**，所以
    `run sys_info '{"action":"disk"}'` 到脚本里实际是 `{action:disk}`。
    本脚本会自动把这种"伪 JSON"修回合法 JSON，但值里含逗号 / 花括号 / 单引号时
    无法可靠还原。**推荐一律用 k=v 形式**，它不经 JSON 转义，最省事也最稳。

.NOTES
    与 MCP 通道的唯一区别：MCP 会把工具定义（含参数说明）预先塞进 AI 上下文；
    走命令行时 AI 需要先 `schema <工具名>` 查参数。功能与结果完全一致。
#>
$ErrorActionPreference = 'Stop'

$mcpDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($mcpDir)) { $mcpDir = (Get-Location).Path }
$toolsDir = Join-Path $mcpDir 'tools'
$offDir = Join-Path $toolsDir '_disabled'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8NoBom)
$out.AutoFlush = $true
function Out-Line([string]$s) { $out.Write($s + "`n"); $out.Flush() }
function Out-Raw([string]$s) { if (-not [string]::IsNullOrEmpty($s)) { $out.Write($s); $out.Flush() } }

# ---- 定位工具脚本：tools\ 优先，其次 tools\_disabled\ ----
function Get-ToolEntry([string]$name) {
    foreach ($d in @($toolsDir, $offDir)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $p = Join-Path $d ($name + '.tool.ps1')
        if (Test-Path -LiteralPath $p) {
            return [pscustomobject]@{ Name = $name; File = $p; Mounted = ($d -eq $toolsDir) }
        }
    }
    return $null
}

# ---- 解析工具脚本头部的 # @mcp-tool 元数据块 ----
function Get-ToolHeader([string]$file) {
    $txt = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    $name = ''; $desc = ''; $params = @(); $timeout = ''
    $m = [regex]::Match($txt, '(?m)^#\s*name:\s*(\S+)\s*$')
    if ($m.Success) { $name = $m.Groups[1].Value }
    $m = [regex]::Match($txt, '(?m)^#\s*description:\s*(.+?)\s*$')
    if ($m.Success) { $desc = $m.Groups[1].Value }
    $m = [regex]::Match($txt, '(?m)^#\s*params:\s*(\[.*\])\s*$')
    # 注意：不能写 @(x | ConvertFrom-Json) —— @(cmd) 只收集到 1 个元素（数组本身）；
    # 必须先赋值再 @() 包装，见 mcp\工具集规范.md 坑 19。
    if ($m.Success) {
        try {
            $parsed = $m.Groups[1].Value | ConvertFrom-Json
            if ($null -ne $parsed) { $params = @($parsed) } else { $params = @() }
        } catch { $params = @() }
    }
    $m = [regex]::Match($txt, '(?m)^#\s*timeout:\s*(\d+)')
    if ($m.Success) { $timeout = $m.Groups[1].Value }
    return [pscustomobject]@{ Name = $name; Description = $desc; Params = $params; Timeout = $timeout }
}

function Get-AllEntries {
    $r = @()
    foreach ($d in @($toolsDir, $offDir)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $mounted = ($d -eq $toolsDir)
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Filter '*.tool.ps1' | Sort-Object Name)) {
            $h = Get-ToolHeader $f.FullName
            $n = if ($h.Name) { $h.Name } else { $f.Name -replace '\.tool\.ps1$', '' }
            $r += [pscustomobject]@{ Name = $n; File = $f.FullName; Mounted = $mounted; Params = @($h.Params); Desc = $h.Description }
        }
    }
    return $r
}

function First-Sentence([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $i = $s.IndexOf('。')
    if ($i -gt 0) { return $s.Substring(0, $i + 1) }
    return $s
}

function Show-Usage {
    Out-Line '本地 MCP 工具命令行调度器'
    Out-Line ''
    Out-Line '  call-tool.ps1 list                      列出全部工具（含未挂载）'
    Out-Line '  call-tool.ps1 schema <工具名>            查看某工具的参数表与示例'
    Out-Line '  call-tool.ps1 run <工具名> <k=v>...      调用工具（推荐，免引号转义）'
    Out-Line '  call-tool.ps1 run <工具名> ''<JSON>''     调用工具（JSON 形式）'
    Out-Line '  call-tool.ps1 <工具名> <k=v>...          同上，可省略 run'
    Out-Line '  call-tool.ps1 help                      显示本帮助'
    Out-Line ''
    Out-Line '  选项： -ArgsFile <路径>   从文件读参数 JSON（值含逗号/花括号时用）'
    Out-Line ''
    Out-Line '示例：'
    Out-Line '  powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 list'
    Out-Line '  powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 schema pdf2txt'
    Out-Line '  powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 run log_query action=crash source=adb'
    Out-Line ('  powershell -NoProfile -ExecutionPolicy Bypass -File call-tool.ps1 run git_summary ''{"action":"status"}''')
}

function Show-List {
    $all = @(Get-AllEntries)
    $on = @($all | Where-Object { $_.Mounted })
    $off = @($all | Where-Object { -not $_.Mounted })
    Out-Line ('本地 MCP 工具共 ' + $all.Count + ' 个：已挂载 ' + $on.Count + ' 个（MCP 可直接调用），命令行 ' + $off.Count + ' 个')
    Out-Line ''
    foreach ($grp in @(
        @{ T = '【已挂载】MCP tools/list 里有，AI 可直接调用'; L = $on },
        @{ T = '【命令行】未挂载，用 call-tool.ps1 run <名> k=v 调用'; L = $off })) {
        Out-Line $grp.T
        Out-Line ''
        foreach ($e in $grp.L) {
            Out-Line ('  ' + $e.Name.PadRight(16) + ' 参数' + ([string]@($e.Params).Count).PadLeft(2) + '  ' + (First-Sentence $e.Desc))
        }
        Out-Line ''
    }
}

function Show-Schema([string]$name) {
    $e = Get-ToolEntry $name
    if ($null -eq $e) {
        Out-Line ('找不到工具：' + $name + '（用 list 查看全部工具名）')
        return 2
    }
    $h = Get-ToolHeader $e.File
    $state = if ($e.Mounted) { '已挂载（MCP tools/list 里有，AI 可直接调用）' } else { '未挂载（只能走命令行）' }
    Out-Line ('工具：' + $name)
    Out-Line ('状态：' + $state)
    Out-Line ('脚本：' + $e.File)
    if ($h.Timeout) { Out-Line ('超时：' + $h.Timeout + ' s') }
    Out-Line ''
    Out-Line '说明：'
    Out-Line ('  ' + $h.Description)
    Out-Line ''
    $params = @($h.Params)
    if ($params.Count -eq 0) {
        Out-Line '该工具无参数。'
        Out-Line ''
    } else {
        $wName = 4; foreach ($p in $params) { if ([string]$p.name.Length -gt $wName) { $wName = [string]$p.name.Length } }
        Out-Line ('参数（' + $params.Count + ' 个）：')
        foreach ($p in $params) {
            $rq = if ($p.required -eq $true) { '[必填]' } else { '[可选]' }
            $ty = [string]$p.type; if (-not $ty) { $ty = 'string' }
            Out-Line ('  ' + ([string]$p.name).PadRight($wName) + '  ' + $rq + ' ' + $ty.PadRight(7) + ' ' + [string]$p.description)
        }
        Out-Line ''
    }
    # 示例 JSON：必填项填占位值
    $parts = @()
    foreach ($p in $params) {
        if ($p.required -ne $true) { continue }
        $ty = [string]$p.type
        $v = if ($ty -eq 'boolean') { 'false' } elseif ($ty -eq 'integer') { '0' } else { '"<' + $p.name + '>"' }
        $parts += ('"' + $p.name + '":' + $v)
    }
    $json = if ($parts.Count -eq 0) { '{}' } else { '{' + ($parts -join ',') + '}' }
    $kv = @()
    foreach ($p in $params) {
        if ($p.required -ne $true) { continue }
        $ty = [string]$p.type
        $v = if ($ty -eq 'boolean') { 'false' } elseif ($ty -eq 'integer') { '0' } else { '<' + $p.name + '>' }
        $kv += ([string]$p.name + '=' + $v)
    }
    $kvStr = if ($kv.Count -eq 0) { '' } else { ' ' + ($kv -join ' ') }
    $exe = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $mcpDir 'call-tool.ps1') + '"'
    Out-Line '调用示例（k=v，推荐；值含空格时用双引号包住单个值）：'
    Out-Line ('  ' + $exe + ' run ' + $name + $kvStr)
    if ($kv.Count -gt 0) {
        Out-Line '调用示例（JSON；注意 powershell -File 会吞双引号，本脚本会自动修回）：'
        Out-Line ('  ' + $exe + ' run ' + $name + ' ''' + $json + '''')
    }
    return 0
}

function Invoke-Tool([string]$name, [string]$json) {
    $e = Get-ToolEntry $name
    if ($null -eq $e) {
        Out-Line ('找不到工具：' + $name + '（用 list 查看全部工具名）')
        return 2
    }
    if ([string]::IsNullOrWhiteSpace($json)) { $json = '{}' }
    $ok = $true
    try { $null = $json | ConvertFrom-Json } catch { $ok = $false }
    if (-not $ok) {
        # 被 -File 吃掉双引号的情形，修回来再试
        $fixed = Repair-Json $json
        if ($null -ne $fixed) {
            try { $null = $fixed | ConvertFrom-Json; $json = $fixed; $ok = $true } catch { }
        }
    }
    if (-not $ok) {
        Out-Line '参数不是合法 JSON。两种写法：'
        Out-Line ('  run ' + $name + ' key=value key2=value2     # 推荐，免转义')
        Out-Line ('  run ' + $name + ' ''{"key":"value"}''       # JSON 形式')
        return 2
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $e.File)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $psi.StandardOutputEncoding = $utf8NoBom } catch { }
    try { $psi.StandardErrorEncoding = $utf8NoBom } catch { }
    $p = [System.Diagnostics.Process]::Start($psi)
    $tOut = $p.StandardOutput.ReadToEndAsync()
    $tErr = $p.StandardError.ReadToEndAsync()
    # 参数以 UTF-8 原始字节写 stdin：走 StandardInput 会按代码页 936 编码，中文会乱码
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.BaseStream.Flush()
    $p.StandardInput.Close()
    $p.WaitForExit()
    $so = ''; $se = ''
    try { $so = [string]$tOut.Result } catch { }
    try { $se = [string]$tErr.Result } catch { }
    Out-Raw $so
    if (-not [string]::IsNullOrWhiteSpace($se)) {
        Out-Line ''
        Out-Line '--- 工具 stderr ---'
        Out-Raw $se
    }
    if ($p.ExitCode -ne 0) {
        Out-Line ''
        Out-Line ('退出码 ' + $p.ExitCode + '（非 0 视为失败）')
    }
    return $p.ExitCode
}

# ---- 容错一：把被 powershell.exe -File 吃掉双引号的"伪 JSON"修回合法 JSON ----
#   {action:time}      ->  {"action":"time"}
#   {names:[a,b]}      ->  {"names":["a","b"]}
#   {path:C:\dir\file.txt}  ->  {"path":"C:\\dir\\file.txt"}
# 仅在严格 JSON 解析失败后调用；正常 JSON 根本不走这里。
function Repair-Json([string]$s) {
    $t = $s.Trim()
    if (-not ($t.StartsWith('{') -or $t.StartsWith('['))) {
        if ($t.IndexOf(':') -ge 0) { $t = '{' + $t + '}' } else { return $null }
    }
    $sb = New-Object System.Text.StringBuilder
    $stack = New-Object System.Collections.ArrayList
    $expectKey = $false
    $i = 0
    $n = $t.Length
    while ($i -lt $n) {
        $c = [string]$t[$i]
        if ($c -eq '"' -or $c -eq "'") {
            # 已有引号的字面量：原样复制（含 \ 转义）
            $null = $sb.Append($c); $i++
            while ($i -lt $n) {
                $d = [string]$t[$i]
                if ($d -eq '\') {
                    $null = $sb.Append($d); $i++
                    if ($i -lt $n) { $null = $sb.Append([string]$t[$i]); $i++ }
                    continue
                }
                $null = $sb.Append($d); $i++
                if ($d -eq $c) { break }
            }
            continue
        }
        if ($c -eq '{' -or $c -eq '[') {
            $null = $sb.Append($c); $i++
            $null = $stack.Add($(if ($c -eq '{') { 'o' } else { 'a' }))
            $expectKey = ($c -eq '{')
            continue
        }
        if ($c -eq '}' -or $c -eq ']') {
            $null = $sb.Append($c); $i++
            if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) }
            $expectKey = $false
            continue
        }
        if ($c -eq ',') {
            $null = $sb.Append($c); $i++
            $expectKey = ($stack.Count -gt 0 -and [string]$stack[$stack.Count - 1] -eq 'o')
            continue
        }
        if ($c -eq ':') { $null = $sb.Append($c); $i++; $expectKey = $false; continue }
        if ([char]::IsWhiteSpace($t[$i])) { $null = $sb.Append($c); $i++; continue }
        # 裸 token：键读到 ':' 为止；值读到 ',' '}' ']' 为止（值里可以有 ':' 和空格）
        $stops = if ($expectKey) { ',:}]' } else { ',}]' }
        $j = $i
        while ($j -lt $n -and $stops.IndexOf([string]$t[$j]) -lt 0) { $j++ }
        $tok = $t.Substring($i, $j - $i).Trim()
        $i = $j
        if ($tok.Length -eq 0) { continue }
        if ((-not $expectKey) -and ($tok -match '^-?\d+(\.\d+)?$' -or $tok -eq 'true' -or $tok -eq 'false' -or $tok -eq 'null')) {
            $null = $sb.Append($tok)
        } else {
            $null = $sb.Append('"' + $tok.Replace('\', '\\').Replace('"', '\"') + '"')
        }
    }
    return $sb.ToString()
}

# ---- 容错二：k=v 形式（推荐）。值按字面量推断类型，不经 JSON 转义 ----
function Convert-Scalar([string]$v) {
    if ($v -eq 'true') { return $true }
    if ($v -eq 'false') { return $false }
    if ($v -eq 'null') { return $null }
    if ($v -match '^-?\d+$') { return [long]$v }
    if ($v -match '^-?\d+\.\d+$') { return [double]$v }
    if ($v.StartsWith('[') -or $v.StartsWith('{')) {
        try { return ($v | ConvertFrom-Json) } catch { }
    }
    return $v
}

function Convert-PairsToJson([string[]]$pairs) {
    $o = [ordered]@{}
    foreach ($kv in $pairs) {
        $ix = $kv.IndexOf('=')
        if ($ix -lt 1) { return $null }
        $k = $kv.Substring(0, $ix).Trim()
        if ($k.Length -eq 0) { return $null }
        $o[$k] = Convert-Scalar $kv.Substring($ix + 1)
    }
    return ($o | ConvertTo-Json -Compress -Depth 10)
}

# 判断参数形式：以 { [ 开头 = JSON；全是 k=v = 键值对；其余按 JSON 报错
function Resolve-ArgsJson([string[]]$rest) {
    if ($rest.Count -eq 0) { return '{}' }
    $first = ([string]$rest[0]).Trim()
    if ($first.StartsWith('{') -or $first.StartsWith('[')) { return [string]$rest[0] }
    $allPairs = $true
    foreach ($a in $rest) { if (([string]$a).IndexOf('=') -lt 1) { $allPairs = $false; break } }
    if ($allPairs) {
        $j = Convert-PairsToJson $rest
        if ($null -ne $j) { return $j }
    }
    return [string]$rest[0]
}

# ---- 主流程 ----
$argv = @($args)
$jsonArg = ''
$keep = @()
for ($i = 0; $i -lt $argv.Count; $i++) {
    if ($argv[$i] -eq '-ArgsFile') {
        if ($i + 1 -ge $argv.Count) { Out-Line '-ArgsFile 缺少路径'; exit 2 }
        $fp = $argv[$i + 1]
        if (-not (Test-Path -LiteralPath $fp)) { Out-Line ('参数文件不存在：' + $fp); exit 2 }
        $jsonArg = [IO.File]::ReadAllText($fp, [Text.Encoding]::UTF8)
        $i++
        continue
    }
    $keep += $argv[$i]
}
$argv = $keep

if ($argv.Count -eq 0) { Show-Usage; exit 0 }

$cmd = [string]$argv[0]
$lc = $cmd.ToLower()

if ($lc -eq 'help' -or $lc -eq '-h' -or $lc -eq '--help' -or $lc -eq '-?') { Show-Usage; exit 0 }
if ($lc -eq 'list' -or $lc -eq '-list' -or $lc -eq 'ls') { Show-List; exit 0 }

if ($lc -eq 'schema') {
    if ($argv.Count -lt 2) { Out-Line '用法： call-tool.ps1 schema <工具名>'; exit 2 }
    exit (Show-Schema ([string]$argv[1]))
}

$rest = @()
if ($argv.Count -ge 2) { $rest = @($argv[1..($argv.Count - 1)]) }

if ($lc -eq 'run') {
    if ($rest.Count -eq 0) { Out-Line '用法： call-tool.ps1 run <工具名> <k=v>...  或  run <工具名> ''<JSON>'''; exit 2 }
    $tool = [string]$rest[0]
    if ($rest.Count -gt 1) { $rest = @($rest[1..($rest.Count - 1)]) } else { $rest = @() }
    if ([string]::IsNullOrWhiteSpace($jsonArg)) { $jsonArg = Resolve-ArgsJson $rest }
    exit (Invoke-Tool $tool $jsonArg)
}

# 省略 run：第一个参数就是工具名
if ([string]::IsNullOrWhiteSpace($jsonArg)) { $jsonArg = Resolve-ArgsJson $rest }
exit (Invoke-Tool $cmd $jsonArg)
