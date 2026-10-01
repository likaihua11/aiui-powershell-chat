#requires -Version 5.1
<#
.SYNOPSIS
    kb-local-mcp.ps1 的冒烟测试（不经过 IDE，直接喂 JSON-RPC 消息）

.DESCRIPTION
    用 .NET Process 拉起服务端进程，依次发送
      initialize -> notifications/initialized -> tools/list -> tools/call x22 -> ping
    并把每一步的响应原文落盘到 _smoke-test-result.txt，便于核对中文是否乱码。

     工具未挂载时（脚本在 tools\_disabled\，不在 tools/list 中）服务端 tools/call 会回"未知工具"，
     这类用例改由本测试直接拉起脚本，契约与服务端一致（-File + 参数以 UTF-8 字节直写 stdin），
     断言逻辑不变，覆盖率不随挂载状态下降。

    两个关键点：
      1) stdin 用 BaseStream 直接写 UTF-8 字节。PS 5.1 所在的 .NET Framework
         没有 ProcessStartInfo.StandardInputEncoding 属性，若用 StandardInput 写中文，
         会按系统代码页 936 编码，服务端收到的是乱码；
      2) 通知类消息（无 id）服务端不会回复，所以只有带 id 的请求才读响应，
         否则 ReadLine 会一直阻塞。读响应统一用 ReadLineAsync + 超时，避免挂死。

    第 3 步除断言 tools/list 有响应外，还会逐个校验 inputSchema 是否"合法 JSON Schema"：
      - inputSchema.type 必须是 object；
      - properties 的键名必须是合法标识符（^[A-Za-z_][A-Za-z0-9_]*$）；
      - 每个属性的 type 只能是 string/integer/number/boolean/object/array；
      - required 若存在必须是数组（PS 5.1 把空数组序列化成 "" 会被客户端判非法）。
    这四条正是 2026-09-29 那次 IDE 400 报错的根因
    （"string string string string string string" is not valid ... 'anyOf'），
    以后这类元数据写坏会在本地就被拦下，不会等到 IDE 里炸。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File test-kb-local-mcp.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File test-kb-local-mcp.ps1 -Root &lt;你的资料目录&gt; -SkipSelfcheck

.NOTES
    同样不使用 param 块（PS 5.1 -File 调用的老问题）。
    踩坑记录：调用行里不要直接写 '字符串' + $var + '字符串' 这种拼接 ——
    PowerShell 参数模式下 "+" 会被当成独立参数，导致 "不能把 String 转成 Boolean" 之类的怪错。
#>

$ErrorActionPreference = 'Stop'

# 自定位工作区根（可移植）：本脚本在 <root>\mcp\ 下，上溯一级
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { $Root = $PSScriptRoot }
$Query = '检索'          # 故意用中文：同时验证 stdin/stdout 的 UTF-8 通路
$Glob = '*.md'
$SkipSelfcheck = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    $n = [string]$args[$i]
    $v = if ($i + 1 -lt $args.Count) { [string]$args[$i + 1] } else { '' }
    if ($n -eq '-Root') { $Root = $v; $i++ }
    elseif ($n -eq '-Glob') { $Glob = $v; $i++ }
    elseif ($n -eq '-SkipSelfcheck') { $SkipSelfcheck = $true }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
$serverFile = Join-Path $scriptDir 'kb-local-mcp.ps1'
$resultFile = Join-Path $scriptDir '_smoke-test-result.txt'
$serverLog = Join-Path $scriptDir '_server-stderr.txt'
$toolsDir = Join-Path $scriptDir 'tools'
$disabledDir = Join-Path $toolsDir '_disabled'

if (-not (Test-Path -LiteralPath $serverFile)) { throw ('服务端脚本不存在: ' + $serverFile) }

# ---- 启动服务端 ----
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -LogFile "{2}"' -f $serverFile, $Root, $serverLog)
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
try { $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$p = [System.Diagnostics.Process]::Start($psi)

# ---- 工具函数 ----
function Send-Line([string]$json) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json + "`n")
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.BaseStream.Flush()
}

function Read-One([int]$timeoutMs) {
    $task = $p.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($timeoutMs)) { return $null }
    return $task.Result
}

function Shorten([string]$s, [int]$max) {
    if ($null -eq $s) { return '<null>' }
    if ($s.Length -le $max) { return $s }
    return $s.Substring(0, $max) + (' ...(truncated, total {0} chars)' -f $s.Length)
}

$script:report = New-Object System.Collections.Generic.List[string]
$script:passCount = 0
$script:failCount = 0
$script:skipCount = 0
$script:lastResp = ''
$script:toolCount = 0
$script:toolNames = ''

