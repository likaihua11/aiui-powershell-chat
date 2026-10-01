#requires -Version 5.1
<#
.SYNOPSIS
    本地知识库 MCP 服务（工具集版 v0.8.5：3 个内建工具 + tools\ 下任意个外部工具）

.DESCRIPTION
    用 PowerShell 5.1 手写的 stdio 型 MCP 服务端，零外部依赖
    （本机实测没有 python3 / pip / node / npm / uv，所以走不了官方 SDK）。

    传输：stdio（行分隔 JSON-RPC 2.0，一条消息一行）；协议：MCP 2024-11-05。

    暴露的工具 = 3 个内建 + tools\*.tool.ps1 里声明的外部工具：
      内建：search_local（全文检索） read_local（按路径读全文） list_local（列目录）
      外部：把脚本丢进 tools\ 目录即自动多一个 MCP 工具，服务端代码与 IDE 注册都不用改
            （脚本头部用 # @mcp-tool ... # @mcp-tool-end 块声明 name/description/params/timeout）

    三条编码规矩（服务端自身层面；工具集的「本地 MCP 工具技术约束」另见 mcp\工具集规范.md）。违反其中任一条，IDE 侧就会连不上或报解析错误：
      1) stdout 只能输出协议 JSON；日志、异常、提示一律写 stderr（本脚本已全部走 stderr）；
      2) 输出必须是 UTF-8 且不带 BOM；
      3) 本文件必须存成 UTF-8 with BOM —— PS 5.1 会把无 BOM 的 .ps1 按 GBK(936) 解析，
         脚本里的中文字面量会烂掉（本机已在 kb.ps1、pdf2txt 上踩过两次）。

v0.8.5 变更记录（2026-10-01）：
【新增 1 个联网只读工具】github_api（直连 GitHub 官方 REST API 读公开仓库数据：仓库信息 / 目录与文件内容 /
README / issue 与 PR（列表与详情）/ 提交 / 发布 / 分支 / 标签 / 贡献者 / 用户与组织 / 仓库与 issue 搜索，
另有 rate_limit 查剩余次数）。**无第三方中转、无 API key 门槛、无调用额度**，受限的只是 GitHub 自身限速
（匿名 60 次/小时/出口 IP，带 token 5000 次/小时），每次调用都回显 X-RateLimit 剩余量与重置时间；
只发 GET、不改动 GitHub 数据、不写本地文件。按规矩先进 tools\_disabled\ 目录走命令行，跑一段时间再决定是否挂载
（offline_audit 判为 REVIEW：对外联网、无额度，description 已声明依赖与限速）。
【冒烟测试】补 2 个用例（10v github_api rate_limit 联网 / 10w 非法 repo 本地拒绝），
PASS 53 -> 56、FAIL=0、SKIP=0。服务端代码本轮未改动。
v0.8.4 变更记录（2026-09-30）：
【Write-Log 加日志轮转】新增 -LogMaxKB 参数（默认 512 KB）：-LogFile 每写满 200 行查一次体积，
超阈值即轮转成 <LogFile>.1（只保留一代），总量有界（≤ 2 × LogMaxKB）。此前 _server-stderr.txt
每次工具调用都追加一行、只涨不降（实测 1108 行 / 84.8 KB）。
【参数】新增 -LogMaxKB <KB>（与 -LogFile 配套；不传 -LogFile 时无副作用）。
v0.8.3 变更记录（2026-09-30）：
  【新增 2 个联网工具】web_fetch（抓指定 URL 的网页：mode=head 探活 / text 正文 / html 原始 /
    links 抽链接 / title 取标题；编码按 Content-Type 的 charset -> HTML meta -> UTF-8 三段式判定，
    修掉中文乱码）与 web_search（抓 cn.bing.com 公开 HTML 检索页取搜索结果；site 参数在本地按
    结果域名过滤，因为 Bing 不认原生 site: 语法；上游 HTML 页不可翻页，count 仅作返回条数上限）。
    两者都不依赖有额度 / 配额的第三方服务、无 API key（过 offline_audit 门禁），先放 tools\_disabled\
    走命令行调用，跑一段时间后再决定是否挂载。冒烟测试补 2 个用例（10o web_fetch mode=head /
    10p web_search），PASS 47 -> 51、FAIL=0、SKIP=0。
v0.8.2 变更记录（2026-09-30）：
  【挂载模型重构】废除「档位」机制（删除 tools\profile.tool.ps1），改为**最小挂载**：
    tools\ 直下只保留 5 个「IDE 无法替代」的外部工具（fs_ops / code_index / log_query /
    grep_regex / adb_ops），其余 12 个移入 tools\_disabled\（该目录原有 5 个退役工具，合计 17 个）。
    tools/list 从 v0.8.1 的约 12.6 KB（brief，21 工具）降到约 5.6 KB（brief，8 工具），
    累计比 v0.8.0 的约 31 KB 省约 82%。
  【新增命令行调度器】未挂载工具用 mcp\call-tool.ps1 调用，不进 AI 上下文：
    call-tool.ps1 list / schema <名> / run <名> <k=v>... 或 '<JSON>'，-ArgsFile 传文件。
    调用契约与服务端 Invoke-ExternalTool 一致（参数 UTF-8 字节走 stdin，结果走 stdout，退出码透传）。
  【配套】挂载 / 下架 = 把 *.tool.ps1 在 tools\ 与 tools\_disabled\ 之间移动；每次 tools/call 之后
    服务端比对挂载快照，有变化就补发 notifications/tools/list_changed，客户端不必重启。
v0.8.1 变更记录（2026-09-30）：
  【工具描述瘦身】tools/list 从约 31 KB（≈9.7k token）降到约 11 KB（≈3.4k token），省约 66%。
    默认 brief 模式：工具描述只留首句（≤90 字），参数只保留 action 与必填项的 description，
    其余参数只留 type；完整描述与全部参数说明迁到 mcp\工具手册.md（AI 可用 read_local 读）。
    加 -Full 参数即恢复完整描述（IDE 侧 MCP 注册配置里追加 -Full 即可）。
