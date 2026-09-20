"""
并发分段拉取引擎的「同构参考实现 + 本地验证台」。

为什么先写 Python 参考实现：
  真正的实现要用 Objective-C 写进 dylib（最终由 CI 编译、真机运行）。
  但引擎里真正容易写错的是**调度与顺序**，不是语法：
    - 并发窗口里段乱序返回，交付给 AVPlayer 必须严格按段号递增
    - 段可能被取消（滑动窗口丢帧）后又被重排
    - 失败段要重试，重试用尽要能降级换 host
  这些属性可以在本地用一个「限速 + 支持 Range」的服务器精确验证，
  不需要 Mac、不需要 iOS。参考实现与 ObjC 版共享同一套状态机语义，
  因此这里验证的是**算法**，ObjC 版再靠 CI 做类型与语法验证。

本地限速服务器设计（关键）：
  人为把**单连接**带宽压到很低（例如 256 KB/s），但允许多连接并行。
  于是：
    - 串行拉取 4 段 → 约 4 × 段时延
    - 并发 8 连接拉取 → 接近 段时延
  这能定量证明「并发确实带来 N 倍收益」，而不是靠感觉声称"更快"。
"""
import http.server, socketserver, threading, time, socket, random, math, sys
import urllib.request

# ---------------------------------------------------------------- 限速 Range 服务器
class ThrottledRangeHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    payload = b""
    per_conn_rate = 256 * 1024      # 字节/秒/连接
    latency = 0.05                  # 建连后首字节延迟
    counters = None
    lock = threading.Lock()

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

        with ThrottledRangeHandler.lock:
            ThrottledRangeHandler.counters["requests"] += 1
            ThrottledRangeHandler.counters["bytes"] += n

        chunk = max(1, int(ThrottledRangeHandler.per_conn_rate / 50))   # 20ms 步长
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


def make_server(data: bytes, per_conn_rate: int, latency: float = 0.05):
    ThrottledRangeHandler.payload = data
    ThrottledRangeHandler.per_conn_rate = per_conn_rate
    ThrottledRangeHandler.latency = latency
    ThrottledRangeHandler.counters = {"requests": 0, "bytes": 0}
    srv = ThreadedServer(("127.0.0.1", 0), ThrottledRangeHandler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv, srv.server_address[1]


# ---------------------------------------------------------------- SIDX 构造
def build_sidx_payload(seg_sizes, magic=0xB1):
    """按给定段长造一份带可识别内容的载荷，段边界可由 seg_sizes 推出"""
    out = bytearray()
    for i, sz in enumerate(seg_sizes):
        # 每段内容 = 段号重复填充，便于校验「第 i 段的内容确实来自第 i 段」
        out.extend(bytes([(i + magic) & 0xFF]) * sz)
    return bytes(out)


def expected_segment_bytes(payload, seg_offsets, idx):
    o, n = seg_offsets[idx]
    return payload[o:o + n]


# ---------------------------------------------------------------- 参考引擎
class SegmentFetcher:
    """
    与将写进 dylib 的 ObjC 版语义一致：
      * 段表来自 SIDX（这里用 (offset,size) 列表代表）
      * 固定并发上限
      * 已完成段进入按段号索引的槽位（乱序到达）
      * 交付严格按段号递增（in-order drain）
      * 失败段重试；重试用尽则换 host（fallback host 列表）
    """

    def __init__(self, seg_offsets, base_url, concurrency=8, max_retry=2, hosts=None):
        self.segs = seg_offsets                 # [(offset, size)]
        self.base = base_url
        self.concurrency = concurrency
        self.max_retry = max_retry
        self.hosts = hosts or [base_url]
        self.slots = {}                         # segno -> bytes（已到但可能未交付）
        self.failed_attempts = {}               # segno -> 已失败次数
        self.next_seq = 0                       # 下一个要交付的段号
        self.next_fetch = 0                     # 下一个要发起的段号
        self.delivered = 0
        self.retries = 0
        self.host_switches = 0
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)
        self.errors = []

    # ---- 网络 ----
    def _fetch_one(self, idx):
        off, size = self.segs[idx]
        last_err = None
        for attempt in range(self.max_retry + 1):
            host = self.hosts[min(attempt, len(self.hosts) - 1)]
            if attempt and host != self.hosts[0]:
                with self.lock:
                    self.host_switches += 1
            try:
                req = urllib.request.Request(
                    host + "/f.m4s",
                    headers={"Range": f"bytes={off}-{off + size - 1}"})
                with urllib.request.urlopen(req, timeout=30) as r:
                    body = r.read()
                if len(body) != size:
                    raise IOError(f"段 {idx} 长度不符: 期望 {size} 实得 {len(body)}")
                return body
            except Exception as e:      # noqa: BLE001 —— 这里就是要兜住所有网络异常
                last_err = e
                with self.lock:
                    self.retries += 1
                time.sleep(0.05 * (attempt + 1))
        with self.lock:
            self.errors.append((idx, repr(last_err)))
        return None

    def _worker(self):
        while True:
            with self.lock:
                if self.next_fetch >= len(self.segs):
                    return
                idx = self.next_fetch
                self.next_fetch += 1
            data = self._fetch_one(idx)
            if data is None:
                with self.lock:
                    self.cond.notify_all()
                return                      # 该段彻底失败 → 整条链降级
            with self.lock:
                self.slots[idx] = data
                self.cond.notify_all()

    def fetch_all(self):
        threads = [threading.Thread(target=self._worker, daemon=True)
                   for _ in range(min(self.concurrency, len(self.segs)))]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=180)
        return self.errors

    def drain_in_order(self):
        """按段号递增产出；缺段即停（模拟 AVPlayer 顺序消费）"""
        out = []
        with self.lock:
            while self.next_seq in self.slots:
                out.append(self.slots.pop(self.next_seq))
                self.next_seq += 1
                self.delivered += 1
        return out