$report.Add('=== kb-local-mcp smoke test ===')
$report.Add('time   : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$report.Add('server : ' + $serverFile)
$report.Add('root   : ' + $Root)
$report.Add('query  : ' + $Query)
$report.Add('')

function Pass([string]$msg) { $script:passCount++; $script:report.Add('PASS  ' + $msg) }
function Fail([string]$msg) { $script:failCount++; $script:report.Add('FAIL  ' + $msg) }
function Skip([string]$msg) { $script:skipCount++; $script:report.Add('SKIP  ' + $msg) }

# 判断某个外部工具当前是否挂载（tools\ 直下有同名 .tool.ps1；停用后移入 _disabled\ 子目录）
function Test-ToolMounted([string]$name) {
    $p = Join-Path $toolsDir ($name + '.tool.ps1')
    return (Test-Path -LiteralPath $p)
}

# 脚本是否可用（已挂载或已停用都算）——未挂载的工具由本测试直接拉起脚本，
# 这样"工具被移进 _disabled\ 后相对路径错位"这类 bug 也能被测出来
function Get-ToolScriptPath([string]$name) {
    $p1 = Join-Path $toolsDir ($name + '.tool.ps1')
    if (Test-Path -LiteralPath $p1) { return $p1 }
    $p2 = Join-Path $disabledDir ($name + '.tool.ps1')
    if (Test-Path -LiteralPath $p2) { return $p2 }
    return ''
}

function Test-ToolAvailable([string]$name) {
    return ((Get-ToolScriptPath $name) -ne '')
}

# 把任意文本编成 JSON 字符串字面量（自己拼响应行时用）
function ConvertTo-JsonString([string]$s) {
    if ($null -eq $s) { return '""' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append([char]34)
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 34) { [void]$sb.Append('\"') }
        elseif ($c -eq 92) { [void]$sb.Append('\\') }
        elseif ($c -eq 8) { [void]$sb.Append('\b') }
        elseif ($c -eq 12) { [void]$sb.Append('\f') }
        elseif ($c -eq 10) { [void]$sb.Append('\n') }
        elseif ($c -eq 13) { [void]$sb.Append('\r') }
        elseif ($c -eq 9) { [void]$sb.Append('\t') }
        elseif ($c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append([char]34)
    return $sb.ToString()
}

# 直拉未挂载的脚本：契约与服务端 Invoke-ExternalTool 完全一致
function Invoke-ToolDirect([string]$name, [string]$argJson) {
    $sp = Get-ToolScriptPath $name
    if ($sp -eq '') { return $null }
    $dpsi = New-Object System.Diagnostics.ProcessStartInfo
    $dpsi.FileName = 'powershell.exe'
    $dpsi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $sp)
    $dpsi.UseShellExecute = $false
    $dpsi.RedirectStandardInput = $true
    $dpsi.RedirectStandardOutput = $true
    $dpsi.RedirectStandardError = $true
    $dpsi.CreateNoWindow = $true
    try { $dpsi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    try { $dpsi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    $dp = [System.Diagnostics.Process]::Start($dpsi)
    $taskOut = $dp.StandardOutput.ReadToEndAsync()
    $taskErr = $dp.StandardError.ReadToEndAsync()
    # stdin 直接写 UTF-8 字节：走 StandardInput 会按代码页 936 编码，中文参数会变乱码
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($argJson)
    $dp.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $dp.StandardInput.BaseStream.Flush()
    $dp.StandardInput.Close()
    $code = -1
    if (-not $dp.WaitForExit(600000)) { try { $dp.Kill() } catch { } }
    else { $code = $dp.ExitCode }
    $o = ''; $e = ''
    try { $o = [string]$taskOut.Result } catch { }
    try { $e = [string]$taskErr.Result } catch { }
    $dp.Dispose()
    return @{ code = $code; out = $o; err = $e }
}

# 请求是不是"调用一个未挂载但已知的工具"？是则返回工具名，否则返回空串
function Get-DirectCallTarget([string]$json) {
    if ($json -notmatch '"tools/call"') { return '' }
    $o = $null
    try { $o = $json | ConvertFrom-Json } catch { return '' }
    if ($null -eq $o) { return '' }
    $pr = $o.PSObject.Properties['params']
    if ($null -eq $pr -or $null -eq $pr.Value) { return '' }
    $nr = $pr.Value.PSObject.Properties['name']
    if ($null -eq $nr -or $null -eq $nr.Value) { return '' }
    $n = [string]$nr.Value
    if ($n -eq '') { return '' }
    if (Test-ToolMounted $n) { return '' }
    if (-not (Test-ToolAvailable $n)) { return '' }
    return $n
}

# 直调并把结果包装成与服务端同形状的响应行，供既有断言复用
function Invoke-StepDirect([string]$title, [string]$json, [string]$name) {
    $o = $json | ConvertFrom-Json
    $argJson = '{}'
    $ar = $o.params.PSObject.Properties['arguments']
    if ($null -ne $ar -and $null -ne $ar.Value) { $argJson = ($ar.Value | ConvertTo-Json -Compress -Depth 20) }
    $script:report.Add('** ' + $name + ' 未挂载（不在 tools/list 里），由测试直接拉起脚本；参数: ' + (Shorten $argJson 300))
    $r = Invoke-ToolDirect $name $argJson
    if ($null -eq $r) {
        Fail ($title + '：脚本不存在，无法直调')
        $script:report.Add('')
        return $null
    }
    $isErr = 'false'
    if ($r.code -ne 0) { $isErr = 'true' }
    $line = '{"jsonrpc":"2.0","id":' + [string]$o.id + ',"result":{"content":[{"type":"text","text":' + (ConvertTo-JsonString ([string]$r.out)) + '}],"isError":' + $isErr + '}}'
    $script:report.Add(('<< [直调] 退出码 ' + $r.code))
    $script:report.Add('<< ' + (Shorten $r.out 4000))
    if (-not [string]::IsNullOrWhiteSpace($r.err)) { $script:report.Add('<< [直调 stderr] ' + (Shorten $r.err 1500)) }
    $script:report.Add('')
    return $line
}

# 发一条请求并把响应原文收进报告；返回响应行（异常时返回 $null）
function Run-Step([string]$title, [string]$json, [bool]$expectReply) {
    $script:report.Add('--- ' + $title + ' ---')
    $script:report.Add('>> ' + (Shorten $json 400))
    # 未挂载的工具不在 tools/list 里，服务端 tools/call 会回"未知工具" —— 改由测试自己
    # 直拉脚本，断言逻辑与挂载状态解耦（2026-09-30：原先"未挂载即 Skip"的写法，让 5 个
    # 工具的 $PSScriptRoot 相对路径错位长期无人发现，直到真被调用才暴露）
    if ($expectReply) {
        $directName = Get-DirectCallTarget $json
        if ($directName -ne '') { return (Invoke-StepDirect $title $json $directName) }
    }
    Send-Line $json
    if (-not $expectReply) {
        $script:report.Add('<< (通知类消息，按规范不回复)')
        $script:report.Add('')
        return $null
    }
    $line = Read-One 180000
    if ($null -eq $line) {
        Fail ($title + '：超时或连接已关闭')
        $script:report.Add('')
        return $null
    }
    $script:report.Add('<< ' + (Shorten $line 4000))
    $script:report.Add('')
    return $line
}

# 断言某个响应是"成功"（含 result 且 isError 不是 true）
function Assert-ResultOK([string]$title, [string]$line) {
    if ($null -eq $line) { return }
    if ($line -notmatch '"result"') { Fail ($title + '：响应里没有 result'); return }
    if ($line -match '"isError":true') { Fail ($title + '：isError=true，不该失败'); return }
    Pass $title
}

# ---- 校验 tools/list 的 schema 是否合法（核心回归断言）----
function Assert-ToolList([string]$line) {
    if ($null -eq $line) { return }
    $obj = $null
    try { $obj = $line | ConvertFrom-Json } catch { Fail 'tools/list：响应不是合法 JSON'; return }
    $tools = @($obj.result.tools)
    if ($tools.Count -eq 0) { Fail 'tools/list：tools 为空或不是数组（是否被序列化成 {} 了）'; return }

    $script:toolCount = $tools.Count
    $script:toolNames = (@($tools | ForEach-Object { $_.name }) -join ', ')
    Pass ('tools/list 返回 ' + $tools.Count + ' 个工具: ' + $script:toolNames)

    $allowed = @('string', 'integer', 'number', 'boolean', 'object', 'array')
    $bad = 0
    foreach ($t in $tools) {
        $tn = [string]$t.name
        if ($tn -notmatch '^[A-Za-z0-9_-]{1,64}$') { Fail ('工具名非法: "' + $tn + '"'); $bad++; continue }
        if ([string]::IsNullOrWhiteSpace([string]$t.description)) { Fail ('工具 ' + $tn + '：description 为空（AI 无法据此选择工具）'); $bad++ }
        if ($null -eq $t.inputSchema) { Fail ('工具 ' + $tn + '：缺 inputSchema'); $bad++; continue }
        if ([string]$t.inputSchema.type -ne 'object') { Fail ('工具 ' + $tn + '：inputSchema.type 应为 object，实际 "' + [string]$t.inputSchema.type + '"'); $bad++ }

        $propNames = @()
        if ($null -ne $t.inputSchema.properties) {
            $propNames = @($t.inputSchema.properties.PSObject.Properties | ForEach-Object { $_.Name })
        }
        foreach ($pn in $propNames) {
            if ($pn -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                # 就是这条把 IDE 搞崩过：属性名被拼成了 "file usage type date readme mode"
                Fail ('工具 ' + $tn + '：属性名非法（疑似把多个参数拼成一个名字）: "' + $pn + '"')
                $bad++
                continue
            }
            $pt = [string]$t.inputSchema.properties.$pn.type
            if ($allowed -notcontains $pt) {
                # 就是这条把 IDE 搞崩过：type 被拼成了 "string string string string string string"
                Fail ('工具 ' + $tn + '：属性 ' + $pn + ' 的 type 非法（疑似把多个类型拼成一个值）: "' + $pt + '"')
                $bad++
            }
        }

        $req = $t.inputSchema.required
        if ($null -ne $req -and -not ($req -is [array])) {
            Fail ('工具 ' + $tn + '：required 不是数组（PS 5.1 把空数组序列化成 "" 会这样）: "' + [string]$req + '"')
            $bad++
        }
        # 注意：required 缺省时是 $null，而 @($null) 会得到一个含 $null 元素的数组，会误报
        if ($null -ne $req) {
            foreach ($rn in @($req)) {
                if ($propNames -notcontains [string]$rn) { Fail ('工具 ' + $tn + '：required 里的 "' + [string]$rn + '" 不在 properties 中'); $bad++ }
            }
        }
    }
    if ($bad -eq 0) { Pass 'tools/list 的 inputSchema 全部合法（属性名/类型/required 均通过校验）' }
}

# ---- 断言某个响应是"失败"（isError=true）----
function Assert-ResultError([string]$title, [string]$line) {
    if ($null -eq $line) { return }
    if ($line -match '"isError":true') { Pass ($title + '（按预期返回 isError=true）') }
    else { Fail ($title + '：本应失败，却返回了成功') }
}

# ---- 步骤 1~3：握手 + 工具清单 ----
Run-Step '1) initialize' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1.0"}}}' $true | Out-Null
Run-Step '2) notifications/initialized' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' $false | Out-Null
$listLine = Run-Step '3) tools/list' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' $true
Assert-ToolList $listLine

# ---- 步骤 4：内建工具 search_local（中文参数，验证 UTF-8 通路）----
$callSearch = '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_local","arguments":{"query":"' + $Query + '","glob":"' + $Glob + '","maxResults":3,"contextLines":1}}}'
$r4 = Run-Step '4) tools/call search_local' $callSearch $true
Assert-ResultOK 'search_local 执行成功' $r4

# ---- 步骤 5：内建工具 read_local（越界路径，期望被拒绝）----
$r5 = Run-Step '5) tools/call read_local（越界路径，应拒绝）' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_local","arguments":{"path":"..\\..\\Windows\\win.ini"}}}' $true
Assert-ResultError 'read_local 拦住了目录穿越' $r5

# ---- 步骤 6：内建工具 list_local ----
$r6 = Run-Step '6) tools/call list_local' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_local","arguments":{"dir":"mcp","recursive":true,"sortBy":"size"}}}' $true
Assert-ResultOK 'list_local 执行成功' $r6

# ---- 步骤 7：外部工具 selfcheck（走"服务端拉起子进程 + stdin 传 JSON"通路）----
if ($SkipSelfcheck) {
    $report.Add('--- 7) tools/call selfcheck（已跳过）---')
    $report.Add('')
}
elseif (-not (Test-ToolAvailable 'selfcheck')) {
    $report.Add('--- 7) tools/call selfcheck（脚本缺失，已跳过）---')
    $report.Add('')
    Skip 'selfcheck 脚本缺失，跳过该用例'
}
else {
    # 注意：拼接必须先落到变量，不能直接写在调用行里（参数模式下 "+" 会被当成独立参数）
    $callSelfcheck = '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"selfcheck","arguments":{"root":"' + ($Root -replace '\\', '\\') + '"}}}'
    $r7 = Run-Step '7) tools/call selfcheck（外部工具）' $callSelfcheck $true
    Assert-ResultOK 'selfcheck（外部工具）执行成功' $r7
}

if (-not (Test-ToolAvailable 'add_readme_row')) {
    $script:report.Add('--- 8) tools/call add_readme_row（脚本缺失，已跳过）---')
    $script:report.Add('')
    Skip 'add_readme_row 脚本缺失，跳过该用例'
}
else {
# ---- 步骤 8：外部工具 add_readme_row（写临时 readme 并核对 +1 行，测完即删）----
$tmpReadme = Join-Path $scriptDir '_smoke-readme-tmp.md'
$seed = "# 冒烟测试临时表（用完即删）`r`n`r`n| 日期 | 文件 | 类型 | 用途 |`r`n|---|---|---|---|`r`n| 20260101 | _seed.md | 探针 | 定位锚点（add_readme_row 需要） |`r`n"
[IO.File]::WriteAllText($tmpReadme, $seed, (New-Object Text.UTF8Encoding($true)))
$lineCntBefore = @([IO.File]::ReadAllLines($tmpReadme)).Count
$callAdd = '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"add_readme_row","arguments":{"file":"_smoke-probe.txt","usage":"冒烟测试探针","type":"探针","readme":"' + ($tmpReadme -replace '\\', '\\') + '"}}}'
$r8 = Run-Step '8) tools/call add_readme_row（外部工具，写临时表）' $callAdd $true
Assert-ResultOK 'add_readme_row（外部工具）执行成功' $r8
$lineCntAfter = @([IO.File]::ReadAllLines($tmpReadme)).Count
if ($lineCntAfter -eq $lineCntBefore + 1) { Pass ('add_readme_row 确实追加了 1 行登记（' + $lineCntBefore + ' -> ' + $lineCntAfter + '）') }
else { Fail ('add_readme_row 行数未按预期 +1：' + $lineCntBefore + ' -> ' + $lineCntAfter) }
Remove-Item -LiteralPath $tmpReadme -Force -ErrorAction SilentlyContinue
}


if (-not (Test-ToolAvailable 'offline_audit')) {
    $script:report.Add('--- 10) tools/call offline_audit（脚本缺失，已跳过）---')
    $script:report.Add('')
    Skip 'offline_audit 脚本缺失，跳过该用例'
}
else {
# ---- 步骤 10：外部工具 offline_audit（只读扫描，须给出结论行）----
$auditDir = Join-Path $Root 'mcp'
$callAudit = '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"offline_audit","arguments":{"root":"' + ($auditDir -replace '\\', '\\') + '"}}}'
$r10 = Run-Step '10) tools/call offline_audit（外部工具，只读）' $callAudit $true
Assert-ResultOK 'offline_audit（外部工具）执行成功' $r10
if ($r10 -match 'RESULT: PASS') { Pass 'offline_audit 结论为 PASS（mcp 目录内全部纯本地）' }
else { Fail 'offline_audit 结论非 PASS，需检查联网依赖' }
}

# ---- 步骤 10a：外部工具 grep_regex（只读正则检索）----
$callGrep = '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"grep_regex","arguments":{"pattern":"(禁止|禁用).{0,8}(广播|延迟)","dir":"mcp","glob":"*.md","maxResults":2}}}'
$rG = Run-Step '10a) tools/call grep_regex（外部工具，只读）' $callGrep $true
Assert-ResultOK 'grep_regex（外部工具）执行成功' $rG
if ($rG -match '共命中 \d+ 个文件') { Pass 'grep_regex 返回命中统计行' }
else { Fail 'grep_regex 未返回命中统计行' }

# ---- 步骤 10b：外部工具 log_query（只读日志检索）----
$demoLog = Join-Path $scriptDir '_smoke-log-tmp.txt'
$demoLines = "[1] 08-27 14:45:41.169  2758  2758 D BtSetting: connect start`r`n[1] 08-27 14:45:42.100  2758  2758 E BtSetting: connect fail, reason = timeout`r`n[1] 08-27 14:45:43.000  2758  2758 I Other: nothing here`r`n"
[IO.File]::WriteAllText($demoLog, $demoLines, (New-Object Text.UTF8Encoding($false)))
$callLog = '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"log_query","arguments":{"file":"' + ($demoLog -replace '\\', '\\') + '","tag":"BtSetting","keys":"fail","around":1}}}'
$rL = Run-Step '10b) tools/call log_query（外部工具，只读）' $callLog $true
Assert-ResultOK 'log_query（外部工具）执行成功' $rL
if ($rL -match '命中 1 行') { Pass 'log_query 命中数正确（1 行）' }
else { Fail 'log_query 命中数不符预期' }
Remove-Item -LiteralPath $demoLog -Force -ErrorAction SilentlyContinue

# ---- 步骤 10c：外部工具 apk_info（只读；本机无示例 APK 时跳过）----
$demoApk = $null
foreach ($cand in @(
        (Join-Path $PSScriptRoot 'sample\BtSetting-debug.apk'),
        (Join-Path $PSScriptRoot 'sample\Hicar-debug.apk'),
        (Join-Path $PSScriptRoot 'sample\BTPhone-release.apk'))) {
    if (Test-Path -LiteralPath $cand) { $demoApk = $cand; break }
}
if ($null -eq $demoApk -or -not (Test-ToolAvailable 'apk_info')) {
    $script:report.Add('--- 10c) tools/call apk_info（无示例 APK 或脚本缺失，已跳过）---')
    $script:report.Add('')
    if (-not (Test-ToolAvailable 'apk_info')) { Skip 'apk_info 脚本缺失，跳过该用例' }
}
else {
    $callApk = '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"apk_info","arguments":{"apk":"' + ($demoApk -replace '\\', '\\') + '","fields":"package,version"}}}'
    $rA = Run-Step '10c) tools/call apk_info（外部工具，只读）' $callApk $true
    Assert-ResultOK 'apk_info（外部工具）执行成功' $rA
    if ($rA -match '包名') { Pass 'apk_info 返回包名行' }
    else { Fail 'apk_info 未返回包名' }
}
# ---- 步骤 10d：外部工具 tool_admin（只读 action=list，须给出两侧挂载清单）----
if (-not (Test-ToolAvailable 'tool_admin')) {
    $script:report.Add('--- 10d) tools/call tool_admin（脚本缺失，已跳过）---')
    $script:report.Add('')
    Skip 'tool_admin 脚本缺失，跳过该用例'
}
else {
    $callToggle = '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"tool_admin","arguments":{"action":"list"}}}'
    $rT = Run-Step '10d) tools/call tool_admin（外部工具，只读 list）' $callToggle $true
    Assert-ResultOK 'tool_admin（外部工具）执行成功' $rT
    if ($rT -match '【已挂载】' -and $rT -match '【已停用】') { Pass 'tool_admin 返回两侧挂载清单' }
    else { Fail 'tool_admin 未返回预期的挂载清单' }
    # 数量必须与文件系统一致：专抓"$PSScriptRoot 上溯层数错位"导致把 _disabled\ 当成挂载目录
    $expMount = @(Get-ChildItem -LiteralPath $toolsDir -Filter '*.tool.ps1' -File).Count
    $expOff = 0
    if (Test-Path -LiteralPath $disabledDir) { $expOff = @(Get-ChildItem -LiteralPath $disabledDir -Filter '*.tool.ps1' -File).Count }
    if ($rT -match ('已挂载】' + $expMount + ' 个')) { Pass ('tool_admin 挂载数与文件系统一致（' + $expMount + '）') }
    else { Fail ('tool_admin 挂载数与文件系统不符，期望 ' + $expMount + ' 个') }
    if ($rT -match ('已停用】' + $expOff + ' 个')) { Pass ('tool_admin 停用数与文件系统一致（' + $expOff + '）') }
    else { Fail ('tool_admin 停用数与文件系统不符，期望 ' + $expOff + ' 个') }
    if ($rT -match ('外部工具合计 ' + ($expMount + $expOff) + ' 个')) { Pass ('tool_admin 合计与文件系统一致（' + ($expMount + $expOff) + '）') }
    else { Fail ('tool_admin 合计与文件系统不符，期望 ' + ($expMount + $expOff) + ' 个') }
}

# ---- 步骤 10e：外部工具 tool_admin（只读，须给出排名表与零调用清单）----
if (-not (Test-ToolAvailable 'tool_admin')) {
    $script:report.Add('--- 10e) tools/call tool_admin（脚本缺失，已跳过）---')
    $script:report.Add('')
    Skip 'tool_admin 脚本缺失，跳过该用例'
}
else {
    # days=0 走全部历史，避免「窗口内无记录」导致断言失败
    $callUsage = '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"tool_admin","arguments":{"action":"usage","days":0}}}'
    $rU = Run-Step '10e) tools/call tool_admin（外部工具，只读排名）' $callUsage $true
    Assert-ResultOK 'tool_admin（外部工具）执行成功' $rU
    if ($rU -match '【有调用】' -and $rU -match '【零调用】') { Pass 'tool_admin 返回排名表与零调用清单' }
    else { Fail 'tool_admin 未返回预期的排名结构' }
}

# ---- 步骤 10f~10h：外部工具 fs_ops（写 / 查 / 删，全部在临时目录内自测后清理）----
$probeDir = Join-Path (Join-Path $scriptDir '_t') 'smoke-fs'
$probeFile = Join-Path $probeDir 'smoke.txt'
if (Test-Path -LiteralPath $probeDir) { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }
$callWrite = '{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"fs_ops","arguments":{"action":"write","path":"' + ($probeFile -replace '\\', '\\') + '","content":"a\nb"}}}'
$rF1 = Run-Step '10f) tools/call fs_ops write（外部工具）' $callWrite $true
Assert-ResultOK 'fs_ops write（外部工具）执行成功' $rF1
if ($rF1 -match '三查') { Pass 'fs_ops write 返回三查结果' }
else { Fail 'fs_ops write 未返回三查结果' }
$callStat = '{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"fs_ops","arguments":{"action":"stat","path":"' + ($probeFile -replace '\\', '\\') + '"}}}'
$rF2 = Run-Step '10g) tools/call fs_ops stat（外部工具）' $callStat $true
Assert-ResultOK 'fs_ops stat（外部工具）执行成功' $rF2
if ($rF2 -match '行数' -and $rF2 -match 'MD5') { Pass 'fs_ops stat 返回行数与哈希' }
else { Fail 'fs_ops stat 未返回行数/哈希' }
$callDel = '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"fs_ops","arguments":{"action":"delete","path":"' + ($probeDir -replace '\\', '\\') + '","recursive":true,"dryRun":false,"permanent":true}}}'
$rF3 = Run-Step '10h) tools/call fs_ops delete（外部工具，清理临时目录）' $callDel $true
Assert-ResultOK 'fs_ops delete（外部工具）执行成功' $rF3
if (Test-Path -LiteralPath $probeDir) { Fail 'fs_ops delete 后临时目录仍存在' }
else { Pass 'fs_ops delete 确实删掉了临时目录' }

if (-not (Test-ToolAvailable 'sys_info')) {
    $script:report.Add('--- 10i) tools/call sys_info（脚本缺失，已跳过）---')
    $script:report.Add('')
    Skip 'sys_info 脚本缺失，跳过该用例'
}
else {
# ---- 步骤 10i：外部工具 sys_info（只读系统信息）----
$callInfo = '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"sys_info","arguments":{"action":"disk"}}}'
$rI = Run-Step '10i) tools/call sys_info（外部工具，只读）' $callInfo $true
Assert-ResultOK 'sys_info（外部工具）执行成功' $rI
if ($rI -match '本地盘') { Pass 'sys_info disk 返回磁盘行' }
else { Fail 'sys_info 未返回磁盘信息' }
}

if (-not (Test-ToolAvailable 'sys_control')) {
    $script:report.Add('--- 10j~10l) tools/call sys_control（脚本缺失，已跳过）---')
    $script:report.Add('')
    Skip 'sys_control 脚本缺失，跳过该用例'
}
else {
# ---- 步骤 10j：外部工具 sys_control（危险动作默认只预演）----
$callCtl = '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"sys_control","arguments":{"action":"run","command":"echo kb-local-smoke","dryRun":true}}}'
$rC = Run-Step '10j) tools/call sys_control（外部工具，dryRun）' $callCtl $true
Assert-ResultOK 'sys_control（外部工具）执行成功' $rC
if ($rC -match 'DRY-RUN') { Pass 'sys_control dryRun 返回预演说明' }
else { Fail 'sys_control dryRun 未返回预演说明' }

# ---- 步骤 10k：外部工具 sys_control 危险命令拦截（应被拒绝）----
$callDanger = '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"sys_control","arguments":{"action":"run","command":"shutdown /s /t 0"}}}'
$rD = Run-Step '10k) tools/call sys_control 危险命令（应被拒绝）' $callDanger $true
Assert-ResultError 'sys_control 拦住了危险命令' $rD

# ---- 步骤 10l：环境自愈（IDE 会把 PATHEXT 覆写成 .CPL，导致 chcp/cmd/xxx.exe 全不可用）----
# 这是原先的覆盖盲区：污染环境下老用例也能全绿，但真实 MCP 通道里 pdf2txt 等会失败。
$cmdEnv = 'chcp 65001 | Out-Null; ''PATHEXT='' + $env:PATHEXT'
$callEnv = '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"sys_control","arguments":{"action":"run","command":"' + $cmdEnv + '","dryRun":false}}}'
$rE = Run-Step '10l) tools/call sys_control 原生命令 + 环境自愈' $callEnv $true
Assert-ResultOK 'sys_control 执行原生命令成功（环境自愈生效）' $rE
if ($rE -match '\.EXE') { Pass 'PATHEXT 含 .EXE（环境自愈生效）' }
else { Fail 'PATHEXT 不含 .EXE（环境自愈未生效）' }
if ($rE -match 'CommandNotFound') { Fail '原生命令仍解析失败（CommandNotFound）' }
else { Pass 'chcp 等原生命令可正常解析' }
}

# ---- 步骤 10m：pdf2txt 真实转换（覆盖"工具能列出、实际却不可用"的盲区）----
# 原测试 PDF 取自需求区（2026-09-30 已删）；默认改用本目录固件，可用 $env:SMOKE_PDF 覆盖
$smokePdf = if ($env:SMOKE_PDF) { [string]$env:SMOKE_PDF } else { (Join-Path $PSScriptRoot '_fixtures\smoke-sample.pdf') }
if (-not (Test-ToolAvailable 'pdf2txt')) {
    $script:report.Add('--- 10m) tools/call pdf2txt（脚本缺失，已跳过）---')
    $script:report.Add('')
    Skip 'pdf2txt 脚本缺失，跳过该用例'
}
elseif (Test-Path -LiteralPath $smokePdf) {
    $pdfEsc = $smokePdf.Replace('\', '\\')
    $outEsc = (Join-Path $PSScriptRoot '_t\_smoke_pdf').Replace('\', '\\')
    $callPdf = '{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"pdf2txt","arguments":{"pdf":"' + $pdfEsc + '","outDir":"' + $outEsc + '"}}}'
    $rP = Run-Step '10m) tools/call pdf2txt 真实转换（外部工具）' $callPdf $true
    Assert-ResultOK 'pdf2txt 转换成功' $rP
    if ($rP -match '个切片文件') { Pass 'pdf2txt 确实产出了切片文件' } else { Fail 'pdf2txt 未产出切片文件' }
}
else {
    Skip 'pdf2txt 冒烟用的 PDF 不存在，跳过该用例'
}
# ---- 步骤 10n：code_index 缓存目录（覆盖"缓存误落到 tools\_code-index"的路径错位）----
$ciRoot = $scriptDir
$callCi = '{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"code_index","arguments":{"action":"build","root":"' + ($ciRoot -replace '\\', '\\') + '","maxFiles":50}}}'
$rCi = Run-Step '10n) tools/call code_index build（校验缓存目录）' $callCi $true
Assert-ResultOK 'code_index（外部工具）执行成功' $rCi
if ($rCi -match 'mcp\\\\_code-index' -and $rCi -notmatch 'tools\\\\_code-index') { Pass 'code_index 缓存落在 mcp\_code-index（未误落 tools\）' }
else { Fail 'code_index 缓存目录不正确（相对路径上溯层数可能错位）' }

# ---- 步骤 10o：web_fetch 真实联网探活（覆盖"联网工具只是个壳"的盲区）----
if (-not (Test-ToolAvailable 'web_fetch')) {
    Skip 'web_fetch 脚本缺失，跳过该用例'
}
else {
    $callWf = '{"jsonrpc":"2.0","id":26,"method":"tools/call","params":{"name":"web_fetch","arguments":{"url":"https://cn.bing.com","mode":"head"}}}'
    $rWf = Run-Step '10o) tools/call web_fetch mode=head 联网探活' $callWf $true
    if ($null -ne $rWf -and $rWf -match '请求失败|没拿到响应|无法解析') {
        Skip 'web_fetch 探活失败：当前网络不可达（环境问题，非代码缺陷）'
    }
    else {
        Assert-ResultOK 'web_fetch（外部工具）执行成功' $rWf
        if ($rWf -match '状态\s*:\s*200') { Pass 'web_fetch 探活拿到 HTTP 200（mode=head 真发 HEAD）' }
        else { Fail 'web_fetch 探活没拿到 HTTP 200' }
    }
}

# ---- 步骤 10p：web_search 真实联网检索 ----
if (-not (Test-ToolAvailable 'web_search')) {
    Skip 'web_search 脚本缺失，跳过该用例'
}
else {
    $callWs = '{"jsonrpc":"2.0","id":27,"method":"tools/call","params":{"name":"web_search","arguments":{"query":"powershell","count":5}}}'
    $rWs = Run-Step '10p) tools/call web_search 真实检索' $callWs $true
    if ($null -ne $rWs -and $rWs -match '搜索失败|没拿到响应') {
        Skip 'web_search 检索失败：当前网络不可达（环境问题，非代码缺陷）'
    }
    else {
        Assert-ResultOK 'web_search（外部工具）执行成功' $rWs
        if ($rWs -match '=== web_search ===' -and $rWs -match '\[1\]') { Pass 'web_search 解析出结果列表（序号/标题/链接）' }
        else { Fail 'web_search 未解析出任何结果条目' }
    }
}

# ---- 步骤 10q：ps_run 通用 PowerShell 执行器（覆盖编码 / 退出码 / 危险拦截 / 预演）----
if (-not (Test-ToolAvailable 'ps_run')) {
    Skip 'ps_run 脚本缺失，跳过该用例'
}
else {
    $callPr = '{"jsonrpc":"2.0","id":28,"method":"tools/call","params":{"name":"ps_run","arguments":{"script":"Write-Output ''冒烟中文 OK''"}}}'
    $rPr = Run-Step '10q) tools/call ps_run 基本执行（中文编码）' $callPr $true
    Assert-ResultOK 'ps_run（外部工具）执行成功' $rPr
    if ($rPr -match '冒烟中文 OK') { Pass 'ps_run 中文输出未乱码（UTF-8 子进程 + 自动判编码生效）' }
    else { Fail 'ps_run 中文输出乱码' }

    $callPrExit = '{"jsonrpc":"2.0","id":29,"method":"tools/call","params":{"name":"ps_run","arguments":{"script":"exit 5"}}}'
    $rPrExit = Run-Step '10r) tools/call ps_run 退出码传播（应报错）' $callPrExit $true
    Assert-ResultError 'ps_run 把子进程退出码 5 传回 isError' $rPrExit

    $callPrDanger = '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"ps_run","arguments":{"script":"diskpart"}}}'
    $rPrDanger = Run-Step '10s) tools/call ps_run 危险命令（应被拒绝）' $callPrDanger $true
    Assert-ResultError 'ps_run 拦住了危险命令' $rPrDanger

    $callPrDry = '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"ps_run","arguments":{"script":"1+1","dryRun":true}}}'
    $rPrDry = Run-Step '10t) tools/call ps_run dryRun 预演' $callPrDry $true
    Assert-ResultOK 'ps_run dryRun 执行成功' $rPrDry
    if ($rPrDry -match '预演') { Pass 'ps_run dryRun 返回预演说明' } else { Fail 'ps_run dryRun 未返回预演说明' }
}

# ---- 步骤 10u：Write-Log 日志轮转（-LogMaxKB；覆盖"日志只涨不降"的盲区）----
# 独立起一个服务端把阈值压到 1 KB，灌 260 条通知顶过"每 200 行查一次"的检查点，
# 再发一条 ping 确认前序消息已处理完，最后断言出现了 .1 轮转文件。
# 若轮转逻辑坏掉（比如没接上 -LogMaxKB），这条会 FAIL —— 没有它就没人发现。
$rotLog = Join-Path $scriptDir '_t\_rotate.log'
$rotDir = Split-Path -Parent $rotLog
if (-not (Test-Path -LiteralPath $rotDir)) { [void](New-Item -ItemType Directory -Path $rotDir -Force) }
foreach ($f in @($rotLog, ($rotLog + '.1'))) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }

$rpsi = New-Object System.Diagnostics.ProcessStartInfo
$rpsi.FileName = 'powershell.exe'
$rpsi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -LogFile "{2}" -LogMaxKB 1' -f $serverFile, $Root, $rotLog)
$rpsi.UseShellExecute = $false
$rpsi.RedirectStandardInput = $true
$rpsi.RedirectStandardOutput = $true
$rpsi.RedirectStandardError = $true
$rpsi.CreateNoWindow = $true
try { $rpsi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { $rpsi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$rp = [System.Diagnostics.Process]::Start($rpsi)
# stderr 必须持续排空！服务端每条日志都写 stderr，若管道缓冲区（约 4 KB）写满而测试不读，
# 服务端会阻塞在"写 stderr"上、测试阻塞在"写 stdin"上 —— 硬死锁（2026-09-30 实测踩到，
# 且会把整条 MCP 请求队列一起堵死）。BeginErrorReadLine 即刻起异步读，数据丢弃即可。
try { $rp.BeginErrorReadLine() } catch { }
$script:report.Add('--- 10u) Write-Log 轮转（-LogMaxKB 1，灌 260 条通知）---')
try {
    $nb = [System.Text.Encoding]::UTF8.GetBytes('{"jsonrpc":"2.0","method":"notifications/initialized"}' + "`n")
    for ($k = 0; $k -lt 260; $k++) { $rp.StandardInput.BaseStream.Write($nb, 0, $nb.Length) }
    $rp.StandardInput.BaseStream.Flush()
    $pb = [System.Text.Encoding]::UTF8.GetBytes('{"jsonrpc":"2.0","id":99,"method":"ping"}' + "`n")
    $rp.StandardInput.BaseStream.Write($pb, 0, $pb.Length)
    $rp.StandardInput.BaseStream.Flush()
    $rtask = $rp.StandardOutput.ReadLineAsync()
    if (-not $rtask.Wait(90000)) { Fail '轮转用例：灌入通知后 ping 无响应' }
    else {
        $script:report.Add('<< ' + (Shorten $rtask.Result 200))
        Start-Sleep -Milliseconds 600
        if (Test-Path -LiteralPath ($rotLog + '.1')) {
            Pass ('Write-Log 轮转生效（生成 _rotate.log.1，' + (Get-Item -LiteralPath ($rotLog + '.1')).Length + ' B）')
        }
        else { Fail 'Write-Log 未轮转（_rotate.log.1 不存在：-LogMaxKB 参数或轮转逻辑失效）' }
    }
}
finally {
    try { $rp.StandardInput.Close() } catch { }
    if (-not $rp.WaitForExit(15000)) { try { $rp.Kill() } catch { } }
    foreach ($f in @($rotLog, ($rotLog + '.1'))) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
}
$script:report.Add('')

# ---- 步骤 10v：github_api 联网只读查询（覆盖联网工具的配额解析与本地参数校验）----
if (-not (Test-ToolAvailable 'github_api')) {
    Skip 'github_api 脚本缺失，跳过该用例'
}
else {
    $callGh = '{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"github_api","arguments":{"action":"rate_limit"}}}'
    $rGh = Run-Step '10v) tools/call github_api rate_limit 联网查询' $callGh $true
    if ($null -ne $rGh -and $rGh -match '请求失败|没拿到响应|无法解析') {
        Skip 'github_api 查询失败：当前网络不可达（环境问题，非代码缺陷）'
    }
    else {
        Assert-ResultOK 'github_api（外部工具）执行成功' $rGh
        if ($rGh -match '剩余\s*\d+\s*/\s*\d+') { Pass 'github_api 解析出配额（X-RateLimit 剩余/上限）' }
        else { Fail 'github_api 未解析出配额信息' }
    }

    # 纯本地校验（不联网）：非法 repo 必须被拒
    $callGhBad = '{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"github_api","arguments":{"action":"repo","repo":"no-slash"}}}'
    $rGhBad = Run-Step '10w) tools/call github_api 非法 repo（应报错）' $callGhBad $true
    Assert-ResultError 'github_api 拒绝了非法 repo 参数' $rGhBad
}

# ---- 步骤 8：未知工具（应报错并列出可用工具）----
$r11 = Run-Step '11) tools/call 不存在的工具（应报错）' '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}' $true
Assert-ResultError '未知工具被正确拒绝' $r11

# ---- 步骤 9：ping + 关闭 stdin，服务端应自行退出 ----
$r12 = Run-Step '12) ping' '{"jsonrpc":"2.0","id":8,"method":"ping"}' $true
Assert-ResultOK 'ping 有响应' $r12

$p.StandardInput.Close()
if (-not $p.WaitForExit(15000)) {
    try { $p.Kill() } catch { }
    Fail '关闭 stdin 后服务端未在 15s 内自行退出'
}
else { Pass ('关闭 stdin 后服务端自行退出，退出码 ' + $p.ExitCode) }

$stderrText = ''
try { $stderrText = $p.StandardError.ReadToEnd() } catch { }

$script:report.Add('--- 服务端 stderr ---')
$script:report.Add($stderrText)
$script:report.Add('')
$script:report.Add(('工具清单: {0} 个  ->  {1}' -f $script:toolCount, $script:toolNames))
$script:report.Add(('=== 结果: PASS={0} FAIL={1} SKIP={2} ===' -f $script:passCount, $script:failCount, $script:skipCount))

[System.IO.File]::WriteAllLines($resultFile, $script:report, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ('smoke test done. PASS={0} FAIL={1} SKIP={2}' -f $script:passCount, $script:failCount, $script:skipCount)
Write-Host ('result -> ' + $resultFile)
if ($script:failCount -gt 0) { exit 1 }
exit 0

