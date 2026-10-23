#!/bin/sh
# qsdmn.sh — управление quasar daemon'ом прямо на станции (без ПК).
#
#   ./qsdmn.sh stop      — остановить квазар (Алиса замолкает, микрофон выключен)
#   ./qsdmn.sh start     — запустить квазар
#   ./qsdmn.sh restart   — перезапустить квазар
#   ./qsdmn.sh status    — что сейчас запущено
#   ./qsdmn.sh reboot    — перезагрузить СТАНЦИЮ
#
# Пока идёт команда — индикация: кольцо анимируется (Lite/Micro),
# у моделей с часами (много светодиодов) все диоды горят на полную.
set -u

QUASAR=/system/vendor/quasar
RUN="$QUASAR/run.sh"
LAUNCHER=quasar_launcher2
LEDROOT=/sys/class/leds
LOG=/tmp/qsdmn.log
ANIM_PID=""

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }

leds() { ls -d "$LEDROOT"/* 2>/dev/null; }

maxb() { cat "$1/max_brightness" 2>/dev/null || echo 255; }

ledset() { [ -w "$1/brightness" ] && echo "$2" >"$1/brightness" 2>/dev/null; }

# все диоды на полную
led_full() {
    for l in $(leds); do ledset "$l" "$(maxb "$l")"; done
}

led_off() {
    for l in $(leds); do ledset "$l" 0; done
}

# бегущий огонь по кольцу; $1 — цвет (red/green/blue), $2 — сколько кругов
anim() {
    color="${1:-blue}"
    rings="${2:-3}"
    n=0
    while :; do
        for r in 0 1 2 3 4 5 6 7; do
            for l in $(leds); do
                case "$l" in
                *":$color:ring$r"*) ledset "$l" "$(maxb "$l")" ;;
                *":$color:"*) ledset "$l" 0 ;;
                esac
            done
            sleep 0.12
        done
        n=$((n + 1))
        [ "$n" -ge "$rings" ] && break
    done
    led_off
}

# индикация: start — зелёный, stop — красный, reboot — красный на полную
indicate() {
    case "$1" in
    start) anim green 1 ;;
    stop) anim red 1 ;;
    reboot) led_full ;;
    *) anim blue 1 ;;
    esac
}

indicate_async() {
    total=$(ls -d "$LEDROOT"/* 2>/dev/null | wc -l)
    if [ "$total" -gt 12 ]; then
        # модель с часами: фулл-заливка
        led_full
        ANIM_PID=""
    else
        indicate "$1" &
        ANIM_PID=$!
    fi
}

indicate_done() {
    [ -n "$ANIM_PID" ] && kill "$ANIM_PID" 2>/dev/null
    ANIM_PID=""
    led_off
}

ka() { # kill по имени, без pkill
    for p in $(pidof "$1" 2>/dev/null); do kill "$p" 2>/dev/null; done
}

stop_all() {
    # сначала супервизор: иначе он поднимет детей обратно
    ka "$LAUNCHER"
    sleep 1
    ka maind
    sleep 1
    for p in $(pidof "$LAUNCHER" 2>/dev/null) $(pidof maind 2>/dev/null); do
        kill -9 "$p" 2>/dev/null
    done
    sleep 1
    if [ -n "$(pidof maind 2>/dev/null)$(pidof "$LAUNCHER" 2>/dev/null)" ]; then
        echo "не удалось остановить quasar"
        return 1
    fi
    echo "quasar остановлен"
}

start_all() {
    if [ -n "$(pidof "$LAUNCHER" 2>/dev/null)" ]; then
        echo "quasar уже запущен"
        return 0
    fi
    sh "$RUN" >/dev/null 2>&1
    sleep 3
    if [ -z "$(pidof maind 2>/dev/null)" ]; then
        echo "quasar не поднялся (см. /data/quasar/launcher2.out)"
        return 1
    fi
    echo "quasar запущен"
}

status() {
    l=$(pidof "$LAUNCHER" 2>/dev/null)
    p=$(pidof maind 2>/dev/null)
    echo "launcher: ${l:-нет}"
    echo "maind:    ${p:-нет}"
    [ -n "$p" ] && ps | grep "[m]aind" | sed 's/^/  /'
}

case "${1:-}" in
stop)
    indicate_async stop
    log "stop"
    stop_all
    rc=$?
    indicate_done
    exit $rc
    ;;
start)
    indicate_async start
    log "start"
    start_all
    rc=$?
    indicate_done
    exit $rc
    ;;
restart)
    indicate_async stop
    log "restart"
    stop_all
    indicate_done
    indicate_async start
    start_all
    rc=$?
    indicate_done
    exit $rc
    ;;
reboot)
    indicate_async reboot
    log "reboot"
    sync
    sleep 1
    reboot
    ;;
status)
    status
    ;;
*)
    echo "использование: $0 {start|stop|restart|status|reboot}"
    exit 1
    ;;
esac