v0.8.0 变更记录（2026-09-30）：
  【新增外部工具 3 个】adb_ops（Android 设备操作：装卸 APK / 启动强停清数据 / 传文件 / 截图 / 查包 / 跑设备命令）、
    git_summary（多仓库 Git 汇总：overview / status / diff / log / branches / stash / repos）、
    gradle_task（Gradle 工程任务：info / tasks / variants / run，自动探测并注入 JAVA_HOME）。
  【升级外部工具 4 个】code_index 扩到 Java / Kotlin / C / C++ / Python 五语言；log_query 增 source=adb
    直连抓 logcat 与 action=crash 崩溃归并去重；grep_regex 增 mode=content/files/res 与 glob 多模式；
    fs_ops 增 batchReplace 目录批量替换与 transcode 批量转码。
  【规模】外部工具 11 → 17 个，暴露工具 14 → 20 个。tools/list 约 31 KB（token 预算见 mcp\README.md 第 8 节）。
  本版未改服务端协议与内建工具逻辑，仅版本号对齐工具集规模。

v0.7.2 修复记录（2026-09-29）：
  【根因】IDE（Copilot 插件）拉起本服务时，把环境变量 PATHEXT 覆写成 ".CPL" 并清空 ComSpec，
  并砍掉大量变量（子进程只剩 19 个）。后果有两类：
    ① PowerShell 认为 .exe 是"文档"，`& xxx.exe` 直接报 CantActivateDocumentInPipeline
       —— pdf2txt 调 jjs 即因此失败（现象是"jjs 退出码 "后面空白，$LASTEXITCODE 未被赋值）；
    ② 解析不到 chcp / cmd / where 等原生命令（PATHEXT 缺 .COM/.EXE，无法补全扩展名）。
  注意：本机终端环境是完整的，所以命令行手动测试测不出，只有经 IDE 的 MCP 通道才复现。
  【修法】服务端启动时做「环境自愈」Repair-EnvVars：从注册表 Machine 级环境取标准值，
  补回 PATHEXT（确保含 .EXE）、ComSpec、TEMP/TMP、以及 PATH 里的 System32，并写启动日志。
  因为外部工具子进程用 ProcessStartInfo 继承本进程环境，所以此处修一次即覆盖全部工具。
  sys_control.tool.ps1 另自带同款自愈（它要 spawn 用户命令，且可能被命令行直调）。
  冒烟测试新增用例 10l 覆盖该盲区（原先在污染环境下也能全绿，属覆盖漏洞）。
v0.7.1 变更记录（2026-09-29）：
  外部工具 12 → 11 个 —— 把两个「工具集治理」工具合并为 tool_admin
  （action=list 列两侧挂载清单 / usage 调用次数排名 / disable 停用 / enable 启用；
  disable、enable 默认 dryRun 预演，不删除、不覆盖、拒绝操作自身）；
  原 toggle_tool 与 tool_usage 移入 tools\_disabled\ 保留，可随时移回；服务端代码未改。
  冒烟测试改为调用 tool_admin（PASS=32 FAIL=0 SKIP=2）。
v0.7.0 变更记录（2026-09-29）：
  外部工具 9 → 12 个，服务端代码未改（本版只改版本号与本记录）：
    新增 fs_ops       文件 / 目录增删改查（12 个 action：write / append / replace / insert /
                      deleteLines / mkdir / copy / move / delete / stat / exists / read），
                      带改动前自动备份、落盘后三查（行数 / BOM / 尾部污染）、白名单根约束
                      （白名单文件 mcp\_fs-roots.txt）、落盘审计日志（mcp\_fs-ops-audit.log）；
                      删除默认只预演、默认移入 _trash 回收目录、非空目录须 recursive=true
    新增 sys_info     系统信息只读查询（12 项：概况 / CPU / 内存 / 磁盘 / 网络 / 端口 /
                      进程 / 服务 / 环境变量 / 已装软件 / 时间 / 目录占用）
    新增 sys_control  电脑控制（run 执行命令 / kill 结束进程 / start 启动程序 / open 打开 /
                      service 启停服务 / clipboard 剪贴板 / power 电源）；kill、service、power
                      默认只预演，run 有危险命令拦截，kill 有系统关键进程保护名单
  冒烟测试扩至 27 步，覆盖全部 12 个外部工具；15 个工具的 tools/list 实测 17,046 字节。
v0.6.4 变更记录（2026-09-29）：
  增加工具调用计数：① Write-Log 时间戳补日期（yyyy-MM-dd HH:mm:ss），使时间窗统计成立；
  ② tools/call 每次调用落一行 "tool-call: <名称> ok=<bool>"（成功失败都记），
  供 log_query 按窗口汇总、以调用次数排名决定工具挂载；③ 协议路径未改。

v0.6.3 变更记录（2026-09-29）：
  新增 toggle_tool（停用 / 启用外部工具：在 tools\ 与 tools\_disabled\ 之间移动脚本，
  默认 dryRun 预演、不删除、不覆盖、拒绝操作自身）；冒烟测试改造为「未挂载用例自动跳过」；
  3 个治理类工具停用（apply_agents_rule / offline_audit / kb_mirror_audit 移入 tools\_disabled\）；服务端代码未改。

v0.6.2 变更记录（2026-09-29）：
  外部工具扩到 10 个 —— 新增 grep_regex（.NET 正则全文检索）、log_query（离线日志定向检索）、
  apk_info（自写 AXML 解析器读 APK 包信息）；服务端代码未改。
  冒烟测试扩到 22 步，覆盖 7 个外部工具的真实调用。

v0.6.1 变更记录（2026-09-29）：
  外部工具扩到 7 个 —— 新增 kb_mirror_audit（本地 kb 镜像体检）；服务端代码未改。

v0.6.0 变更记录（2026-09-29）：
  外部工具扩到 6 个 —— 新增 kb_mirror（中心 kb 只读镜像成本地语料）；服务端代码未改。

