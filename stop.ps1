# stop.ps1 — останавливает стенд на Windows.
param([switch]$Quiet)
$Base = Split-Path -Parent $PSCommandPath

$killed = 0

$pidFile = "$Base\run\server.pid"
if (Test-Path $pidFile) {
    $srvPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    if ($srvPid) {
        try { Stop-Process -Id ([int]$srvPid) -Force -ErrorAction Stop; $killed++ } catch {}
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# на случай, если pid-файла нет: ищем по командной строке
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*equasar_server.py*" } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch {}
    }

if (-not $Quiet) {
    Write-Host "[OK] стенд остановлен (процессов снято: $killed)."
    Write-Host "Не забудь вернуть на роутере DNS в режим «Автоматически»!"
}
