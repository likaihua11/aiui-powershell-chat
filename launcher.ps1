<#
  aiui launcher - 极简常驻启动器（浏览器与本地脚本之间的桥）
  ------------------------------------------------------------
  为什么需要它：浏览器沙箱不能启动本地进程，而页面又由 serve.ps1 托管 ——
  一旦 serve.ps1 挂掉（例如被某个对话重启掐断），页面就再也起不来了。
  本脚本常驻在独立端口，只回答“后端还活着吗 / 帮我启动它”。

  端点：
    GET  /api/ping     -> {ok, serveUp, servePort}
    POST /api/launch   -> 后端未运行则启动 serve.ps1（已运行则原样返回）
    POST /api/restart  -> 停旧起新（调 update.ps1）
GET  /api/voice[?start=1] -> 查询（带 start=1 且未运行则静默拉起）；POST /api/voice -> 拉起本地语音助手（voice-assistant 的 start.bat）
    GET  /             -> 极简状态页

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File launcher.ps1 [-Port 8788] [-ServePort 8787]
#>
[CmdletBinding()]
param(
  [int]$Port = 8788,
  [int]$ServePort = 8787,
[int]$VoicePort = 8756
)
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$serveExe  = Join-Path $scriptDir 'serve.ps1'
$updateExe = Join-Path $scriptDir 'update.ps1'
$aiRoot    = Split-Path -Parent $scriptDir
$voiceDir  = Join-Path $aiRoot 'voice-assistant'
$voiceBat  = Join-Path $voiceDir 'start.bat'

$utf8 = New-Object System.Text.UTF8Encoding($false)

Add-Type -AssemblyName System.Net.Http | Out-Null
$script:probeHttp = New-Object System.Net.Http.HttpClient
$script:probeHttp.Timeout = [TimeSpan]::FromSeconds(4)

# 后端是否真的在服务 —— 不能用「端口在听 / TCP 连得上」来判断。
# netstat 里的 LISTENING（PID 4）是 http.sys 内核端点，只代表端口「有注册」：
# 旧后端进程被杀/卡死而没释放注册时，端口照样 LISTENING、TCP 也连得上，但请求一律 503。
# 旧实现只看 TCP 连通，于是永远回「在线」，/api/launch 与界面「测试连接」的自救路径被废掉
# （后端挂了也拉不起来）。现在改为发 HTTP 探针并校验身份（/api/health 的 name 必须是 aiui）。
function Test-ServeUp {
  try {
    $r = $script:probeHttp.GetAsync('http://127.0.0.1:' + $ServePort + '/api/health').GetAwaiter().GetResult()
    if (-not $r.IsSuccessStatusCode) { return $false }   # 503 等一律视为没在跑
    $txt = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    return ($txt -match '"name"\s*:\s*"aiui"')
  } catch {
    $ex = $_.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    # 超时 = 连上了但没及时回（后端在串行处理流式响应），按「在跑」处理；连接被拒等才是没在跑
    return ($ex -is [System.Threading.Tasks.TaskCanceledException] -or $ex -is [System.OperationCanceledException] -or $ex -is [System.TimeoutException])
  }
}

# 启动后端：独立进程 + 最小化窗口，不随本启动器退出而被回收
function Start-ServeBackend {
  if (Test-ServeUp) { return $false }
  if (-not (Test-Path -LiteralPath $serveExe)) { throw ('未找到 serve.ps1：' + $serveExe) }
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $serveExe, '-Port', $ServePort)
  Start-Process -FilePath 'powershell' -ArgumentList $argList -WindowStyle Minimized | Out-Null
  return $true
}

# 停旧起新
function Restart-ServeBackend {
  if (-not (Test-Path -LiteralPath $updateExe)) { throw ('未找到 update.ps1：' + $updateExe) }
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updateExe, '-Port', $ServePort)
  Start-Process -FilePath 'powershell' -ArgumentList $argList -WindowStyle Minimized | Out-Null
  return $true
}

# 语音助手是否在监听（TCP 探测，独立于 HTTP，不受其忙碌影响）
function Test-VoiceUp {
try {
$c = New-Object System.Net.Sockets.TcpClient
$null = $c.ConnectAsync('127.0.0.1', $VoicePort).Wait(400)
$ok = $c.Connected
$c.Close()
return $ok
} catch { return $false }
}

# 启动语音助手：走它自己的 start.bat（复用其中的模型/环境变量）；
# VOICE_NO_BROWSER=1 让它别额外弹一个浏览器标签页
function Start-VoiceService {
if (Test-VoiceUp) { return $false }
if (-not (Test-Path -LiteralPath $voiceBat)) { throw ('未找到语音助手启动脚本：' + $voiceBat) }
$env:VOICE_NO_BROWSER = '1'
Start-Process -FilePath $voiceBat -WorkingDirectory $voiceDir -WindowStyle Minimized | Out-Null
return $true
}