v0.5.0 变更记录（2026-09-29）：
  外部工具扩到 5 个 —— 新增 apply_agents_rule（规则正本幂等注入 AGENTS.md）与
  offline_audit（联网依赖审计·配额红线门禁）；服务端代码未改。
  冒烟测试由 9 步扩到 12 步，覆盖全部 5 个外部工具的真实调用。

    v0.4.0 修复记录（2026-09-29）：
      症状：IDE 报 400 —— Invalid schema for function 'mcp_kblocal_add_readme_row':
            "string string string string string string" is not valid under any of the schemas
            listed in the 'anyOf' keyword，整个 kblocal 工具集加载失败。
      原因：v0.3.0 解析工具头部 # params: 那行时，没把 JSON 数组逐项取字段，
            而是把各参数对象的字段用空格拼成了单个字符串，于是生成了
              properties: { "file usage type date readme mode": { "type": "string string string ..." } }
            —— 属性名和 type 值双双非法，客户端做 JSON Schema 校验时直接拒绝整个服务器。
      修法：
        a) # params: 严格按 ConvertFrom-Json 解析成对象数组，逐项展开成独立属性；
        b) 参数名必须匹配 ^[A-Za-z_][A-Za-z0-9_]*$，不合法就丢弃该参数（宁可少参数，也不产出非法 schema）；
        c) type 只允许 string/integer/number/boolean/object/array，其它一律降级为 string 并记日志；
        d) 无必填参数时省略 required 字段（PS 5.1 把空数组序列化成 "" 同样会被客户端判为非法）；
        e) 冒烟测试加"schema 合法性"断言，把这类错误拦在使用之前。

.PARAMETER Root
    知识库根目录，检索范围（默认：本脚本上一级目录）

.PARAMETER LogFile
    可选：把 stderr 日志同时追加写入该文件，便于事后排查

.PARAMETER ToolsDir
    外部工具目录（默认 <本脚本目录>\tools）

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File kb-local-mcp.ps1 -Root <你的资料目录>
    powershell -NoProfile -ExecutionPolicy Bypass -File test-kb-local-mcp.ps1   # 冒烟测试

.NOTES
    不使用 param 块：PS 5.1 用 -File 调用带 param 的脚本时，脚本自身输出会被当成参数
    再次绑定，报 System.String -> SwitchParameter 转换异常（同 kb.ps1 的坑）。改为手动解析 $args。
#>

$ErrorActionPreference = 'Continue'

# ---- 手动解析命令行参数（不用 param，原因见 .NOTES）----
# 自定位工作区根（可移植）：本脚本在 <root>\mcp\ 下，上溯一级即工作区根；外部仍可用 -Root 覆盖
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { $Root = $PSScriptRoot }
$LogFile = ''
$LogMaxKB = 512   # -LogFile 的轮转阈值（KB）：超过即轮转成 <日志>.1，防无限增长
$ToolsDir = Join-Path $PSScriptRoot 'tools'
$DisabledDir = Join-Path $ToolsDir '_disabled'
# 描述模式：默认 brief（精简，tools/list 约 31 KB -> 约 11 KB）；-Full 恢复完整描述
$Brief = $true
for ($i = 0; $i -lt $args.Count; $i++) {
    $n = [string]$args[$i]
    $v = if ($i + 1 -lt $args.Count) { [string]$args[$i + 1] } else { '' }
    if ($n -eq '-Root') { $Root = $v; $i++ }
    elseif ($n -eq '-LogFile') { $LogFile = $v; $i++ }
    elseif ($n -eq '-ToolsDir') { $ToolsDir = $v; $i++ }
elseif ($n -eq '-LogMaxKB') { $LogMaxKB = [int]$v; $i++ }
    elseif ($n -eq '-Full') { $Brief = $false }
    elseif ($n -eq '-Brief') { $Brief = $true }
}

# ---- 标准流：显式指定 UTF-8 无 BOM，不依赖 [Console]::OutputEncoding ----
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stdinReader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8NoBom)
$stdoutWriter = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8NoBom)
$stdoutWriter.AutoFlush = $true
# stderr 同样用 UTF-8 流：[Console]::Error 会按控制台代码页(936)编码，中文日志会变乱码
$stderrWriter = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), $utf8NoBom)
$stderrWriter.AutoFlush = $true

$script:LogWrites = 0   # 日志轮转计数（每 N 行查一次体积，见 Write-Log）
$script:ExternalTools = @{}
$script:ToolsSnapshot = ''

function Write-Log([string]$m) {
    $t = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    try { $stderrWriter.Write($t + "`n"); $stderrWriter.Flush() } catch { }
    if ($LogFile) {
    try {
        # 日志轮转：不设上限时 _server-stderr.txt 会无限增长（每次工具调用都追加一行）。
        # 每写满 200 行查一次体积，超过 LogMaxKB 就把当前文件挪成 <LogFile>.1（只保留一代），
        # 总量有界（≤ 2 × LogMaxKB），排查时最近的日志仍在主文件里。
        $script:LogWrites++
        if ($script:LogWrites -ge 200) {
            $script:LogWrites = 0
            $fi = Get-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue
            if ($fi -and $fi.Length -ge ($LogMaxKB * 1KB)) {
                $rot = $LogFile + '.1'
                if (Test-Path -LiteralPath $rot) { Remove-Item -LiteralPath $rot -Force -ErrorAction SilentlyContinue }
                Move-Item -LiteralPath $LogFile -Destination $rot -Force -ErrorAction SilentlyContinue
            }
        }
        [System.IO.File]::AppendAllText($LogFile, $t + [Environment]::NewLine, $utf8NoBom)
    }
    catch { }
}
}

function Send-Message($obj) {
    $json = $obj | ConvertTo-Json -Depth 30 -Compress
    $stdoutWriter.Write($json + "`n")
    $stdoutWriter.Flush()
}

# 正常响应
function Send-Result($id, $result) {
    Send-Message ([ordered]@{ jsonrpc = '2.0'; id = $id; result = $result })
}

# 错误响应
function Send-Error($id, [int]$code, [string]$message) {
    Send-Message ([ordered]@{ jsonrpc = '2.0'; id = $id; error = [ordered]@{ code = $code; message = $message } })
}

# 工具返回内容（MCP 规定放 result.content[].text）
function Send-ToolText($id, [string]$text, [bool]$isError = $false) {
    Send-Result $id ([ordered]@{
            content = @([ordered]@{ type = 'text'; text = $text })
            isError = $isError
        })
}

