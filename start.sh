#!/bin/bash
# Поднимает стенд eQuasar для Яндекс Станции Лайт 1 (yandexmicro).
# Запуск:  ./start.sh
set -uo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
[ -z "$IP" ] && IP="$(ipconfig getifaddr en1 2>/dev/null || true)"
if [ -z "$IP" ]; then echo "[!] не смог определить IP мака (en0/en1)"; exit 1; fi

DNSMASQ="$(command -v dnsmasq || echo /opt/homebrew/sbin/dnsmasq)"
[ -x "$DNSMASQ" ] || { echo "[!] dnsmasq не найден: brew install dnsmasq"; exit 1; }

mkdir -p "$BASE/run" "$BASE/log"

# --- гасим прошлый запуск ---
[ -f "$BASE/run/dnsmasq.pid" ] && kill -9 "$(cat "$BASE/run/dnsmasq.pid")" 2>/dev/null
[ -f "$BASE/run/server.pid" ] && kill -9 "$(cat "$BASE/run/server.pid")" 2>/dev/null
sleep 1

# --- конфиг DNS ---
sed -e "s|__MACIP__|$IP|g" -e "s|__LOGDIR__|$BASE/log|g" -e "s|__RUNDIR__|$BASE/run|g" \
    "$BASE/config/dnsmasq.conf.tpl" > "$BASE/run/dnsmasq.conf"
"$DNSMASQ" --test -C "$BASE/run/dnsmasq.conf" || { echo "[!] конфиг dnsmasq битый"; exit 1; }
"$DNSMASQ" --conf-file="$BASE/run/dnsmasq.conf"
sleep 1

# --- сервер :80/:443 ---
( cd "$BASE" && /usr/bin/python3 scripts/equasar_server.py --downgrade >> "$BASE/log/server.log" 2>&1 & echo $! > "$BASE/run/server.pid" )
sleep 2

echo
echo "=== СТЕНД ПОДНЯТ ==="
echo "  мак            : $IP"
echo "  DNS            : quasar.yandex.net / .ru / scbh.yandex.net -> $IP"
echo "  сервер         : 80 и 443 (серты eMudhra)"
echo "  прошивка       : 0.369.1.46.4778262442.20261013.297 (локально, 66 814 464 б)"
echo "  лог            : $BASE/log/server.log"
echo
echo "Проверка DNS (должно быть $IP):"
dig +short +time=3 @"$IP" quasar.yandex.net A 2>/dev/null || true
echo
echo "Дальше: включи на роутере DNS = $IP, потом сбрасывай колонку (см. README.md)."
