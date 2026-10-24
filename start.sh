#!/bin/bash
# Поднимает стенд eQuasar для Яндекс Станции Лайт 1 (yandexmicro).
# Запуск:  ./start.sh
set -uo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || exec sudo --preserve-env=SYNC_PROXY,COLUMN_IPS,LOCAL_IP,EQUASAR_MODE bash "$0" "$@"

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

# --- какой питон брать: нужен OpenSSL >= 1.1.1 (TLS 1.3) ---
PYBIN=""
for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$c" ] || continue
    if "$c" -c 'import ssl,sys; sys.exit(0 if ssl.OPENSSL_VERSION_INFO >= (1,1,1) else 1)' 2>/dev/null; then
        PYBIN="$c"; break
    fi
done
[ -z "$PYBIN" ] && PYBIN=/usr/bin/python3
echo "[*] python: $PYBIN ($("$PYBIN" -c 'import ssl; print(ssl.OPENSSL_VERSION)' 2>/dev/null))"
export LOCAL_IP="${LOCAL_IP:-$IP}"
# флаг-файл: touch run/sync_proxy — sync берётся у Яндекса и дополняется adbd
[ -f "$BASE/run/sync_proxy" ] && export SYNC_PROXY=1

# --- сервер :80/:443 ---
( cd "$BASE" && MODE=""; [ -f "$BASE/run/ota_only" ] && MODE="--ota-only"; "$PYBIN" scripts/equasar_server.py --downgrade $MODE >> "$BASE/log/server.log" 2>&1 & echo $! > "$BASE/run/server.pid" )
sleep 2

echo
echo "=== СТЕНД ПОДНЯТ ==="
echo "  мак            : $IP"
echo "  DNS            : quasar.yandex.net / .ru / scbh.yandex.net -> $IP"
echo "  сервер         : 80 и 443 (серты eMudhra)
  режим          : $( [ -f "$BASE/run/ota_only" ] && echo "только прошивка (OTA-only)" || echo "ADB + прошивка" )"
FW="$(ls "$BASE"/firmware/*.zip 2>/dev/null | head -1)"
if [ -n "$FW" ]; then
    echo "  прошивка       : $(basename "$FW") ($(wc -c <"$FW" | tr -d ' ') б)"
else
    echo "  прошивка       : в firmware/ нет .zip (режим отката будет отдавать 404)"
fi
echo "  лог            : $BASE/log/server.log"
echo
echo "Проверка DNS (должно быть $IP):"
dig +short +time=3 @"$IP" quasar.yandex.net A 2>/dev/null || true
echo
echo "Дальше: включи на роутере DNS = $IP, потом сбрасывай колонку (см. README.md)."