# 单行裁剪，避免超长行（压缩过的源码、日志）把响应撑爆；read_local 用更大的上限
function Format-Line([string]$line, [int]$max = 300) {
    if ($null -eq $line) { return '' }
    $s = $line.Trim()
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max) + ' ...' }
    return $s
}

# 把传入路径解析成绝对路径，并强制约束在 -Root 之内（防目录穿越）
function Resolve-UnderRoot([string]$PathIn) {
    if ([string]::IsNullOrWhiteSpace($PathIn)) { throw 'path 不能为空' }
    $p = $PathIn
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $Root $p }
    $full = [System.IO.Path]::GetFullPath($p)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('路径越界：只允许访问检索根目录以内的路径 -> ' + $PathIn)
    }
    return $full
}

# 相对根目录的显示路径
function Get-RelPath([string]$full) {
    $rel = $full
    if ($rel.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($Root.Length).TrimStart('\') }
    return $rel
}

# ============ 内建工具 1：search_local ============
function Invoke-SearchLocal($Arguments) {
    $query = [string]$Arguments.query
    if ([string]::IsNullOrWhiteSpace($query)) { throw 'query 不能为空' }

    $glob = if ($Arguments.glob) { [string]$Arguments.glob } else { '*.md' }
    $max = if ($Arguments.maxResults) { [int]$Arguments.maxResults } else { 20 }
    $ctx = if ($null -ne $Arguments.contextLines) { [int]$Arguments.contextLines } else { 0 }
    if ($max -lt 1) { $max = 1 } elseif ($max -gt 100) { $max = 100 }
    if ($ctx -lt 0) { $ctx = 0 } elseif ($ctx -gt 3) { $ctx = 3 }

    if (-not (Test-Path -LiteralPath $Root)) { throw ("Root 目录不存在: " + $Root) }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $glob -Force -ErrorAction SilentlyContinue)
    $scanned = $files.Count

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('本地检索: query="{0}"  glob="{1}"  context={2}' -f $query, $glob, $ctx))
    [void]$sb.AppendLine(('检索根目录: {0}' -f $Root))

    $hitFiles = 0
    $hitLines = 0
    foreach ($f in $files) {
        if ($hitFiles -ge $max) { break }
        if ($ctx -gt 0) {
            $m = @(Select-String -LiteralPath $f.FullName -Pattern $query -SimpleMatch -Context $ctx, $ctx -ErrorAction SilentlyContinue)
        }
        else {
            $m = @(Select-String -LiteralPath $f.FullName -Pattern $query -SimpleMatch -ErrorAction SilentlyContinue)
        }
        if ($m.Count -eq 0) { continue }

        $hitFiles++
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('## {0}   ({1} 处, {2} B)' -f (Get-RelPath $f.FullName), $m.Count, $f.Length))

        $shown = 0
        foreach ($x in $m) {
            if ($shown -ge 5) {
                [void]$sb.AppendLine(('  ... 该文件另有 {0} 处未展开' -f ($m.Count - $shown)))
                break
            }
            $shown++
            $hitLines++

            if ($ctx -gt 0) {
                foreach ($pre in $x.Context.PreContext) {
                    [void]$sb.AppendLine(('      | ' + (Format-Line $pre)))
                }
            }
            [void]$sb.AppendLine(('  L{0}: {1}' -f $x.LineNumber, (Format-Line $x.Line)))
            if ($ctx -gt 0) {
                foreach ($post in $x.Context.PostContext) {
                    [void]$sb.AppendLine(('      | ' + (Format-Line $post)))
                }
            }
        }
    }

    $sw.Stop()
    [void]$sb.AppendLine('')
    if ($hitFiles -eq 0) {
        [void]$sb.AppendLine(('未命中：已扫描 {0} 个文件（glob={1}），耗时 {2:N2}s' -f $scanned, $glob, $sw.Elapsed.TotalSeconds))
    }
    else {
        $tail = ''
        if ($hitFiles -ge $max) { $tail = '（命中文件数已达 maxResults 上限，可能还有更多）' }
        [void]$sb.AppendLine(('共命中 {0} 个文件 / 展示 {1} 行  — 已扫描 {2} 个文件（glob={3}），耗时 {4:N2}s {5}' -f $hitFiles, $hitLines, $scanned, $glob, $sw.Elapsed.TotalSeconds, $tail))
    }
    return $sb.ToString()
}

# ============ 内建工具 2：read_local ============
function Invoke-ReadLocal($Arguments) {
    $full = Resolve-UnderRoot ([string]$Arguments.path)

    $start = if ($Arguments.startLine) { [int]$Arguments.startLine } else { 1 }
    $maxL = if ($Arguments.maxLines) { [int]$Arguments.maxLines } else { 200 }
    if ($start -lt 1) { $start = 1 }
    if ($maxL -lt 1) { $maxL = 1 } elseif ($maxL -gt 1000) { $maxL = 1000 }

    if (-not (Test-Path -LiteralPath $full)) { throw ('文件不存在: ' + $Arguments.path) }
    if (Test-Path -LiteralPath $full -PathType Container) { throw ('这是目录、不是文件（找内容请用 search_local）: ' + $Arguments.path) }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $item = Get-Item -LiteralPath $full
    $all = @(Get-Content -LiteralPath $full -Encoding UTF8)
    $total = $all.Count

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('读取: {0}' -f (Get-RelPath $full)))
    [void]$sb.AppendLine(('绝对路径: {0}   {1} B   总行数: {2}' -f $full, $item.Length, $total))

    if ($total -eq 0) {
        [void]$sb.AppendLine('(空文件)')
    }
    elseif ($start -gt $total) {
        [void]$sb.AppendLine(('startLine={0} 已超出总行数 {1}，未读到内容' -f $start, $total))
    }
    else {
        $to = [Math]::Min($total, $start + $maxL - 1)
        [void]$sb.AppendLine(('本次显示 L{0}~L{1}（共 {2} 行）' -f $start, $to, ($to - $start + 1)))
        [void]$sb.AppendLine('')
        for ($n = $start; $n -le $to; $n++) {
            [void]$sb.AppendLine(('{0,6}: {1}' -f $n, (Format-Line $all[$n - 1] 1000)))
        }
        if ($to -lt $total) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine(('... 还有 {0} 行未显示；继续读请传 startLine={1}' -f ($total - $to), ($to + 1)))
        }
    }

    $sw.Stop()
    [void]$sb.AppendLine(('耗时 {0:N2}s（整个文件读入内存，分页在内存里截取）' -f $sw.Elapsed.TotalSeconds))
    return $sb.ToString()
}

