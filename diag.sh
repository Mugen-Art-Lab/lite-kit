#!/bin/bash
# diag.sh — «если что-то пошло не так»: задаёт вопросы, собирает логи, DNS,
# состояние сервера, прошивку, дерево и окружение в ОДИН архив в корне репозитория.
#
#   ./diag.sh                 спросить, что случилось, и собрать
#   ./diag.sh --no-ask        без вопросов (для автоматизации)
#   ./diag.sh --column 192.168.0.245
#   ./diag.sh --out ~/Desktop
#
# Ничего не отправляет в сеть, кроме DNS/HTTP-проверок этого же стенда.
set -uo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE" || exit 1

ASK=1
OUT="$BASE"
COLUMN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-ask)  ASK=0; shift ;;
        --out)     OUT="${2:-$BASE}"; shift 2 ;;
        --column)  COLUMN="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *)         echo "[!] неизвестный аргумент: $1"; exit 2 ;;
    esac
done

STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
W="$BASE/.diag-$STAMP"
mkdir -p "$W/logs" "$W/probe" || exit 1

# --- маскировка секретов (токены, куки, длинные base64/hex) ---
mask() {
    sed -E \
        -e 's/([Tt]oken|[Ss]ecret|[Pp]assword|[Aa]uthorization|[Cc]ookie|[Ww]ifi_hash|[Hh]ash)"?[[:space:]]*[:=][[:space:]]*"?[^",}[:space:]]{6,}/\1=***/g' \
        -e 's/[A-Za-z0-9+\/_-]{72,}/***BLOCK***/g' 2>/dev/null || cat
}

have() { command -v "$1" >/dev/null 2>&1; }
OS="$(uname -s)"

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "------------------------------------------------------------"; }

# ---------------------------------------------------------------- вопросы
CHOICE="-"
VERBATIM="-"
WHEN="-"
if [ "$ASK" = "1" ]; then
    hr
    say "Диагностика стенда lite-kit"
    say "Ответь на 3 вопроса — всё остальное соберётся само."
    hr
    say "Что происходит?"
    say "  1) Колонка говорит «Что-то пошло не так» / ошибка активации"
    say "  2) ADB не включается (нет :5555), колонка просит привязку"
    say "  3) Прошивка не предлагается / не скачивается / «битый файл»"
    say "  4) Колонка не видит интернет (нет ответа, нет звука)"
    say "  5) Окко / музыка / другие сервисы"
    say "  6) Другое"
    printf 'Номер [1-6]: '
    read -r CHOICE
    echo
    say "Напиши ДОСЛОВНО, что говорит или показывает колонка (можно пропустить):"
    read -r VERBATIM
    echo
    say "Когда началось / что менял перед этим (необязательно):"
    read -r WHEN
    echo
fi

if [ -z "$COLUMN" ] && [ "$ASK" = "1" ]; then
    printf 'IP колонки, если знаешь (Enter — найти автоматически): '
    read -r COLUMN
fi

{
    echo "== выбор: $CHOICE"
    echo "== дословно с колонки: $VERBATIM"
    echo "== когда началось / что менял: $WHEN"
    echo "== IP колонки (введён): ${COLUMN:--}"
    echo "== платформа: $OS"
    echo "== время: $(date)"
} > "$W/answers.txt"

# ---------------------------------------------------------------- система
{
    echo "== дата: $(date)"
    echo "== hostname: $(hostname 2>/dev/null)"
    echo "== пользователь: $(id -un 2>/dev/null)"
    uname -a 2>&1
    sw_vers 2>&1
    [ -f /etc/os-release ] && { . /etc/os-release; echo "== os: $PRETTY_NAME"; }
    echo "== python:"; (python3 -V 2>&1 || python -V 2>&1)
    echo "== bash: ${BASH_VERSION:-?}"
    echo "== curl: $(curl --version 2>/dev/null | head -1)"
    echo "== git: $(git --version 2>&1)"
} > "$W/system.txt" 2>&1

