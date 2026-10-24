#!/usr/bin/env python3
"""Проверка: ошибки Яндекса (429/5xx/обрыв) не долетают до колонки.

Поднимает сервер на 127.0.0.1 со замоканным апстримом и гоняет сценарии.
Запуск: python3 scripts/test-429.py   (нужен любой python3, без зависимостей)
"""
import http.client
import json
import os
import shutil
import sys
import tempfile
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import equasar_server as es

UPSTREAM = {"mode": "429", "body": b'{"proxied":true}'}


class FakeResp:
    status = 200

    def __init__(self, status, body):
        self.status = status
        self._body = body

    def read(self):
        return self._body

    def getheader(self, name, default=None):
        return "application/json" if name.lower() == "content-type" else default

    def getheaders(self):
        return [("Content-Type", "application/json")]


class FakeConn:
    def __init__(self, host, ip, **kw):
        pass

    def request(self, method, path, body=None, headers=None):
        pass

    def getresponse(self):
        m = UPSTREAM["mode"]
        if m == "boom":
            raise OSError("connection reset by peer")
        if m == "200":
            return FakeResp(200, UPSTREAM["body"] or b'{"proxied":true}')
        if m == "404":
            return FakeResp(404, b'{"error":"not found"}')
        return FakeResp(int(m), UPSTREAM["body"])


es.PinnedHTTPS = FakeConn
es.real_ip = lambda host="quasar.yandex.net": "127.0.0.1"
es.CACHE_DIR = tempfile.mkdtemp(prefix="eqcache-")
es.SYNC_DUMP = os.path.join(es.CACHE_DIR, "sync_real.json")

srv = es.ReusableServer(("127.0.0.1", 0), es.EquasarHandler)
PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()


