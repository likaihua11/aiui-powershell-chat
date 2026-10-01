@echo off
rem ============================================================
rem  aiui one-click start (just double-click this file)
rem    1) make sure the resident launcher on 8788 is up (minimized window;
rem       closing it does not affect the page)
rem    2) make sure the backend on 8787 is up (it opens its own window)
rem    3) closing that window stops the backend and frees the port
rem
rem  NOTE: this file is deliberately pure ASCII. cmd.exe decodes .bat files with
rem  the console codepage (936 / GBK here), so a file with UTF-8 Chinese comments
rem  gets mangled into bogus "is not recognized as an internal command" lines.
rem ============================================================
setlocal
cd /d "%~dp0"
set PORT=8787
set LPORT=8788
rem ---- 1) launcher ----
rem NOTE: probe over HTTP, do NOT trust the port state.
rem netstat "LISTENING" with PID 4 is the http.sys kernel endpoint: it only means the port has a
rem registration, NOT that the process behind it is alive. When a launcher.ps1 is killed or hangs
rem without releasing its registration, the port still shows LISTENING and TCP still connects,
rem yet every request gets 503 Service Unavailable - and a new launcher could never bind again.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{$r=Invoke-WebRequest -UseBasicParsing -TimeoutSec 4 'http://127.0.0.1:%LPORT%/api/ping'; if($r.Content -match 'ok.*true'){exit 0}else{exit 1}}catch{exit 1}"
if not errorlevel 1 (
  echo [aiui] launcher already running on port %LPORT%
  goto :backend
)
netstat -ano | findstr ":%LPORT%" | findstr "LISTENING" >nul
if not errorlevel 1 (
  echo [aiui] [!] port %LPORT% has a registration but no launcher answers on it.
  echo [aiui]     Usually a stale http.sys registration left by a force-killed launcher.ps1.
  echo [aiui]     Find the owner:  netsh http show servicestate ^| findstr /i "%LPORT%"
  echo [aiui]     Not starting a second launcher - it could never bind to that registration.
  goto :backend
)
echo [aiui] starting launcher on port %LPORT% ...
start "aiui launcher" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -Port %LPORT% -ServePort %PORT%
timeout /t 2 >nul
:backend
rem ---- 2) backend ----
rem Same story as above, and this one bites far more often because the backend is restarted by
rem hand all the time. serve.ps1 -Check verifies the identity of whatever answers on the port
rem (exit 0 = the aiui backend really answers, exit 1 = it does not), so a leftover registration
rem can never fool us into "already running" -> which would send the browser to a 503 page.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1" -Check -Port %PORT% >nul 2>&1
if not errorlevel 1 (
  echo [aiui] backend already running on port %PORT%, opening browser ...
echo [aiui] phone (same Wi-Fi): open this on your phone
powershell -NoProfile -Command "$i=((Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric,InterfaceMetric | Select-Object -First 1).InterfaceIndex); $a=@(Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $i | Select-Object -ExpandProperty IPAddress); if($a.Count -eq 0){$a=@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -ExpandProperty IPAddress)}; foreach($ip in $a){ Write-Host ('[aiui]   http://' + $ip + ':' + $env:PORT + '/') }"
  start "" "http://127.0.0.1:%PORT%/"
  timeout /t 2 >nul
  exit /b 0
)
echo [aiui] starting backend on port %PORT% ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1" -Port %PORT% -Open -Lan