# ---------------------------------------------------------------- сеть
IFACE=""
MYIP=""
if [ "$OS" = "Darwin" ]; then
    # дефолтный маршрут может быть VPN (utun) — берём первый частный IPv4
    MYIP="$(ifconfig 2>/dev/null | awk '/^[a-z0-9]+:/{ifc=$1} /inet /{ip=$2;
        if (ip !~ /^127\./ && (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./)) {print ifc, ip; exit}}' \
        | awk '{print $2}')"
    IFACE="$(ifconfig 2>/dev/null | awk '/^[a-z0-9]+:/{ifc=$1} /inet /{ip=$2; if (ip=="'"$MYIP"'") {sub(":","",ifc); print ifc; exit}}')"
else
    IFACE="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
    MYIP="$(ip -4 addr show dev "${IFACE:-$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')}" 2>/dev/null \
            | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
    [ -z "$MYIP" ] && MYIP="$(ip -4 addr 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -vE '^127\.' | head -1)"
fi

{
    echo "== интерфейс: ${IFACE:--}  ip: ${MYIP:--}"
    echo
    echo "== адреса/маршруты:"
    if have ip; then ip -4 addr 2>&1; echo; ip route 2>&1
    else ifconfig 2>&1; echo; netstat -rn 2>&1 | head -25; fi
    echo
    echo "== DNS-серверы системы:"
    if [ "$OS" = "Darwin" ]; then scutil --dns 2>/dev/null | awk '/nameserver\[/{print}' | head -10
    else cat /etc/resolv.conf 2>&1; fi
    command -v resolvectl >/dev/null && { echo; resolvectl status 2>&1 | head -20; }
    echo
    echo "== ARP-таблица (колонки Яндекса: b8:87:6e):"
    arp -an 2>&1 | head -40
} > "$W/net.txt" 2>&1

# автопоиск колонки, если IP не дан
if [ -z "$COLUMN" ]; then
    if [ "$OS" = "Darwin" ]; then
        COLUMN="$(arp -an 2>/dev/null | grep -i 'b8:87:6e' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^169\.254\.' | head -1)"
    else
        COLUMN="$(ip neigh 2>/dev/null | grep -i 'b8:87:6e' | awk '{print $1}' | grep -v '^169\.254\.' | head -1)"
        [ -z "$COLUMN" ] && COLUMN="$(arp -an 2>/dev/null | grep -i 'b8:87:6e' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^169\.254\.' | head -1)"
    fi
fi
{ echo; echo "== колонка: ${COLUMN:-не найдена}"; } >> "$W/net.txt"
echo "== колонка (определена): ${COLUMN:-не найдена}" >> "$W/answers.txt"

# ---------------------------------------------------------------- DNS
q() {  # q <имя> [сервер]
    if have dig; then
        if [ -n "${2:-}" ]; then dig +time=3 +tries=1 +short "$1" @"$2" 2>&1 | head -5
        else dig +time=3 +tries=1 +short "$1" 2>&1 | head -5; fi
    else
        if [ -n "${2:-}" ]; then nslookup "$1" "$2" 2>&1 | awk '/Address: |Name:/{print}' | tail -5
        else nslookup "$1" 2>&1 | awk '/Address: |Name:/{print}' | tail -5; fi
    fi
}
{
    echo "== системный резолвер:"
    if [ "$OS" = "Darwin" ]; then
        scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | sort -u | head -10
    else
        grep nameserver /etc/resolv.conf 2>/dev/null
    fi
    echo
    for d in quasar.yandex.net yandex.ru okko.tv music.yandex.ru alice.yandex.net; do
        echo "-- $d (система): $(q "$d" "" 2>/dev/null || true)"
    done
    echo
    echo "== через этот стенд ($MYIP):"
    for d in quasar.yandex.net yandex.ru okko.tv music.yandex.ru; do
        echo "-- $d: $(q "$d" "$MYIP" 2>/dev/null | tr '\n' ' ')"
    done
    echo
    echo "== контроль (8.8.8.8 — работает ли интернет вообще):"
    echo "-- ya.ru: $(q ya.ru 8.8.8.8 2>/dev/null | tr '\n' ' ')"
} > "$W/dns.txt" 2>&1

# ---------------------------------------------------------------- колонка: пинг/порты
{
    echo "== пинг ${COLUMN:--}:"
    if [ -n "$COLUMN" ]; then
        if [ "$OS" = "Darwin" ]; then ping -c2 -W1000 "$COLUMN" 2>&1 | tail -4
        else ping -c2 -W2 "$COLUMN" 2>&1 | tail -4; fi
    fi
    echo
    echo "== слушатели 53/80/443:"
    L="$(lsof -nP -iTCP:80 -iTCP:443 -iUDP:53 -sTCP:LISTEN 2>/dev/null | head -20)"
    if [ -z "$L" ]; then
        if [ "$OS" = "Darwin" ]; then
            netstat -an -p tcp 2>/dev/null | awk '$NF=="LISTEN"' | grep -E '\.(53|80|443) ' | head -10
            netstat -an -p udp 2>/dev/null | grep -E '\.(53) ' | head -5
        else
            (ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null) | grep -E ':(53|80|443)\b' | head -20
        fi
    else
        echo "$L"
    fi
    echo
    echo "== процессы стенда:"
    ps -Ao pid,args 2>/dev/null | grep -E "[e]quasar_server|[q]uasar" | head -10
} > "$W/ports.txt" 2>&1

# ---------------------------------------------------------------- DHCP / нет интернета
LINKLOCAL=0
case "${COLUMN:-}" in 169.254.*) LINKLOCAL=1 ;; esac
PING_OK=0
if [ -n "$COLUMN" ]; then
    if [ "$OS" = "Darwin" ]; then ping -c1 -W1000 "$COLUMN" >/dev/null 2>&1 && PING_OK=1
    else ping -c1 -W1 "$COLUMN" >/dev/null 2>&1 && PING_OK=1; fi