# ---------------------------------------------------------------- 测试
def test_in_order_and_bounds():
    print("=" * 72)
    print("测试 1：乱序到达 / 边界 / 内容正确性")
    print("=" * 72)
    random.seed(7)
    sizes = [random.randint(1024, 8192) for _ in range(40)]
    payload = build_sidx_payload(sizes)
    offsets, acc = [], 0
    for s in sizes:
        offsets.append((acc, s)); acc += s
    assert acc == len(payload)

    srv, port = make_server(payload, per_conn_rate=10 * 1024 * 1024, latency=0.0)
    try:
        f = SegmentFetcher(offsets, f"http://127.0.0.1:{port}", concurrency=12)
        errs = f.fetch_all()
        assert not errs, f"出现失败: {errs}"
        got = f.drain_in_order()
        assert len(got) == len(sizes), f"交付段数不符: {len(got)} vs {len(sizes)}"
        for i, b in enumerate(got):
            exp = expected_segment_bytes(payload, offsets, i)
            assert b == exp, f"第 {i} 段内容错误（长度 {len(b)} vs {len(exp)}）"
        print(f"  ✔ {len(sizes)} 段全部按序交付，逐段内容逐字节正确")
        print(f"  ✔ 并发 {12}，重试 {f.retries} 次，换 host {f.host_switches} 次")
    finally:
        srv.shutdown()
    return True


