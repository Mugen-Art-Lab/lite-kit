#!/bin/bash
# Ищет колонку в сети и проверяет ADB.
set -uo pipefail
ADB="${ADB:-$(command -v adb || echo /usr/local/bin/adb)}"

# подсеть берём из маршрута по умолчанию — ничего не хардкодим
IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
MYIP="$(ipconfig getifaddr "${IFACE:-en0}" 2>/dev/null || true)"
NET="${MYIP%.*}"
[ -n "$NET" ] || { echo "[!] не смог определить локальную подсеть"; exit 1; }
echo "[*] ищу колонку (MAC b8:87:6e = Yandex / Intertech) в $NET.0/24..."
for i in $(seq 2 254); do ping -c1 -W150 "$NET.$i" >/dev/null 2>&1 & done; wait

IPS="$(arp -an | grep -i 'b8:87:6e' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)"
[ -z "$IPS" ] && { echo "[!] колонка не найдена в ARP — она выключена или не в Wi-Fi"; exit 1; }

for ip in $IPS; do
  ping -c1 -W400 "$ip" >/dev/null 2>&1 || continue
  if nc -z -G1 "$ip" 5555 2>/dev/null; then
    echo "[+] $ip:5555 ОТКРЫТ -> подключаюсь"
    "$ADB" start-server >/dev/null 2>&1
    "$ADB" connect "$ip:5555" >/dev/null 2>&1
    sleep 1
    echo -n "    id: "; "$ADB" -s "$ip:5555" shell id 2>&1 | head -1
    echo -n "    прошивка: "; "$ADB" -s "$ip:5555" shell 'cat /system/vendor/quasar/version_full 2>/dev/null' 2>&1 | head -1
    exit 0
  else
    echo "[.] $ip — живой, но :5555 закрыт (ADB ещё не активирован)"
  fi
done
"$ADB" devices
