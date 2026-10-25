# diag.ps1 - "если что-то пошло не так": задаёт вопросы, собирает логи, DNS,
# состояние стенда, прошивку, дерево и окружение в ОДИН zip в корне репозитория.
#
#   .\diag.ps1                 спросить, что случилось, и собрать
#   .\diag.ps1 -NoAsk          без вопросов (для автоматизации)
#   .\diag.ps1 -Column 192.168.31.207
#   .\diag.ps1 -Out C:\Users\me\Desktop
#
# Ничего не отправляет в сеть, кроме DNS/HTTP-проверок этого же стенда.

param(
    [switch]$NoAsk,
    [string]$Out = "",
    [string]$Column = ""
)

$ErrorActionPreference = "Continue"
$Base = Split-Path -Parent $PSCommandPath
if (-not $Out) { $Out = $Base }
Set-Location $Base

$Stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$Work  = Join-Path $Base ".diag-$Stamp"
New-Item -ItemType Directory -Force -Path $Work, "$Work\logs", "$Work\probe" | Out-Null

# --- маскировка секретов (токены, куки, длинные base64/hex) ---
function Mask-Text {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $t = [regex]::Replace($Text,
        '(?i)(token|secret|password|authorization|cookie|wifi_hash)"?\s*[:=]\s*"?[^",}\s]{6,}', '$1=***')
    $t = [regex]::Replace($t, '[A-Za-z0-9+/_-]{72,}', '***BLOCK***')
    return $t
}
function Save-Text {
    param([string]$Path, [string[]]$Lines)
    ($Lines | ForEach-Object { Mask-Text $_ }) -join "`r`n" | Set-Content -Path $Path -Encoding UTF8
}

$hr = "-" * 60

# ---------------------------------------------------------------- вопросы
$choice = "-"; $verbatim = "-"; $when = "-"
if (-not $NoAsk) {
    Write-Host $hr
    Write-Host "Диагностика стенда lite-kit"
    Write-Host "Ответь на 3 вопроса - остальное соберётся само."
    Write-Host $hr
    Write-Host "Что происходит?"
    Write-Host "  1) Колонка говорит «Что-то пошло не так» / ошибка активации"
    Write-Host "  2) ADB не включается (нет :5555), колонка просит привязку"
    Write-Host "  3) Прошивка не предлагается / не скачивается / «битый файл»"
    Write-Host "  4) Колонка не видит интернет (нет ответа, нет звука)"
    Write-Host "  5) Окко / музыка / другие сервисы"
    Write-Host "  6) Другое"
    $choice = Read-Host "Номер [1-6]"
    Write-Host ""
    Write-Host "Напиши ДОСЛОВНО, что говорит или показывает колонка (можно пропустить):"
    $verbatim = Read-Host
    Write-Host ""
    Write-Host "Когда началось / что менял перед этим (необязательно):"
    $when = Read-Host
    Write-Host ""
    if (-not $Column) { $Column = Read-Host "IP колонки, если знаешь (Enter - найти автоматически)" }
}

Save-Text "$Work\answers.txt" @(
    "== выбор: $choice",
    "== дословно с колонки: $verbatim",
    "== когда началось / что менял: $when",
    "== IP колонки (введён): $(if ($Column) { $Column } else { '-' })",
    "== время: $(Get-Date)"
)

# ---------------------------------------------------------------- система
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
$os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
Save-Text "$Work\system.txt" @(
    "== дата: $(Get-Date)",
    "== hostname: $env:COMPUTERNAME",
    "== пользователь: $env:USERNAME",
    "== os: $os",
    "== версия: $([Environment]::OSVersion.VersionString)",
    "== powershell: $($PSVersionTable.PSVersion)",
    "== python: $(if ($py) { $py } else { 'не найден' })",
    "== права администратора: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
)

# ---------------------------------------------------------------- сеть
$myIp = $null
$route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
if ($route) {
    $myIp = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
}
$netLines = @()
$netLines += "== ip: $(if ($myIp) { $myIp } else { '-' })"
$netLines += ""
$netLines += "== адаптеры:"
$netLines += (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)  if=$($_.InterfaceAlias)" })
$netLines += ""
$netLines += "== маршруты:"
$netLines += (Get-NetRoute -ErrorAction SilentlyContinue | Select-Object -First 25 |
              ForEach-Object { "$($_.DestinationPrefix) -> $($_.NextHop) metric $($_.RouteMetric) if=$($_.InterfaceAlias)" })
