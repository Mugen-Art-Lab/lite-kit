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


def _downgrade_payload():
    return json.dumps({
        "hasUpdate": True,
        "version": OTA_VERSION,
        "downloadUrl": "https://quasar.yandex.net" + OTA_PREFIX + os.path.basename(OTA_FILE),
        "crc32": 371630625,
        "critical": True,
        "fallbackUrl": "https://quasar.yandex.net" + OTA_PREFIX + os.path.basename(OTA_FILE),
        "fallbackIp": LOCAL_IP,
        "updateId": "150484",
    }).encode()


BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OTA_FILE = os.path.join(BASE_DIR, "firmware", "0.369.1.46.4778262442.20261013.297.zip")
OTA_PREFIX = "/yandexmicro/ota/"
OTA_VERSION = "0.369.1.46.4778262442.20261013.297"

# --- опциональные настройки через окружение (все необязательные) ---
# IP мака: по умолчанию определяется автоматически
LOCAL_IP = os.environ.get("LOCAL_IP") or _local_ip()
# дополнительные IP колонки: по умолчанию ПУСТО — матчим по User-Agent и по device-id в пути
COLUMN_IPS = {ip.strip() for ip in os.environ.get("COLUMN_IPS", "").split(",") if ip.strip()}
# device-id колонки: можно переопределить, если у вас другая станция
COLUMN_ID = os.environ.get("COLUMN_ID", "LP00000000000001982300007d20fe15")

MODE_DOWNGRADE = False

class EquasarHandler(http.server.BaseHTTPRequestHandler):
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
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()

    def handle_request(self):
        clean_path = self.path.split("?")[0]
        # подменяем ответы ТОЛЬКО самой колонке; телефон/приложение идут в настоящий Яндекс
        ua = self.headers.get("User-Agent", "")
        is_column = (COLUMN_ID in self.path) or ("YandexStation" in ua) or (self.client_address[0] in COLUMN_IPS)


        # --- раздача OTA со своего диска (кусками, с Range) ---
        if clean_path.startswith(OTA_PREFIX):
            self.serve_ota()
            return

        
        if clean_path == "/generate_204":
            self.send_response(204)
            self.end_headers()
            return
            
        if clean_path in ["/get_sync_info", "/quasar/get_sync_info"] and is_column:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(SYNC_INFO_PAYLOAD)))
            self.end_headers()
            self.wfile.write(SYNC_INFO_PAYLOAD)
            print("  >>> [SUCCESS] Колонке отправлена команда активации ADB! <<<")
            return
            
        if clean_path in ["/check_updates", "/quasar/check_updates"] and is_column:
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
        self.proxy_upstream()

    def serve_ota(self):
        """Отдача локального OTA-файла с поддержкой Range (колонка качает кусками)."""
        import os
        if not os.path.exists(OTA_FILE):
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

    def proxy_upstream(self):
        host = (self.headers.get("Host") or UPSTREAM_HOST).split(":")[0]
        ip = real_ip(host)
        try:
            body = None
            if self.command in ("POST", "PUT"):
                n = int(self.headers.get("Content-Length") or 0)
                if n:
                    body = self.rfile.read(n)
            skip = ("host", "connection", "content-length", "accept-encoding", "transfer-encoding")
            hdrs = {k: v for k, v in self.headers.items() if k.lower() not in skip}
            conn = PinnedHTTPS(host, ip, timeout=20)
            conn.request(self.command, self.path, body=body, headers=hdrs)
            r = conn.getresponse()
            data = r.read()
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
    global MODE_DOWNGRADE
    parser = argparse.ArgumentParser(description="eQuasar Server for Yandex Station Lite 1")
    parser.add_argument("--downgrade", action="store_true", help="Включить режим даунгрейда на уязвимую прошивку")
    args = parser.parse_args()

    if args.downgrade or os.environ.get("EQUASAR_MODE") == "downgrade":
        MODE_DOWNGRADE = True

    cert_path, key_path = find_certificates()
    if not cert_path or not key_path:
        print("[!] Ошибка: Сертификаты fullchain.pem и quasar-all.key не найдены.")
        sys.exit(1)

    print("==================================================================")
    print("      eQuasar Server — Кроссплатформенный сервер eQuasar          ")
    print("==================================================================")
    if MODE_DOWNGRADE:
        print("РЕЖИМ: [ДАУНГРЕЙД] — Отдача официальной уязвимой прошивки Яндекса")
    else:
        print("РЕЖИМ: [ВЗЛОМ / АКТИВАЦИЯ] — Включение ADB, обновления заблокированы")
    print("Сертификаты загружены из:", os.path.dirname(cert_path))
    print("Готов принимать запросы от Станции Лайт на портах 80 и 443.")
    print("Нажмите Ctrl+C для остановки.")
    print("------------------------------------------------------------------")

    t_http = threading.Thread(target=run_http, daemon=True)
    t_https = threading.Thread(target=run_https, args=(cert_path, key_path), daemon=True)

    t_http.start()
    t_https.start()

    try:
        t_http.join()
        t_https.join()
    except KeyboardInterrupt:
        print("\n[*] Сервер остановлен.")

if __name__ == "__main__":
    main()