fi
COL_MAC="$( [ -n "$COLUMN" ] && arp -an 2>/dev/null | grep -F "($COLUMN)" | grep -oE '([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}' | head -1 )"
LEASE_LINE="$(command -v dhcp-lease-list >/dev/null 2>&1 && dhcp-lease-list 2>/dev/null | head -20)"

{
    echo "== колонка: ${COLUMN:-не найдена}"
    echo "== MAC: ${COL_MAC:-неизвестен}"
    echo "== link-local (169.254.x.x, т.е. DHCP не сработал): $([ "$LINKLOCAL" = "1" ] && echo ДА || echo нет)"
    echo "== пинг: $([ "$PING_OK" = "1" ] && echo ок || echo НЕ ОТВЕЧАЕТ)"
    echo
    echo "== ARP-строки для этого MAC:"
    [ -n "${COL_MAC:-}" ] && arp -an 2>/dev/null | grep -i "$COL_MAC" || echo "(нет)"
    echo
    echo "== DHCP-аренды на этой машине (если есть):"
    echo "${LEASE_LINE:-(не применимо)}"
} > "$W/dhcp.txt" 2>&1

if [ "$CHOICE" = "4" ] || [ "$LINKLOCAL" = "1" ] || [ "$PING_OK" = "0" ]; then
    {
        echo "КОЛОНКА НЕ ПОЛУЧАЕТ АДРЕС / НЕТ ИНТЕРНЕТА"
        echo
        if [ "$LINKLOCAL" = "1" ]; then
            echo "В ARP у колонки ${COLUMN} — адрес 169.254.x.x."
            echo "Это значит: DHCP ей адрес НЕ ВЫДАЛ, и она назначила его сама себе."
            echo
        fi
        echo "Что проверить на роутере (по порядку):"
        echo
        echo "1) DHCP вообще включён? Какой пул и срок аренды?"
        echo "   (обычно 192.168.0.100-250, lease 24h)"
        echo
        echo "2) В списке аренд найди MAC колонки: ${COL_MAC:-b8:87:6e:xx:xx:xx}"
        echo "   - если аренда есть, но колонка её не берёт — удали эту аренду;"
        echo "   - если аренда старая/от другой сети — тоже удали."
        echo
        echo "3) Убери статическую привязку (reservation) для этого MAC."
        echo "   Нужно, чтобы колонка САМА выбрала свободный адрес из пула,"
        echo "   а не пыталась получить зарезервированный/чужой."
        echo
        echo "4) Проверь, что не мешает:"
        echo "   - изоляция клиентов / AP isolation / 'гостевая сеть';"
        echo "   - MAC-фильтр;"
        echo "   - лимит клиентов на DHCP или на Wi-Fi;"
        echo "   - второй DHCP-сервер в сети (роутер + что-то ещё)."
        echo
        echo "5) Перезагрузи колонку (вынуть из розетки на 10 с)."
        echo "   После старта она должна получить адрес и появиться в арендах."
        echo
        echo "6) Если адрес так и не появился — временно поставь в роутере"
        echo "   DHCP-пул пошире и lease покороче (1h), затем снова перезагрузи."
        echo
        echo "7) Когда адрес появился — проверь доступность:"
        echo "   ping ${COLUMN:-<ip>} и порт 5555 (ADB)."
    } > "$W/advice.txt"
    echo
    echo "!!! DHCP: $([ "$LINKLOCAL" = "1" ] && echo "колонка на 169.254 — адрес ей не выдали" || echo "колонка не отвечает/без адреса")"
    echo "    Подробный чек-лист по DHCP — advice.txt в архиве."
