# Downloads portable Node.js and Android platform-tools (adb) into .\runtime. No install, no admin rights.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = Join-Path $PSScriptRoot 'runtime'
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Get-Zip($url, $dest, $check) {
    if (Test-Path (Join-Path $dest $check)) { Write-Host "OK already present: $dest"; return }
    $zip = Join-Path $root ([IO.Path]::GetFileName($url))
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $zip
    $tmp = Join-Path $root 'tmp_extract'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $inner = Get-ChildItem $tmp | Select-Object -First 1      # zips contain one top folder
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Move-Item $inner.FullName $dest
    Remove-Item $tmp -Recurse -Force; Remove-Item $zip -Force
}

Get-Zip 'https://nodejs.org/dist/v20.18.0/node-v20.18.0-win-x64.zip' (Join-Path $root 'node') 'node.exe'
Get-Zip 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' (Join-Path $root 'platform-tools') 'adb.exe'
Write-Host "`nDone. Double-click start.bat." -ForegroundColor Green