$netLines += ""
$netLines += "== DNS серверы:"
$netLines += (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              ForEach-Object { "$($_.InterfaceAlias): $($_.ServerAddresses -join ', ')" })
Save-Text "$Work\net.txt" $netLines

# автопоиск колонки по MAC (Яндекс/Intertech: b8:87:6e) в ARP
if (-not $Column) {
    $arp = (arp -a 2>$null) -join "`n"
    $m = [regex]::Matches($arp, '(?im)^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-f-]{17})\s')
    foreach ($x in $m) {
        if ($x.Groups[2].Value -replace "-", ":" -match '^b8:87:6e' -and $x.Groups[1].Value -notlike '169.254.*') {
            $Column = $x.Groups[1].Value; break
        }
    }
}

# ---------------------------------------------------------------- DNS
function Q($name, $server) {
    try {
        if ($server) { $r = Resolve-DnsName -Name $name -Server $server -Type A -QuickTimeout -ErrorAction Stop }
        else         { $r = Resolve-DnsName -Name $name -Type A -QuickTimeout -ErrorAction Stop }
        ($r | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress }) -join " "
    } catch { "FAIL: $($_.Exception.Message.Split([Environment]::NewLine)[0])" }
}
$dnsLines = @()
$dnsLines += "== системный резолвер:"
$srv = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
$dnsLines += ($srv -join ", ")
$dnsLines += ""
foreach ($d in @("quasar.yandex.net", "yandex.ru", "okko.tv", "music.yandex.ru", "alice.yandex.net")) {
    $dnsLines += "-- $d (система): $(Q $d '')"
}
$dnsLines += ""
$dnsLines += "== через этот стенд ($myIp):"
foreach ($d in @("quasar.yandex.net", "yandex.ru", "okko.tv", "music.yandex.ru")) {
    $dnsLines += "-- ${d}: $(Q $d $myIp)"
}
$dnsLines += ""
$dnsLines += "== контроль (8.8.8.8 - работает ли интернет вообще):"
$dnsLines += "-- ya.ru: $(Q 'ya.ru' '8.8.8.8')"
Save-Text "$Work\dns.txt" $dnsLines

# ---------------------------------------------------------------- колонка: пинг/порты/процессы
$portLines = @()
if ($Column) {
    $portLines += "== пинг ${Column}:"
    $portLines += (Test-Connection -ComputerName $Column -Count 2 -ErrorAction SilentlyContinue |
                   ForEach-Object { "  $($_.Address): $($_.ResponseTime) ms" })
    $portLines += ""
}
$portLines += "== слушатели 53/80/443:"
$portLines += (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
               Where-Object { $_.LocalPort -in 53, 80, 443 } |
               ForEach-Object { "  $($_.LocalAddress):$($_.LocalPort) pid=$($_.OwningProcess) $(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName)" })
$portLines += ""
$portLines += "== python-процессы стенда:"
$portLines += (Get-CimInstance Win32_Process -Filter "Name like '%python%'" -ErrorAction SilentlyContinue |
               ForEach-Object { "  pid=$($_.ProcessId) $($_.CommandLine)" })
Save-Text "$Work\ports.txt" $portLines

# ---------------------------------------------------------------- DHCP / нет интернета
$linkLocal = $false
if ($Column -like "169.254.*") { $linkLocal = $true }
$pingOk = $false
if ($Column) { $pingOk = [bool](Test-Connection -ComputerName $Column -Count 1 -Quiet -ErrorAction SilentlyContinue) }
$colMac = ""
if ($Column) {
    $nb = Get-NetNeighbor -IPAddress $Column -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nb) { $colMac = $nb.LinkLayerAddress }
}
$leases = @()
$lh = "$env:SystemRoot\System32\dhcp\dhcpsrvlog*.log"
$leases += (Get-ChildItem $lh -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

$dhcpLines = @(
    "== колонка: $(if ($Column) { $Column } else { 'не найдена' })",
    "== MAC: $(if ($colMac) { $colMac } else { 'неизвестен' })",
    "== link-local (169.254.x.x, т.е. DHCP не сработал): $(if ($linkLocal) { 'ДА' } else { 'нет' })",
    "== пинг: $(if ($pingOk) { 'ок' } else { 'НЕ ОТВЕЧАЕТ' })",
    "",
    "== соседи (ARP) для этого адреса:",
    ((Get-NetNeighbor -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $Column } |
      ForEach-Object { "$($_.IPAddress) $($_.LinkLayerAddress) $($_.State)" }) -join "`r`n")
)
Save-Text "$Work\dhcp.txt" $dhcpLines