# ============ 内建工具 3：list_local ============
function Invoke-ListLocal($Arguments) {
    $dirIn = ''
    if ($Arguments.dir) { $dirIn = [string]$Arguments.dir }
    $base = if ([string]::IsNullOrWhiteSpace($dirIn)) { [System.IO.Path]::GetFullPath($Root) } else { Resolve-UnderRoot $dirIn }

    if (-not (Test-Path -LiteralPath $base)) { throw ('目录不存在: ' + $dirIn) }
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw ('这不是目录（读文件请用 read_local）: ' + $dirIn) }

    $pattern = '*'
    if ($Arguments.pattern) { $pattern = [string]$Arguments.pattern }
    $recursive = $false
    if ($null -ne $Arguments.recursive) { $recursive = [bool]$Arguments.recursive }
    $sortBy = 'name'
    if ($Arguments.sortBy) { $sortBy = ([string]$Arguments.sortBy).ToLowerInvariant() }
    if (@('name', 'size', 'time') -notcontains $sortBy) { $sortBy = 'name' }
    $max = if ($Arguments.maxResults) { [int]$Arguments.maxResults } else { 100 }
    if ($max -lt 1) { $max = 1 } elseif ($max -gt 500) { $max = 500 }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $items = if ($recursive) {
        @(Get-ChildItem -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue)
    }
    else {
        @(Get-ChildItem -LiteralPath $base -Force -ErrorAction SilentlyContinue)
    }
    $items = @($items | Where-Object { $_.Name -like $pattern })

    switch ($sortBy) {
        'size' { $items = @($items | Sort-Object -Property Length -Descending) }
        'time' { $items = @($items | Sort-Object -Property LastWriteTime -Descending) }
        default { $items = @($items | Sort-Object -Property FullName) }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('列目录: {0}   pattern="{1}"  recursive={2}  sortBy={3}' -f (Get-RelPath $base), $pattern, $recursive, $sortBy))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('条目（匹配 {0} 个，显示 {1} 个）:' -f $items.Count, [Math]::Min($items.Count, $max)))
    [void]$sb.AppendLine('')

    $shown = 0
    foreach ($it in $items) {
        if ($shown -ge $max) { break }
        $shown++
        $rel = Get-RelPath $it.FullName
        if ($it.PSIsContainer) {
            $rel = $rel + '\'
            [void]$sb.AppendLine(('{0,12}  {1}  {2}' -f '<DIR>', $it.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $rel))
        }
        else {
            [void]$sb.AppendLine(('{0,12:N0}  {1}  {2}' -f $it.Length, $it.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $rel))
        }
    }
    if ($items.Count -gt $shown) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('... 还有 {0} 个未显示（可加大 maxResults，上限 500）' -f ($items.Count - $shown)))
    }

    $sw.Stop()
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('耗时 {0:N2}s' -f $sw.Elapsed.TotalSeconds))
    return $sb.ToString()
}

# ============ 描述精简（brief 模式）============
# 实测：20 个工具的完整 tools/list 约 31 KB ≈ 9.7k token，其中参数级描述占 40%、
# 工具级描述占 29%。brief 模式把工具描述截到首句、参数只留 action 与必填项的描述，
# 可降到约 11 KB；完整说明迁到 mcp\工具手册.md，需要时用 read_local 读。
function Get-BriefDesc([string]$s, [int]$max = 90) {
    if (-not $script:Brief) { return $s }
    $t = [string]$s
    if ([string]::IsNullOrWhiteSpace($t)) { return $t }
    $i = $t.IndexOf('。')
    if ($i -gt 0 -and $i -lt $max) { return $t.Substring(0, $i + 1) }
    if ($t.Length -gt $max) { return $t.Substring(0, $max) + '…' }
    return $t
}

function Get-BriefSchema($schema) {
    if (-not $script:Brief) { return $schema }
    $req = @()
    if ($schema['required']) { $req = @($schema['required']) }
    $props = [ordered]@{}
    # 取键不能用 $src.Keys：参数名里若有 keys（log_query 就有），PowerShell 的 DictionaryAdapter
    # 会优先返回"键 keys 的值"而不是键名集合，遍历出来的元素就不是字符串了。GetEnumerator 才稳。
    $src = $schema['properties']
    if ($null -ne $src) {
        foreach ($e in $src.GetEnumerator()) {
            $k = [string]$e.Key
            $pp = $e.Value
            $o = [ordered]@{ type = [string]$pp['type'] }
            if ($k -eq 'action' -or ($req -contains $k)) { $o['description'] = [string]$pp['description'] }
            $props[$k] = $o
        }
    }
    $out = [ordered]@{ type = 'object'; properties = $props }
    if ($req.Count -gt 0) { $out['required'] = $req }
    return $out
}

# brief 模式下把工具定义压缩后再发给客户端；-Full 时原样返回
function Get-DefForClient($def) {
    if (-not $script:Brief) { return $def }
    return [ordered]@{
        name        = [string]$def['name']
        description = (Get-BriefDesc ([string]$def['description']))
        inputSchema = (Get-BriefSchema $def['inputSchema'])
    }
}

# 工具挂载状态快照：tool_admin 改过挂载后，服务端据此补发 tools/list_changed
function Get-ToolsSnapshot {
    $a = @(Get-ChildItem -LiteralPath $ToolsDir -File -Filter '*.tool.ps1' -ErrorAction SilentlyContinue | Sort-Object -Property Name | ForEach-Object { $_.Name })
    $b = @(Get-ChildItem -LiteralPath $DisabledDir -File -Filter '*.tool.ps1' -ErrorAction SilentlyContinue | Sort-Object -Property Name | ForEach-Object { 'off:' + $_.Name })
    return ((@($a) + @($b)) -join '|')
}

