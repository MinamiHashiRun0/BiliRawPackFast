#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""起 N 个「按连接限速」的 Range HTTP 服务，用来在 CI 里真跑多 CDN 并发代理。

用途：inject/probe/test_proxy_e2e.m 需要一组**真实的、各自有限的**上游链路，
才能证明「代理把单连接拆成多 CDN 并发」确实带来提速。
本脚本就是那组上游。

字节配方（Python 与 ObjC 两侧必须一致）：
    byte[i] = (i * 31 + 7) & 0xFF
这个配方让测试能**按字节位置**校验内容，与分片粒度无关 ——
分段方式怎么变都能验出"第几字节是不是对的"。

用法：
    python3 serve_multi_cdn.py <base_port> <n_servers> <size_bytes> <rate_Bps>
"""
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

SIZE = 0
RATE = 0
BODY = b""


def make_body(size):
    # byte[i] = (i * 31 + 7) & 0xFF，用 bytes 快速生成
    return bytes(((i * 31 + 7) & 0xFF) for i in range(size))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeCDN/1.0"

    def log_message(self, fmt, *args):   # 静音
        pass

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(SIZE))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

    def do_GET(self):
        start, end = 0, SIZE - 1
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            spec = rng[6:].split(",")[0]
            a, _, b = spec.partition("-")
            if a:
                start = int(a)
            if b:
                end = int(b)
            if end > SIZE - 1:
                end = SIZE - 1
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % SIZE)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

        length = end - start + 1
        partial = rng is not None
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, SIZE))
        self.end_headers()

        # 按 RATE 字节/秒限速（按连接，独立令牌桶）
        chunk = 16384
        sent = 0
        t0 = time.monotonic()
        try:
            while sent < length:
                n = min(chunk, length - sent)
                self.wfile.write(BODY[start + sent:start + sent + n])
                sent += n
                # 目标时刻 = t0 + 已发字节/RATE
                target = t0 + sent / RATE
                now = time.monotonic()
                if target > now:
                    time.sleep(target - now)
        except (BrokenPipeError, ConnectionResetError):
            pass


def serve(port):
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    srv.serve_forever()


def main():
    global SIZE, RATE, BODY
    base_port = int(sys.argv[1]) if len(sys.argv) > 1 else 18081
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    SIZE = int(sys.argv[3]) if len(sys.argv) > 3 else 6 * 1024 * 1024
    RATE = float(sys.argv[4]) if len(sys.argv) > 4 else 1024 * 1024

    BODY = make_body(SIZE)
    print("fixture %d bytes, rate %.0f B/s/conn, servers %d..%d"
          % (SIZE, RATE, base_port, base_port + n - 1), flush=True)

    threads = []
    for i in range(n):
        t = threading.Thread(target=serve, args=(base_port + i,), daemon=True)
        t.start()
        threads.append(t)

    # 就绪探测
    for i in range(n):
        p = base_port + i
        for _ in range(60):
            try:
                s = socket.create_connection(("127.0.0.1", p), 0.5)
                s.close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            print("server %d 未就绪" % p, file=sys.stderr, flush=True)
            sys.exit(1)
    print("ALL READY", flush=True)

    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
