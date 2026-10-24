#!/usr/bin/env python3
"""dnscheck.py <server-ip> [name] — проверить, что DNS-стенд отдаёт локальный IP."""
import socket
import struct
import sys


def query(server, name, qtype=1, timeout=3.0):
    q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    for part in name.rstrip(".").split("."):
        q += bytes([len(part)]) + part.encode()
    q += b"\x00" + struct.pack(">HH", qtype, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(q, (server, 53))
        data, _ = s.recvfrom(2048)
    finally:
        s.close()
    ancount = int.from_bytes(data[6:8], "big")
    if not ancount:
        return None
    return socket.inet_ntoa(data[-4:])


def main():
    server = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    name = sys.argv[2] if len(sys.argv) > 2 else "quasar.yandex.net"
    try:
        ip = query(server, name)
    except Exception as e:
        print(f"  (DNS-проверка не удалась: {e!r})")
        return 1
    if not ip:
        print(f"  (нет A-записи для {name})")
        return 1
    print(f"  {name} -> {ip}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