# 内建工具定义（顺序即工具列表里的顺序）
function Get-BuiltinToolDefinitions {
    return , @(
        [ordered]@{
            name        = 'search_local'
            description = '在本地资料目录中做全文检索（大小写不敏感），返回命中的文件相对路径、行号与行内容。数据源是本地资料目录（默认：本脚本上一级目录），不联网。'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    query        = [ordered]@{ type = 'string'; description = '要检索的关键词（按字面匹配，不按正则）' }
                    glob         = [ordered]@{ type = 'string'; description = '文件过滤，默认 *.md；可传 *.txt 等' }
                    maxResults   = [ordered]@{ type = 'integer'; description = '最多返回多少个命中文件，默认 20，上限 100' }
                    contextLines = [ordered]@{ type = 'integer'; description = '每条命中附带的前后行数，默认 0，上限 3' }
                }
                required   = @('query')
            }
        },
        [ordered]@{
            name        = 'read_local'
            description = '按路径读取本地资料目录中某个文件的全文（可分页），返回带行号的内容。路径相对于检索根目录，也可以是根目录内的绝对路径；越界路径会被拒绝。配合 search_local / list_local 使用：先搜到文件，再读全文。'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    path      = [ordered]@{ type = 'string'; description = '相对检索根目录的文件路径，如 mcp\README.md；正反斜杠均可' }
                    startLine = [ordered]@{ type = 'integer'; description = '从第几行开始读，默认 1' }
                    maxLines  = [ordered]@{ type = 'integer'; description = '本次最多读多少行，默认 200，上限 1000' }
                }
                required   = @('path')
            }
        },
        [ordered]@{
            name        = 'list_local'
            description = '列出本地资料目录的内容（文件名通配筛选 / 可递归 / 可按名称、大小、时间排序），返回相对路径、大小、修改时间。不知道确切文件名时先用它看目录结构。'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    dir        = [ordered]@{ type = 'string'; description = '相对检索根目录的目录，默认根目录本身' }
                    pattern    = [ordered]@{ type = 'string'; description = '文件名通配，默认 *（全部）' }
                    recursive  = [ordered]@{ type = 'boolean'; description = '是否包含子目录，默认 false' }
                    sortBy     = [ordered]@{ type = 'string'; description = '排序字段：name（默认，按路径）/ size（大在前）/ time（新在前）' }
                    maxResults = [ordered]@{ type = 'integer'; description = '最多返回多少个条目，默认 100，上限 500' }
                }
                required   = @()
            }
        }
    )
}

function Invoke-BuiltinTool([string]$name, $Arguments) {
    switch ($name) {
        'search_local' { return @{ text = (Invoke-SearchLocal $Arguments); isError = $false } }
        'read_local' { return @{ text = (Invoke-ReadLocal $Arguments); isError = $false } }
        'list_local' { return @{ text = (Invoke-ListLocal $Arguments); isError = $false } }
        default { return @{ text = ('未实现的内建工具: ' + $name); isError = $true } }
    }
}

# ============ 外部工具（tools\*.tool.ps1）============

# 读取单个工具脚本头部的 @mcp-tool 块；解析不出来就返回 $null（跳过，不让坏元数据污染 tools/list）
function Get-ExternalToolMeta([string]$file) {
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $file -Encoding UTF8) }
    catch { Write-Log ('读工具文件失败: ' + $file + ' -> ' + $_.Exception.Message); return $null }

    $inBlock = $false
    $name = ''; $desc = ''; $paramJson = ''; $timeout = 120
    foreach ($ln in $lines) {
        $t = $ln.Trim()
        if ($t -eq '# @mcp-tool') { $inBlock = $true; continue }
        if ($t -eq '# @mcp-tool-end') { break }
        if (-not $inBlock) { continue }
        if ($t -match '^#\s*name\s*:\s*(.+)$') { $name = $Matches[1].Trim() }
        elseif ($t -match '^#\s*description\s*:\s*(.+)$') { $desc = $Matches[1].Trim() }
        elseif ($t -match '^#\s*params\s*:\s*(.+)$') { $paramJson = $Matches[1].Trim() }
        elseif ($t -match '^#\s*timeout\s*:\s*(\d+)\s*$') { $timeout = [int]$Matches[1] }
    }

    if ([string]::IsNullOrWhiteSpace($name)) { Write-Log ('跳过外部工具（缺 name）: ' + (Split-Path $file -Leaf)); return $null }
    if ($name -notmatch '^[A-Za-z0-9_-]{1,64}$') { Write-Log ('跳过外部工具（name 非法 "' + $name + '"）: ' + (Split-Path $file -Leaf)); return $null }
    if ([string]::IsNullOrWhiteSpace($desc)) { Write-Log ('跳过外部工具（缺 description，AI 无法据此选择工具）: ' + $name); return $null }
    if ($timeout -lt 5) { $timeout = 5 } elseif ($timeout -gt 3600) { $timeout = 3600 }

    # 关键修复点：params 必须是 JSON 数组，逐项解析；解析失败就当作"无参数"，绝不退化成字符串拼接
    $paramList = @()
    if (-not [string]::IsNullOrWhiteSpace($paramJson)) {
        try {
            $parsed = $paramJson | ConvertFrom-Json
            if ($null -ne $parsed) { $paramList = @($parsed) }
        }
        catch {
            Write-Log ('外部工具 ' + $name + ' 的 # params: 不是合法 JSON，已按"无参数"处理 -> ' + $_.Exception.Message)
            $paramList = @()
        }
    }

    return [ordered]@{
        name        = $name
        description = $desc
        paramList   = $paramList
        timeout     = $timeout
        file        = $file
    }
}