if ($choice -eq "4" -or $linkLocal -or -not $pingOk) {
    $macText = if ($colMac) { $colMac } else { "b8:87:6e:xx:xx:xx" }
    $advice = @(
        "КОЛОНКА НЕ ПОЛУЧАЕТ АДРЕС / НЕТ ИНТЕРНЕТА",
        ""
    )
    if ($linkLocal) {
        $advice += "В ARP у колонки $Column - адрес 169.254.x.x."
        $advice += "Это значит: DHCP ей адрес НЕ ВЫДАЛ, и она назначила его сама себе."
        $advice += ""
    }
    $advice += @(
        "Что проверить на роутере (по порядку):",
        "",
        "1) DHCP вообще включён? Какой пул и срок аренды?",
        "   (обычно 192.168.0.100-250, lease 24h)",
        "",
        "2) В списке аренд найди MAC колонки: $macText",
        "   - если аренда есть, но колонка её не берёт - удали эту аренду;",
        "   - если аренда старая/от другой сети - тоже удали.",
        "",
        "3) Убери статическую привязку (reservation) для этого MAC.",
        "   Нужно, чтобы колонка САМА выбрала свободный адрес из пула,",
        "   а не пыталась получить зарезервированный/чужой.",
        "",
        "4) Проверь, что не мешает:",
        "   - изоляция клиентов / AP isolation / 'гостевая сеть';",
        "   - MAC-фильтр;",
        "   - лимит клиентов на DHCP или на Wi-Fi;",
        "   - второй DHCP-сервер в сети (роутер + что-то ещё).",
        "",
        "5) Перезагрузи колонку (вынуть из розетки на 10 с).",
        "   После старта она должна получить адрес и появиться в арендах.",
        "",
        "6) Если адрес так и не появился - временно поставь в роутере",
        "   DHCP-пул пошире и lease покороче (1h), затем снова перезагрузи.",
        "",
        "7) Когда адрес появился - проверь доступность:",
        "   ping $(if ($Column) { $Column } else { '<ip>' }) и порт 5555 (ADB)."
    )
    Save-Text "$Work\advice.txt" $advice
    Write-Host ""
    if ($linkLocal) { Write-Host "!!! DHCP: колонка на 169.254 - адрес ей не выдали" }
    else            { Write-Host "!!! DHCP/сеть: колонка не отвечает или без адреса" }
    Write-Host "    Подробный чек-лист по DHCP - advice.txt в архиве."
}

