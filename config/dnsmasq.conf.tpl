# DNS-стенд: quasar.* -> этот мак, остальное — в интернет
# __MACIP__ подставляется start.sh
no-resolv
server=1.1.1.1
server=8.8.8.8
server=77.88.8.8

listen-address=__MACIP__
listen-address=127.0.0.1
bind-interfaces

# наши подмены (A)
address=/quasar.yandex.net/__MACIP__
address=/quasar.yandex.ru/__MACIP__
address=/scbh.yandex.net/__MACIP__

# AAAA -> NODATA, иначе колонка уйдёт на настоящий IPv6 мимо нас
# AAAA не отдаём вообще: иначе станция получает "::" и пытается в IPv6
filter-AAAA

# поддомены не перехватываем
server=/iot.quasar.yandex.ru/1.1.1.1
server=/iot.quasar.yandex.net/1.1.1.1

cache-size=2000
log-queries
log-facility=__LOGDIR__/dnsmasq.log
pid-file=__RUNDIR__/dnsmasq.pid
