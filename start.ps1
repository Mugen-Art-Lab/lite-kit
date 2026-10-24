# start.ps1 — поднимает стенд eQuasar на Windows (DNS + HTTPS на 53/80/443).
# Запуск: правый клик -> "Выполнить с помощью PowerShell" или  powershell -ExecutionPolicy Bypass -File .\start.ps1
# Сам запросит права администратора.

$ErrorActionPreference = "Continue"
$Base = Split-Path -Parent $PSCommandPath
Set-Location $Base

# --- права администратора ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[*] нужны права администратора — перезапускаю с UAC..."
    Start-Process powershell -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    exit
}

# --- IP этой машины в локальной сети ---
$ip = $null
$route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
if ($route) {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
}
if (-not $ip) { Write-Host "[!] не смог определить IP этой машины"; exit 1 }

# --- python ---
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
if (-not $py) { Write-Host "[!] python не найден: установи с python.org (галочка Add to PATH)"; exit 1 }

New-Item -ItemType Directory -Force -Path "$Base\run", "$Base\log" | Out-Null

# --- гасим прошлый запуск ---
& "$Base\stop.ps1" -Quiet | Out-Null
Start-Sleep -Seconds 1

# --- порты свободны? ---
foreach ($p in 53, 80, 443) {
    $busy = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    if ($busy) {
        Write-Host "[!] порт $p уже занят (PID $($busy[0].OwningProcess)). Освободи или останови службу."
        Write-Host "    на Windows порт 53 часто держит служба 'Internet Connection Sharing' или DNS-клиент"
        exit 1
    }
}

# --- правила firewall (входящие) ---
netsh advfirewall firewall delete rule name="lite-kit" | Out-Null
netsh advfirewall firewall add rule name="lite-kit" dir=in action=allow protocol=TCP localport=53,80,443 profile=any | Out-Null
netsh advfirewall firewall add rule name="lite-kit dns" dir=in action=allow protocol=UDP localport=53 profile=any | Out-Null

# --- аргументы ---
$env:LOCAL_IP = if ($env:LOCAL_IP) { $env:LOCAL_IP } else { $ip }
$env:BUILTIN_DNS = "1"
$argl = @("scripts\equasar_server.py", "--dns")
if (Test-Path "$Base\run\downgrade") { $argl += "--downgrade" }
if (Test-Path "$Base\run\sync_proxy") { $env:SYNC_PROXY = "1" }
if ($env:SYNC_RETRIES) { $env:SYNC_RETRIES = $env:SYNC_RETRIES }
if ($env:SYNC_RETRY_DELAY) { $env:SYNC_RETRY_DELAY = $env:SYNC_RETRY_DELAY }

# --- запуск сервера (лог в log\server.log) ---
# создаём процесс через WMI: он не наследует консольные хендлы, и start.ps1 не «висит»
$pyw = Join-Path (Split-Path -Parent $py) "pythonw.exe"
if (Test-Path $pyw) { $py = $pyw }
# launcher-файл: так надёжно работают кавычки и перенаправление логов
$launcher = "$Base\run\server.cmd"
$lines = @(
    "@echo off",
    "cd /d `"$Base`"",
    ("`"$py`" " + ($argl -join " ") + " >> `"$Base\log\server.log`" 2>> `"$Base\log\server.err.log`"")
)
Set-Content -Path $launcher -Value $lines -Encoding ascii
$null = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = "cmd.exe /c `"$launcher`""
    CurrentDirectory = $Base
}
Start-Sleep -Seconds 3

$srvProc = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*equasar_server.py*" } | Select-Object -First 1
if (-not $srvProc) {
    Write-Host "[!] сервер не запустился:"
    Get-Content "$Base\log\server.err.log" -Tail 20 -ErrorAction SilentlyContinue
    Get-Content "$Base\log\server.log" -Tail 20 -ErrorAction SilentlyContinue
    exit 1
}
$srvProc.ProcessId | Out-File -Encoding ascii "$Base\run\server.pid"

Write-Host ""
Write-Host "=== СТЕНД ПОДНЯТ ==="
Write-Host "  адрес машины   : $ip"
Write-Host "  DNS            : quasar.yandex.net / .ru / scbh.yandex.net -> $ip"
Write-Host "  сервер         : 53 (UDP/TCP), 80 и 443"
Write-Host "  режим          : $(if (Test-Path "$Base\run\downgrade") { 'откат на прошивку (downgrade)' } else { 'ADB, обновления заблокированы' })"
$fw = Get-ChildItem "$Base\firmware\*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($fw) { Write-Host "  прошивка       : $($fw.Name) ($($fw.Length) б)" } else { Write-Host "  прошивка       : в firmware\ нет .zip (раздача прошивки недоступна)" }
Write-Host "  лог            : $Base\log\server.log"
Write-Host ""
Write-Host "Проверка DNS на этой машине (должно быть $ip):"
& $py "$Base\scripts\dnscheck.py" $ip quasar.yandex.net
Write-Host ""
Write-Host "Дальше: в роутере поставь DNS = $ip, потом сбрасывай колонку (см. README.md)."