# ---------------------------------------------------------------- пробы стенда
$idx = @("== пробы стенда (127.0.0.1 и $(if ($myIp) { $myIp } else { '-' })):")
$hostIp = if ($myIp) { $myIp } else { "127.0.0.1" }
function Probe($file, $url, $method) {
    $code = "-"; $size = 0; $t = 0
    $req = @{ Uri = $url; UseBasicParsing = $true; TimeoutSec = 25; ErrorAction = "Stop" }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $req.SkipCertificateCheck = $true }
    if ($method -eq "HEAD") { $req.Method = "Head" }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-WebRequest @req
        $sw.Stop(); $t = $sw.Elapsed.TotalSeconds
        $code = [int]$r.StatusCode
        if ($method -eq "HEAD") {
            Set-Content -Path "$Work\probe\$file" -Value ($r.Headers.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -Encoding UTF8
        } else {
            $size = $r.RawContentLength
            Set-Content -Path "$Work\probe\$file" -Value $r.Content -Encoding UTF8
        }
    } catch {
        $code = "ERR: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
        Set-Content -Path "$Work\probe\$file" -Value $code -Encoding UTF8
    }
    $script:idx += "-- $file -> $code ($([math]::Round($t, 3))s, $size b)"
}
# отключаем проверку сертификата для самоподписанных (PS 5.1)
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
foreach ($h in @("127.0.0.1", $hostIp) | Select-Object -Unique) {
    $p = if ($h -eq "127.0.0.1") { "" } else { ($h -replace "\.", "_") + "_" }
    Probe "${p}generate_204.txt"   "http://$h/generate_204" "HEAD"
    Probe "${p}root.txt"           "http://$h/" "GET"
    Probe "${p}check_updates.json" "http://$h/check_updates?device_id=DIAG&version=0.0.0&platform=yandexmicro" "GET"
    Probe "${p}sync.json"          "http://$h/get_sync_info?device_id=DIAG&version=0.0.0&platform=yandexmicro" "GET"
    Probe "${p}https_root.txt"     "https://$h/" "GET"
}
Set-Content -Path "$Work\probe\_index.txt" -Value $idx -Encoding UTF8
$idx | ForEach-Object { Write-Host $_ }

# ---------------------------------------------------------------- прошивка
if (-not ("Crc32" -as [type])) {
    Add-Type -TypeDefinition @"
public static class Crc32 {
    static readonly uint[] T = new uint[256];
    static Crc32() {
        for (uint i = 0; i < 256; i++) {
            uint c = i;
            for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            T[i] = c;
        }
    }
    public static uint Compute(byte[] d) {
        uint c = 0xFFFFFFFFu;
        foreach (byte b in d) c = T[(c ^ b) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }
}
"@
}
$fw = @()
$fw += "== файлы firmware/:"
if (Test-Path "firmware") {
    $fw += (Get-ChildItem "firmware" -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { "{0,12}  {1}" -f $_.Length, ($_.FullName.Replace($Base, ".")) })
} else { $fw += "(папки firmware/ нет)" }
$fw += ""
$fw += "== manifest.json:"
Get-ChildItem "firmware" -Recurse -Filter "manifest.json" -ErrorAction SilentlyContinue | ForEach-Object {
    $fw += "-- $($_.FullName.Replace($Base, '.'))"
    $fw += (Get-Content $_.FullName -Raw)
    $fw += ""
}
$fw += "== проверка zip (магия, crc32, sha256):"
Get-ChildItem "firmware" -Recurse -Filter "*.zip" -ErrorAction SilentlyContinue | ForEach-Object {
    $z = $_
    $fs = [IO.File]::OpenRead($z.FullName)
    $magic = ""
    try { $b = New-Object byte[] 2; [void]$fs.Read($b, 0, 2); $magic = [Text.Encoding]::ASCII.GetString($b) } finally { $fs.Dispose() }
    $crc = "-"
    try {
        $bytes = [IO.File]::ReadAllBytes($z.FullName)
        $crc = [Crc32]::Compute($bytes)
    } catch { $crc = "-" }
    $sha = (Get-FileHash -Algorithm SHA256 -Path $z.FullName).Hash.ToLower()
    $fw += "-- $($z.Name)"
    $fw += "   размер: $($z.Length) б"
    $fw += "   магия:  '$magic' $(if ($magic -eq 'PK') { 'OK' } else { 'НЕ ZIP!' })"
    $fw += "   crc32:  $crc"
    $fw += "   sha256: $sha"
    if ($z.Length -eq 33212) { $fw += "   !!! обрезанный файл (33212 б) - качать из downloadUrl, а не с зеркала" }
}
Save-Text "$Work\firmware.txt" $fw

# ---------------------------------------------------------------- дерево/гит/конфиг/серты
$tree = @()
$tree += "== дерево (2 уровня, без .git/log):"
$tree += (Get-ChildItem -Recurse -Depth 1 -Force -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -notmatch '\\\.git($|\\)' -and $_.FullName -notmatch '\\log\\' -and $_.FullName -notmatch '\\\.diag-' } |
          ForEach-Object { $_.FullName.Replace($Base, ".") } | Sort-Object | Select-Object -First 200)
