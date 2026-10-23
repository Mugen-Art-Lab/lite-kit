#!/bin/bash
# Останавливает стенд.
set -uo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

[ -f "$BASE/run/server.pid" ] && kill -9 "$(cat "$BASE/run/server.pid")" 2>/dev/null && rm -f "$BASE/run/server.pid"
[ -f "$BASE/run/dnsmasq.pid" ] && kill -9 "$(cat "$BASE/run/dnsmasq.pid")" 2>/dev/null && rm -f "$BASE/run/dnsmasq.pid"
# на случай, если pid-файлов нет
pkill -f "equasar_server.py" 2>/dev/null
pkill -f "dnsmasq --conf-file=$BASE/run/dnsmasq.conf" 2>/dev/null

echo "[OK] стенд остановлен."
echo "Не забудь вернуть на роутере DNS в режим «Автоматически»!"
