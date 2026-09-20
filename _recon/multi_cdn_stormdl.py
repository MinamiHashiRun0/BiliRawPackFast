"""
多 CDN 并发：采用 stormdl 的成熟调度算法（第 5 版）

前四版全被我自己的实测否掉，记录如下（这类"我以为是难点其实早有定论"的坑要留痕）：
  第 1 版：把「单连接速率」当成 host 上限 → 并发越多越慢，假结论
  第 2 版：改用「单连接+总上限」但限速器形同虚设（实测 7.29 vs 上限 2.0 MiB/s）
  第 3 版：改令牌桶后限速准了（实测 3.10 vs 理论 3.0），但调度指标错：
           rate_of = 累计字节/累计耗时，被并发排队污染 → 最快的 CDN 只拿到 1 条连接
  第 4 版：改「单请求吞吐 EMA」仍是反向分配 —— 说明问题不在指标平滑方式，
           而在**评分函数的结构**

第 5 版改用 stormdl（Rust，adaptive multi-segment parallel downloads）的算法：
  https://github.com/augani/stormdl  crates/storm-segment/src/multi_source.rs

    score = (speed + 1.0) * error_penalty * load_factor
    error_penalty = 1 / (1 + errors * 0.5)
    load_factor   = 1 / (1 + active * 0.1)
    速度取**每次请求的速度采样**的滚动均值（最近 10 个），不是累计值相除

  要点：
    * (speed + 1.0) 保证冷启动时分数为正，且不会把慢节点饿死
    * load_factor 是**温和**的负载惩罚（active=10 时仍有 1/2 分数），
      因此多个连接可以合理地压在同一个强节点上
    * 速度样本按请求采集，天然不受并发排队影响
"""
import http.server, socketserver, threading, time, sys, collections, random
import urllib.request

MiB = 1024 * 1024


class RateLimiter:
    def __init__(self, rate):
        self.rate = float(rate); self.allowance = self.rate
        self.last = time.time(); self.lock = threading.Lock()

    def consume(self, n):
        while True:
            with self.lock:
                now = time.time()
                self.allowance += (now - self.last) * self.rate
                self.last = now
                cap = self.rate * 0.2
                if self.allowance > cap: self.allowance = cap
                if self.allowance >= n:
                    self.allowance -= n; return
                wait = (n - self.allowance) / self.rate
            time.sleep(min(max(wait, 0.0005), 0.05))


class CdnHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    payload = b""
    limiters = {}
    counters = {}
    clk = threading.Lock()

    def log_message(self, *a): pass
    def do_GET(self): self._serve(False)
    def do_HEAD(self): self._serve(True)

    def _name(self):
        p = self.path.split("/")
        return p[2] if len(p) > 2 else "unknown"

    def _serve(self, head_only):
        name = self._name()
        lim = CdnHandler.limiters.get(name)
        if lim is None:
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        total = len(CdnHandler.payload)
        rng = self.headers.get("Range")
        start, end = 0, total - 1
        if rng and rng.startswith("bytes="):
            a, _, b = rng[6:].split(",")[0].partition("-")
            start = int(a) if a else 0
            end = min(int(b) if b else total - 1, total - 1)
        n = end - start + 1
        self.send_response(206)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        self.send_header("Content-Length", str(n))
        self.end_headers()
        if head_only: return
        with CdnHandler.clk:
            c = CdnHandler.counters[name]; c["requests"] += 1; c["bytes"] += n
        CHUNK = 16 * 1024
        pos, remaining = start, n
        try:
            while remaining > 0:
                k = min(CHUNK, remaining)
                lim.consume(k)
                self.wfile.write(CdnHandler.payload[pos:pos + k])
                pos += k; remaining -= k
        except (BrokenPipeError, ConnectionResetError):
            pass


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True; allow_reuse_address = True


def make_server(seg_count, seg_size, totals):
    CdnHandler.payload = bytes((i % 251) for i in range(seg_count * seg_size))
    CdnHandler.limiters = {n: RateLimiter(t) for n, t in totals.items()}
    CdnHandler.counters = {n: {"requests": 0, "bytes": 0} for n in totals}
    srv = ThreadedServer(("127.0.0.1", 0), CdnHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


class SourceStats:
    """照搬 stormdl 的 SourceStats"""
    def __init__(self):
        self.bytes_downloaded = 0
        self.errors = 0
        self.active = 0
        self.samples = collections.deque(maxlen=10)

    def avg_speed(self):
        return (sum(self.samples) / len(self.samples)) if self.samples else 0.0

    def score(self):
        error_penalty = 1.0 / (1.0 + self.errors * 0.5)
        load_factor = 1.0 / (1.0 + self.active * 0.1)
        return (self.avg_speed() + 1.0) * error_penalty * load_factor


class Downloader:
    def __init__(self, port, hosts, n, size, conn):
        self.port, self.hosts = port, list(hosts)
        self.n, self.size, self.conn = n, size, conn
        self.stats = {h: SourceStats() for h in self.hosts}
        self.assigned = collections.Counter()
        self.lock = threading.Lock()

    def _pick(self):
        with self.lock:
            return max(self.hosts, key=lambda h: self.stats[h].score())

    def fetch(self, host, seg):
        off = seg * self.size
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/h/{host}/f.m4s",
            headers={"Range": f"bytes={off}-{off+self.size-1}"})
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=180) as r:
            body = r.read()
        dt = max(time.time() - t0, 1e-6)
        if len(body) != self.size:
            raise IOError(f"段 {seg}: {len(body)} != {self.size}")
        # ★ stormdl 的做法：把**本次请求的速度**作为一个样本推入滚动窗口
        speed = len(body) / dt
        with self.lock:
            st = self.stats[host]
            st.bytes_downloaded += len(body)
            st.samples.append(speed)
        return body

    def run(self, sched):
        nxt = [0]; res = {}; lk = threading.Lock()
        def work():
            while True:
                with lk:
                    if nxt[0] >= self.n: return
                    seg = nxt[0]; nxt[0] += 1
                h = sched(seg, self)
                with self.lock:
                    self.stats[h].active += 1
                try:
                    d = self.fetch(h, seg)
                    with lk:
                        res[seg] = d; self.assigned[h] += 1
                except Exception as e:
                    with self.lock:
                        self.stats[h].errors += 1
                    with lk:
                        res[seg] = None
                    print(f"      段 {seg} 失败: {e}")
                finally:
                    with self.lock:
                        self.stats[h].active -= 1
        ths = [threading.Thread(target=work) for _ in range(self.conn)]
        t0 = time.time()
        for t in ths: t.start()
        for t in ths: t.join(timeout=600)
        return time.time() - t0, res