# 由参数数组生成 inputSchema —— 目标：任何输入都只能产出合法 JSON Schema
function New-InputSchema($paramList) {
    $allowed = @('string', 'integer', 'number', 'boolean', 'object', 'array')
    $props = [ordered]@{}
    $req = New-Object System.Collections.Generic.List[string]

    foreach ($p in @($paramList)) {
        if ($null -eq $p) { continue }

        $n = ''
        try { $n = [string]$p.name } catch { }
        $n = $n.Trim()
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        if ($n -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            Write-Log ('丢弃非法参数名（只能是字母/数字/下划线，且不以数字开头）: "' + $n + '"')
            continue
        }

        $t = ''
        try { $t = [string]$p.type } catch { }
        $t = $t.Trim().ToLowerInvariant()
        if ($allowed -notcontains $t) {
            if (-not [string]::IsNullOrWhiteSpace($t)) { Write-Log ('参数 ' + $n + ' 的 type 非法（"' + $t + '"），已降级为 string') }
            $t = 'string'
        }

        $d = ''
        try { $d = [string]$p.description } catch { }
        if ([string]::IsNullOrWhiteSpace($d)) { $d = $n }

        $props[$n] = [ordered]@{ type = $t; description = $d }

        $isReq = $false
        try { $isReq = [bool]$p.required } catch { }
        if ($isReq) { [void]$req.Add($n) }
    }

    $schema = [ordered]@{ type = 'object'; properties = $props }
    # 无必填参数时整个省略 required —— PS 5.1 把空数组序列化成 "" 同样过不了客户端校验
    if ($req.Count -gt 0) { $schema['required'] = $req.ToArray() }
    return $schema
}

# 扫描 tools 目录，刷新 $script:ExternalTools
function Update-ExternalTools {
    $map = @{}
    if (Test-Path -LiteralPath $ToolsDir) {
        $files = @(Get-ChildItem -LiteralPath $ToolsDir -File -Filter '*.tool.ps1' -ErrorAction SilentlyContinue | Sort-Object -Property Name)
        foreach ($f in $files) {
            $meta = Get-ExternalToolMeta $f.FullName
            if ($null -eq $meta) { continue }
            if ($map.ContainsKey($meta.name)) {
                Write-Log ('外部工具重名，忽略后者: ' + $meta.name + ' <- ' + (Split-Path $meta.file -Leaf))
                continue
            }
            $map[$meta.name] = $meta
        }
    }
    $script:ExternalTools = $map
}

function Get-AllToolDefinitions {
    $defs = New-Object System.Collections.Generic.List[object]
    # 注意：函数返回数组时不要写 @(函数名) —— 那会把整个数组再包一层，序列化出嵌套数组，
    # 客户端校验 tools[].name 时就会拿到 "a b c" 这种拼接串。先赋值给变量再 foreach 才对。
    $builtins = Get-BuiltinToolDefinitions
    foreach ($d in $builtins) { [void]$defs.Add((Get-DefForClient $d)) }
    Update-ExternalTools
    foreach ($k in @($script:ExternalTools.Keys | Sort-Object)) {
        $m = $script:ExternalTools[$k]
        [void]$defs.Add((Get-DefForClient ([ordered]@{
                        name        = $m.name
                        description = $m.description
                        inputSchema = (New-InputSchema $m.paramList)
                    })))
    }
    # ",@" 防单元素数组被解包（解包后 ConvertTo-Json 会把 tools 写成 {} 而不是 [{}]）
    return , $defs.ToArray()
}

function Get-ToolNames {
    $names = @('search_local', 'read_local', 'list_local')
    $names += @($script:ExternalTools.Keys | Sort-Object)
    return $names
}

# 外部工具：参数以 JSON 经 stdin 传入，stdout 作为结果，退出码非 0 视为失败
function Invoke-ExternalTool($meta, $Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $meta.file)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    try { $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

    $payload = '{}'
    if ($null -ne $Arguments) { $payload = ($Arguments | ConvertTo-Json -Depth 20 -Compress) }

    Write-Log ('external tool: ' + $meta.name + ' -> ' + (Split-Path $meta.file -Leaf) + ' (timeout=' + $meta.timeout + 's)')

    $p = [System.Diagnostics.Process]::Start($psi)
    $taskOut = $p.StandardOutput.ReadToEndAsync()
    $taskErr = $p.StandardError.ReadToEndAsync()

    # stdin 直接写 UTF-8 字节：走 StandardInput 会按代码页 936 编码，中文参数会变乱码
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.BaseStream.Flush()
    $p.StandardInput.Close()

    if (-not $p.WaitForExit($meta.timeout * 1000)) {
        try { $p.Kill() } catch { }
        Write-Log ('外部工具超时: ' + $meta.name)
        return @{ text = ('外部工具 ' + $meta.name + ' 执行超时（' + $meta.timeout + 's）已强制终止'); isError = $true }
    }

    $stdout = ''; $stderr = ''
    try { $stdout = [string]$taskOut.Result } catch { }
    try { $stderr = [string]$taskErr.Result } catch { }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($stdout)
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('--- 工具 stderr ---')
        [void]$sb.Append($stderr)
    }
    $ok = ($p.ExitCode -eq 0)
    if (-not $ok) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('外部工具退出码 {0}（非 0 视为失败）' -f $p.ExitCode))
    }
    return @{ text = $sb.ToString().TrimEnd(); isError = (-not $ok) }
}

