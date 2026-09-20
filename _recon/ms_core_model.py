#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bsp_ms_core.c 的等价 Python 模型。

目的：本机没有 C 编译器，CI 又要等。先用 Python 把同一套算法跑一遍，
确认 test_ms_core.c 里那些「理论值」断言是对的 —— 否则 CI 红了也分不清
是代码错还是我算错了。
两边必须逐条对齐：评分公式、令牌桶、pick 规则、滑动窗口。
"""

WINDOW = 10
MAXH = 64


class Host:
    def __init__(self, name, cap, burst):
        self.name = name
        self.healthy = True
        self.active = 0
        self.errors = 0
        # 定长环形缓冲，与 bsp_ms_core.c 的 speed_buf/speed_len/speed_pos 一一对应
        self.buf = [0.0] * WINDOW
        self.speed_len = 0
        self.pos = 0
        self.sum = 0.0
        self.tokens = burst
        self.cap = cap
        self.burst = burst
        self.refilled_at = 0.0

    def mean(self):
        return self.sum / self.speed_len if self.speed_len > 0 else 0.0

    def score(self):
        return ((self.mean() + 1.0)
                * (1.0 / (1.0 + self.errors * 0.5))
                * (1.0 / (1.0 + self.active * 0.1)))


class Planner:
    def __init__(self, n, cap, burst):
        if cap > 0 and burst < cap:
            burst = cap
        self.h = [Host("h%d" % i, cap if cap > 0 else 0.0,
                       burst if cap > 0 else 0.0) for i in range(n)]

    def tick(self, now):
        for h in self.h:
            if h.cap <= 0:
                h.refilled_at = now
                continue
            dt = now - h.refilled_at
            if dt <= 0:
                continue
            h.tokens = min(h.burst, h.tokens + dt * h.cap)
            h.refilled_at = now

    def tokens_at(self, i, now):
        h = self.h[i]
        if h.cap <= 0:
            return 1e18
        dt = now - h.refilled_at
        if dt <= 0:
            return h.tokens
        return min(h.burst, h.tokens + dt * h.cap)

    def wait_for(self, i, need, now):
        h = self.h[i]
        if h.cap <= 0:
            return 0.0
        d = need - self.tokens_at(i, now)
        return d / h.cap if d > 0 else 0.0

    def pick(self, need, now):
        best_scored, best_score = -1, -1.0
        best_tok, best_tok_i, best_tok_score = -1.0, -1, -1.0
        for i, h in enumerate(self.h):
            if not h.healthy:
                continue
            tok = self.tokens_at(i, now)
            sc = h.score()
            if tok >= need and sc > best_score:
                best_score, best_scored = sc, i
            if tok > best_tok or (tok == best_tok and sc > best_tok_score):
                best_tok, best_tok_i, best_tok_score = tok, i, sc
        return best_scored if best_scored >= 0 else best_tok_i

    def begin(self, i, nbytes, now):
        self.tick(now)
        h = self.h[i]
        h.tokens -= nbytes
        if h.cap > 0 and h.tokens < -h.burst:
            h.tokens = -h.burst
        h.active += 1

    def finish(self, i, nbytes, secs, error):
        h = self.h[i]
        if h.active > 0:
            h.active -= 1
        if error:
            h.errors += 1
            return
        if nbytes <= 0 or secs <= 0:
            return
        sp = nbytes / secs
        if h.speed_len == WINDOW:
            h.sum -= h.buf[h.pos]
        else:
            h.speed_len += 1
        h.buf[h.pos] = sp
        h.sum += sp
        h.pos = (h.pos + 1) % WINDOW


def run_transfer(cap, nhosts, total, chunk, verbose=False):
    p = Planner(nhosts, cap, cap)
    now = 0.0
    served = 0
    guard = 0
    per = [0] * nhosts
    while served < total and guard < 1_000_000:
        guard += 1
        h = p.pick(chunk, now)
        if h < 0:
            break
        w = p.wait_for(h, chunk, now)
        if w > 0:
            now += w
            p.tick(now)
        p.begin(h, chunk, now)
        served += chunk
        per[h] += chunk
        p.finish(h, chunk, 1.0, 0)
    if verbose:
        print("      各主机 MiB", [round(x / 1048576, 2) for x in per])
    return now, served


def main():
    print("=== Python 模型：核对我写在 C 测试里的理论值 ===")

    CAP = 3145728.0          # 3 MiB/s
    TOTAL = 24 << 20
    CHUNK = 262144

    t1, s1 = run_transfer(CAP, 1, TOTAL, CHUNK, verbose=True)
    t4, s4 = run_transfer(CAP, 4, TOTAL, CHUNK, verbose=True)
    expect = (TOTAL - int(CAP)) / CAP
    print("[9] 单链路 %.3fs（我断言 expect=%.3f）  4链路 %.3fs  提速 %.2fx"
          % (t1, expect, t4, t1 / t4))
    print("    单链路断言 expect-0.05 <= t <= expect+0.6 -> %s"
          % ("通过" if expect - 0.05 <= t1 <= expect + 0.6 else "★ 不通过"))
    print("    4链路断言 t <= 2.5 -> %s" % ("通过" if t4 <= 2.5 else "★ 不通过"))

    # [6] 4 台各 1MiB/s 送 32MiB
    C2, T2, K2 = 1048576.0, 32 << 20, 262144
    t6, s6 = run_transfer(C2, 4, T2, K2, verbose=True)
    print("[6] 4×1MiB/s 送 32MiB 用时 %.3fs（断言 <=10.0 -> %s）"
          % (t6, "通过" if t6 <= 10.0 else "★ 不通过"))
    lo = t6 * C2 - C2 - K2
    print("    每主机下界 %.2f MiB（实际 8.00 MiB）" % (lo / 1048576))

    # [7] 单台 3MiB/s 送 24MiB
    t7, s7 = run_transfer(3145728.0, 1, 24 << 20, 262144)
    e7 = ((24 << 20) - 3145728) / 3145728.0
    print("[7] 单台 3MiB/s 送 24MiB 用时 %.3fs，理论 %.3fs（断言 %.3f±）-> %s"
          % (t7, e7, e7, "通过" if e7 - 0.05 <= t7 <= e7 + 1.0 else "★ 不通过"))

    # [5a] 同速 12 片在途应分散到 4 台各 3 片
    p = Planner(4, 0, 0)
    cnt = [0] * 4
    for _ in range(12):
        h = p.pick(CHUNK, 0.0)
        p.begin(h, CHUNK, 0.0)
        cnt[h] += 1
    print("[5a] 在途分布 %s（断言 3/3/3/3）-> %s"
          % (cnt, "通过" if cnt == [3, 3, 3, 3] else "★ 不通过"))

    # [5b] 贪心 + 健康度
    q = Planner(4, 0, 0)
    for _ in range(WINDOW):
        q.finish(0, 8 << 20, 1.0, 0)
        q.finish(1, 2 << 20, 1.0, 0)
        q.finish(2, 209715, 1.0, 0)
        q.finish(3, 8 << 20, 1.0, 0)
    q.finish(3, 0, 0, 1)
    q.finish(3, 0, 0, 1)
    seq = []
    seq.append(q.pick(CHUNK, 0.0))
    q.h[0].healthy = False
    seq.append(q.pick(CHUNK, 0.0))
    q.h[3].healthy = False
    seq.append(q.pick(CHUNK, 0.0))
    q.h[1].healthy = False
    seq.append(q.pick(CHUNK, 0.0))
    print("[5b] 依次 pick = %s（断言 [0,3,1,2]）-> %s"
          % (seq, "通过" if seq == [0, 3, 1, 2] else "★ 不通过"))

    # [1] 评分公式
    r = Planner(2, 0, 0)
    print("[1] 空 %s" % r.h[0].score())
    for _ in range(WINDOW):
        r.finish(0, 1000, 1.0, 0)
    print("    10×1000B/s mean=%.1f score=%.1f" % (r.h[0].mean(), r.h[0].score()))
    for _ in range(WINDOW):
        r.finish(0, 2000, 1.0, 0)
    print("    再来 10×2000B/s mean=%.1f" % r.h[0].mean())
    r.finish(0, 0, 0, 1)
    print("    1 次错误 score=%.4f 期望 %.4f" % (r.h[0].score(), 2001.0 / 1.5))
    r.begin(0, 0, 0.0)
    r.begin(0, 0, 0.0)
    print("    active=2 score=%.4f 期望 %.4f" % (r.h[0].score(), 2001.0 / 1.5 / 1.2))

    # [2] 令牌桶
    t = Planner(2, 1048576.0, 1048576.0)
    print("[2] 开局桶=%.0f" % t.h[0].tokens)
    for _ in range(4):
        t.begin(0, 262144, 0.0)
    print("    4×256K 后桶=%.0f" % t.h[0].tokens)
    print("    pick(256K) = %d（期望 1）" % t.pick(262144, 0.0))
    t.tick(0.5)
    print("    0.5s 后 host0 桶=%.0f（期望 524288）" % t.tokens_at(0, 0.5))
    t.tick(100.0)
    print("    100s 后封顶=%.0f（期望 1048576）" % t.tokens_at(0, 100.0))
    t.begin(0, 1048576, 100.0)
    print("    掏空后 wait(512K)=%.4f（期望 0.5）" % t.wait_for(0, 524288, 100.0))


if __name__ == "__main__":
    main()
