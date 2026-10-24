#!/bin/bash
# Ищет колонку в сети и проверяет ADB. Linux и macOS.
set -uo pipefail
OS="$(uname -s)"
ADB="${ADB:-$(command -v adb || echo /usr/local/bin/adb)}"

# подсеть берём из маршрута по умолчанию — ничего не хардкодим
if [ "$OS" = "Darwin" ]; then
    IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
    MYIP="$(ipconfig getifaddr "${IFACE:-en0}" 2>/dev/null || true)"
    PING_W="-W150"      # macOS: миллисекунды
    NC_W=(-G1)
else
    IFACE="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
    MYIP="$(ip -4 addr show dev "${IFACE:-$(ip route | awk '/^default/{print $5; exit}')}" 2>/dev/null \
            | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
    PING_W="-W1"        # Linux: секунды
    NC_W=(-w1)
fi
NET="${MYIP%.*}"
[ -n "$NET" ] || { echo "[!] не смог определить локальную подсеть"; exit 1; }
echo "[*] ищу колонку (MAC b8:87:6e = Yandex / Intertech) в $NET.0/24..."
for i in $(seq 2 254); do ping -c1 $PING_W "$NET.$i" >/dev/null 2>&1 & done; wait

if [ "$OS" = "Darwin" ]; then
    IPS="$(arp -an | grep -i 'b8:87:6e' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)"
else
    IPS="$(ip neigh 2>/dev/null | grep -i 'b8:87:6e' | awk '{print $1}' | sort -u)"
    [ -z "$IPS" ] && IPS="$(arp -an 2>/dev/null | grep -i 'b8:87:6e' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)"
fi
[ -z "$IPS" ] && { echo "[!] колонка не найдена в ARP — она выключена или не в Wi-Fi"; exit 1; }

for ip in $IPS; do
  ping -c1 $PING_W "$ip" >/dev/null 2>&1 || continue
  if nc -z "${NC_W[@]}" "$ip" 5555 2>/dev/null; then
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