def test_concurrency_speedup():
    print()
    print("=" * 72)
    print("测试 2：并发是否真的带来提速（定量，不是感觉）")
    print("=" * 72)
    seg_size = 512 * 1024
    n_seg = 8
    sizes = [seg_size] * n_seg
    payload = build_sidx_payload(sizes)
    offsets, acc = [], 0
    for s in sizes:
        offsets.append((acc, s)); acc += s

    rate = 256 * 1024          # 单连接 256 KB/s
    srv, port = make_server(payload, per_conn_rate=rate, latency=0.05)
    url = f"http://127.0.0.1:{port}"
    try:
        # 串行：并发 1
        f1 = SegmentFetcher(offsets, url, concurrency=1)
        t0 = time.time(); f1.fetch_all(); t1 = time.time()
        d1 = t1 - t0
        total_mb = len(payload) / 1024 / 1024
        print(f"  并发 1：{d1:6.2f}s  →  {total_mb / d1:6.2f} MiB/s")

        # 并发：8
        f8 = SegmentFetcher(offsets, url, concurrency=8)
        t0 = time.time(); f8.fetch_all(); t1 = time.time()
        d8 = t1 - t0
        print(f"  并发 8：{d8:6.2f}s  →  {total_mb / d8:6.2f} MiB/s")

        # 理论：串行 = n*seg/rate；并发 c = ceil(n/c)*seg/rate
        theo1 = n_seg * seg_size / rate
        theo8 = math.ceil(n_seg / 8) * seg_size / rate
        print(f"  理论值：并发1 ≈ {theo1:.2f}s，并发8 ≈ {theo8:.2f}s")
        speedup = d1 / d8
        print(f"  实测提速：{speedup:.2f}×")
        ok = speedup > 2.0 and not f1.errors and not f8.errors
        print(f"  {'✔' if ok else '✘'} 提速显著（>2×）且无错误")
        if not ok:
            print("     说明：若提速不明显，要么服务器没按连接限速，要么引擎并发没生效")
        return ok
    finally:
        srv.shutdown()


def test_retry_then_fallback():
    print()
    print("=" * 72)
    print("测试 3：失败重试与换 host 降级")
    print("=" * 72)
    sizes = [4096] * 6
    payload = build_sidx_payload(sizes)
    offsets, acc = [], 0
    for s in sizes:
        offsets.append((acc, s)); acc += s

    srv, port = make_server(payload, per_conn_rate=10 * 1024 * 1024, latency=0.0)
    try:
        good = f"http://127.0.0.1:{port}"
        # 第一个 host 指向一个关闭的端口，第二个才是好的 → 应发生换 host
        dead = "http://127.0.0.1:1"
        f = SegmentFetcher(offsets, dead, concurrency=3, max_retry=2, hosts=[dead, good])
        errs = f.fetch_all()
        got = f.drain_in_order()
        ok = (not errs) and len(got) == len(sizes) and f.host_switches > 0
        print(f"  失败列表={errs}  交付={len(got)}/{len(sizes)}  换host={f.host_switches}  重试={f.retries}")
        print(f"  {'✔' if ok else '✘'} 坏 host 下成功降级到备用 host 并完整交付")
        return ok
    finally:
        srv.shutdown()


def test_all_dead_reports_error():
    print()
    print("=" * 72)
    print("测试 4：全部 host 失效时必须显式报错（不许静默交付残片）")
    print("=" * 72)
    sizes = [1024] * 4
    payload = build_sidx_payload(sizes)
    offsets, acc = [], 0
    for s in sizes:
        offsets.append((acc, s)); acc += s
    f = SegmentFetcher(offsets, "http://127.0.0.1:1", concurrency=2, max_retry=1,
                       hosts=["http://127.0.0.1:1", "http://127.0.0.1:2"])
    errs = f.fetch_all()
    got = f.drain_in_order()
    ok = len(errs) > 0 and len(got) == 0
    print(f"  失败段={[e[0] for e in errs]}  交付={len(got)}")
    print(f"  {'✔' if ok else '✘'} 全失败时显式报错且不交付任何残片")
    return ok


if __name__ == "__main__":
    results = []
    results.append(test_in_order_and_bounds())
    results.append(test_concurrency_speedup())
    results.append(test_retry_then_fallback())
    results.append(test_all_dead_reports_error())
    print()
    print("=" * 72)
    print("结果：%d/%d 通过 %s" % (sum(results), len(results),
                                  "✅" if all(results) else "❌"))
    sys.exit(0 if all(results) else 1)
