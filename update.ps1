<#
  aiui 一键更新：停掉正在运行的 serve.ps1 并重启最新版，使后端路由与前端页面的全部改动随即生效。
  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File update.ps1 [-Port 8787] [-Open]
  说明：
    - 自动结束匹配 serve.ps1 的旧进程（含 IDE 包装进程）；
    - 以独立窗口启动新进程，脚本执行完即返回；
    - 启动后做健康检查并打印版本与技能数。
#>
[CmdletBinding()]
param(
  [int]$Port = 8787,
  [switch]$Open
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$serve = Join-Path $here 'serve.ps1'
if (-not (Test-Path -LiteralPath $serve)) { Write-Host ('未找到 serve.ps1：' + $serve) -ForegroundColor Red; exit 1 }

Write-Host '--- aiui 一键更新 ---' -ForegroundColor Cyan

# 1) 结束旧进程 —— 必须先「请它优雅退出」，实在不走再强杀。
#    为什么不能直接 Stop-Process -Force：那会让 serve.ps1 的 finally 来不及跑,
#    http://127.0.0.1:<Port>/ 与 http://localhost:<Port>/ 的注册就残留在 http.sys 里,
#    之后该端口永远「LISTENING + 503」，新进程也再绑不上（只能去杀掉那个残留进程才能恢复）。
function Test-ServeAlive {
  try {
    $r = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $Port + '/api/health') -UseBasicParsing -TimeoutSec 2
    return ($r.Content -match '"name"\s*:\s*"aiui"')
  } catch { return $false }
}

$me = $PID
if (Test-ServeAlive) {
  Write-Host '请求旧后端优雅退出（释放 http.sys 注册）...' -ForegroundColor DarkYellow
  try { Invoke-WebRequest -Uri ('http://127.0.0.1:' + $Port + '/api/shutdown') -Method POST -UseBasicParsing -TimeoutSec 3 | Out-Null } catch { }
  $gone = $false
  for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Milliseconds 250
    if (-not (Test-ServeAlive)) { $gone = $true; break }
  }
  if ($gone) { Write-Host '旧后端已优雅退出，端口注册已释放' -ForegroundColor Green }
  else { Write-Host '旧后端未响应 shutdown，改为强制结束' -ForegroundColor DarkYellow }
} else {
  Write-Host '未检测到运行中的 aiui 后端（将直接启动）' -ForegroundColor DarkGray
}

# 兜底：清掉可能残留的 serve.ps1 进程（例如旧版本没有 /api/shutdown 端点时）
$old = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*-File*serve.ps1*' -and $_.ProcessId -ne $me })
foreach ($p in $old) {
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Host ('已强制停止旧进程 PID ' + $p.ProcessId) -ForegroundColor DarkYellow } catch { }
}
Start-Sleep -Milliseconds 500

# 2) 启动最新版
$argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $serve, '-Port', $Port)
if ($Open) { $argList += '-Open' }
Start-Process -FilePath 'powershell' -ArgumentList $argList | Out-Null
Write-Host ('已启动 serve.ps1  (port=' + $Port + ')') -ForegroundColor Green

# 3) 健康检查 + 技能数
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
  Start-Sleep -Milliseconds 400
  try {
    $h = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/api/health') -TimeoutSec 3
    if ($h.ok) {
      $ok = $true
      Write-Host ('后端在线：version=' + $h.version + '  port=' + $Port) -ForegroundColor Green
      try {
        $s = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/api/skills') -TimeoutSec 3
        $ids = @($s.skills) | ForEach-Object { $_.id }
        Write-Host ('技能：' + @($s.skills).Count + ' 个  (' + ($ids -join '、') + ')') -ForegroundColor Gray
      } catch { Write-Host '技能列表读取失败（是否旧版后端）' -ForegroundColor DarkYellow }
      break
    }
  } catch { }
}
if (-not $ok) { Write-Host '服务已启动，但健康检查未通过，请查看新开的窗口输出。' -ForegroundColor Yellow }
Write-Host '完成：浏览器刷新页面即可看到全部改动。' -ForegroundColor Cyan