fi

# ---------------------------------------------------------------- пробы стенда
probe() {  # probe <имя-файла> <curl-аргументы...>
    local name="$1"; shift
    local code
    code="$(curl -sk -m 25 -o "$W/probe/$name" -w '%{http_code} %{time_total}s %{size_download}b' "$@" 2>&1)"
    echo "-- $name -> $code" >> "$W/probe/_index.txt"
}
HOST_IP="${MYIP:-127.0.0.1}"
echo "== пробы стенда (127.0.0.1 и $HOST_IP):" > "$W/probe/_index.txt"
for H in 127.0.0.1 "$HOST_IP"; do
    [ "$H" = "127.0.0.1" ] && P="" || P="${H//./_}_"
    probe "${P}generate_204.txt"   -I "http://$H/generate_204"
    probe "${P}root.txt"           "http://$H/"
    probe "${P}check_updates.json" "http://$H/check_updates?device_id=DIAG&version=0.0.0&platform=yandexmicro"
    probe "${P}sync.json"          "http://$H/get_sync_info?device_id=DIAG&version=0.0.0&platform=yandexmicro"
    probe "${P}https_root.txt"     "https://$H/"
done
cat "$W/probe/_index.txt"

# ---------------------------------------------------------------- прошивка
{
    echo "== файлы firmware/:"
    if [ -d firmware ]; then
        find firmware -type f 2>/dev/null | sort | while read -r f; do
            printf '%12s  %s\n' "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" "$f"
        done
    else
        echo "(папки firmware/ нет)"
    fi
    echo
    echo "== manifest.json:"
    for m in firmware/manifest.json firmware/*/manifest.json; do
        [ -f "$m" ] && { echo "-- $m"; cat "$m"; echo; }
    done
    echo
    echo "== проверка zip (магия, crc32, sha256, совпадение с manifest):"
    find firmware -name '*.zip' -type f 2>/dev/null | sort | while read -r z; do
        magic="$(head -c 2 "$z" 2>/dev/null)"
        size="$(wc -c < "$z" | tr -d ' ')"
        crc="-"; sha="-"
        if have python3; then
            crc="$(python3 - "$z" <<'PY' 2>/dev/null
import sys, zlib
try:
    print(zlib.crc32(open(sys.argv[1], "rb").read()) & 0xFFFFFFFF)
except Exception:
    print("-")
PY
)"
        elif have crc32; then crc="$(crc32 "$z" 2>/dev/null)"
        fi
        if have shasum; then sha="$(shasum -a 256 "$z" 2>/dev/null | awk '{print $1}')"
        elif have sha256sum; then sha="$(sha256sum "$z" 2>/dev/null | awk '{print $1}')"; fi
        echo "-- $z"
        echo "   размер: $size б"
        echo "   магия:  '${magic}' $([ "$magic" = "PK" ] && echo OK || echo 'НЕ ZIP!')"
        echo "   crc32:  $crc"
        echo "   sha256: $sha"
        [ "$size" = "33212" ] && echo "   !!! обрезанный файл (33212 б) — качать из downloadUrl, а не с зеркала"
    done
} > "$W/firmware.txt" 2>&1

# ---------------------------------------------------------------- дерево/гит/конфиг/серты
{
    echo "== дерево (2 уровня, без .git/log):"
    find . -maxdepth 2 -not -path './.git*' -not -path './log/*' -not -path './.diag-*' 2>/dev/null | sort | head -200
    echo
    echo "== флаги run/:"
    ls -la run 2>/dev/null || echo "(пусто)"
    echo
    echo "== git:"
    git rev-parse --short HEAD 2>&1
    git log -3 --oneline 2>&1
    echo "-- изменения:"; git status --porcelain 2>&1 | head -20
} > "$W/tree.txt" 2>&1

{
    echo "== переменные окружения (значимые):"
    for v in LOCAL_IP COLUMN_IPS MIRROR_URL SYNC_LOCAL SYNC_RETRIES SYNC_RETRY_DELAY UPSTREAM_TIMEOUT DNS_PORT HTTP_PORT HTTPS_PORT; do
        eval "val=\${$v:-}"
        [ -n "${val:-}" ] && echo "$v=$val"
    done
    echo
    echo "== config/:"
    for f in config/*; do [ -f "$f" ] && { echo "-- $f"; cat "$f"; echo; }; done
} 2>&1 | mask > "$W/config.txt"

{
    echo "== сертификаты:"
    for c in certs/fullchain.pem certs/cert.pem certs/*.pem; do
        [ -f "$c" ] || continue
        echo "-- $c"
        openssl x509 -in "$c" -noout -subject -issuer -dates 2>&1 | head -5
    done
    echo
    echo "== ключи (только наличие/права):"
    ls -l certs 2>/dev/null
} > "$W/certs.txt" 2>&1

# ---------------------------------------------------------------- логи
for f in log/*.log log/server.log; do
    [ -f "$f" ] || continue
    tail -n 5000 "$f" 2>&1 | mask > "$W/logs/$(basename "$f")"
done
[ -f log/sync_real.json ] && cp log/sync_real.json "$W/logs/sync_real.json" 2>/dev/null

# ---------------------------------------------------------------- опись
{
    echo "lite-kit — диагностика от $(date)"
    echo
    echo "answers.txt   — что выбрал и что дословно говорит колонка"
    echo "system.txt    — ОС, python, окружение"
    echo "net.txt       — адреса, маршруты, DNS, ARP (колонки: b8:87:6e)"
    echo "dns.txt       — ответы DNS для quasar/yandex/okko/music"
    echo "ports.txt     — кто слушает 53/80/443 + процессы стенда"
    echo "dhcp.txt      — адрес/MAC колонки, link-local, ARP, аренды"
    echo "advice.txt    — что делать, если колонка не получила IP (нет интернета)"
    echo "probe/        — ответы самого стенда: generate_204, check_updates, sync"
    echo "firmware.txt  — что лежит в firmware/: размер, zip-магия, crc32, sha256"
    echo "tree.txt      — структура папки, флаги run/, состояние git"
    echo "config.txt    — config/ и переменные (токены замаскированы)"
    echo "certs.txt     — срок/издатель сертификатов"
    echo "logs/         — последние 5000 строк yandex/local/dns/server (замаскированы)"
    echo
    echo "Секреты (токены, куки) вырезаны автоматически."
} > "$W/README.txt"

# ---------------------------------------------------------------- архив
mkdir -p "$OUT" 2>/dev/null
ZIP="$OUT/lite-kit-diag-$STAMP.zip"
TGZ="$OUT/lite-kit-diag-$STAMP.tgz"
ok=0
if have zip; then
    ( cd "$W" && zip -qr "$ZIP" . ) && ok=1
fi
if [ "$ok" = "0" ]; then
    ( cd "$W" && tar czf "$TGZ" . ) && ZIP="$TGZ" && ok=1
fi
if [ "$ok" = "0" ]; then
    echo "[!] не смог упаковать (нет zip и tar). Собранное лежит в: $W"
    exit 1
fi

SIZE="$(wc -c < "$ZIP" | tr -d ' ')"
rm -rf "$W"

hr
echo "[+] готово: $ZIP"
echo "    размер: $((SIZE / 1024)) КБ"
echo
echo "    Внутри: ответы, логи, DNS, пробы стенда, прошивка, дерево, конфиг."
echo "    Отправь этот архив целиком — по нему видно, что сломалось."
hr
[ "$OS" = "Darwin" ] && open -R "$ZIP" 2>/dev/null
exit 0