# ---- 环境自愈（2026-09-29 踩坑，见 mcp\工具集规范.md 坑 18）----
# IDE（Copilot 插件）拉起本服务时，会把 PATHEXT 覆写成 ".CPL" 并清空 ComSpec。
# 后果：子进程里 PowerShell 认为 .exe 是"文档"（& xxx.exe 报 CantActivateDocumentInPipeline），
#       且解析不到 chcp / cmd / where 等原生命令（找不到 .COM / .EXE）。
# 对策：启动时从注册表取系统标准值补回。外部工具子进程用 ProcessStartInfo 继承本进程环境，
#       故在这里修一次即可覆盖全部工具。
function Repair-EnvVars {
    $fixed = @()
    $machineEnv = @{}
    try {
        $props = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction Stop
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -notlike 'PS*') { $machineEnv[$p.Name] = [string]$p.Value }
        }
    } catch { }

    # 1) PATHEXT 必须含 .EXE，否则 & <xxx>.exe 会被当成"文档"而拒绝执行
    if (([string]$env:PATHEXT) -notmatch '\.EXE') {
        if ($machineEnv.ContainsKey('PATHEXT')) { $env:PATHEXT = $machineEnv['PATHEXT'] }
        else { $env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC' }
        $fixed += ('PATHEXT=' + $env:PATHEXT)
    }
    # 2) ComSpec 缺失会让 cmd.exe 及相关调用异常
    if ([string]::IsNullOrWhiteSpace($env:ComSpec)) {
        if ($machineEnv.ContainsKey('ComSpec')) { $env:ComSpec = $machineEnv['ComSpec'] }
        else { $env:ComSpec = (Join-Path $env:SystemRoot 'system32\cmd.exe') }
        $fixed += ('ComSpec=' + $env:ComSpec)
    }
    # 3) TEMP/TMP 缺失会让 Java 等运行时起不来
    foreach ($n in @('TEMP', 'TMP')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($n))) {
            $v = [string]$env:TEMP
            if ($machineEnv.ContainsKey($n)) { $v = $machineEnv[$n] }
            if (-not [string]::IsNullOrWhiteSpace($v)) {
                [Environment]::SetEnvironmentVariable($n, $v)
                $fixed += ($n + '=' + $v)
            }
        }
    }
    # 4) PATH 兜底：必须含 System32，否则原生命令全找不到
    $sys32 = Join-Path $env:SystemRoot 'system32'
    if (([string]$env:PATH) -notmatch [regex]::Escape($sys32)) {
        $env:PATH = $sys32 + ';' + $env:PATH
        $fixed += ('PATH+=' + $sys32)
    }
    return $fixed
}

$envFixed = Repair-EnvVars
if (@($envFixed).Count -gt 0) { Write-Log ('环境自愈(IDE 覆写了 PATHEXT/ComSpec): ' + (@($envFixed) -join '; ')) }

# ============ 主循环 ============
Write-Log ('kb-local-mcp started. version=0.8.5 root=' + $Root)
Write-Log ('tools dir = ' + $ToolsDir)
Update-ExternalTools
Write-Log ('外部工具已加载: ' + (@($script:ExternalTools.Keys | Sort-Object) -join ', '))
$script:ToolsSnapshot = Get-ToolsSnapshot
Write-Log ('描述模式 = ' + $(if ($Brief) { 'brief（精简）' } else { 'full（完整）' }) + '；挂载快照 = ' + $script:ToolsSnapshot)
$initialized = $false

while ($true) {
    $line = $null
    try { $line = $stdinReader.ReadLine() } catch { break }
    if ($null -eq $line) { break }          # 客户端关闭 stdin -> 退出
    $line = $line.Trim()
    if ($line -eq '') { continue }

    $msg = $null
    try { $msg = $line | ConvertFrom-Json } catch { Write-Log ('忽略非法 JSON: ' + $line); continue }
    if ($null -eq $msg) { continue }

    $method = [string]$msg.method
    $hasId = $null -ne $msg.id
    $id = $msg.id

    try {
        switch ($method) {
            'initialize' {
                Write-Log ('initialize from ' + [string]$msg.params.clientInfo.name)
                Send-Result $id ([ordered]@{
                        protocolVersion = '2024-11-05'
                        capabilities    = [ordered]@{ tools = [ordered]@{} }
                        serverInfo      = [ordered]@{ name = 'kb-local'; version = '0.8.5' }
                    })
                break
            }
            'notifications/initialized' {
                $initialized = $true
                Write-Log 'notifications/initialized'
                break   # 通知类消息：不回复
            }
            'ping' {
                if ($hasId) { Send-Result $id ([ordered]@{}) }
                break
            }
            'tools/list' {
                $defs = Get-AllToolDefinitions
                $payload = [ordered]@{ tools = $defs }
                $bytes = 0
                try { $bytes = [Text.Encoding]::UTF8.GetByteCount(($payload | ConvertTo-Json -Depth 30 -Compress)) } catch { }
                Write-Log ('tools/list -> ' + $defs.Count + ' tools, ' + $bytes + ' bytes')
                Send-Result $id $payload
                break
            }
            'tools/call' {
                $name = [string]$msg.params.name
                $arguments = $msg.params.arguments
                try {
                    if (@('search_local', 'read_local', 'list_local') -contains $name) {
                        $r = Invoke-BuiltinTool $name $arguments
                    }
                    elseif ($script:ExternalTools.ContainsKey($name)) {
                        $r = Invoke-ExternalTool $script:ExternalTools[$name] $arguments
                    }
                    else {
                        Send-ToolText $id ('未知工具: ' + $name + "`n可用工具: " + ((Get-ToolNames) -join ', ')) $true
                        break
                    }
                    Write-Log ('tool-call: ' + $name + ' ok=' + (-not [bool]$r.isError))
                    Send-ToolText $id ([string]$r.text) ([bool]$r.isError)
                    # tool_admin / call-tool 可能刚改过 tools\ 挂载：比对快照，有变化就通知客户端重拉
                    try {
                        $snapNow = Get-ToolsSnapshot
                        if ($snapNow -ne [string]$script:ToolsSnapshot) {
                            $script:ToolsSnapshot = $snapNow
                            Update-ExternalTools
                            Send-Message ([ordered]@{ jsonrpc = '2.0'; method = 'notifications/tools/list_changed' })
                            Write-Log '已补发 notifications/tools/list_changed（工具目录发生变化）'
                        }
                    }
                    catch { Write-Log ('挂载快照刷新失败: ' + $_.Exception.Message) }
                }
                catch {
                    Write-Log ('工具执行异常: ' + $_.Exception.Message)
                    Send-ToolText $id ('执行失败: ' + $_.Exception.Message) $true
                }
                break
            }
            default {
                # 通知类（无 id）静默忽略；请求类回 -32601
                if ($hasId) { Send-Error $id -32601 ('未实现的方法: ' + $method) }
                break
            }
        }
    }
    catch {
        Write-Log ('处理消息异常: ' + $_.Exception.Message)
        if ($hasId) { Send-Error $id -32603 $_.Exception.Message }
    }
}

Write-Log 'kb-local-mcp exited (stdin closed)'

