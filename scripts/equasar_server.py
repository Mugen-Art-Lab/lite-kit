#!/usr/bin/env python3
"""
equasar_server.py — Кроссплатформенный локальный сервер eQuasar (Linux / Windows / macOS)
Имитирует сервер активации Яндекса, отдавая Станции Лайт команду на включение постоянного ADB
или манифест даунгрейда на уязвимую прошивку.
Работает на портах 80 (HTTP) и 443 (HTTPS) с встроенными сертификатами eMudhra.
"""

import http.server
import ssl
import sys
import os
import threading
import socketserver
import argparse
import socket
import http.client
import json
import time
import urllib.request

UPSTREAM_HOST = "quasar.yandex.net"


def real_ip(host=UPSTREAM_HOST):
    """Настоящий IP через DoH (локальный DNS отдаёт нам .56, поэтому спрашиваем Google)."""
    try:
        u = "https://dns.google/resolve?name=%s&type=A" % host
        d = json.loads(urllib.request.urlopen(u, timeout=5).read())
        for a in d.get("Answer", []):
            if a.get("type") == 1:
                return a["data"]
    except Exception:
        pass
    return "213.180.193.230"


class PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, ip, **kw):
        super().__init__(host, **kw)
        self._ip = ip

    def connect(self):
        self.sock = socket.create_connection((self._ip, self.port or 443), self.timeout)
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.host)

SYNC_INFO_PAYLOAD = b'{"status":"ok","config":{"account_config":{"spotter":"alisa"},"device_config":{"name":"quasar"},"system_config":{"adbd":{"remoteActivation":true,"network":true,"fullDurationMs":31536000000}},"adbd":{"remoteActivation":true,"network":true,"fullDurationMs":31536000000}},"subscription":{"mode":"transaction"}}'

