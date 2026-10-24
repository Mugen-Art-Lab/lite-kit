#!/bin/bash
# test-ota.sh — проверка режима OTA-only: манифест, отдача файла, Range, crc32.
#
# Запуск на машине со стендом (Linux/macOS):
#   ./scripts/test-ota.sh                 # через 127.0.0.1
#   ./scripts/test-ota.sh 192.168.0.109   # через свой IP
set -u
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-127.0.0.1}"
UA="yandexmini/1.369.4.46"
OK=0; FAIL=0

say() { printf '%s\n' "$*"; }
ok()  { OK=$((OK+1));   say "  ✅ $*"; }
bad() { FAIL=$((FAIL+1)); say "  ❌ $*"; }

FW="$(ls "$BASE_DIR"/firmware/*.zip 2>/dev/null | head -1)"
[ -z "$FW" ] && { say "[!] в firmware/ нет .zip"; exit 1; }
NAME="$(basename "$FW")"
SIZE="$(wc -c <"$FW" | tr -d ' ')"
CRC="$(python3 - "$FW" <<'PY'
import sys, zlib
print(zlib.crc32(open(sys.argv[1], 'rb').read()) & 0xFFFFFFFF)
PY
)"

say "файл: $NAME ($SIZE б, crc32 $CRC)"
say "стенд: https://$HOST"
say

say "1) манифест /check_updates"
MAN="$(curl -k -s -m 10 -H "Host: quasar.yandex.net" -H "User-Agent: $UA" \
  "https://$HOST/check_updates?device_id=test&version=0.1")"
echo "$MAN" | head -c 400; say

python3 - "$MAN" "$NAME" "$CRC" <<'PY' && ok "манифест корректный" || bad "манифест не совпал с файлом"
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
name, crc = sys.argv[2], int(sys.argv[3])
assert d.get("hasUpdate") is True, "hasUpdate != true"
assert d.get("version") in sys.argv[2], "версия не из имени файла"
assert int(d.get("crc32", -1)) == crc, "crc32 не совпадает"
assert d.get("downloadUrl", "").endswith(name), "downloadUrl не на наш файл"
sys.exit(0)
PY

say "2) полная отдача файла"
RES="$(curl -k -s -o /tmp/ota_test.bin -w "%{http_code} %{size_download}" -m 120 \
  -H "Host: quasar.yandex.net" -H "User-Agent: $UA" \
  "https://$HOST$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['downloadUrl'].split('quasar.yandex.net',1)[1])" "$MAN")")"
CODE="${RES%% *}"; GOT="${RES##* }"
if [ "$CODE" = "200" ] && [ "$GOT" = "$SIZE" ]; then ok "скачано $GOT б (200)"; else bad "код $CODE, получено $GOT из $SIZE"; fi
[ -f /tmp/ota_test.bin ] && rm -f /tmp/ota_test.bin

say "3) Range (станция качает кусками)"
RCODE="$(curl -k -s -o /dev/null -w "%{http_code}" -m 30 \
  -H "Host: quasar.yandex.net" -H "Range: bytes=0-1048575" \
  "https://$HOST$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['downloadUrl'].split('quasar.yandex.net',1)[1])" "$MAN")")"
[ "$RCODE" = "206" ] && ok "Range работает (206)" || bad "Range вернул $RCODE (ожидали 206)"

say "4) /get_sync_info должен уходить в настоящий Яндекс (в этом режиме ADB не включаем)"
SYNC="$(curl -k -s -m 15 -H "Host: quasar.yandex.net" \
  "https://$HOST/get_sync_info?device_id=test&platform=yandexmini")"
LEN=${#SYNC}
if [ "$LEN" -gt 2000 ]; then ok "проксируется (ответ $LEN б)"; else bad "похоже на локальный ответ ($LEN б)"; fi

say
say "итог: успешно $OK, ошибок $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