def sched_stormdl(dl):
    """schema: 每次取 score 最高的 host —— stormdl 的 select_for_segment 语义"""
    return lambda seg, d: d._pick()


def sched_pick_best_probe(hosts):
    st = {"best": None, "probed": 0}
    def s(seg, dl):
        if st["probed"] < len(hosts):
            h = hosts[st["probed"]]; st["probed"] += 1; return h
        if st["best"] is None:
            st["best"] = max(hosts, key=lambda h: dl.stats[h].avg_speed())
        return st["best"]
    return s


def sched_equal(hosts):
    c = {"i": 0}
    def s(seg, dl):
        h = hosts[c["i"] % len(hosts)]; c["i"] += 1; return h
    return s


def main():
    SEG, SIZE, CONN = 24, 512 * 1024, 12
    totals_mib = {
        "upos-sz-mirror08c":   2.0,
        "upos-sz-mirrorcos":   3.0,
        "upos-sz-mirroraliov": 1.0,
        "upos-sz-mirrorhw":    0.5,
    }
    totals = {n: int(v * MiB) for n, v in totals_mib.items()}
    srv, port = make_server(SEG, SIZE, totals)
    data_mb = SEG * SIZE / MiB
    try:
        print("=" * 82)
        print("多 CDN 并发：采用 stormdl 调度算法（令牌桶确定性限速）")
        print("=" * 82)
        print(f"数据 {data_mb:.1f} MiB = {SEG} 段 × {SIZE//1024} KiB，连接数 {CONN}")
        print("各 CDN 总带宽上限（MiB/s）：")
        for n, v in totals_mib.items():
            print(f"   {v:4.1f}   {n}")
        best = max(totals_mib.values()); sm = sum(totals_mib.values())
        print(f"\n理论上限：选一个最快的 → {best:.1f}；多 CDN 相加 → {sm:.1f}（{sm/best:.2f}×）")
        print()

        print("先量单 CDN 天花板（12 连接全打 mirrorcos）…")
        CdnHandler.limiters = {n: RateLimiter(t) for n, t in totals.items()}
        one = Downloader(port, ["upos-sz-mirrorcos"], SEG, SIZE, CONN)
        el1, _ = one.run(lambda seg, d: "upos-sz-mirrorcos")
        print(f"   实测 {el1:.2f}s → {data_mb/el1:.2f} MiB/s（理论 {best:.1f}）\n")

        trials = [
            ("A. pick-best（≈重定向：选一个最快的）", sched_pick_best_probe(list(totals))),
            ("B. equal-split（平均分给所有 CDN）",   sched_equal(list(totals))),
            ("C. stormdl score-based（取最高分）",    None),   # 特殊：用 dl._pick
        ]
        out = []
        for label, sc in trials:
            CdnHandler.limiters = {n: RateLimiter(t) for n, t in totals.items()}
            dl = Downloader(port, list(totals), SEG, SIZE, CONN)
            fn = sc if sc else (lambda seg, d: d._pick())
            el, res = dl.run(fn)
            good = sum(1 for i in range(SEG)
                       if res.get(i) == bytes(((i*SIZE+j) % 251) for j in range(SIZE)))
            mb = data_mb / el
            print("-" * 82)
            print(f"{label}")
            print(f"   耗时 {el:6.2f}s   {mb:5.2f} MiB/s   内容正确 {good}/{SEG}"
                  f"   相对单CDN天花板 {mb/best*100:5.1f}%")
            print("   连接分配: " + "  ".join(f"{n.split('-')[-1]}={dl.assigned[n]}" for n in totals))
            print("   速度样本均值(MiB/s): " + "  ".join(
                f"{n.split('-')[-1]}={dl.stats[n].avg_speed()/MiB:.2f}" for n in totals))
            out.append((label, el, mb, good == SEG))

        print()
        print("=" * 82)
        base = out[0][1]
        for lbl, el, mb, okc in out:
            print(f"  {lbl:42} {el:6.2f}s  {mb:5.2f} MiB/s  {'OK' if okc else 'BAD'}"
                  f"  相对A {base/el:5.2f}×")
        print()
        ok = all(o[3] for o in out)
        return 0 if ok else 1
    finally:
        srv.shutdown()


if __name__ == "__main__":
    sys.exit(main())