$tree += ""
$tree += "== флаги run/:"
if (Test-Path "run") { $tree += (Get-ChildItem "run" -Force | ForEach-Object { $_.Name }) } else { $tree += "(пусто)" }
$tree += ""
$tree += "== git:"
$tree += (git rev-parse --short HEAD 2>&1)
$tree += (git log -3 --oneline 2>&1)
$tree += (git status --porcelain 2>&1 | Select-Object -First 20)
Save-Text "$Work\tree.txt" $tree

$cfg = @()
$cfg += "== переменные окружения (значимые):"
foreach ($v in @("LOCAL_IP", "COLUMN_IPS", "MIRROR_URL", "SYNC_LOCAL", "SYNC_RETRIES", "SYNC_RETRY_DELAY", "UPSTREAM_TIMEOUT")) {
    $val = [Environment]::GetEnvironmentVariable($v)
    if ($val) { $cfg += "$v=$val" }
}
$cfg += ""
$cfg += "== config/:"
Get-ChildItem "config" -File -ErrorAction SilentlyContinue | ForEach-Object {
    $cfg += "-- $($_.Name)"
    $cfg += (Get-Content $_.FullName -Raw)
}
Save-Text "$Work\config.txt" $cfg

$cert = @()
$cert += "== сертификаты:"
Get-ChildItem "certs" -File -ErrorAction SilentlyContinue | ForEach-Object {
    $cert += "-- $($_.Name)  $($_.Length) б"
    if ($_.Extension -eq ".pem") {
        try {
            $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $_.FullName
            $cert += "   subject: $($c.Subject)"
            $cert += "   issuer:  $($c.Issuer)"
            $cert += "   до:      $($c.NotAfter)"
        } catch { }
    }
}
Save-Text "$Work\certs.txt" $cert

# ---------------------------------------------------------------- логи
Get-ChildItem "log" -Filter "*.log" -ErrorAction SilentlyContinue | ForEach-Object {
    $tail = Get-Content $_.FullName -Tail 5000 -ErrorAction SilentlyContinue
    Save-Text "$Work\logs\$($_.Name)" $tail
}
if (Test-Path "log\sync_real.json") { Copy-Item "log\sync_real.json" "$Work\logs\" -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- опись
$readme = @(
    "lite-kit - диагностика от $(Get-Date)",
    "",
    "answers.txt   - что выбрал и что дословно говорит колонка",
    "system.txt    - ОС, python, права",
    "net.txt       - адреса, маршруты, DNS,"
    "dns.txt       - ответы DNS для quasar/yandex/okko/music (+ контроль 8.8.8.8)",
    "ports.txt     - кто слушает 53/80/443 + процессы стенда",
    "dhcp.txt      - адрес/MAC колонки, link-local, ARP",
    "advice.txt    - что делать, если колонка не получила IP",
    "probe/        - ответы самого стенда: generate_204, check_updates, sync",
    "firmware.txt  - что лежит в firmware/: размер, zip-магия, crc32, sha256",
    "tree.txt      - структура папки, флаги run/, состояние git",
    "config.txt    - config/ и переменные (токены замаскированы)",
    "certs.txt     - срок/издатель сертификатов",
    "logs/         - последние 5000 строк yandex/local/dns/server (замаскированы)",
    "",
    "Секреты (токены, куки) вырезаны автоматически."
)
Set-Content -Path "$Work\README.txt" -Value $readme -Encoding UTF8

# ---------------------------------------------------------------- архив
$zip = Join-Path $Out "lite-kit-diag-$Stamp.zip"
Compress-Archive -Path "$Work\*" -DestinationPath $zip -Force
$size = (Get-Item $zip).Length
Remove-Item -Recurse -Force $Work

Write-Host $hr
Write-Host "[+] готово: $zip"
Write-Host "    размер: $([math]::Round($size / 1KB)) КБ"
Write-Host ""
Write-Host "    Внутри: ответы, логи, DNS, пробы стенда, прошивка, дерево, конфиг."
Write-Host "    Отправь этот архив целиком - по нему видно, что сломалось."
Write-Host $hr
Start-Process explorer.exe -ArgumentList "/select,`"$zip`""
