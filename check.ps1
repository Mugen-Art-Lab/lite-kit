# check.ps1 — ищет колонку в сети и проверяет ADB (Windows).
$ErrorActionPreference = "Continue"
$Base = Split-Path -Parent $PSCommandPath

$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb -and (Test-Path "$Base\tools\adb.exe")) { $adb = "$Base\tools\adb.exe" }
if (-not $adb) { Write-Host "[!] adb не найден (положи adb.exe в tools\ или добавь в PATH)" }

# подсеть из маршрута по умолчанию
$route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
$myIp = $null
if ($route) {
    $myIp = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
}
if (-not $myIp) { Write-Host "[!] не смог определить локальную подсеть"; exit 1 }
$net = $myIp.Substring(0, $myIp.LastIndexOf("."))
Write-Host "[*] ищу колонку (MAC b8:87:6e = Yandex) в $net.0/24..."

# прогреваем ARP
1..254 | ForEach-Object -Parallel {
    Test-Connection -ComputerName "$using:net.$_" -Count 1 -Quiet -TimeoutSeconds 1 | Out-Null
} -ThrottleLimit 64 -ErrorAction SilentlyContinue

$rows = arp -a | Select-String "b8-87-6e" | ForEach-Object {
    if ($_.Line -match "([0-9]{1,3}(\.[0-9]{1,3}){3})") { $Matches[1] }
} | Sort-Object -Unique

if (-not $rows) { Write-Host "[!] колонка не найдена в ARP — выключена или не в Wi-Fi"; exit 1 }

foreach ($ip in $rows) {
    $open = $false
    try { $open = (Test-NetConnection -ComputerName $ip -Port 5555 -InformationLevel Quiet -WarningAction SilentlyContinue) } catch {}
    if ($open) {
        Write-Host "[+] $ip:5555 ОТКРЫТ -> подключаюсь"
        & $adb start-server 2>$null | Out-Null
        & $adb connect "$ip`:5555" | Out-Null
        Start-Sleep -Seconds 1
        Write-Host -NoNewline "    id: "; & $adb -s "$ip`:5555" shell id | Select-Object -First 1
        Write-Host -NoNewline "    прошивка: "; & $adb -s "$ip`:5555" shell "cat /system/vendor/quasar/version_full 2>/dev/null" | Select-Object -First 1
        exit 0
    } else {
        Write-Host "[.] $ip — живой, но :5555 закрыт (ADB ещё не активирован)"
    }
}
if ($adb) { & $adb devices }
