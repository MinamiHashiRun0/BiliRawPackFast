"""
给 BSSegmentFetcher 的 macOS 运行测试提供后端。

两个关键点：
  1. 夹具内容必须与 test_segment_fetcher.m 里的期望一致
     —— 每段 = 该段号对应的单字节重复填充，值 (i + 0xB1) & 0xFF。
     这样「第 i 段内容是否正确」是可判定的，而不是只看长度。
  2. **按连接限速**（默认 128 KiB/s）。
     本机回环太快，不限速的话并发 1 与并发 8 都是瞬间完成，
     测出来的"提速"没有意义；真实场景里 B站正是对单连接限速，
     所以这里必须复现该特性，测试才有代表性。

用法:
  python serve_test_data.py <port> <out_dir> [segments] [seg_size] [per_conn_kibps]
  生成 <out_dir>/f.m4s（一次写入，多个测试用例共用；小的用例只取前 N 段，
  由于每段只依赖段号，前缀复用是合法的）
"""
import http.server, os, socketserver, sys, threading, time


class ThrottledRangeHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    payload = b""
    per_conn_rate = 128 * 1024
    latency = 0.02

    def log_message(self, *a):
        pass

    def do_HEAD(self):
        self._serve(head_only=True)

    def do_GET(self):
        self._serve(head_only=False)

    def _serve(self, head_only):
        total = len(self.payload)
        rng = self.headers.get("Range")
        start, end = 0, total - 1
        if rng and rng.startswith("bytes="):
            spec = rng[len("bytes="):].split(",")[0]
            a, _, b = spec.partition("-")
            if a:
                start = int(a)
                end = int(b) if b else total - 1
            else:
                start = max(0, total - int(b))
            end = min(end, total - 1)
        if start > end or start >= total:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{total}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        n = end - start + 1
        self.send_response(206)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        self.send_header("Content-Length", str(n))
        self.end_headers()
        if head_only:
            return

        chunk = max(1, int(ThrottledRangeHandler.per_conn_rate / 50))
        time.sleep(ThrottledRangeHandler.latency)
        sent = 0
        try:
            while sent < n:
                k = min(chunk, n - sent)
                self.wfile.write(self.payload[start + sent:start + sent + k])
                sent += k
                time.sleep(0.02)
        except (BrokenPipeError, ConnectionResetError):
            pass


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def build_payload(segments, seg_size):
    """
    载荷的第 i 个字节 = i % 251。

    为什么用「按字节位置」而不是「按段号」编码：
      最初的实现是每段填一个属于该段的常量字节。结果测试里所有
      「逐段内容逐字节正确」都失败了 —— 因为夹具是按 256KiB 段生成的，
      而测试用例会用 4KiB 的段去断言，两者分段粒度不同，期望值对不上。
      问题出在夹具设计，不在被测引擎（引擎的按序/段数/重试/降级都通过了）。
      改成按字节位置编码后，夹具与分段方式无关：
      任意分段下，只要「第 k 段应从偏移 o 取 n 字节」，期望内容就唯一确定。
    251 取质数，避免与段长或块长的任何对齐关系。
    """
    return bytes((i % 251) for i in range(segments * seg_size))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    port = int(sys.argv[1])
    out_dir = sys.argv[2]
    segments = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    seg_size = int(sys.argv[4]) if len(sys.argv) > 4 else 262144
    kibps = int(sys.argv[5]) if len(sys.argv) > 5 else 128

    os.makedirs(out_dir, exist_ok=True)
    payload = build_payload(segments, seg_size)
    path = os.path.join(out_dir, "f.m4s")
    with open(path, "wb") as f:
        f.write(payload)

    ThrottledRangeHandler.payload = payload
    ThrottledRangeHandler.per_conn_rate = kibps * 1024

    srv = ThreadedServer(("127.0.0.1", port), ThrottledRangeHandler)
    print(f"已生成 {path}: {len(payload):,} 字节 "
          f"({segments} 段 × {seg_size:,})", flush=True)
    print(f"按连接限速 {kibps} KiB/s，监听 127.0.0.1:{port}", flush=True)
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