# 写 JSON 响应（UTF-8 无 BOM，避免中文乱码）
function Send-Json($ctx, $code, $obj) {
  $bytes = $utf8.GetBytes(($obj | ConvertTo-Json -Depth 8 -Compress))
  $ctx.Response.StatusCode = $code
  $ctx.Response.ContentType = 'application/json; charset=utf-8'
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}
function Send-Text($ctx, $code, $text) {
  $bytes = $utf8.GetBytes($text)
  $ctx.Response.StatusCode = $code
  $ctx.Response.ContentType = 'text/html; charset=utf-8'
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}
# 允许来自 8787 页面的跨端口请求
function Add-Cors($ctx) {
  $h = $ctx.Response.Headers
  $h['Access-Control-Allow-Origin'] = '*'
  $h['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
  $h['Access-Control-Allow-Headers'] = 'Content-Type'
}

$listener = New-Object System.Net.HttpListener
foreach ($p in @("http://127.0.0.1:$Port/", "http://localhost:$Port/")) {
  try { $listener.Prefixes.Add($p) } catch { Write-Host ("prefix skipped: " + $p) -ForegroundColor DarkYellow }
}
try { $listener.Start() } catch {
  Write-Host ('启动器无法监听 ' + $Port + '：' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host '  aiui launcher' -ForegroundColor Cyan
Write-Host ('  状态页  http://127.0.0.1:' + $Port + '/') -ForegroundColor Gray
Write-Host ('  后端    http://127.0.0.1:' + $ServePort + '/  (当前 ' + $(if (Test-ServeUp) { '在线' } else { '未运行' }) + ')') -ForegroundColor Gray
Write-Host '  关闭本窗口即停止启动器（后端不受影响）' -ForegroundColor DarkGray
Write-Host ''

while ($listener.IsListening) {
  $ctx = $null
  try { $ctx = $listener.GetContext() } catch { break }
  try {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod
    Add-Cors $ctx

    if ($method -eq 'OPTIONS') { $ctx.Response.StatusCode = 204; $ctx.Response.Close(); continue }

    if ($path -eq '/api/ping') {
      Send-Json $ctx 200 @{ ok = $true; serveUp = (Test-ServeUp); servePort = $ServePort; launcherPort = $Port }
      continue
    }

    if ($path -eq '/api/launch') {
      if (Test-ServeUp) { Send-Json $ctx 200 @{ ok = $true; started = $false; note = 'already running' }; continue }
      $started = Start-ServeBackend
      Send-Json $ctx 200 @{ ok = $true; started = $started; servePort = $ServePort }
      continue
    }

    if ($path -eq '/api/restart') {
      $null = Restart-ServeBackend
      Send-Json $ctx 200 @{ ok = $true; restarted = $true; servePort = $ServePort }
      continue
    }

    if ($path -eq '/api/voice') {
if ($method -eq 'POST') {
if (Test-VoiceUp) { Send-Json $ctx 200 @{ ok = $true; started = $false; up = $true; port = $VoicePort; note = 'already running' }; continue }
$vstarted = Start-VoiceService
Send-Json $ctx 200 @{ ok = $true; started = $vstarted; up = (Test-VoiceUp); port = $VoicePort }
continue
}
if ($req.Url.Query -match 'start=1') {
        if (Test-VoiceUp) { Send-Json $ctx 200 @{ ok = $true; started = $false; up = $true; port = $VoicePort; note = 'already running' }; continue }
        $vstarted = Start-VoiceService
        Send-Json $ctx 200 @{ ok = $true; started = $vstarted; up = (Test-VoiceUp); port = $VoicePort }
        continue
      }
      Send-Json $ctx 200 @{ ok = $true; up = (Test-VoiceUp); port = $VoicePort }
continue
}

if ($path -eq '/' -or $path -eq '/index.html') {
      $up = Test-ServeUp
      $body = @"
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>aiui launcher</title>
<style>body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;max-width:640px;margin:12vh auto;padding:0 24px;color:#222;line-height:1.9}
h1{font-size:20px;font-weight:600}code{background:#f4f4f4;padding:2px 6px;border-radius:4px}
.b{display:inline-block;padding:8px 16px;border:1px solid #ddd;border-radius:8px;cursor:pointer;background:#fff;font-size:14px;margin-right:8px}
.b:hover{border-color:#999}.ok{color:#0a7c3e}.no{color:#b33}</style></head>
<body><h1>aiui 启动器</h1>
<p>后端（<code>127.0.0.1:$ServePort</code>）：<b class="$(if ($up) { 'ok">在线' } else { 'no">未运行' })</b></p>
<p><button class="b" onclick="fetch('/api/launch',{method:'POST'}).then(()=>setTimeout(()=>location.reload(),1500))">启动后端</button>
<button class="b" onclick="fetch('/api/restart',{method:'POST'}).then(()=>setTimeout(()=>location.reload(),2500))">重启后端</button></p>
<p><a href="http://127.0.0.1:$ServePort/">打开 aiui 界面 →</a></p>
</body></html>
"@
      Send-Text $ctx 200 $body
      continue
    }

    Send-Json $ctx 404 @{ ok = $false; error = 'not found' }
  } catch {
    try { Send-Json $ctx 500 @{ ok = $false; error = $_.Exception.Message } } catch { }
  }
}

try { $listener.Stop() } catch { }
try { $listener.Close() } catch { }