NO_UPDATE_PAYLOAD = b'{"hasUpdate":false}'

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _local_ip():
    """IP этой машины в локалке — чтобы колонка могла скачать прошивку с нас."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def _find_ota():
    """Ищем образ прошивки и метаданные в firmware/ (модель может быть любой)."""
    import glob
    d = os.path.join(BASE_DIR, "firmware")
    zips = sorted(glob.glob(os.path.join(d, "*.zip")))
    meta = {}
    try:
        meta = json.load(open(os.path.join(d, "manifest.json"), encoding="utf-8"))
    except Exception:
        pass
    if not zips:
        return None, meta
    # если в манифесте указан filename — берём его, иначе самый свежий по имени
    want = meta.get("filename")
    path = os.path.join(d, want) if want and os.path.exists(os.path.join(d, want)) else zips[-1]
    return path, meta


OTA_FILE, OTA_META = _find_ota()
_OTA_NAME = os.path.basename(OTA_FILE) if OTA_FILE else ""


def _guess_platform(name):
    """0.xxx — Lite/Micro, 1.xxx — Mini/Midi (по ветке версии в имени файла)."""
    b = os.path.basename(name or "")
    return "yandexstation" if b.startswith("1.") else "yandexmicro"


# версия и модель берутся ИЗ ИМЕНИ ФАЙЛА — манифест в firmware/ может быть устаревшим
OTA_VERSION = _OTA_NAME[:-4] if _OTA_NAME.endswith(".zip") else _OTA_NAME
OTA_PLATFORM = _guess_platform(_OTA_NAME)
OTA_PREFIX = "/%s/ota/" % OTA_PLATFORM
_OTA_CRC = {"v": None}


def _ota_crc():
    """CRC32 реального файла (с кэшем). Манифесту не доверяем — он часто не совпадает."""
    if _OTA_CRC["v"] is not None:
        return _OTA_CRC["v"]
    if not OTA_FILE or not os.path.exists(OTA_FILE):
        return 0
    import zlib
    crc = 0
    with open(OTA_FILE, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            crc = zlib.crc32(chunk, crc)
    _OTA_CRC["v"] = crc & 0xFFFFFFFF
    return _OTA_CRC["v"]


def _downgrade_payload():
    name = os.path.basename(OTA_FILE) if OTA_FILE else ""
    return json.dumps({
        "hasUpdate": True,
        "version": OTA_VERSION,
        "downloadUrl": "https://quasar.yandex.net" + OTA_PREFIX + name,
        "crc32": _ota_crc(),
        "critical": True,
        "fallbackUrl": "https://quasar.yandex.net" + OTA_PREFIX + name,
        "fallbackIp": LOCAL_IP,
        "updateId": "150484",
    }).encode()


# --- опциональные настройки через окружение (все необязательные) ---
LOCAL_IP = os.environ.get("LOCAL_IP") or _local_ip()
COLUMN_IPS = {ip.strip() for ip in os.environ.get("COLUMN_IPS", "").split(",") if ip.strip()}
COLUMN_ID = os.environ.get("COLUMN_ID", "LP00000000000001982300007d20fe15")

MODE_DOWNGRADE = False
BUILD = "V7-LOCAL-SYNC"
MODE_PASSTHROUGH = False   # всё прозрачно в настоящий Яндекс (диагностика)
MODE_OTA_ONLY = False      # только прошивка: /check_updates + zip, остальное — в Яндекс (Mini)
SYNC_PROXY = os.environ.get("SYNC_PROXY") == "1"   # sync: настоящий ответ Яндекса + adbd
# повторы при 429/5xx: сколько всего попыток и пауза между ними
RETRY_ATTEMPTS = max(1, int(os.environ.get("SYNC_RETRIES", "3")))
RETRY_DELAY = max(0.0, float(os.environ.get("SYNC_RETRY_DELAY", "2.5")))


SYNC_DUMP = os.path.join(BASE_DIR, "log", "sync_real.json")
SYNC_TEMPLATE = os.path.join(BASE_DIR, "log", "sync_template.json")
# базовый шаблон — «обычные» станции, он лежит в репозитории и не зависит от Mini
SYNC_BASE = os.path.join(BASE_DIR, "scripts", "sync_template.json")
ADBD = {"remoteActivation": True, "network": True, "fullDurationMs": 31536000000}

_TEMPLATE = {"loaded": False, "data": None}


def _sanitize(d):
    """Убираем из шаблона секреты и привязку к конкретному устройству."""
    if not isinstance(d, dict):
        return d
    d.pop("glagol", None)                       # там локальные серт+ключ
    cfg = d.get("config")
    if isinstance(cfg, dict):
        acc = cfg.get("account_config")
        if isinstance(acc, dict):
            acc.pop("user_wifi_config", None)   # хеш Wi-Fi пользователя
        dev = cfg.get("device_config")
        if isinstance(dev, dict):
            dev.pop("location", None)           # координаты пользователя
    return d


def _load_template():
    """Шаблон: базовый (Lite) -> сгенерированный; дамп Mini — только по USE_SYNC_DUMP=1."""
    paths = [SYNC_BASE, SYNC_TEMPLATE]
    if os.environ.get("USE_SYNC_DUMP") == "1":
        paths.append(SYNC_DUMP)
    for path in paths:
        if not os.path.exists(path):
            continue
        try:
            d = _sanitize(json.load(open(path, encoding="utf-8")))
        except Exception:
            continue
        return d
    return None


def _inject_adbd(d):
    """Вписывает ADB во все ветки, которые читают разные прошивки."""
    cfg = d.setdefault("config", {})
    for section in ("system_config", "device_config"):
        cfg.setdefault(section, {})["adbd"] = dict(ADBD)
    cfg["adbd"] = dict(ADBD)
    d["adbd"] = dict(ADBD)
    d.setdefault("status", "ok")
    return d


def sync_payload(source=None):
    """Ответ /get_sync_info со включённым ADB — одинаково для всех моделей.

    source — готовый dict (например, настоящий ответ Яндекса); иначе шаблон.
    """
    if source is not None:
        d = json.loads(json.dumps(source))       # копия, оригинал не портим
        return json.dumps(_inject_adbd(d), ensure_ascii=False).encode()
    if not _TEMPLATE["loaded"]:
        _TEMPLATE["data"] = _load_template()
        _TEMPLATE["loaded"] = True
    base = _TEMPLATE["data"]
    if base is None:
        d = json.loads(SYNC_INFO_PAYLOAD.decode())
    else:
        d = json.loads(json.dumps(base))        # копия
    return json.dumps(_inject_adbd(d), ensure_ascii=False).encode()


OK_PAYLOAD = b'{"status":"ok"}'
# 429/5xx Яндекса колонке не отдаём вообще: она считает это провалом активации.
UPSTREAM_SOFT_ERRORS = (429,)


def is_sync_path(path):
    """Sync-подобный запрос: /get_sync_info, /sync, ... — отвечаем локально."""
    return "sync" in (path or "").lower()


def upstream_soft_error(status):
    """Ответы, которые нельзя пробрасывать колонке (лимиты и перегрузка Яндекса)."""
    return status in UPSTREAM_SOFT_ERRORS or status >= 500


# ключи, значения которых не должны попадать в лог
SECRET_MARKERS = ("token", "secret", "password", "private", "authorization",
                  "cookie", "wifi_hash", "latitude", "longitude", "certificate")


def _masked(obj):
    if isinstance(obj, dict):
        return {k: ("<скрыто>" if any(m in str(k).lower() for m in SECRET_MARKERS)
                    else _masked(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_masked(x) for x in obj]
    return obj


def _masked_json(payload):
    """JSON для лога: секреты/координаты заменены на <скрыто>."""
    try:
        return json.dumps(_masked(json.loads(payload)), ensure_ascii=False)
    except Exception:
        return payload[:1000].decode("utf-8", "replace")


CACHE_DIR = os.path.join(BASE_DIR, "log", "cache")


def _cache_file(path_qs):
    import hashlib
    return os.path.join(CACHE_DIR, hashlib.sha1(path_qs.encode()).hexdigest() + ".cache")


class EquasarHandler(http.server.BaseHTTPRequestHandler):
    # старые прошивки (Mini 2019) ждут HTTP/1.1, на HTTP/1.0 считают проверку связи неудачной
    protocol_version = "HTTP/1.1"
    def log_message(self, format, *args):
        client = self.client_address[0]
        ua = self.headers.get("User-Agent", "-")
        print(f"[{client}] {self.command} {self.path} UA={ua} -> {args[1] if len(args) > 1 else 'OK'}")
        sys.stdout.flush()

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def do_HEAD(self):
        # колонка проверяет связность через HEAD /generate_204
        if self.path.split("?")[0] == "/generate_204":
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()

    def _drain_body(self):
        self._read_body()

    def _read_body(self):
        """Читает тело запроса один раз (повторные вызовы отдают то же самое)."""
        if getattr(self, "_body", None) is None:
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                n = 0
            try:
                self._body = self.rfile.read(n) if n > 0 else b""
            except OSError:
                self._body = b""
        return self._body

    def _send_json(self, payload, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _log_sync_request(self):
        """Что именно спросила колонка: путь, заголовки, тело (секреты маскируются)."""
        body = self._read_body() if self.command in ("POST", "PUT") else b""
        hdrs = "; ".join(
            f"{k}: {'<скрыто>' if any(m in k.lower() for m in SECRET_MARKERS) else v}"
            for k, v in self.headers.items()
            if k.lower() not in ("host", "connection", "content-length"))
        print(f"  <<< [SYNC←] {self.command} {self.path} от {self.client_address[0]}")
        print(f"      заголовки: {hdrs[:800]}")
        if body:
            print(f"      тело {len(body)}b: {_masked_json(body)}")
        sys.stdout.flush()

    def _log_payload(self, tag, payload, source):
        """Что именно уходит колонке: размер, состояние adbd и сам JSON (без секретов)."""
        status = "нет данных"
        try:
            d = json.loads(payload)
            cfg = d.get("config") or {}
            marks = {
                "config.system_config.adbd": (cfg.get("system_config") or {}).get("adbd"),
                "config.device_config.adbd": (cfg.get("device_config") or {}).get("adbd"),
                "config.adbd": cfg.get("adbd"),
                "top.adbd": d.get("adbd"),
            }
            status = ", ".join(f"{k}={'on' if v else 'НЕТ'}" for k, v in marks.items())
            text = _masked_json(payload)
        except Exception:
            text = payload[:1000].decode("utf-8", "replace")
        print(f"  >>> [{tag}] payload {len(payload)}b, источник: {source}, adbd: {status}")
        print(f"      {text[:4000]}{' …(обрезано)' if len(text) > 4000 else ''}")
        sys.stdout.flush()

    def _send_local_fallback(self, kind, why):
        """Апстрим ответил 429/5xx — колонке всё равно отдаём 200.

        kind="sync" — полный конфиг с adbd.remoteActivation=true,
        иначе — короткий {"status":"ok"}, чтобы активация не срывалась.
        """
        payload = sync_payload() if kind == "sync" else OK_PAYLOAD
        self._send_json(payload)
        print(f"  >>> [FALLBACK] {why} — отдаю локально 200 "
              f"({'sync + adbd:true' if kind == 'sync' else 'ok'}) <<<")
        if kind == "sync":
            self._log_payload("SYNC→", payload, "локальный шаблон (fallback)")

    def _upstream(self, host, ip, body, hdrs):
        """Запрос в Яндекс с повторами на 429/5xx: 3 попытки, пауза 2.5с по умолчанию."""
        last = (None, b"")
        for attempt in range(1, RETRY_ATTEMPTS + 1):
            conn = PinnedHTTPS(host, ip, timeout=20)
            conn.request(self.command, self.path, body=body, headers=hdrs)
            r = conn.getresponse()
            data = r.read()
            if not upstream_soft_error(r.status):
                return r, data
            last = (r, data)
            if attempt < RETRY_ATTEMPTS:
                print(f"  ... [RETRY] upstream {r.status} на {self.path.split('?')[0]}, "
                      f"попытка {attempt}/{RETRY_ATTEMPTS}, пауза {RETRY_DELAY:g}с")
                sys.stdout.flush()
                time.sleep(RETRY_DELAY)
        print(f"  ... [RETRY] upstream {last[0].status if last[0] else '-'} после "
              f"{RETRY_ATTEMPTS} попыток — сдаюсь, отдаю локально")
        sys.stdout.flush()
        return last

    def handle_request(self):
        clean_path = self.path.split("?")[0]
        if SYNC_PROXY and is_sync_path(clean_path):
            # реальный ответ Яндекса (родные поля устройства) + adbd; при 429/5xx — шаблон
            self.serve_sync_real(dump_path=os.path.join(BASE_DIR, "log", "sync_real.json"))
            return
        if MODE_PASSTHROUGH:
            # режим «сквозь»: ничего не подменяем, просто проксируем в настоящий Яндекс
            self.proxy_upstream()
            return
        if MODE_OTA_ONLY:
            # только доставка прошивки: манифест и сам zip отдаём мы, всё прочее — в Яндекс
            if clean_path.endswith(".zip") or clean_path.startswith(OTA_PREFIX):
                self.serve_ota()
                return
            if clean_path.startswith("/check_updates") or clean_path.startswith("/allow_update"):
                # отдаём манифест всем, кто спросил про обновление (это безопасно: только прошивка)
                payload = _downgrade_payload()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                print("  >>> [OTA-ONLY] выдан манифест прошивки <<<")
                return
            self.proxy_upstream()
            return
        # подменяем ответы ТОЛЬКО самой колонке; телефон/приложение идут в настоящий Яндекс
        ua = self.headers.get("User-Agent", "")
        ua_l = ua.lower()
        path_l = self.path.lower()
        is_column = (
            (COLUMN_ID in self.path)
            or (self.client_address[0] in COLUMN_IPS)
            or any(k in ua_l for k in ("yandexstation", "yandexmicro", "yandexmini", "yandexmidi"))
            # станция иногда приходит без User-Agent — узнаём по характерным параметрам
            or ("platform=yandex" in path_l)
            or (path_l.startswith("/get_sync_info") and "device_id=" in path_l)
            or (path_l.startswith("/check_updates") and "device_id=" in path_l)
        )


        # --- то, что не наше: кэшируем, чтобы 429 от Яндекса не долетал до колонки ---
        if path_l.startswith("/glagol/") or path_l.startswith("/telemetry") or path_l.startswith("/metrics"):
            self.serve_cached()
            return

        # --- раздача OTA со своего диска (кусками, с Range) ---
        if clean_path.endswith(".zip") or clean_path.startswith(OTA_PREFIX):
            self.serve_ota()
            return

        
        if clean_path == "/generate_204":
            self.send_response(204)
            self.end_headers()
            return
            
        # на этот стенд попадает только колонка (DNS подменён у неё) — отвечаем локально всегда
        if "register" in clean_path.lower() and os.environ.get("PROXY_REGISTER") != "1":
            self._drain_body()
            # Mini 1.369 зацикливается на регистрации, если ответ не такой — проверено на живой колонке
            _r = b'{"message":"allvalid","status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(_r)))
            self.end_headers()
            self.wfile.write(_r)
            print("  >>> [REGISTER] локальный ответ allvalid <<<")
            return

        if clean_path in ("/set_device_capability", "/update_device_state"):
            self._drain_body()
            _ok = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(_ok)))
            self.end_headers()
            self.wfile.write(_ok)
            return

        if "get_sync_info" in clean_path.lower():
            self._log_sync_request()
            try:
                _p = sync_payload()
            except Exception as e:
                print(f"  !!! [SYNC] шаблон сломан ({e!r}), отдаю встроенный")
                _p = SYNC_INFO_PAYLOAD
            self._send_json(_p)
            print("  >>> [SUCCESS] Колонке отправлена команда активации ADB! <<<")
            self._log_payload("SYNC→", _p, "локальный шаблон")
            return
            
        # любые варианты пути (в т.ч. /quasar/check_updates, /check_updates/v2) — не только точный
        if ("check_updates" in clean_path.lower() or "allow_update" in clean_path.lower()) and is_column:
            # Предлагаем обновление ВСЕГДА, пока колонка не на этой версии.
            # Если попытка не удалась — она осталась на старой версии и получит предложение снова.
            cur = ""
            try:
                import urllib.parse as _u
                q = _u.parse_qs(_u.urlparse(self.path).query)
                cur = (q.get("version") or [""])[0]
            except Exception:
                pass
            already = cur.startswith(OTA_VERSION)
            payload = _downgrade_payload() if (MODE_DOWNGRADE and not already) else NO_UPDATE_PAYLOAD
            if already:
                print("  >>> [OTA] колонка уже на целевой версии — hasUpdate:false <<<")
            elif MODE_DOWNGRADE:
                print("  >>> [DOWNGRADE] Колонке отправлен манифест уязвимой прошивки! <<<")
            else:
                print("  >>> [SECURITY] Запрос обновлений заблокирован (hasUpdate: false) <<<")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
            
        # Всё остальное (/register, /get_config, ...) — пробрасываем в настоящий Яндекс,
        # иначе колонка получает "OK" вместо реального ответа и ругается "что-то не так".
        # Но 429/5xx от Яндекса колонке не отдаём: она принимает это за провал синка.
        self.proxy_upstream(fallback="sync" if is_sync_path(self.path) else "ok")

    def serve_ota(self):
        """Отдача локального OTA-файла с поддержкой Range (колонка качает кусками)."""
        import os
        if not OTA_FILE or not os.path.exists(OTA_FILE):
            self.send_response(404)
            self.end_headers()
            return
        size = os.path.getsize(OTA_FILE)
        start, end = 0, size - 1
        rng = self.headers.get("Range")
        code = 200
        if rng and rng.startswith("bytes="):
            try:
                a, _, b = rng[6:].partition("-")
                if a:
                    start = int(a)
                if b:
                    end = int(b)
                code = 206
            except Exception:
                start, end, code = 0, size - 1, 200
        length = max(0, end - start + 1)
        self.send_response(code)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if code == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(OTA_FILE, "rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(65536, left))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except Exception:
                    return
                left -= len(chunk)
        if start == 0 and end == size - 1:
            print("  >>> [OTA] файл отдан ПОЛНОСТЬЮ (%d б) <<<" % size)
        print(f"  >>> [OTA] отдано {length}б (bytes {start}-{end}/{size}) <<<")
        sys.stdout.flush()

    def serve_sync_real(self, dump_path=None):
        """Настоящий ответ Яндекса + вписанный ADB.

        Ответ отдаётся как есть (со всеми полями устройства), меняется/добавляется
        только adbd. Любая проблема (429/5xx/не JSON/обрыв) — локальный шаблон с ADB.
        Сырой ответ пишется в dump_path только при DUMP_SYNC=1.
        """
        host = (self.headers.get("Host") or UPSTREAM_HOST).split(":")[0]
        ip = real_ip(host)
        self._log_sync_request()
        try:
            body = self._read_body() if self.command in ("POST", "PUT") else None
            skip = ("host", "connection", "content-length", "accept-encoding", "transfer-encoding")
            hdrs = {k: v for k, v in self.headers.items() if k.lower() not in skip}
            r, data = self._upstream(host, ip, body, hdrs)
            if r.status == 200:
                try:
                    d = json.loads(data)
                except (ValueError, UnicodeDecodeError):
                    d = None
                if isinstance(d, dict) and d:
                    if dump_path and os.environ.get("DUMP_SYNC") == "1":
                        try:
                            with open(dump_path, "wb") as f:
                                f.write(data)
                            print(f"  >>> [DUMP] сырой ответ сохранён: {dump_path} ({len(data)}b)")
                        except OSError as e:
                            print(f"  >>> [DUMP] не смог сохранить: {e}")
                    payload = sync_payload(source=d)
                    self._send_json(payload)
                    print(f"  >>> [SYNC-REAL] ответ Яндекса + adbd ({len(data)}b) <<<")
                    self._log_payload("SYNC-REAL→", payload, "настоящий ответ Яндекса")
                    return
                print("  !!! [SYNC-REAL] 200, но не JSON — беру локальный шаблон")
            else:
                print(f"  !!! [SYNC-REAL] upstream {r.status} — беру локальный шаблон")
            self._send_local_fallback("sync", f"upstream {r.status} на sync")
        except Exception as e:
            self._send_local_fallback("sync", f"нет связи с Яндексом ({e!r})")

    def serve_cached(self, ttl_ok=True, dump_path=None):
        """Проксируем с кэшем: 200 — кэшируем и отдаём; ошибка/429 — отдаём кэш, если есть."""
        key = self.path
        cache = _cache_file(key)
        host = (self.headers.get("Host") or UPSTREAM_HOST).split(":")[0]
        ip = real_ip(host)
        kind = "sync" if is_sync_path(self.path) else "ok"
        body = self._read_body() if self.command in ("POST", "PUT") else None
        skip = ("host", "connection", "content-length", "accept-encoding", "transfer-encoding")
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in skip}
        try:
            r, data = self._upstream(host, ip, body, hdrs)
            if r.status == 200:
                try:
                    os.makedirs(CACHE_DIR, exist_ok=True)
                    with open(cache, "wb") as f:
                        f.write(data)
                except OSError:
                    pass
                self.send_response(200)
                self.send_header("Content-Type", r.getheader("Content-Type") or "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if os.path.exists(cache):
                with open(cache, "rb") as f:
                    data = f.read()
                print(f"  >>> [CACHE] upstream {r.status}, отдаю кэш ({len(data)}b)")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            # кэша нет, а Яндекс ответил 429/5xx — колонке отдаём локальный 200
            if upstream_soft_error(r.status):
                self._send_local_fallback(kind, f"upstream {r.status} на {self.path}")
                return
            self.send_response(r.status)
            self.end_headers()
        except Exception as e:
            if os.path.exists(cache):
                with open(cache, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self._send_local_fallback(kind, f"нет связи с Яндексом ({e!r})")

    def proxy_upstream(self, dump_path=None, fallback=None):
        host = (self.headers.get("Host") or UPSTREAM_HOST).split(":")[0]
        ip = real_ip(host)
        try:
            body = self._read_body() if self.command in ("POST", "PUT") else None
            skip = ("host", "connection", "content-length", "accept-encoding", "transfer-encoding")
            hdrs = {k: v for k, v in self.headers.items() if k.lower() not in skip}
            r, data = self._upstream(host, ip, body, hdrs)
            if dump_path and r.status == 200:
                try:
                    with open(dump_path, "wb") as f:
                        f.write(data)
                    print(f"  >>> [DUMP] настоящий ответ сохранён: {dump_path} ({len(data)}b)")
                except OSError as e:
                    print(f"  >>> [DUMP] не смог сохранить: {e}")
            elif dump_path:
                print(f"  >>> [DUMP] пропущен: Яндекс ответил {r.status}, в шаблон не пишем")
            # лимит/перегрузка Яндекса не должна долетать до колонки
            if fallback and upstream_soft_error(r.status):
                self._send_local_fallback(fallback, f"upstream {r.status} на {self.path}")
                return
            self.send_response(r.status)
            for k, v in r.getheaders():
                if k.lower() in ("content-type", "content-length", "cache-control", "etag", "last-modified"):
                    self.send_header(k, v)
            if not r.getheader("Content-Length"):
                self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            print(f"  >>> [PROXY] {self.command} {self.path} -> {r.status} ({len(data)}b) <<<")
            sys.stdout.flush()
        except Exception as e:
            if fallback:
                self._send_local_fallback(fallback, f"нет связи с Яндексом ({e!r})")
                return
            self.send_response(502)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")
            print(f"  !!! [PROXY] ошибка {self.path}: {e!r}")
            sys.stdout.flush()

class ReusableServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True

def run_http(port=80):
    try:
        httpd = ReusableServer(("0.0.0.0", port), EquasarHandler)
        print(f"[*] HTTP сервер слушает порт {port}...")
        httpd.serve_forever()
    except Exception as e:
        print(f"[!] Ошибка запуска HTTP на порту {port}: {e}")

def run_https(cert_file, key_file, port=443):
    try:
        httpd = ReusableServer(("0.0.0.0", port), EquasarHandler)
        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        # старые прошивки (Mini 2019) умеют только TLS 1.2 и ниже — не отсекаем их
        try:
            ctx.minimum_version = ssl.TLSVersion.TLSv1
            ctx.set_ciphers("DEFAULT@SECLEVEL=0")
        except (AttributeError, ValueError, ssl.SSLError):
            pass
        ctx.load_cert_chain(certfile=cert_file, keyfile=key_file)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        print(f"[*] HTTPS сервер слушает порт {port} (с сертификатами)...")
        httpd.serve_forever()
    except Exception as e:
        print(f"[!] Ошибка запуска HTTPS на порту {port}: {e}")

def find_certificates():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        (os.path.join(base_dir, "..", "certs", "fullchain.pem"),
         os.path.join(base_dir, "..", "certs", "quasar-all.key")),
        (os.path.join(base_dir, "..", "nginx-win", "nginx-1.26.2", "conf", "certs", "fullchain.pem"),
         os.path.join(base_dir, "..", "nginx-win", "nginx-1.26.2", "conf", "certs", "quasar-all.key")),
    ]
    for cert_path, key_path in candidates:
        if os.path.exists(cert_path) and os.path.exists(key_path):
            return cert_path, key_path
    return None, None

def main():
    global MODE_DOWNGRADE, MODE_PASSTHROUGH, MODE_OTA_ONLY
    parser = argparse.ArgumentParser(description="eQuasar Server for Yandex Station Lite 1")
    parser.add_argument("--downgrade", action="store_true", help="Включить режим даунгрейда на уязвимую прошивку")
    parser.add_argument("--ota-only", action="store_true",
                        help="Только прошивка (Mini): отдавать манифест и zip, всё остальное — в Яндекс")
    parser.add_argument("--passthrough", action="store_true",
                        help="Прозрачный режим: всё проксируется в настоящий Яндекс (для диагностики TLS)")
    args = parser.parse_args()

    if args.downgrade or os.environ.get("EQUASAR_MODE") == "downgrade":
        MODE_DOWNGRADE = True
    if args.ota_only or os.environ.get("EQUASAR_MODE") == "ota":
        MODE_OTA_ONLY = True
    if args.passthrough or os.environ.get("EQUASAR_MODE") == "passthrough":
        MODE_PASSTHROUGH = True

    cert_path, key_path = find_certificates()
    if not cert_path or not key_path:
        print("[!] Ошибка: Сертификаты fullchain.pem и quasar-all.key не найдены.")
        sys.exit(1)

    if OTA_FILE:
        print(f"[OTA] {os.path.basename(OTA_FILE)} | версия {OTA_VERSION} | crc32 {_ota_crc()} | "
              f"модель {OTA_PLATFORM} | отдаём по {OTA_PREFIX}")
    else:
        print("[OTA] в firmware/ нет .zip — режим отката будет отдавать 404")
    print("==================================================================")
    print("      eQuasar Server — Кроссплатформенный сервер eQuasar          ")
    print(f"      build {BUILD}")
    if MODE_PASSTHROUGH:
        print("[РЕЖИМ] PASSTHROUGH — всё уходит в настоящий Яндекс, подмены выключены")
    if MODE_OTA_ONLY:
        print("[РЕЖИМ] OTA-ONLY — только прошивка: манифест и zip, всё остальное в Яндекс (ADB не включаем)")
    if SYNC_PROXY:
        print("[РЕЖИМ] SYNC_PROXY — sync: настоящий ответ Яндекса + adbd "
              "(429/5xx → локальный шаблон)")
    print("==================================================================")
    if MODE_DOWNGRADE:
        print("РЕЖИМ: [ДАУНГРЕЙД] — Отдача официальной уязвимой прошивки Яндекса")
    else:
        print("РЕЖИМ: [ВЗЛОМ / АКТИВАЦИЯ] — Включение ADB, обновления заблокированы")
    print("Сертификаты загружены из:", os.path.dirname(cert_path))
    print("Готов принимать запросы от Станции Лайт на портах 80 и 443.")
    print("Нажмите Ctrl+C для остановки.")
    print("------------------------------------------------------------------")

    # порты можно переопределить (удобно для проверки, когда 80/443 заняты)
    _hp = int(os.environ.get("HTTP_PORT", "80"))
    _sp = int(os.environ.get("HTTPS_PORT", "443"))
    t_http = threading.Thread(target=run_http, args=(_hp,), daemon=True)
    t_https = threading.Thread(target=run_https, args=(cert_path, key_path, _sp), daemon=True)

    t_http.start()
    t_https.start()

    try:
        t_http.join()
        t_https.join()
    except KeyboardInterrupt:
        print("\n[*] Сервер остановлен.")

if __name__ == "__main__":
    main()