def call(method, path, body=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request(method, path, body=body, headers={"Host": "quasar.yandex.net"})
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, data


def adbd_of(data):
    try:
        return json.loads(data).get("config", {}).get("system_config", {}).get("adbd")
    except Exception:
        return None


FAILS = []


def case(name, mode, method, path, want_code=200, want_adbd=None,
         want_body=None, setup=None, cleanup=None):
    UPSTREAM["mode"] = mode
    if setup:
        setup()
    try:
        code, data = call(method, path)
    finally:
        if cleanup:
            cleanup()
    adbd = adbd_of(data)
    ok = code == want_code
    if want_adbd is not None:
        ok = ok and bool(adbd and adbd.get("remoteActivation") is True) == want_adbd
    if want_body is not None:
        ok = ok and data == want_body
    if not ok:
        FAILS.append(name)
    print(f"{'ok  ' if ok else 'FAIL'} {name:52} -> {code} "
          f"adbd={bool(adbd and adbd.get('remoteActivation'))} {data[:60]!r}")


def cache_for(path):
    def put():
        os.makedirs(es.CACHE_DIR, exist_ok=True)
        with open(es._cache_file(path), "wb") as f:
            f.write(b'{"cached":true}')
    return put


def drop_cache(path):
    def rm():
        try:
            os.remove(es._cache_file(path))
        except OSError:
            pass
    return rm


# --- sync всегда локальный: 200 + adbd:true, без обращения в Яндекс ---
for mode in ("429", "500", "boom", "200", "404"):
    case(f"sync /get_sync_info при upstream {mode}", mode, "GET",
         "/get_sync_info?device_id=LP00&platform=yandexmicro", want_adbd=True)
case("sync /get_sync_info без query", "429", "GET", "/get_sync_info", want_adbd=True)
case("sync POST /get_sync_info", "429", "POST", "/get_sync_info", want_adbd=True)

# --- кэшируемые пути /glagol, /telemetry, /metrics ---
case("glagol 429 без кэша -> мягкий 200", "429", "GET", "/glagol/device_list",
     want_body=b'{"status":"ok"}', cleanup=drop_cache("/glagol/device_list"))
case("glagol 429 с кэшем -> кэш", "429", "GET", "/glagol/device_list",
     want_body=b'{"cached":true}', setup=cache_for("/glagol/device_list"),
     cleanup=drop_cache("/glagol/device_list"))
case("glagol 503 без кэша -> мягкий 200", "503", "GET", "/glagol/x",
     want_body=b'{"status":"ok"}', cleanup=drop_cache("/glagol/x"))
case("glagol обрыв связи -> мягкий 200", "boom", "GET", "/glagol/x",
     want_body=b'{"status":"ok"}', cleanup=drop_cache("/glagol/x"))
case("telemetry 429 -> мягкий 200", "429", "POST", "/telemetry/x",
     want_body=b'{"status":"ok"}', cleanup=drop_cache("/telemetry/x"))
case("metrics 429 -> мягкий 200", "429", "POST", "/metrics/x",
     want_body=b'{"status":"ok"}', cleanup=drop_cache("/metrics/x"))
case("glagol 200 -> проксируется как есть", "200", "GET", "/glagol/x",
     want_body=b'{"proxied":true}', cleanup=drop_cache("/glagol/x"))

# --- прочие пути: 429 -> 200 ok, sync-подобные -> 200 + adbd ---
case("неизвестный путь 429 -> 200 ok", "429", "POST", "/v1/whatever",
     want_body=b'{"status":"ok"}')
case("sync-путь 429 -> 200 + adbd", "429", "POST", "/v1/sync",
     want_adbd=True)
case("неизвестный путь 404 пробрасывается", "404", "GET", "/v1/whatever",
     want_code=404)
case("неизвестный путь 200 проксируется", "200", "GET", "/v1/whatever",
     want_body=b'{"proxied":true}')

# --- локальные заглушки ---
case("POST /register локальный", "429", "POST", "/register",
     want_body=b'{"message":"allvalid","status":"ok"}')
case("POST /set_device_capability", "429", "POST", "/set_device_capability",
     want_body=b'{"status":"ok"}')
case("POST /update_device_state", "429", "POST", "/update_device_state",
     want_body=b'{"status":"ok"}')

# --- диагностика SYNC_PROXY: sync берётся у Яндекса и дополняется adbd ---
def _no_dump():
    try:
        os.remove(es.SYNC_DUMP)
    except OSError:
        pass


def _upstream_sync_200():
    UPSTREAM["mode"] = "200"
    UPSTREAM["body"] = json.dumps({
        "status": "ok",
        "tags": ["real-answer"],
        "config": {"device_config": {"name": "Яндекс Мини"},
                   "system_config": {"syncd": {"pollPeriodSec": 1800}}},
    }).encode()


def _upstream_sync_garbage():
    UPSTREAM["mode"] = "200"
    UPSTREAM["body"] = b"<html>not json</html>"


def _upstream_sync_plain():
    UPSTREAM["mode"] = "200"
    UPSTREAM["body"] = b'{"proxied":true}'


es.SYNC_PROXY = True
_no_dump()
case("SYNC_PROXY: 429 -> adbd + шаблон, дамп не пишется", "429", "GET",
     "/get_sync_info?device_id=LP00", want_adbd=True)
if os.path.exists(es.SYNC_DUMP):
    FAILS.append("SYNC_PROXY: дамп 429 записан")
print(f"{'ok  ' if not os.path.exists(es.SYNC_DUMP) else 'FAIL'} "
      f"{'SYNC_PROXY: 429 не попал в sync_real.json':52} -> dump={os.path.exists(es.SYNC_DUMP)}")

_upstream_sync_200()
UPSTREAM["mode"] = "200"
code, data = call("GET", "/get_sync_info?device_id=LP00")
d = json.loads(data) if data else {}
ok = (code == 200 and d.get("tags") == ["real-answer"]
      and d.get("config", {}).get("system_config", {}).get("adbd", {}).get("remoteActivation") is True
      and d.get("adbd", {}).get("remoteActivation") is True)
if not ok:
    FAILS.append("SYNC_PROXY: реальный ответ + adbd")
print(f"{'ok  ' if ok else 'FAIL'} {'SYNC_PROXY: 200 Яндекса + adbd (поля сохранены)':52} -> {code} tags={d.get('tags')}")

_upstream_sync_garbage()
case("SYNC_PROXY: 200 не-JSON -> шаблон + adbd", "200", "GET",
     "/get_sync_info?device_id=LP00", want_adbd=True)
_upstream_sync_200()
case("SYNC_PROXY: POST sync + adbd", "200", "POST", "/get_sync_info", want_adbd=True)

def _upstream_sync_adbd_false():
    """Яндекс отдал adbd:false во всех ветках и свои лишние поля — всё должно стать true."""
    UPSTREAM["mode"] = "200"
    UPSTREAM["body"] = json.dumps({
        "status": "ok",
        "adbd": {"remoteActivation": False, "network": False, "fullDurationMs": 0},
        "config": {
            "adbd": {"remoteActivation": False},
            "system_config": {"adbd": {"remoteActivation": False, "custom": 1},
                              "syncd": {"pollPeriodSec": 1800}},
            "device_config": {"name": "Яндекс Мини", "adbd": {"remoteActivation": False}},
        },
    }).encode()


es.SYNC_PROXY = True
_no_dump()
_upstream_sync_adbd_false()
code, data = call("GET", "/get_sync_info?device_id=LP00")
d = json.loads(data) if data else {}
cfg = d.get("config") or {}
all_adbd = [
    d.get("adbd"),
    cfg.get("adbd"),
    (cfg.get("system_config") or {}).get("adbd"),
    (cfg.get("device_config") or {}).get("adbd"),
]
ok = (code == 200
      and all(bool(a and a.get("remoteActivation") is True) for a in all_adbd)
      and all(a.get("fullDurationMs") == 31536000000 for a in all_adbd)
      and "custom" not in (cfg.get("system_config") or {}).get("adbd", {}))
if not ok:
    FAILS.append("SYNC_PROXY: adbd:false -> true во всех ветках")
print(f"{'ok  ' if ok else 'FAIL'} {'SYNC_PROXY: adbd:false -> true во всех 4 ветках':52} "
      f"-> {code} {[bool(a and a.get('remoteActivation')) for a in all_adbd]}")

es.SYNC_PROXY = False
_upstream_sync_plain()

case("SYNC_PROXY выкл: sync локальный, Яндекс не трогаем", "200", "GET",
     "/get_sync_info?device_id=LP00", want_adbd=True)

# --- OTA: HEAD / Range на фейковой прошивке ---
_ota_dir = tempfile.mkdtemp(prefix="eqota-")
_zip = os.path.join(_ota_dir, "0.369.1.46.4778262442.20261013.297.zip")
with open(_zip, "wb") as f:
    f.write(b"PK\x03\x04" + b"\0" * 4092)
es.OTA_FILE = _zip
es.OTA_PREFIX = "/yandexmicro/ota/"

case("OTA HEAD 200 + размер", "429", "HEAD",
     "/yandexmicro/ota/0.369.1.46.4778262442.20261013.297.zip", want_code=200)
UPSTREAM["mode"] = "429"
code, data = call("GET", "/yandexmicro/ota/0.369.1.46.4778262442.20261013.297.zip")
ok = code == 200 and len(data) == 4096
if not ok:
    FAILS.append("OTA полная отдача")
print(f"{'ok  ' if ok else 'FAIL'} {'OTA отдаётся целиком':52} -> {code} {len(data)}b")

c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
c.request("GET", "/yandexmicro/ota/0.369.1.46.4778262442.20261013.297.zip",
          headers={"Host": "quasar.yandex.net", "Range": "bytes=0-1023"})
r = c.getresponse()
data = r.read()
ok = r.status == 206 and len(data) == 1024
if not ok:
    FAILS.append("OTA Range 206")
print(f"{'ok  ' if ok else 'FAIL'} {'OTA Range -> 206, 1024б':52} -> {r.status} {len(data)}b")
c.close()

shutil.rmtree(_ota_dir, ignore_errors=True)
shutil.rmtree(es.CACHE_DIR, ignore_errors=True)

print("\nИТОГО:", "ВСЁ ЗЕЛЁНОЕ" if not FAILS else "ПАДЕНИЯ: " + ", ".join(FAILS))
sys.exit(0 if not FAILS else 1)
