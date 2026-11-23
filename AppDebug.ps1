# AppDebug: Firebase Events Live, PowerShell edition. No Node.js, no install, no admin rights.
# Serves the same web page as server.js on http://localhost:4455 and talks to adb.
param([int]$Port = 4455)
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$sessionsRoot = if ($env:SESSIONS_DIR) { $env:SESSIONS_DIR } else { Join-Path $root 'sessions' }

# ---- locate adb
$adbExe = $env:ADB
if (-not $adbExe) {
    foreach ($c in @('runtime\platform-tools\adb.exe', 'platform-tools\adb.exe', 'platform-tools\platform-tools\adb.exe', 'adb.exe')) {
        $f = Join-Path $root $c
        if (Test-Path $f) { $adbExe = $f; break }
    }
}
if (-not $adbExe) { $adbExe = 'adb' }

function Quote-Arg([string]$a) {
    if ($a -eq '' -or $a -match '[\s"|&<>^]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

function Invoke-Adb([string[]]$ArgList, [switch]$Binary, [int]$TimeoutMs = 15000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:adbExe
    $psi.Arguments = (($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $ms = New-Object System.IO.MemoryStream
    $copy = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {}; throw 'adb timed out' }
    $copy.Wait(); $errTask.Wait()
    if ($Binary) { return , $ms.ToArray() }
    $out = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $err = $errTask.Result
    if ($p.ExitCode -ne 0 -and $err.Trim()) { throw $err.Trim() }
    if (-not $out.Trim()) { $out = $err }
    return $out
}

# ---- state
$script:msgs = New-Object System.Collections.ArrayList
$script:allEvents = New-Object System.Collections.ArrayList
$script:pending = New-Object System.Collections.ArrayList
$script:epoch = 1; $script:seq = 0; $script:session = $null
$script:lastDir = ''; $script:lastError = ''
$script:lc = $null; $script:lcRead = $null
$PARSE = @{ inEvent = $false; inParam = $false; name = ''; time = ''; params = [ordered]@{}; raw = @(); pName = ''; pVal = '' }
$svcRes = @('^\d\d-\d\d\s+(\d\d:\d\d:\d\d\.\d+)\s+[A-Z]/FA-SVC\s*\(\s*\d+\):\s*(.*)$',
            '^\d\d-\d\d\s+(\d\d:\d\d:\d\d\.\d+)\s+\d+\s+\d+\s+[A-Z]\s+FA-SVC\s*:\s*(.*)$')

function Unq([string]$s) {
    $s = $s.Trim()
    if ($s.Length -ge 2 -and $s.StartsWith('"') -and $s.EndsWith('"')) { return $s.Substring(1, $s.Length - 2) }
    return $s
}

function Add-Event($ev) {
    $script:seq++
    $ev['id'] = $script:seq
    [void]$script:allEvents.Add($ev)
    if ($script:session.mode -ne 'instant') { [void]$script:pending.Add($ev.id) }
    [void]$script:msgs.Add(@{ type = 'event'; event = $ev })
}

function Write-Csv {
    if (-not $script:session -or $script:allEvents.Count -eq 0) { return }
    $keys = @($script:allEvents | ForEach-Object { $_.params.Keys } | Sort-Object -Unique)
    $q = { param($v) '"' + ([string]$v -replace '"', '""') + '"' }
    $head = @('Time', 'EventName', 'Screenshot', 'AnnotatedScreenshot') + $keys + @('FullObject')
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add((($head | ForEach-Object { & $q $_ }) -join ';'))
    foreach ($e in $script:allEvents) {
        $row = @($e.time, $e.name, $e.shot, $e.annotated)
        foreach ($k in $keys) { $row += $e.params[$k] }
        $row += $e.full
        [void]$lines.Add((($row | ForEach-Object { & $q $_ }) -join ';'))
    }
    $path = Join-Path $script:session.dir 'firebase_report.csv'
    [System.IO.File]::WriteAllText($path, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding $true))
}

function Get-AppBounds([string]$serial, [string]$pkg) {
    try { $out = Invoke-Adb @('-s', $serial, 'shell', "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp|Window #|mFrame='") } catch { return $null }
    if (-not $out.Contains($pkg)) { return $null }
    $inT = $false
    foreach ($line in ($out -split "`r?`n")) {
        if ($line.Contains('Window #') -and $line.Contains($pkg)) { $inT = $true }
        elseif ($line.Contains('Window #')) { $inT = $false }
        elseif ($inT) {
            $m = [regex]::Match($line, 'mFrame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
            if ($m.Success) {
                $x = [int]$m.Groups[1].Value; $y = [int]$m.Groups[2].Value
                $r = [int]$m.Groups[3].Value; $b = [int]$m.Groups[4].Value
                if (($r - $x) -gt 200 -and ($b - $y) -gt 200) { return @{ x = $x; y = $y; w = ($r - $x); h = ($b - $y) } }
            }
        }
    }
    return @{ full = $true }
}

function On-BatchEnd([string]$time) {
    $ids = @($script:pending.ToArray()); $script:pending.Clear()
    if ($ids.Count -eq 0 -or -not $script:session) { return }
    $evs = @($script:allEvents | Where-Object { $ids -contains $_.id })
    $base = ($time -replace '[:.]', '-') + "_batch_$($evs.Count)events"
    [void]$script:msgs.Add([ordered]@{ type = 'batch'; id = $base; time = $time; eventIds = $ids; shot = $null; bounds = $null })
    $batch = [ordered]@{ id = $base; time = $time; eventIds = $ids; shot = $null; bounds = $null }
    try {
        $bounds = Get-AppBounds $script:session.serial $script:session.pkg
        if ($bounds) {
            $png = Invoke-Adb @('-s', $script:session.serial, 'exec-out', 'screencap', '-p') -Binary -TimeoutMs 8000
            $rel = "screenshots/$base.png"
            [System.IO.File]::WriteAllBytes((Join-Path $script:session.dir ($rel -replace '/', '\')), $png)
            $batch['shot'] = $rel; $batch['bounds'] = $bounds
            foreach ($e in $evs) { $e['shot'] = $rel; $e['annotated'] = "screenshots/${base}_sidebyside.png" }
        } else {
            foreach ($e in $evs) { $e['shot'] = 'SKIPPED (not in foreground)'; $e['annotated'] = 'SKIPPED (not in foreground)' }
        }
    } catch { }
    [void]$script:msgs.Add(@{ type = 'batch-update'; batch = $batch })
    Write-Csv
}

function Process-Svc([string]$line) {
    $m = $null
    foreach ($re in $svcRes) { $mm = [regex]::Match($line, $re); if ($mm.Success) { $m = $mm; break } }
    if (-not $m) { return }
    $t = $m.Groups[1].Value; $msg = $m.Groups[2].Value.Trim()
    if ($msg -eq 'event {') {
        $PARSE.inEvent = $true; $PARSE.inParam = $false; $PARSE.name = ''; $PARSE.time = $t; $PARSE.params = [ordered]@{}; $PARSE.raw = @('event {'); return
    }
    if ($PARSE.inEvent) {
        $PARSE.raw = @($PARSE.raw) + $msg
        if ($msg -eq 'param {') { $PARSE.inParam = $true; $PARSE.pName = ''; $PARSE.pVal = '' }
        elseif ($PARSE.inParam) {
            if ($msg -match '^name:\s*(.+)$') { $PARSE.pName = Unq $Matches[1] }
            elseif ($msg -match '^(?:string|int|double|float)_value:\s*(.+)$') { $PARSE.pVal = Unq $Matches[1] }
            elseif ($msg -eq '}') { if ($PARSE.pName) { $PARSE.params[$PARSE.pName] = $PARSE.pVal }; $PARSE.inParam = $false }
        }
        elseif ($msg -match '^name:\s*(.+)$') { $PARSE.name = Unq $Matches[1] }
        elseif ($msg -eq '}') {
            $PARSE.inEvent = $false
            Add-Event ([ordered]@{ time = $PARSE.time; kind = 'event'; name = $PARSE.name; params = $PARSE.params; full = ($PARSE.raw -join ' '); shot = ''; annotated = '' })
        }
        return
    }
    if ($msg -match 'End-of-batch') { On-BatchEnd $t }
}

function Process-Instant([string]$line) {
    $t = [regex]::Match($line, '^(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)')
    $time = if ($t.Success) { $t.Groups[1].Value } else { '' }
    $m = [regex]::Match($line, 'Logging event(?: \(FE\))?: (?:origin=\w+,)?(?:name=)?([^,\s]+?(?:\(\w+\))?)(?:,\s*(?:params=)?)(Bundle\[.*)$')
    if (-not $m.Success) { return }
    $params = [ordered]@{}
    $b = [regex]::Match($m.Groups[2].Value, 'Bundle\[\{([\s\S]*)\}\]')
    if ($b.Success -and $b.Groups[1].Value.Trim()) {
        foreach ($part in [regex]::Split($b.Groups[1].Value, ', (?=[A-Za-z_]\w*(?:\(\w+\))?=)')) {
            $i = $part.IndexOf('=')
            if ($i -gt 0) { $params[($part.Substring(0, $i) -replace '\(\w+\)$', '')] = $part.Substring($i + 1) }
        }
    }
    Add-Event ([ordered]@{ time = $time; kind = 'event'; name = ($m.Groups[1].Value -replace '\(\w+\)$', ''); params = $params; full = ''; shot = ''; annotated = '' })
}

function Pump-Logcat {
    $n = 0
    while ($script:lcRead -and $script:lcRead.IsCompleted -and $n -lt 500) {
        $line = $null
        try { $line = $script:lcRead.Result } catch { }
        if ($null -eq $line) {
            $script:lcRead = $null; $script:lc = $null
            Write-Csv; $script:session = $null; $script:lastError = 'logcat stopped (device disconnected?)'
            return
        }
        try { if ($script:session.mode -eq 'instant') { Process-Instant $line } else { Process-Svc $line } } catch { }
        $script:lcRead = $script:lc.StandardOutput.ReadLineAsync()
        $n++
    }
}

function Stop-Capture {
    if ($script:lc) { $l = $script:lc; $script:lc = $null; $script:lcRead = $null; try { $l.Kill() } catch { } }
    if ($script:session) {
        Write-Csv
        try { Invoke-Adb @('-s', $script:session.serial, 'shell', 'setprop', 'debug.firebase.analytics.app', '.none.') | Out-Null } catch { }
        $script:lastDir = $script:session.dir; $script:session = $null
    }
}

function Start-Capture([string]$serial, [string]$pkg, [string]$mode) {
    Stop-Capture
    if ($pkg -notmatch '^[\w.]+$') { throw 'Invalid package name' }
    Invoke-Adb @('-s', $serial, 'shell', 'setprop', 'debug.firebase.analytics.app', $pkg) | Out-Null
    Invoke-Adb @('-s', $serial, 'shell', 'setprop', 'log.tag.FA', 'VERBOSE') | Out-Null
    Invoke-Adb @('-s', $serial, 'shell', 'setprop', 'log.tag.FA-SVC', 'VERBOSE') | Out-Null
    $dir = Join-Path $sessionsRoot ('QA_Run_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'screenshots') | Out-Null
    $script:session = @{ serial = $serial; pkg = $pkg; mode = $mode; dir = $dir }
    $script:msgs.Clear(); $script:allEvents.Clear(); $script:pending.Clear()
    $script:epoch++; $script:lastError = ''; $script:lastDir = $dir
    $PARSE.inEvent = $false; $PARSE.inParam = $false
    $tags = if ($mode -eq 'instant') { @('FA:V', 'FA-SVC:S') } else { @('FA-SVC:V') }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:adbExe
    $psi.Arguments = (@('-s', $serial, 'logcat', '-v', 'time', '-T', '1', '-s') + $tags | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:lc = [System.Diagnostics.Process]::Start($psi)
    $script:lcRead = $script:lc.StandardOutput.ReadLineAsync()
}

# ---- HTTP helpers
function Send-Bytes($ctx, [int]$code, [byte[]]$bytes, [string]$ctype) {
    $r = $ctx.Response
    $r.StatusCode = $code
    $r.ContentType = $ctype
    $r.Headers.Add('Cache-Control', 'no-store')
    $r.ContentLength64 = $bytes.Length
    $r.OutputStream.Write($bytes, 0, $bytes.Length)
    $r.OutputStream.Close()
}
function Send-Json($ctx, $obj, [int]$code = 200) {
    $json = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
    Send-Bytes $ctx $code ([System.Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
}
function Read-Body($req) {
    $ms = New-Object System.IO.MemoryStream
    $req.InputStream.CopyTo($ms)
    return , $ms.ToArray()
}
function Read-Json($req) {
    $bytes = Read-Body $req
    if ($bytes.Length -eq 0) { return $null }
    return ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}
function Send-File($ctx, [string]$file) {
    if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { Send-Bytes $ctx 404 ([System.Text.Encoding]::UTF8.GetBytes('Not found')) 'text/plain'; return }
    $ct = switch ([System.IO.Path]::GetExtension($file).ToLower()) { '.html' { 'text/html; charset=utf-8' } '.png' { 'image/png' } '.csv' { 'text/csv; charset=utf-8' } default { 'application/octet-stream' } }
    Send-Bytes $ctx 200 ([System.IO.File]::ReadAllBytes($file)) $ct
}

function Handle-Request($ctx) {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    $key = $req.HttpMethod + ' ' + $path
    switch ($key) {
        'GET /api/devices' {
            $out = Invoke-Adb @('devices', '-l')
            $devs = @()
            foreach ($l in (($out -split "`r?`n") | Select-Object -Skip 1)) {
                if (-not $l.Trim()) { continue }
                $parts = @($l.Trim() -split '\s+')
                $model = ''
                foreach ($x in $parts) { if ($x.StartsWith('model:')) { $model = $x.Substring(6) } }
                $devs += @{ serial = $parts[0]; state = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }); model = $model }
            }
            Send-Json $ctx $devs; return
        }
        'POST /api/pair' { $b = Read-Json $req; Send-Json $ctx @{ out = (Invoke-Adb @('pair', [string]$b.addr, [string]$b.code)) }; return }
        'POST /api/connect' { $b = Read-Json $req; Send-Json $ctx @{ out = (Invoke-Adb @('connect', [string]$b.addr)) }; return }
        'GET /api/packages' {
            $out = Invoke-Adb @('-s', $req.QueryString['serial'], 'shell', 'pm', 'list', 'packages', '-3')
            $pk = @(($out -split "`r?`n") | ForEach-Object { ($_ -replace '^package:', '').Trim() } | Where-Object { $_ } | Sort-Object)
            Send-Json $ctx $pk; return
        }
        'POST /api/start' {
            $b = Read-Json $req
            $mode = if ($b.mode -eq 'instant') { 'instant' } else { 'batch' }
            Start-Capture ([string]$b.serial) ([string]$b.pkg) $mode
            Send-Json $ctx @{ ok = $true; dir = $script:session.dir }; return
        }
        'POST /api/stop' { Stop-Capture; Send-Json $ctx @{ ok = $true }; return }
        'POST /api/clear' { $script:msgs.Clear(); $script:allEvents.Clear(); $script:pending.Clear(); $script:epoch++; Send-Json $ctx @{ ok = $true }; return }
        'GET /api/poll' {
            $since = [int]$req.QueryString['since']; $ep = [int]$req.QueryString['epoch']
            if ($ep -ne $script:epoch -or $since -gt $script:msgs.Count) { $since = 0 }
            $slice = @()
            if ($since -lt $script:msgs.Count) { $slice = $script:msgs.GetRange($since, $script:msgs.Count - $since).ToArray() }
            $st = [ordered]@{ running = [bool]$script:session; dir = $script:lastDir; error = $script:lastError }
            if ($script:session) { $st['serial'] = $script:session.serial; $st['pkg'] = $script:session.pkg; $st['mode'] = $script:session.mode; $st['dir'] = $script:session.dir }
            Send-Json $ctx ([ordered]@{ epoch = $script:epoch; next = $script:msgs.Count; msgs = $slice; status = $st }); return
        }
        'GET /api/screen' {
            $png = Invoke-Adb @('-s', $req.QueryString['serial'], 'exec-out', 'screencap', '-p') -Binary -TimeoutMs 8000
            Send-Bytes $ctx 200 $png 'image/png'; return
        }
        'POST /api/save' {
            if (-not $script:session) { Send-Json $ctx @{ error = 'No session' } 400; return }
            $name = [regex]::Replace([string]$req.QueryString['name'], '[^\w.-]', '')
            if (-not $name.EndsWith('.png')) { Send-Json $ctx @{ error = 'bad name' } 400; return }
            [System.IO.File]::WriteAllBytes((Join-Path (Join-Path $script:session.dir 'screenshots') $name), (Read-Body $req))
            Send-Json $ctx @{ ok = $true }; return
        }
        'GET /api/csv' {
            Write-Csv
            $f = if ($script:lastDir) { Join-Path $script:lastDir 'firebase_report.csv' } else { $null }
            Send-File $ctx $f; return
        }
    }
    if ($req.HttpMethod -eq 'GET' -and $path.StartsWith('/shots/') -and $script:lastDir) {
        $rel = [System.Uri]::UnescapeDataString($path.Substring(7)) -replace '/', '\'
        $full = [System.IO.Path]::GetFullPath((Join-Path $script:lastDir $rel))
        if ($full.StartsWith([System.IO.Path]::GetFullPath($script:lastDir))) { Send-File $ctx $full } else { Send-File $ctx $null }
        return
    }
    if ($req.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) { Send-File $ctx (Join-Path $root 'public\index.html'); return }
    Send-File $ctx $null
}

# ---- main loop (single thread: poll logcat, answer requests)
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch { Write-Host "Cannot listen on port $Port : $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
Write-Host "Firebase Events Live: http://localhost:$Port" -ForegroundColor Green
Write-Host "adb       : $adbExe"
Write-Host "Sessions  : $sessionsRoot"
Write-Host "Leave this window open. Press Ctrl+C to stop.`n"
try { Start-Process "http://localhost:$Port" } catch { }
$ctxTask = $listener.GetContextAsync()
try {
    while ($true) {
        Pump-Logcat
        if ($ctxTask.Wait(40)) {
            $ctx = $ctxTask.Result
            $ctxTask = $listener.GetContextAsync()
            try { Handle-Request $ctx }
            catch {
                try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch { }
            }
        }
    }
} finally {
    Stop-Capture
    $listener.Stop()
}
