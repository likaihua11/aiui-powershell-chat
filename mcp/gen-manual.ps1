$ErrorActionPreference = 'Stop'
$mcp = $PSScriptRoot
$tools = Join-Path $mcp 'tools'
$off = Join-Path $tools '_disabled'

$j = Get-Content (Join-Path $mcp '_v-full.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$list = @($j.result.tools)

$builtins = @('search_local', 'read_local', 'list_local')

# ---- 挂载清单直接从文件系统推导：tools\ 直下 = 已挂载；tools\_disabled\ = 命令行 ----
$mounted = @(Get-ChildItem -LiteralPath $tools -File -Filter '*.tool.ps1' | Sort-Object Name | ForEach-Object { $_.Name -replace '\.tool\.ps1$', '' })
$offNames = @(Get-ChildItem -LiteralPath $off -File -Filter '*.tool.ps1' | Sort-Object Name | ForEach-Object { $_.Name -replace '\.tool\.ps1$', '' })

# tools/list 实际体积：直接量 brief 导出文件
$briefBytes = (Get-Item (Join-Path $mcp '_v-brief.json')).Length
$kbBrief = [Math]::Round($briefBytes / 1024.0, 1)

# 服务端版本：从 kb-local-mcp.ps1 的 serverInfo 里取，避免写死导致过期
$srvVer = '0.0.0'
$mv = [regex]::Match([IO.File]::ReadAllText((Join-Path $mcp 'kb-local-mcp.ps1'), [Text.Encoding]::UTF8), "serverInfo\s*=\s*\[ordered\]@\{[^}]*version\s*=\s*'([0-9.]+)'")
if ($mv.Success) { $srvVer = $mv.Groups[1].Value }

# ---- 未挂载工具不在 _v-full.json 里，头部元数据只能从文件读 ----
function Read-ToolHeader([string]$file) {
    $txt = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    $name = ''; $desc = ''; $params = @(); $to = ''
    $m = [regex]::Match($txt, '(?m)^#\s*name:\s*(\S+)\s*$')
    if ($m.Success) { $name = $m.Groups[1].Value }
    $m = [regex]::Match($txt, '(?m)^#\s*description:\s*(.+?)\s*$')
    if ($m.Success) { $desc = $m.Groups[1].Value }
    $m = [regex]::Match($txt, '(?m)^#\s*params:\s*(\[.*\])\s*$')
    if ($m.Success) {
        try {
            # 不能写 @(x | ConvertFrom-Json)：@(cmd) 只收集到 1 个元素（数组本身）
            $parsed = $m.Groups[1].Value | ConvertFrom-Json
            if ($null -ne $parsed) { $params = @($parsed) }
        } catch { }
    }
    $m = [regex]::Match($txt, '(?m)^#\s*timeout:\s*(\d+)')
    if ($m.Success) { $to = $m.Groups[1].Value }
    return [pscustomobject]@{ Name = $name; Desc = $desc; Params = $params; Timeout = $to }
}
$offHdr = @{}
foreach ($n in $offNames) { $offHdr[$n] = Read-ToolHeader (Join-Path $off ($n + '.tool.ps1')) }

function FirstSentence([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $i = $s.IndexOf('。')
    if ($i -gt 0) { return $s.Substring(0, $i + 1) }
    return $s
}

# ---- 外部工具的 timeout 头 ----
$hdr = @{}
foreach ($n in $mounted) {
    $p = Join-Path $tools ($n + '.tool.ps1'); $to = ''
    foreach ($l in [IO.File]::ReadAllLines($p, [Text.Encoding]::UTF8)) { if ($l -match '^#\s*timeout:\s*(\d+)') { $to = $Matches[1]; break } }
    $hdr[$n] = $to
}

function Esc([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '\|', '\|' -replace "`r?`n", '<br>')
}
function ArgJson($t, $reqList) {
    $parts = @()
    foreach ($p in $t.inputSchema.properties.PSObject.Properties) {
        if ($reqList -notcontains $p.Name) { continue }
        $ty = [string]$p.Value.type; if (-not $ty) { $ty = 'string' }
        $v = if ($ty -eq 'boolean') { 'false' } elseif ($ty -eq 'integer') { '0' } else { '"<' + $p.Name + '>"' }
        $parts += ('"' + $p.Name + '":' + $v)
    }
    if ($parts.Count -eq 0) { return '{}' }
    return '{' + ($parts -join ',') + '}'
}
# 4.1 的说明列：优先用 action 参数描述；没有 action 参数就退回工具描述的首句

$L = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $L.Add($s) }

W '# 本地 MCP 工具手册'
W ''
W '> 本手册由 `mcp\gen-manual.ps1` 从 `mcp\_v-full.json` **自动生成**，请勿手工编辑；内容与 `tools\*.tool.ps1` 实际注册保持一致。'
W '> 重新生成：`export-tools.ps1`（导出 `_v-brief.json` / `_v-full.json` 并做结构校验）→ `gen-manual.ps1`（重建本文件）。'
W ('> 服务端版本 **' + $srvVer + '** ｜ 挂载 **' + $mounted.Count + ' 个外部工具 + 3 个内建工具 = ' + ($mounted.Count + 3) + ' 个**，另有 ' + $offNames.Count + ' 个走命令行')
W ''
W '## 0. 怎么读这本手册'
W ''
W '| 概念 | 说明 |'
W '|---|---|'
W '| 内建工具 | 服务端 `kb-local-mcp.ps1` 里直接实现的 3 个工具，永远可用 |'
W '| 已挂载外部工具 | 放在 `mcp\tools\` **直下**的 `*.tool.ps1`；服务端启动时扫描（**不递归**）并注册，AI 可直接调用 |'
W '| 命令行工具 | 放在 `mcp\tools\_disabled\` 的 `*.tool.ps1`；不在 `tools/list` 里、不占 token，用 `mcp\call-tool.ps1` 调用 |'
W '| 必填 | 参数表里「必填」为 **是** 的项，不传会直接报参数错误 |'
W ''
W ('调用约定：所有外部工具**参数 JSON 从 stdin 进，结果 UTF-8 无 BOM 写 stdout**。MCP 通道默认走 brief 描述模式（`tools/list` 实测 ' + $kbBrief + ' KB），需要完整描述时用 `-Full` 启动。')
W ''
W '## 1. 工具总览'
W ''
W '| # | 工具 | 源文件 | 调用方式 | 参数数 | 必填数 | 超时(s) |'
W '|---|---|---|---|---|---|---|'
$i = 0
foreach ($t in $list) {
    $i++
    $src = if ($builtins -contains $t.name) { '内建' } else { 'tools\' + $t.name + '.tool.ps1' }
    $mode = if ($builtins -contains $t.name) { '内建' } else { 'MCP 直接调用' }
    $req = $t.inputSchema.PSObject.Properties['required']
    $rc = if ($req) { @($t.inputSchema.required).Count } else { 0 }
    $pc = @($t.inputSchema.properties.PSObject.Properties).Count
    $to = if ($hdr.ContainsKey($t.name) -and $hdr[$t.name]) { $hdr[$t.name] } else { '-' }
    W ('| ' + $i + ' | `' + $t.name + '` | ' + $src + ' | ' + $mode + ' | ' + $pc + ' | ' + $rc + ' | ' + $to + ' |')
}
foreach ($n in $offNames) {
    $i++
    $h = $offHdr[$n]
    $pc = @($h.Params).Count
    $rc = @($h.Params | Where-Object { $_.required -eq $true }).Count
    $to = if ($h.Timeout) { $h.Timeout } else { '-' }
    W ('| ' + $i + ' | `' + $n + '` | tools\_disabled\' + $n + '.tool.ps1 | 命令行 | ' + $pc + ' | ' + $rc + ' | ' + $to + ' |')
}
W ''
W '## 2. 内建工具（3 个）'
W ''
foreach ($t in $list) {
    if ($builtins -notcontains $t.name) { continue }
    $req = $t.inputSchema.PSObject.Properties['required']
    $reqList = if ($req) { @($t.inputSchema.required) } else { @() }
    W ('### ' + $t.name)
    W ''
    W (Esc $t.description)
    W ''
    W '| 参数 | 类型 | 必填 | 说明 |'
    W '|---|---|---|---|'
    foreach ($p in $t.inputSchema.properties.PSObject.Properties) {
        $rq = if ($reqList -contains $p.Name) { '**是**' } else { '' }
        $ty = [string]$p.Value.type; if (-not $ty) { $ty = 'string' }
        W ('| `' + $p.Name + '` | ' + $ty + ' | ' + $rq + ' | ' + (Esc ([string]$p.Value.description)) + ' |')
    }
    W ''
    W '```json'
    W ('{"name":"' + $t.name + '","arguments":' + (ArgJson $t $reqList) + '}')
    W '```'
    W ''
}
W ('## 3. 已挂载外部工具（' + $mounted.Count + ' 个）')
W ''
foreach ($t in $list) {
    if ($builtins -contains $t.name) { continue }
    $req = $t.inputSchema.PSObject.Properties['required']
    $reqList = if ($req) { @($t.inputSchema.required) } else { @() }
    $to = if ($hdr.ContainsKey($t.name) -and $hdr[$t.name]) { $hdr[$t.name] + ' s' } else { '默认' }
    W ('### ' + $t.name)
    W ''
    W ('- 源文件：`tools\' + $t.name + '.tool.ps1` ｜ 调用方式：**MCP 直接调用** ｜ 超时：' + $to)
    W ''
    W (Esc $t.description)
    W ''
    if ($reqList.Count -eq 0) {
        W '**无必填参数。**'
        W ''
    }
    W '| 参数 | 类型 | 必填 | 说明 |'
    W '|---|---|---|---|'
    foreach ($p in $t.inputSchema.properties.PSObject.Properties) {
        $rq = if ($reqList -contains $p.Name) { '**是**' } else { '' }
        $ty = [string]$p.Value.type; if (-not $ty) { $ty = 'string' }
        W ('| `' + $p.Name + '` | ' + $ty + ' | ' + $rq + ' | ' + (Esc ([string]$p.Value.description)) + ' |')
    }
    W ''
    W '**示例调用**'
    W ''
    W '```json'
    W ('{"name":"' + $t.name + '","arguments":' + (ArgJson $t $reqList) + '}')
    W '```'
    W ''
}
W '## 4. 命令行工具与调用方式'
W ''
W ('`tools\_disabled\` 下有 ' + $offNames.Count + ' 个工具。它们**不在 `tools/list` 里**，不占 AI 上下文，需要时用 `mcp\call-tool.ps1` 调用。')
W ''
W '### 4.1 清单'
W ''
W '| 工具 | 参数数 | 说明 |'
W '|---|---|---|'
foreach ($n in $offNames) {
    $h = $offHdr[$n]
    W ('| `' + $n + '` | ' + @($h.Params).Count + ' | ' + (Esc (FirstSentence $h.Desc)) + ' |')
}
W ''
W '### 4.2 调用方式'
W ''
W '```powershell'
W '# 列出全部工具（已挂载 + 命令行）'
W 'powershell -NoProfile -ExecutionPolicy Bypass -File mcp\call-tool.ps1 list'
W ''
W '# 查某工具的参数表与示例'
W 'powershell -NoProfile -ExecutionPolicy Bypass -File mcp\call-tool.ps1 schema git_summary'
W ''
W '# 调用（推荐 k=v 形式，免引号转义）'
W 'powershell -NoProfile -ExecutionPolicy Bypass -File mcp\call-tool.ps1 run sys_info action=disk'
W ''
W '# 调用（JSON 形式；powershell -File 会吞双引号，call-tool 会自动修回）'
W 'powershell -NoProfile -ExecutionPolicy Bypass -File mcp\call-tool.ps1 run git_summary ''{"action":"status"}'''
W ''
W '# 值里含逗号 / 花括号时，用 -ArgsFile 传文件'
W 'powershell -NoProfile -ExecutionPolicy Bypass -File mcp\call-tool.ps1 run fs_ops -ArgsFile args.json'
W '```'
W ''
W '### 4.3 怎么把某个工具重新挂到 MCP 上'
W ''
W '把 `tools\_disabled\<名>.tool.ps1` 移到 `tools\` **直下**即可（反向操作就是下架）。服务端会检测到目录变化并自动补发 `notifications/tools/list_changed`，IDE 无需重启。'
W ''
W ('> 挂载越多，每次对话要携带的 `tools/list` 越大。当前已挂载的 ' + $mounted.Count + ' 个是「IDE 无法替代」的核心集：')
W '> `fs_ops`（编码转码 / 批量替换）、`code_index`（离线符号索引，含跨模块引用）、`log_query`（日志与崩溃排障）、`grep_regex`（正则检索 + Android 资源检索）、`adb_ops`（真机操作）。'
W ''
W '## 5. 调用约定与排错'
W ''
W '### 5.1 外部工具的文件约定'
W ''
W '```powershell'
W '# @mcp-tool'
W '# name: <工具名，须匹配 ^[A-Za-z_][A-Za-z0-9_]*$>'
W '# description: <一句话描述，brief 模式下只保留首个句号前的内容>'
W '# params: [{"name":"action","type":"string","required":true,"description":"..."}]'
W '# timeout: 300'
W '# @mcp-tool-end'
W '```'
W ''
W '参数从 stdin 读 JSON，结果写 stdout（UTF-8 **无 BOM**）；诊断信息一律走 stderr，不要污染 stdout。'
W ''
W '### 5.2 服务端常见日志'
W ''
W '| 日志 | 含义 |'
W '|---|---|'
W '| `外部工具已加载: ...` | 本次注册成功的工具名列表 |'
W '| `描述模式 = brief（精简）` / `full（完整）` | 当前描述压缩档；`-Full` 启动即为 full |'
W '| `tools/list -> N tools, B bytes` | 每次 `tools/list` 的体积，用来观察 token 占用 |'
W '| `已补发 notifications/tools/list_changed（工具目录发生变化）` | `tools\` 目录被改动（挂载 / 下架），服务端已通知客户端重新拉取 |'
W '| `tool-call: <name> ok=<True/False>` | 单次工具调用结果；`call-tool.ps1 run tool_admin action=usage`（或 `tool_usage`）据此汇总调用排名 |'
W ''
W '### 5.3 排查工具没出现'
W ''
W '1. 看 `tools\` 目录**直下**是否有该 `.tool.ps1`（子目录不会被扫描）；'
W '2. 看头部 `# name:` 是否与文件名一致、是否含非法字符；'
W '3. 看 stderr 的 `外部工具已加载:` 列表里有没有它；'
W '4. 重名工具只保留先注册的，后一个会被忽略；'
W '5. 用 `call-tool.ps1 list` 确认它是在 `tools\` 还是 `tools\_disabled\`。'
W ''

$dest = Join-Path $mcp '工具手册.md'
[IO.File]::WriteAllLines($dest, $L.ToArray(), (New-Object Text.UTF8Encoding($true)))
Write-Host ('written: ' + $dest)
Write-Host ('lines: ' + $L.Count)
