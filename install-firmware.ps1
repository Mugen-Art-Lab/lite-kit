# install-firmware.ps1 - скачать прошивку с зеркала в firmware\<версия>.zip
#
#   .\install-firmware.ps1                 # меню: платформа -> версия
#   .\install-firmware.ps1 -List           # только список платформ
#   .\install-firmware.ps1 -Platform yandexmicro -Version 0.369.1.46.4778262442.20261013.297
#
# На зеркале файл называется update.zip - сохраняем под именем версии.
param(
    [string]$Platform,
    [string]$Version,
    [switch]$List,
    [string]$Mirror = "http://144.76.194.29:62891"
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Base = Split-Path -Parent $PSCommandPath
$FwDir = Join-Path $Base "firmware"
New-Item -ItemType Directory -Force -Path $FwDir | Out-Null

function Get-Links([string]$Url) {
    $html = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30).Content
    [regex]::Matches($html, 'href="([^"]+)/"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object
}

function Get-VersionKey([string]$v) {
    # каждое число -> 10 цифр, чтобы строковая сортировка была числовой
    ($v -split '\.' | ForEach-Object {
        $n = 0
        if ([int]::TryParse($_, [ref]$n)) { $n.ToString("D10") } else { "0000000000" }
    }) -join ""
}

$plats = @(Get-Links "$Mirror/")
if ($List) {
    Write-Host "Зеркало: $Mirror"
    Write-Host "Платформы:"
    $plats | ForEach-Object { Write-Host "  - $_" }
    exit 0
}

if (-not $Platform) {
    if ($plats.Count -eq 0) { Write-Host "[!] не получил список платформ с $Mirror"; exit 1 }
    Write-Host "Зеркало: $Mirror"
    Write-Host "Выбери платформу:"
    for ($i = 0; $i -lt $plats.Count; $i++) { Write-Host ("  {0,2}) {1}" -f ($i + 1), $plats[$i]) }
    $ans = Read-Host "Номер (Enter = yandexmicro)"
    if ([string]::IsNullOrWhiteSpace($ans)) { $Platform = "yandexmicro" }
    else {
        $idx = 0
        if (-not [int]::TryParse($ans, [ref]$idx) -or $idx -lt 1 -or $idx -gt $plats.Count) {
            Write-Host "[!] нет такой платформы"; exit 1
        }
        $Platform = $plats[$idx - 1]
    }
}
Write-Host "[*] платформа: $Platform"

$versions = @(Get-Links "$Mirror/$Platform/")
if ($versions.Count -eq 0) { Write-Host "[!] нет версий в $Mirror/$Platform/"; exit 1 }
$versions = $versions | Sort-Object -Property @{Expression={ (Get-VersionKey $_) }} -Descending

$known = @{
    "yandexmicro" = "0.369.1.46.4778262442.20261013.297"
    "yandexmini"  = "1.305.4.16.3237824040.20250721"
}
$knownVersion = $known[$Platform]

if (-not $Version) {
    Write-Host "Выбери версию (сверху новые):"
    for ($i = 0; $i -lt $versions.Count; $i++) {
        $mark = ""
        if ($knownVersion -and $versions[$i] -eq $knownVersion) { $mark = "   <-- проверено (ADB работает)" }
        Write-Host ("  {0,2}) {1}{2}" -f ($i + 1), $versions[$i], $mark)
    }
    $ans = Read-Host "Номер (Enter = самая новая)"
    if ([string]::IsNullOrWhiteSpace($ans)) { $Version = $versions[0] }
    else {
        $idx = 0
        if (-not [int]::TryParse($ans, [ref]$idx) -or $idx -lt 1 -or $idx -gt $versions.Count) {
            Write-Host "[!] нет такой версии"; exit 1
        }
        $Version = $versions[$idx - 1]
    }
}

$url = "$Mirror/$Platform/$Version"
Write-Host "[*] версия:    $Version"
Write-Host "[*] качаю:     $url/update.zip"

$tmp = Join-Path $env:TEMP ("fw-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$metaPath = Join-Path $tmp "metadata.json"
$zipPath = Join-Path $tmp "update.zip"

$meta = $null
try {
    Invoke-WebRequest -Uri "$url/metadata.json" -UseBasicParsing -OutFile $metaPath -TimeoutSec 30
    $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
} catch {
    Write-Host "[!] metadata.json не найден, продолжу без него"
}

Invoke-WebRequest -Uri "$url/update.zip" -UseBasicParsing -OutFile $zipPath -TimeoutSec 900

$size = (Get-Item $zipPath).Length
if ($size -lt 1000000) { Write-Host "[!] файл слишком маленький ($size б) - это не прошивка"; exit 1 }

$sha = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
$crc = 0
if ($py) {
    $crc = & $py -c "import sys,zlib;print(zlib.crc32(open(sys.argv[1],'rb').read()) & 0xFFFFFFFF)" $zipPath
    $crc = ($crc | Select-Object -First 1).ToString().Trim()
}
Write-Host "[*] размер:    $size б, crc32 $crc"

if ($meta) {
    if ($meta.version -and $meta.version -ne $Version) {
        Write-Host "[!] внимание: в metadata.json версия $($meta.version), а папка $Version"
    }
    if ($meta.crc32 -and $crc -ne "0" -and "$($meta.crc32)" -ne "$crc") {
        Write-Host "[!] crc32 не совпал с metadata.json ($($meta.crc32)) - файл битый"; exit 1
    }
}

$dest = Join-Path $FwDir "$Version.zip"
Move-Item -Force -Path $zipPath -Destination $dest

$manifest = [ordered]@{
    platform = $Platform
    version  = $Version
    filename = "$Version.zip"
    size     = $size
    crc32    = [int64]$crc
    sha256   = $sha
    note     = "скачано install-firmware.ps1 с $Mirror"
}
$manifest | ConvertTo-Json | Out-File -Encoding utf8 (Join-Path $FwDir "manifest.json")

Get-ChildItem -Path $FwDir -Filter *.zip | Where-Object { $_.Name -ne "$Version.zip" } | ForEach-Object {
    Write-Host "[*] удалён старый: $($_.Name)"
    Remove-Item $_.FullName -Force
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[OK] прошивка: $dest"
Write-Host "     manifest: $($FwDir)\manifest.json"
Write-Host 'Дальше: New-Item run\downgrade -ItemType File -Force; .\stop.ps1; .\start.ps1'
