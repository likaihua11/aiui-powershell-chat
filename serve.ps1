<#
  aiui backend - minimal, zero-dependency local server.
  Endpoints:
    GET  /<file>      -> static file from this folder (html/css/js/json/svg/png/ico)
    GET  /api/health  -> {"ok":true,...}
    GET  /api/models  -> proxy {endpoint}/models  (query: endpoint, apiKey)
    POST /api/chat    -> proxy {endpoint}/chat/completions (streaming SSE, pass-through)
    GET  /api/skills  -> list skills in ./skills (frontmatter: name/description)
GET  /api/sync    -> two-client sync: per-key revisions (file ticks+length) + per-session turn lock
    POST /api/shutdown-> graceful stop, loopback only: releases the http.sys registration before
                         exiting. Use this instead of Stop-Process -Force (see update.ps1).

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File serve.ps1 [-Port 8787] [-Open] [-Lan]
    powershell -NoProfile -ExecutionPolicy Bypass -File serve.ps1 [-Port 8787] -Check
           -Check : 探针模式。只回答「这个端口上真的是 aiui 后端吗」，不启动监听，
                    退出码 0 = 在跑、1 = 没在跑。供 start.bat 等脚本判断，避免误判。
#>
[CmdletBinding()]
param(
  [int]$Port = 8787,
  [switch]$Open,
[switch]$Lan,
[switch]$Check
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http | Out-Null

# 探针模式：只回答「这个端口上真的是 aiui 后端吗」，不启动监听，退出码 0=在跑 / 1=没在跑。
# 为什么必须有它：netstat 里的 LISTENING（PID 4）是 http.sys 内核端点，只代表端口「有注册」，
# 不代表后端活着 —— 旧后端进程被杀/卡死而没释放注册时，端口照样 LISTENING、TCP 照样连得上，
# 但请求一律 503，且新后端再也绑不上（「与现有注册冲突」）。
# 只看端口/TCP 必然误判成「已在运行」，于是 start.bat 直接开浏览器 → 503 白屏。
if ($Check) {
  $probe = New-Object System.Net.Http.HttpClient
  $probe.Timeout = [TimeSpan]::FromSeconds(4)
  $rc = 1
  try {
    $pr = $probe.GetAsync("http://127.0.0.1:$Port/api/health").GetAwaiter().GetResult()
    if ($pr.IsSuccessStatusCode) {
      $pt = $pr.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      if ($pt -match '"name"\s*:\s*"aiui"') { $rc = 0 }   # 认身份，不认端口
    }
    # 非 2xx（含 http.sys 的 503）一律视为「没在跑」，$rc 保持 1
  } catch {
    $ex = $_.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    # 超时 = 连上了但没及时回：后端在串行处理流式响应，算「在跑」；连接被拒等才是真没在跑
    if ($ex -is [System.Threading.Tasks.TaskCanceledException] -or $ex -is [System.OperationCanceledException] -or $ex -is [System.TimeoutException]) { $rc = 0 }
  }
  try { $probe.Dispose() } catch { }
  exit $rc
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RootDir = Split-Path -Parent $scriptDir   # 工作区根（自定位，可移植）：<root>\aiui -> <root>
$script:MemDir = Join-Path $script:RootDir 'jiyi'

$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromMinutes(15)

$listener = New-Object System.Net.HttpListener
# 逐个试绑来挑可用前缀：http.sys 的 urlacl 决定本用户能注册哪些前缀，而单个 HttpListener 里
# 只要有一个前缀绑不上，整个 Start() 就失败。本机踩到的坑：存在 http://+:<Port>/ 预留
# （lan-setup.bat 建的）时，非管理员下具体主机名 127.0.0.1 / localhost 反而被判「拒绝访问」，
# 只有 + 能绑。
$candidates = @("http://127.0.0.1:$Port/", "http://localhost:$Port/", "http://+:$Port/")
$usable = New-Object System.Collections.ArrayList
foreach ($p in $candidates) {
  $probe = New-Object System.Net.HttpListener

  $probe.Prefixes.Add($p)
  try { $probe.Start(); $probe.Stop(); $probe.Close(); [void]$usable.Add($p) }
  catch {
    Write-Host ('  prefix unavailable: ' + $p + ' -> ' + $_.Exception.Message) -ForegroundColor DarkYellow
    try { $probe.Close() } catch { }
  }
}

# + 能用就只用 +：它已覆盖 127.0.0.1 / localhost，也免得把 + 与具体主机名混在同一个 listener 里绑
$lanWide = $usable.Contains("http://+:$Port/")
$usePrefixes = New-Object System.Collections.ArrayList
if ($lanWide) { [void]$usePrefixes.Add("http://+:$Port/") }
else { foreach ($p in $usable) { [void]$usePrefixes.Add($p) } }

if ($usePrefixes.Count -eq 0) {
  Write-Host '  [x] 没有任何可用监听前缀，serve.ps1 无法启动。' -ForegroundColor Red
  Write-Host ('      排查：netsh http show urlacl | findstr /i "' + $Port + '"') -ForegroundColor Gray
  Write-Host '      若已有 http://+:<Port>/ 预留却仍被拒，请以管理员身份重跑 aiui\lan-setup.bat 重新授权。' -ForegroundColor Gray
  exit 1
}
if ($lanWide -and -not $Lan) {
  Write-Host '  [!] 回环前缀被 urlacl 拒绝，已退回 http://+ 监听：同网络任何人都能访问，且无鉴权。' -ForegroundColor Yellow
  Write-Host ('      只想本机用，请以管理员执行：netsh http delete urlacl url=http://+:' + $Port + '/') -ForegroundColor DarkGray
}

foreach ($p in $usePrefixes) { $listener.Prefixes.Add($p) }
try { $listener.Start() } catch {
  Write-Host ('  [x] listener start failed: ' + $_.Exception.Message) -ForegroundColor Red
  # 落到这里多半是端口在 http.sys 里被残留注册占着：
# 旧后端被 Stop-Process -Force 强杀、或直接在控制台里 Ctrl+C，都会跳过 finally 的 Stop/Close，
# 于是 http://127.0.0.1:<Port>/ 与 http://localhost:<Port>/ 的注册一直挂在那个（可能已无响应的）
# 进程名下不释放 —— 表现是端口「LISTENING」、TCP 也连得上，但请求一律 503，而新进程永远绑不上。
  Write-Host '  [i] 若提示「与现有注册冲突」，多半是 http.sys 里残留了旧注册，排查：' -ForegroundColor Yellow
  Write-Host ('      netsh http show servicestate | findstr /i "' + $Port + '"') -ForegroundColor Gray
  Write-Host '      看哪个 PID 注册了它；若该 PID 是已无响应的旧 powershell，结束该进程即可（需管理员）。' -ForegroundColor Gray
  throw
}

function Add-Cors($ctx) {
  $h = $ctx.Response.Headers
  $h['Access-Control-Allow-Origin'] = '*'
  $h['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
  $h['Access-Control-Allow-Headers'] = 'Content-Type, Authorization, X-Aiui-Client'
}

function Send-Bytes($ctx, [int]$status, [string]$ctype, [byte[]]$bytes) {
  $ctx.Response.StatusCode = $status
  $ctx.Response.ContentType = $ctype
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.OutputStream.Close()
}

# ---- 传输优化（2026-10-01）：响应体按需 gzip ----
# 背景：index.html 110 KB 明文全量下发；/api/memory 取一份会话最多 14 MB。
# 手机端每次刷新/同步都要跑满这一趟，是「手机慢」的主因之一。
# 统一在出口压缩：客户端 Accept-Encoding 带 gzip 且体积划算才压，任何异常退回明文。
function Send-Data($ctx, [int]$status, [string]$ctype, [byte[]]$bytes) {
if ($bytes.Length -ge 1024) {
$ae = [string]$ctx.Request.Headers['Accept-Encoding']
$skip = ($ctype -match '^(image/(png|jpeg|gif|webp|ico)|video/|audio/|application/zip)')
if ((-not $skip) -and ($ae -match 'gzip')) {
try {
$ms = New-Object System.IO.MemoryStream
$gzs = New-Object System.IO.Compression.GZipStream -ArgumentList @($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
$gzs.Write($bytes, 0, $bytes.Length)
$gzs.Dispose()
$gz = $ms.ToArray()
$ms.Dispose()
if ($gz.Length -lt $bytes.Length) {
$ctx.Response.Headers['Content-Encoding'] = 'gzip'
$ctx.Response.Headers['Vary'] = 'Accept-Encoding'
Send-Bytes $ctx $status $ctype $gz
return
}
} catch { }
}
}
Send-Bytes $ctx $status $ctype $bytes
}

# ---- 静态资源：gzip + ETag/304 + 单文件缓存 ----
# 原来静态页是 no-store：每次刷新整份重下。改成 no-cache + ETag 后，浏览器每次
# 只带 If-None-Match 问一句：文件没变回 304（0 字节），变了立刻拿到新版（不会拿到旧缓存）。
function Send-Static($ctx, [string]$full, [string]$ctype) {
$si = Get-Item $full -ErrorAction SilentlyContinue
if ($null -eq $si) { Send-Data $ctx 200 $ctype ([IO.File]::ReadAllBytes($full)); return }
$mtime = $si.LastWriteTimeUtc.Ticks
$etag = '"' + ([string]$mtime) + '-' + ([string]$si.Length) + '"'
$ctx.Response.Headers['ETag'] = $etag
$ctx.Response.Headers['Vary'] = 'Accept-Encoding'
$inm = [string]$ctx.Request.Headers['If-None-Match']
if ($inm -and ($inm -eq $etag)) { $ctx.Response.StatusCode = 304; $ctx.Response.OutputStream.Close(); return }
if ($null -eq $script:StaticCache) { $script:StaticCache = @{} }
$c = $script:StaticCache[$full]
if (($null -eq $c) -or ($c.mtime -ne $mtime)) {
$c = @{ mtime = $mtime; raw = [IO.File]::ReadAllBytes($full) }
$script:StaticCache[$full] = $c
if ($script:StaticCache.Count -gt 32) { $script:StaticCache = @{ $full = $c } }
}
Send-Data $ctx 200 $ctype $c.raw
}

function Send-Json($ctx, [int]$status, $obj) {
  $json = $obj | ConvertTo-Json -Depth 12 -Compress
  Send-Data $ctx $status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Read-BodyText($ctx) {
  $sr = New-Object System.IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
  $txt = $sr.ReadToEnd()
  $sr.Close()
  return $txt
}

function Get-ErrText($ex) {
  $cur = $ex
  while ($null -ne $cur.InnerException) { $cur = $cur.InnerException }
  if ($cur.Message) { return $cur.Message }
  return $ex.Message
}

# ---- 客户端来源识别：手机 / 平板发起的轮次不能用本机弹窗（那个窗口开在电脑屏幕上，
# 手机用户根本看不到，只会把工具调用挂到超时）。服务端在 /api/mcp/call 里把判定结果
# 写进 AIUI_CLIENT 环境变量，MCP 工具子进程会继承它（ProcessStartInfo 默认继承）。
function Get-ClientKind($ctx) {
  $h = ''
  try { $h = [string]$ctx.Request.Headers['X-Aiui-Client'] } catch { $h = '' }
  if ($h -eq 'mobile' -or $h -eq 'desktop') { return $h }
  $ua = ''
  try { $ua = [string]$ctx.Request.UserAgent } catch { $ua = '' }
  if ($ua -match '(?i)Android|iPhone|iPad|iPod|HarmonyOS|Windows Phone|Mobile') { return 'mobile' }
  return 'desktop'
}

# ============ 技能（Skills）：本地 ./skills/*.md，frontmatter: name/description ============
$script:SkillsDir = Join-Path $scriptDir 'skills'

function Get-SkillFiles {
  if (-not (Test-Path -LiteralPath $script:SkillsDir)) { return @() }
  return @(Get-ChildItem -LiteralPath $script:SkillsDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
Where-Object { $_.Name -ne 'README.md' -and ([IO.File]::ReadAllText($_.FullName) -match '^\s*---\s*\r?\n') } |
Sort-Object Name)
}

function ConvertFrom-SkillFile([string]$path) {
  $raw = [IO.File]::ReadAllText($path)
  $name = ''; $desc = ''; $brief = ''; $body = $raw
  $m = [regex]::Match($raw, '^\s*---\s*\r?\n(.*?)\r?\n---\s*(\r?\n)?', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if ($m.Success) {
    foreach ($ln in ($m.Groups[1].Value -split "\r?\n")) {
      if ($ln -match '^\s*name\s*:\s*(.+?)\s*$') { $name = $Matches[1].Trim() }
      elseif ($ln -match '^\s*description\s*:\s*(.+?)\s*$') { $desc = $Matches[1].Trim() } elseif ($ln -match '^\s*brief\s*:\s*(.+?)\s*$') { $brief = $Matches[1].Trim() }
    }
    $body = $raw.Substring($m.Length)
  }
  if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($path) }
  [pscustomobject]@{ id = [IO.Path]::GetFileNameWithoutExtension($path); name = $name; description = $desc; brief = $brief; body = $body.Trim() }
}

function Get-SkillsCatalog {
  $out = New-Object System.Collections.ArrayList
  foreach ($f in Get-SkillFiles) {
    try { $s = ConvertFrom-SkillFile $f.FullName; [void]$out.Add([ordered]@{ id = $s.id; name = $s.name; description = $s.description; bytes = $f.Length }) } catch { }
  }
  return ,$out
}

function Read-SkillBody([string]$id, [string]$dir) {
  if ($id -notmatch '^[A-Za-z0-9_-]{1,64}$') { return $null }
if (-not $dir) { $dir = $script:SkillsDir }
$p = Join-Path $dir ($id + '.md')
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
  return (ConvertFrom-SkillFile $p)
}

function Build-SkillBlock($p, [string]$mode = 'brief', [string]$dir = '') {
  $ids = @($p.skills)
  $sb = New-Object System.Text.StringBuilder
  $any = $false
  foreach ($id in $ids) {
    if ($null -eq $id -or ([string]$id).Trim() -eq '') { continue }
$s = Read-SkillBody ([string]$id) $dir
    if ($null -eq $s) { continue }
    if (-not $any) { [void]$sb.Append('【已启用技能】本轮启用的技能（强制约定，必须严格遵守；细节用 read_local 读 <技能目录>\<id>.md）：'); $limit = 6000; $any = $true }
    if ($sb.Length -gt $limit) { [void]$sb.Append("`n[skills block truncated: over " + $limit + " chars]"); break }
    if ($mode -eq 'names') { [void]$sb.Append("`n- " + $s.name); continue }
    $b = $s.body; if ($s.brief) { $b = $s.brief }; [void]$sb.Append("`n- " + $s.name + ": " + $b)
  }
  if (-not $any) { return '' }
  return $sb.ToString()
}

# ============ 长期记忆：jiyi\memory.md（人工可编辑，每次对话注入 system） ============
$script:MemoryFile = Join-Path $script:MemDir 'memory.md'

# ---- 上下文省略标记（2026-10-01，抄自 Hermes agent/compression_marker.py 的设计）：
# 这段文字会落进模型自己续写的上下文里，所以它不能读起来像模型自己会写的东西：
# 裸的 "...[truncated]" 会被模型模仿进新的输出并写到磁盘（Hermes 注释 #83714 实测）。
# 故改用非散文定界符 + 显式「非原文」免责声明 + 每次实例化的真实计数
# （计数让逐字照抄立刻显旧，所以此标记永不被二次套用）。
# 注意：函数体必须自包含 —— worker runspace 里取不到 $script: 变量，故字符就地构造。
function New-ElideMarker([int]$omitted, [int]$total) {
$op = [char]0x27EA
$cl = [char]0x27EB
$o = $omitted.ToString('N0')
$tt = $total.ToString('N0')
$s = 'AIUI-CTX-ELIDE: ' + $o + ' of ' + $tt + ' chars omitted by aiui context budget. '
$s = $s + 'This is NOT part of the original content and must never be reproduced in new output; always write full, untruncated content.'
return ([string]$op + $s + [string]$cl)
}

# 头尾保留：只省略中段。头（环境事实/约定）与尾（最新追加的教训）都保住 ——
# learn-commit.ps1 是追加语义，原来的 Substring(0,limit) 砍掉的正是最该留的尾部。
function Elide-Middle([string]$text, [int]$head, [int]$tail) {
if ($null -eq $text) { return '' }
if ($head -lt 0) { $head = 0 }
if ($tail -lt 0) { $tail = 0 }
if ($text.Length -le ($head + $tail)) { return $text }
return $text.Substring(0, $head) + (New-ElideMarker ($text.Length - $head - $tail) $text.Length) + $text.Substring($text.Length - $tail, $tail)
}

function Build-MemoryBlock([string]$file = '') {
if (-not $file) { $file = $script:MemoryFile }
if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
$raw = ''
try { $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) } catch { return '' }
$raw = $raw.Trim()
if (-not $raw) { return '' }
$limit = 8192
$head = 6000
$tail = 1700
$used = $raw.Length
$pct = [int][Math]::Round(($used * 100.0) / $limit)
$body = $raw
if ($used -gt ($head + $tail)) { $body = Elide-Middle $raw $head $tail }
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('【长期记忆】[已用 ' + $used.ToString('N0') + '/' + $limit + ' 字符，' + $pct + '%] 以下是我跨会话沉淀的事实、偏好与踩过的坑，优先遵循，不要重复已被否决的做法：')
[void]$sb.Append("`n" + $body)
return $sb.ToString()
}

# ---- /api/chat 代理：封成函数，好放进 runspace 池并发跑（不阻塞其它请求）。
# 入参 dir / memFile 显式传入：worker runspace 里取不到脚本作用域的
# $script:SkillsDir / $script:MemoryFile，技能块与记忆块必须走参数。
function Invoke-ChatProxy($ctx, $http, [string]$dir, [string]$memFile) {
$method = $ctx.Request.HttpMethod
        if ($method -ne 'POST') { Send-Json $ctx 405 @{ ok = $false; error = 'POST required' }; continue }
        $body = Read-BodyText $ctx
        if (-not $body) { Send-Json $ctx 400 @{ ok = $false; error = 'empty body' }; continue }
        $p = $body | ConvertFrom-Json
        if (-not $p.endpoint -or -not $p.model) { Send-Json $ctx 400 @{ ok = $false; error = 'endpoint and model required' }; continue }

        $msgs = @($p.messages)
        $sysParts = @()
        $skblock = Build-SkillBlock $p 'brief' $dir; $win = 0; if ($null -ne $p.num_ctx) { $win = [int]$p.num_ctx } elseif ($env:OLLAMA_CONTEXT_LENGTH) { try { $win = [int]$env:OLLAMA_CONTEXT_LENGTH } catch { $win = 0 } }; if ($win -gt 0 -and [string]$p.endpoint -match '(?i)127\.0\.0\.1|localhost') { $ch = ([string]$skblock).Length; foreach ($mm in @($p.messages)) { $ch += ([string]$mm.content).Length }; if ([int]($ch / 2) -gt [int]($win * 0.75)) { Write-Host ("[ctx] win=" + $win + " est=" + [int]($ch / 2) + " -> skills reduced to names"); $skblock = Build-SkillBlock $p 'names' $dir } }
        if ($skblock) { $sysParts += $skblock }
        $memblock = Build-MemoryBlock $memFile
        if ($memblock) { $sysParts += $memblock }
        # 来源端是手机/平板（或用户在设置里选了「总是文字」）时告诉模型：别调用 ask-choice ——
        # 那个窗口开在电脑屏幕上，本端根本看不到；直接把选项写在回复正文里，让用户用文字回答。
        if ((Get-ClientKind $ctx) -eq 'mobile') { $sysParts += "[客户端环境] 本轮来自手机/平板（或已设成文字模式），电脑屏幕上的弹窗本端看不到。需要用户拍板时：不要调用 ask-choice，直接把选项写在回复正文里（编号 + 名称 + value），一句话问清要哪个，然后结束本轮等用户用文字回答。如果你已经调用了，它会返回 skipped=true 和选项清单，照它的 hint 写成文字即可，不要重试。" }
        if ($sysParts.Count -gt 0) {
          $sysExtra = [string]::Join("`n`n", [string[]]$sysParts)
          if ($msgs.Count -gt 0 -and [string]$msgs[0].role -eq 'system') {
            $msgs[0].content = $sysExtra + "`n`n" + [string]$msgs[0].content
          } else {
            $msgs = @([pscustomobject]@{ role = 'system'; content = $sysExtra }) + $msgs
          }
        }
        $url = $p.endpoint.TrimEnd('/') + '/chat/completions'
        $payload = @{ model = $p.model; messages = $msgs; stream = $true }
        if ($null -ne $p.temperature) { $payload.temperature = [double]$p.temperature }
        if ($p.tools) { $payload.tools = $p.tools }
        if ($p.tool_choice) { $payload.tool_choice = $p.tool_choice }
        $json = $payload | ConvertTo-Json -Depth 12 -Compress

        $r = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $url)
        if ($p.apiKey) { $r.Headers.Add('Authorization', 'Bearer ' + $p.apiKey) }
        $r.Content = [System.Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')

        $resp = $null
        try {
          $resp = $http.SendAsync($r, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        } catch {
          $err = (Get-ErrText $_.Exception) -replace '"', "'"
          $m = 'data: {"error":"' + $err + '"}' + "`n`n"
          Send-Bytes $ctx 200 'text/event-stream; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($m))
          return
        }
        if ($null -eq $resp) {
          Send-Json $ctx 502 @{ ok = $false; error = 'upstream returned null response' }
          return
        }
        if (-not $resp.IsSuccessStatusCode) {
          $txt = ''
          try { $txt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { $txt = '' }
          if (-not $txt) { $txt = '{"error":"upstream error"}' }
          Send-Bytes $ctx ([int]$resp.StatusCode) 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($txt))
          return
        }

        $ctx.Response.StatusCode = 200
        $ctx.Response.ContentType = 'text/event-stream; charset=utf-8'
        $ctx.Response.Headers['Cache-Control'] = 'no-cache'
        $ctx.Response.SendChunked = $true
        $out = $ctx.Response.OutputStream
        try {
          $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
          $buf = New-Object byte[] 4096
          while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $out.Flush()
          }
          $in.Dispose()
        } catch {
          # client aborted or upstream broke mid-stream; nothing to send
        } finally {
          try { $out.Close() } catch { }
        }
        return
}
# ============ MCP 客户端（stdio + 云端 HTTP/SSE） ============
$script:McpUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:McpHttpSession = $null

function Mcp-SendLine($proc, $obj) {
  $json = $obj | ConvertTo-Json -Depth 30 -Compress
  $bytes = $script:McpUtf8.GetBytes($json + "`n")
  $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
  $proc.StandardInput.BaseStream.Flush()
}

# 逐行读取子进程 stdout：StreamReader.ReadLineAsync 在同一进程第二次调用会挂起，
# 且 StandardOutput 默认按系统代码页解码会破坏 UTF-8 中文；所以自行做 UTF-8 解码 + 行缓冲。
function Mcp-ReadLine($proc, $wantId, [int]$timeoutMs, $state) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
    $i = $state.text.IndexOf("`n")
    if ($i -ge 0) {
      $line = $state.text.Substring(0, $i)
      $state.text = $state.text.Substring($i + 1)
      $line = $line.Trim()
      if ($line -eq '') { continue }
      $m = $null
      try { $m = $line | ConvertFrom-Json } catch { continue }
      if ($null -ne $m -and $null -ne $m.id -and ([string]$m.id -eq [string]$wantId)) { return $m }
      continue
    }
    $buf = New-Object byte[] 8192
    $t = $proc.StandardOutput.BaseStream.ReadAsync($buf, 0, $buf.Length)
    $rem = $timeoutMs - [int]$sw.ElapsedMilliseconds
    if ($rem -le 0) { break }
    if (-not $t.Wait($rem)) { throw 'MCP 响应超时' }
    $n = $t.Result
    if ($n -le 0) { throw 'MCP 进程输出已关闭' }
    $state.text += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
  }
  throw 'MCP 等待响应超时'
}

function Invoke-McpStdio($server, [string]$method, $params, [int]$timeoutMs, [string]$clientKind) {
  $cmd = [string]$server.command
  if (-not $cmd) { throw '本地 MCP 缺少 command' }
  $argList = @()
  if ($server.args) {
    if ($server.args -is [System.Array]) { $argList = @($server.args) }
    else { $argList = @(([string]$server.args -split '\s+') | Where-Object { $_ -ne '' }) }
  }
  # path placeholder: ${ROOT} -> workspace root (self-located), keeps MCP config portable
if ($argList.Count -gt 0) { $argList = @($argList | ForEach-Object { ([string]$_).Replace('${ROOT}', [string]$script:RootDir) }) }
$psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $cmd
  $quoted = @()
  foreach ($a in $argList) {
    if ([string]$a -match '\s') { $quoted += ('"' + ([string]$a) + '"') } else { $quoted += [string]$a }
  }
  $psi.Arguments = ($quoted -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  # AIUI_CLIENT 是进程级环境变量：并发时两端会互相踩，所以用一个静态门闩把
  # 「设值 → 启动 → 还原」圈成临界区（只占启动那一瞬，开销可忽略）。
  if ($clientKind) {
    $gate = [System.AppDomain]::CurrentDomain.GetData('aiui.envgate')
    if ($null -eq $gate) { $gate = New-Object object; [System.AppDomain]::CurrentDomain.SetData('aiui.envgate', $gate) }
    [System.Threading.Monitor]::Enter($gate)
    try {
      $ckOld = [string]$env:AIUI_CLIENT
      $env:AIUI_CLIENT = $clientKind
      [void]$p.Start()
      $env:AIUI_CLIENT = $ckOld
    } finally { [System.Threading.Monitor]::Exit($gate) }
  } else {
    [void]$p.Start()
  }
  $errTask = $p.StandardError.ReadToEndAsync()
  $state = @{ text = '' }
  try {
    Mcp-SendLine $p ([ordered]@{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = [ordered]@{ protocolVersion = '2024-11-05'; capabilities = [ordered]@{}; clientInfo = [ordered]@{ name = 'aiui'; version = '0.1' } } })
    $init = Mcp-ReadLine $p 1 $timeoutMs $state
    if ($init.error) { throw ('MCP initialize 失败: ' + [string]$init.error.message) }
    Mcp-SendLine $p ([ordered]@{ jsonrpc = '2.0'; method = 'notifications/initialized' })
    Mcp-SendLine $p ([ordered]@{ jsonrpc = '2.0'; id = 2; method = $method; params = $params })
    $resp = Mcp-ReadLine $p 2 $timeoutMs $state
    if ($resp.error) { throw ('MCP 错误: ' + [string]$resp.error.message) }
    return $resp.result
  }
  finally {
    try { $p.StandardInput.Close() } catch { }
    try { if (-not $p.WaitForExit(1500)) { $p.Kill() } } catch { }
    try { [void]$errTask } catch { }
  }
}

function Mcp-HttpPost($client, $server, $obj) {
  $json = $obj | ConvertTo-Json -Depth 30 -Compress
  $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, [string]$server.url)
  $req.Content = [System.Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
  [void]$req.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream')
  if ($script:McpHttpSession) { [void]$req.Headers.TryAddWithoutValidation('Mcp-Session-Id', $script:McpHttpSession) }
  if ($server.headers) {
    foreach ($ln in ([string]$server.headers -split "[\r\n;]+")) {
      if ($ln.Trim() -match '^\s*([^:]+):\s*(.+)$') { [void]$req.Headers.TryAddWithoutValidation($Matches[1].Trim(), $Matches[2].Trim()) }
    }
  }
  $resp = $client.SendAsync($req).GetAwaiter().GetResult()
  if (-not $script:McpHttpSession) {
    $hv = $null
    if ($resp.Headers.TryGetValues('Mcp-Session-Id', [ref]$hv)) { $script:McpHttpSession = @($hv)[0] }
  }
  $txt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  $media = ''
  try { $media = [string]$resp.Content.Headers.ContentType.MediaType } catch { }
  if ($media -like '*event-stream') {
    foreach ($l in ($txt -split "[\r\n]+")) {
      if ($l.StartsWith('data:')) {
        $d = $l.Substring(5).Trim()
        if ($d) { try { return ($d | ConvertFrom-Json) } catch { } }
      }
    }
    return $null
  }
  if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
  try { return ($txt | ConvertFrom-Json) } catch { return $null }
}

function Invoke-McpHttp($server, [string]$method, $params, [int]$timeoutMs) {
  if (-not [string]$server.url) { throw '云端 MCP 缺少 url' }
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromMilliseconds($timeoutMs)
  $script:McpHttpSession = $null
  try {
    $init = Mcp-HttpPost $client $server ([ordered]@{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = [ordered]@{ protocolVersion = '2024-11-05'; capabilities = [ordered]@{}; clientInfo = [ordered]@{ name = 'aiui'; version = '0.1' } } })
    if ($init -and $init.error) { throw ('MCP initialize 失败: ' + [string]$init.error.message) }
    [void](Mcp-HttpPost $client $server ([ordered]@{ jsonrpc = '2.0'; method = 'notifications/initialized' }))
    $resp = Mcp-HttpPost $client $server ([ordered]@{ jsonrpc = '2.0'; id = 2; method = $method; params = $params })
    if ($null -eq $resp) { throw 'MCP 无响应（可能是传输不兼容）' }
    if ($resp.error) { throw ('MCP 错误: ' + [string]$resp.error.message) }
    return $resp.result
  }
  finally { $client.Dispose() }
}

function Invoke-McpServer($server, [string]$method, $params, [int]$timeoutMs, [string]$clientKind) {
  if ([string]$server.type -eq 'cloud') { return (Invoke-McpHttp $server $method $params $timeoutMs) }
  return (Invoke-McpStdio $server $method $params $timeoutMs $clientKind)
}
Write-Host ''
# ---- /api/mcp/call 与 /api/mcp/tools 代理：同样封成函数，好放进 runspace 池并发跑。
# worker runspace 取不到脚本作用域变量，故 rootDir 走参数；下游函数用到的
# $script: 变量（McpUtf8 / McpHttpSession）也在 worker 里就地补齐。
function Invoke-McpCall($ctx, [string]$rootDir) {
  $script:RootDir = $rootDir
  $script:McpUtf8 = New-Object System.Text.UTF8Encoding($false)
  $script:McpHttpSession = $null
  try {
    $p = ((Read-BodyText $ctx) | ConvertFrom-Json)
    $s = $p.server
    if ($null -eq $s) { Send-Json $ctx 400 @{ ok = $false; error = 'server required' }; return }
    $a2 = $p.arguments
    if ($null -eq $a2) { $a2 = [ordered]@{} }
    $params = [ordered]@{ name = [string]$p.tool; arguments = $a2 }
    $ck = Get-ClientKind $ctx
    $res = Invoke-McpServer $s 'tools/call' $params 60000 $ck
    Send-Json $ctx 200 @{ ok = $true; content = $res.content; isError = [bool]$res.isError }
  } catch {
    Send-Json $ctx 200 @{ ok = $false; error = (Get-ErrText $_.Exception) }
  }
}
function Invoke-McpTools($ctx, [string]$rootDir) {
  $script:RootDir = $rootDir
  $script:McpUtf8 = New-Object System.Text.UTF8Encoding($false)
  $script:McpHttpSession = $null
  try {
    $p = ((Read-BodyText $ctx) | ConvertFrom-Json)
    $tools = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    foreach ($s in @($p.servers)) {
      if ($null -eq $s) { continue }
      try {
        $res = Invoke-McpServer $s 'tools/list' ([ordered]@{}) 30000
        foreach ($t in @($res.tools)) {
          [void]$tools.Add([ordered]@{ server = [string]$s.name; name = [string]$t.name; description = [string]$t.description; inputSchema = $t.inputSchema })
        }
      } catch {
        [void]$errors.Add([ordered]@{ server = [string]$s.name; error = (Get-ErrText $_.Exception) })
      }
    }
    Send-Json $ctx 200 @{ ok = $true; tools = $tools; errors = $errors }
  } catch {
    Send-Json $ctx 200 @{ ok = $false; error = (Get-ErrText $_.Exception) }
  }
}
Write-Host '  aiui backend running' -ForegroundColor Green
Write-Host ("  http://127.0.0.1:$Port/         (index.html)") -ForegroundColor Cyan
if ($lanWide) {
try { $lanIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -ExpandProperty IPAddress) } catch { $lanIps = @() }

foreach ($ip in $lanIps) { Write-Host ("  http://" + $ip + ":$Port/         (LAN - phone)") -ForegroundColor Cyan }
Write-Host '  [!] LAN mode: no auth. Anyone on this network can use this shell.' -ForegroundColor Yellow
}
Write-Host '  Ctrl+C to stop.'
Write-Host ''

if ($Open) { Start-Process ("http://127.0.0.1:$Port/") | Out-Null }

# ---- 并发准备：/api/chat 是唯一的长耗时路由（流式），把它丢进 runspace 池；
# 其余路由留在主循环即时处理。这样 PC 正在回答时，手机刷新页面 / 健康探针 /
# 记忆读写都不会被堵住（原来的单线程串行正是「手机点刷新没反应」的根因）。
$script:Pool = $null
$script:Jobs = New-Object System.Collections.ArrayList
try {
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
# 原为手写清单，漏同步会导致 worker 里静默缺函数（只在并发时偶发失灵）。
# 改为从本文件 AST 自动收集，默认排除只在主循环使用的函数。
$mainLoopOnlyFns = @('Complete-ChatJobs')
$workerFns = @()
try {
$selfPath = $PSCommandPath
if (-not $selfPath) { $selfPath = $MyInvocation.MyCommand.Path }
$tk = $null; $pe = $null
$selfAst = [System.Management.Automation.Language.Parser]::ParseFile($selfPath, [ref]$tk, [ref]$pe)
$workerFns = @($selfAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name } | Sort-Object -Unique | Where-Object { $mainLoopOnlyFns -notcontains $_ })
} catch { $workerFns = @() }
$collectMode = 'auto'
if ($workerFns.Count -eq 0) {
$collectMode = 'fallback'
$workerFns = @('Send-Bytes','Send-Json','Read-BodyText','Get-ErrText','Get-ClientKind','ConvertFrom-SkillFile','Read-SkillBody','Build-SkillBlock','Build-MemoryBlock','Elide-Middle','New-ElideMarker','Invoke-ChatProxy','Invoke-McpServer','Invoke-McpStdio','Invoke-McpHttp','Mcp-SendLine','Mcp-ReadLine','Mcp-HttpPost','Invoke-McpCall','Invoke-McpTools')
}
$skipped = @()
foreach ($wf in $workerFns) {
try { $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($wf, (Get-Item ('function:' + $wf)).Definition)) } catch { $skipped += $wf }
}
if ($skipped.Count -gt 0) { Write-Host ('  [!] worker functions skipped: ' + ($skipped -join ',')) -ForegroundColor DarkYellow } else { Write-Host ('  worker fns: ' + $workerFns.Count + ' (' + $collectMode + ')') -ForegroundColor DarkGray }
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 6, $iss, $Host)
$script:Pool.Open()
Write-Host '  concurrency: /api/chat runs in a runspace pool (1-6)' -ForegroundColor DarkGray
} catch {
Write-Host ('  [x] runspace pool unavailable, falling back to serial: ' + $_.Exception.Message) -ForegroundColor DarkYellow
$script:Pool = $null
}
function Complete-ChatJobs {
try {
for ($i = $script:Jobs.Count - 1; $i -ge 0; $i--) {
$j = $script:Jobs[$i]
if ($j.h.IsCompleted) {
try { [void]$j.ps.EndInvoke($j.h) } catch { Write-Host ('  [chat] worker error: ' + (Get-ErrText $_.Exception)) -ForegroundColor DarkYellow }
try { $j.ps.Dispose() } catch { }
$script:Jobs.RemoveAt($i)
}
}
} catch { }
}
try {
  while ($listener.IsListening) {
Complete-ChatJobs
    $ctx = $listener.GetContext()
    try {
      Add-Cors $ctx
      $req = $ctx.Request
      $path = $req.Url.AbsolutePath
      $method = $req.HttpMethod

      if ($method -eq 'OPTIONS') {
        $ctx.Response.StatusCode = 204
        $ctx.Response.OutputStream.Close()
        continue
      }

      if ($method -eq 'GET' -and ($path -eq '/' -or $path -match '\.(html|css|js|json|svg|png|ico)$')) {
        $rel = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
        $rel = $rel -replace '/', '\'
        $full = Join-Path $scriptDir $rel
        $okPath = $false
        try {
          $rp = (Resolve-Path $full -ErrorAction Stop).Path
          $okPath = $rp.StartsWith($scriptDir, [StringComparison]::OrdinalIgnoreCase)
        } catch { $okPath = $false }
        if ($okPath -and (Test-Path $full -PathType Leaf)) {
          $ext = [IO.Path]::GetExtension($full).ToLower()
          $ct = switch ($ext) {
            '.html' { 'text/html; charset=utf-8' }
            '.css'  { 'text/css; charset=utf-8' }
            '.js'   { 'application/javascript; charset=utf-8' }
            '.json' { 'application/json; charset=utf-8' }
            '.svg'  { 'image/svg+xml' }
            '.png'  { 'image/png' }
            default { 'application/octet-stream' }
          }
          $ctx.Response.Headers['Cache-Control'] = 'no-cache'  # no-cache + ETag（见 Send-Static）：未改动回 304 省掉整页传输，改完刷新立刻拿到新版
Send-Static $ctx $full $ct
        } else {
          Send-Json $ctx 404 @{ ok = $false; error = 'not found'; path = $path }
        }
        continue
      }

      if ($path -eq '/api/health') {
        Send-Json $ctx 200 @{ ok = $true; name = 'aiui'; version = '0.3.0'; time = (Get-Date).ToString('s'); root = $script:RootDir }
        continue
      }

      if ($path -eq '/api/skills') {
        Send-Json $ctx 200 @{ ok = $true; dir = $script:SkillsDir; skills = (Get-SkillsCatalog) }
        continue
      }

      if ($path -eq '/api/models') {
        $endpoint = $req.QueryString['endpoint']
        $apiKey = $req.QueryString['apiKey']
        if (-not $endpoint) { Send-Json $ctx 400 @{ ok = $false; error = 'endpoint required' }; continue }
        $url = $endpoint.TrimEnd('/') + '/models'
        $r = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $url)
        if ($apiKey) { $r.Headers.Add('Authorization', 'Bearer ' + $apiKey) }
        try {
          $resp = $http.SendAsync($r).GetAwaiter().GetResult()
          $txt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
          Send-Bytes $ctx ([int]$resp.StatusCode) 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($txt))
        } catch {
          Send-Json $ctx 502 @{ ok = $false; error = (Get-ErrText $_.Exception) }
        }
        continue
      }

if ($path -eq '/api/chat') {
# 长耗时流式请求丢进 runspace 池：主循环立刻回去接下一个请求，
# 于是「PC 正在回答」不再堵住手机刷新页面 / 健康探针 / 记忆读写。
if ($null -ne $script:Pool -and $script:Jobs.Count -le 24) {
$ps = [PowerShell]::Create()
$ps.RunspacePool = $script:Pool
[void]$ps.AddCommand('Invoke-ChatProxy').AddArgument($ctx).AddArgument($http).AddArgument($script:SkillsDir).AddArgument($script:MemoryFile)
$h = $ps.BeginInvoke()
[void]$script:Jobs.Add(@{ ps = $ps; h = $h })
} else {
# 池没起来（极少数）时退回串行路径：功能不丢，只是又会被长请求堵住
Invoke-ChatProxy $ctx $http $script:SkillsDir $script:MemoryFile
}
continue
}

      if ($path -eq '/api/memory') {
        $key = $req.QueryString['key']
        if (-not $key -or $key -notmatch '^[A-Za-z0-9_-]{1,64}$') { Send-Json $ctx 400 @{ ok = $false; error = 'bad key' }; continue }
        if (-not (Test-Path $script:MemDir)) { New-Item -ItemType Directory -Path $script:MemDir -Force | Out-Null }
        $mfile = Join-Path $script:MemDir ($key + '.json')
        if ($method -eq 'GET') {
          if (Test-Path $mfile) { Send-Data $ctx 200 'application/json; charset=utf-8' ([IO.File]::ReadAllBytes($mfile)) }
          else { Send-Bytes $ctx 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('null')) }
          continue
        }
        if ($method -eq 'POST') {
          $mbody = Read-BodyText $ctx
          if (-not $mbody) { $mbody = 'null' }
          try { $null = $mbody | ConvertFrom-Json } catch { Send-Json $ctx 400 @{ ok = $false; error = 'invalid json' }; continue }
          # ---- 配置守卫（2026-10-01）：拒绝用「全默认值 / 空 Key」覆盖服务端已有配置 ----
# 事故：旧缓存页面（手机）加载时会把页面硬编码的默认值整份推到服务端，
# 把两端共享的 model / endpoint / apiKey / skills 全部冲成默认值 →
# 手机用不存在模型 → 上游 404；两端显示不一致；且「客户端读到的就是坏值」，
# 自己无法自愈（形成闭环）。此守卫让服务端直接拒收这类覆盖。
if ($key -eq 'settings') {
try {
$inObj = $mbody | ConvertFrom-Json
$gBad = $false; $gWhy = ''
if (Test-Path $mfile) {
$curObj = [IO.File]::ReadAllText($mfile) | ConvertFrom-Json
$curK = [string]$curObj.apiKey; $inK = [string]$inObj.apiKey
$curM = [string]$curObj.model;  $inM = [string]$inObj.model
if ($curK -ne '' -and $inK -eq '') { $gBad = $true; $gWhy = 'empty-apiKey' }
elseif ($curM -ne '' -and $curM -ne 'qwen2.5:7b' -and $inM -eq 'qwen2.5:7b') { $gBad = $true; $gWhy = 'default-model' }
}
if ($gBad) {
try { [IO.File]::AppendAllText((Join-Path $script:MemDir 'settings-guard.log'), ((Get-Date).ToString('s') + ' REJECT ' + $gWhy + ' inModel=' + [string]$inObj.model + "`r`n"), (New-Object System.Text.UTF8Encoding($false))) } catch { }
Send-Json $ctx 200 @{ ok = $true; rejected = $gWhy }
continue
}
} catch { }
}
[IO.File]::WriteAllText($mfile, $mbody, (New-Object System.Text.UTF8Encoding($false)))
          Send-Json $ctx 200 @{ ok = $true; file = $mfile }
          continue
        }
        Send-Json $ctx 405 @{ ok = $false; error = 'GET/POST only' }
        continue
      }

      # ---- /api/sync：两端同步（PC / 手机共享同一份对话）的轻量接口 ----------
      #   GET ?keys=a,b,c&sess=<会话id>&cid=<客户端id>&act=acquire|release
      #   revs：各 key 的版本 = 文件 LastWriteTimeUtc.Ticks + 长度。用文件时间戳
      #         而不是内存计数，服务重启后版本依然可比（客户端只管「变没变」）。
      #   turn：回合锁。同一时刻只允许一端生成回答，另一端只读并显示提示。
      #         锁是内存态；最后一次接触超过 180 秒即视为陈旧，防止发起端崩溃
      #         后把另一端永久锁死。
      if ($path -eq '/api/sync') {
        if ($method -ne 'GET') { Send-Json $ctx 405 @{ ok = $false; error = 'GET only' }; continue }
        $revs = [ordered]@{}
        foreach ($sk in (([string]$req.QueryString['keys']) -split ',')) {
          $sk = $sk.Trim()
          if (-not $sk -or $sk -notmatch '^[A-Za-z0-9_-]{1,64}$') { continue }
          $sf = Join-Path $script:MemDir ($sk + '.json')
          if (Test-Path $sf) {
            $si = Get-Item $sf
            $revs[$sk] = ([string]$si.LastWriteTimeUtc.Ticks + '-' + [string]$si.Length)
          } else {
            $revs[$sk] = 'none'
          }
        }
        $sySess = [string]$req.QueryString['sess']
        $syCid = [string]$req.QueryString['cid']
        $syAct = [string]$req.QueryString['act']
        $syStale = 180
        if ($null -eq $script:TurnLock) { $script:TurnLock = @{ sess = ''; cid = ''; at = [long]0 } }
        $sy = $script:TurnLock
        $syAge = ([DateTime]::UtcNow.Ticks - [long]$sy.at) / 10000000.0
        $syFree = ($sy.cid -eq '') -or ($syAge -gt $syStale) -or (($sy.sess -eq $sySess) -and ($sy.cid -eq $syCid))
        if ($syCid) {
          if ($syAct -eq 'acquire' -and $syFree) { $sy.sess = $sySess; $sy.cid = $syCid; $sy.at = [DateTime]::UtcNow.Ticks }
          if ($syAct -eq 'release' -and ($sy.sess -eq $sySess) -and ($sy.cid -eq $syCid)) { $sy.sess = ''; $sy.cid = ''; $sy.at = [long]0 }
        }
        $syMine = ($sy.cid -ne '') -and ($sy.sess -eq $sySess) -and ($sy.cid -eq $syCid)
        $syAge2 = ([DateTime]::UtcNow.Ticks - [long]$sy.at) / 10000000.0
        $syBusy = ($sy.cid -ne '') -and (-not $syMine) -and ($sy.sess -eq $sySess) -and ($syAge2 -le $syStale)
        Send-Json $ctx 200 ([ordered]@{
          ok = $true
          revs = $revs
          turn = [ordered]@{ holder = $sy.cid; sess = $sy.sess; mine = $syMine; busy = $syBusy; ageSec = [Math]::Round($syAge2, 1) }
        })
        continue
      }

      if ($path -eq '/api/mcp/tools') {
        if ($method -ne 'POST') { Send-Json $ctx 405 @{ ok = $false; error = 'POST required' }; continue }
        # 列工具也要逐个拉起 MCP 子进程，同样会冻住主循环；一并丢进池里跑。
        if ($null -ne $script:Pool -and $script:Jobs.Count -le 24) {
          $ps = [PowerShell]::Create()
          $ps.RunspacePool = $script:Pool
          [void]$ps.AddCommand('Invoke-McpTools').AddArgument($ctx).AddArgument($script:RootDir)
          $h = $ps.BeginInvoke()
          [void]$script:Jobs.Add(@{ ps = $ps; h = $h })
        } else {
          Invoke-McpTools $ctx $script:RootDir
        }
        continue
      }

      if ($path -eq '/api/mcp/call') {
        if ($method -ne 'POST') { Send-Json $ctx 405 @{ ok = $false; error = 'POST required' }; continue }
        # 工具调用也丢进 runspace 池：原来它在主循环内联执行，一次工具调用就把整站冻住
        # 几秒（手机刷页面、另一端的同步轮询都跟着超时）。池没起来时退回串行，功能不丢。
        if ($null -ne $script:Pool -and $script:Jobs.Count -le 24) {
          $ps = [PowerShell]::Create()
          $ps.RunspacePool = $script:Pool
          [void]$ps.AddCommand('Invoke-McpCall').AddArgument($ctx).AddArgument($script:RootDir)
          $h = $ps.BeginInvoke()
          [void]$script:Jobs.Add(@{ ps = $ps; h = $h })
        } else {
          Invoke-McpCall $ctx $script:RootDir
        }
        continue
      }
      # 优雅退出（仅限本机）：让 while 正常退出，从而走到 finally 的 Stop/Close，
      # 把 http.sys 里的 URL 注册干净释放。update.ps1 重启时优先走这里 —— 直接
      # Stop-Process -Force 会跳过 finally，残留注册会让该端口从此永远「LISTENING + 503」
      # 且新进程再也绑不上（只能去结束那个进程才能救回来）。

      if ($path -eq '/api/shutdown') {
        if (-not $req.IsLocal) { Send-Json $ctx 403 @{ ok = $false; error = 'loopback only' }; continue }
        Send-Json $ctx 200 @{ ok = $true; bye = $true }
        break
      }
      Send-Json $ctx 404 @{ ok = $false; error = 'not found'; path = $path }
    }
    catch {
      try { Send-Json $ctx 500 @{ ok = $false; error = $_.Exception.Message } } catch { }
    }
  }
}
finally {
  try { $listener.Stop() } catch { }
  try { $listener.Close() } catch { }
try { if ($script:Pool) { $script:Pool.Close(); $script:Pool.Dispose() } } catch { }
  try { $http.Dispose() } catch { }
}