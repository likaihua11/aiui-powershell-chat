$ErrorActionPreference = 'Stop'
$d = $PSScriptRoot
$srv = Join-Path $d 'kb-local-mcp.ps1'

function Dump-List($tag, $extraArgs) {
    $in = Join-Path $d '_v-in.txt'; $out = Join-Path $d '_v-out.txt'; $err = Join-Path $d '_v-err.txt'
    $req = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"1"}}}' + "`n" +
           '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' + "`n" +
           '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' + "`n"
    [IO.File]::WriteAllText($in, $req, (New-Object Text.UTF8Encoding($false)))
    foreach ($f in @($out, $err)) { if (Test-Path $f) { Remove-Item $f -Force } }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $srv) + $extraArgs
    $p = Start-Process -FilePath 'powershell' -ArgumentList $a -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 9
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    $lines = @([IO.File]::ReadAllLines($out, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() -ne '' })
    $target = $null
    foreach ($ln in $lines) { if ($ln -match '"id":2') { $target = $ln } }
    $dst = Join-Path $d ("_v-$tag.json")
    [IO.File]::WriteAllText($dst, $target, (New-Object Text.UTF8Encoding($false)))
    Write-Output ("[$tag] 原始响应 $([Text.Encoding]::UTF8.GetByteCount($target)) B -> $dst")
    foreach ($f in @($in, $out, $err)) { if (Test-Path $f) { Remove-Item $f -Force } }
}

Dump-List 'brief' @()
Dump-List 'full' @('-Full')

function Validate($tag) {
    $raw = [IO.File]::ReadAllText((Join-Path $d "_v-$tag.json"), [Text.Encoding]::UTF8)
    $o = $raw | ConvertFrom-Json
    if ($o.error) { Write-Output "[$tag] JSON-RPC 错误: $($o.error | ConvertTo-Json -Compress)"; return }
    $tools = @($o.result.tools)
    Write-Output ("[$tag] tools=$($tools.Count)")
    $bad = @()
    foreach ($t in $tools) {
        $sc = $t.inputSchema
        if ($null -eq $sc) { $bad += "$($t.name): inputSchema null"; continue }
        if ([string]$sc.type -ne 'object') { $bad += "$($t.name): type=$($sc.type)" }
        $pr = $sc.properties
        if ($null -eq $pr) { $bad += "$($t.name): properties null"; continue }
        $keys = @($pr.PSObject.Properties.Name)
        if ($keys.Count -eq 0) { $bad += "$($t.name): properties 空" }
        $descMissing = @()
        foreach ($k in $keys) {
            $v = $pr.$k
            if ($null -eq $v) { $bad += "$($t.name).$k : null"; continue }
            $vt = @($v.PSObject.Properties.Name)
            if ($vt -notcontains 'type') { $bad += "$($t.name).$k : 缺 type" }
            if ($vt -notcontains 'description' -or [string]::IsNullOrEmpty([string]$v.description)) { $descMissing += $k }
        }
        $rqProp = $sc.PSObject.Properties['required']
        if ($null -eq $rqProp) {
            $rq = @()
            Write-Output ("   $($t.name): required 字段缺失（=无必填）, props=$($keys.Count), 无描述参数=$($descMissing.Count)")
        } else {
            $rv = $rqProp.Value
            $rq = @()
            if ($rv -is [string]) { $bad += "$($t.name): required 是字符串 '$rv'"; if ($rv -ne '') { $rq = @($rv) } }
            elseif ($null -ne $rv) { $rq = @($rv) }
            foreach ($k in $rq) {
                if ([string]::IsNullOrEmpty([string]$k)) { $bad += "$($t.name): required 含空项"; continue }
                if ($keys -notcontains $k) { $bad += "$($t.name): required 含不存在的参数 '$k'" }
            }
            Write-Output ("   $($t.name): required=$($rq.Count) props=$($keys.Count) 无描述参数=$($descMissing.Count) 总长=$([Text.Encoding]::UTF8.GetByteCount(($t | ConvertTo-Json -Depth 20 -Compress)))")
        }
    }
    if ($bad.Count -eq 0) { Write-Output "[$tag] 结构校验：通过 OK" } else { Write-Output "[$tag] 结构校验：$($bad.Count) 处异常"; foreach ($b in $bad) { Write-Output ('   - ' + $b) } }
}

Validate 'brief'
Write-Output ''
Validate 'full'
