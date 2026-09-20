"""
决定性实验：换 CDN host 后签名还管用吗？

背景：HAR 抓到的真实请求形如
  https://upos-sz-mirroraliov.bilivideo.com/upgcxcode/95/39/41898543995/41898543995-1-504.mp4
  ?e=…&os=akam&og=cos&upsig=…&uparams=e,gen,uipk,oi,trid,mid,deadline,platform
  &hdnts=exp=…~hmac=…&deadline=…&bw=…&qn_dyeid=…

阶段 2 要做「CDN 重定向」，前提是**换 authority 后签名依然有效**。
从参数结构看，uparams 里不含 host，所以 upsig 很可能与 host 无关；
但 hdnts 是 CDN 侧的 token（`os=akam` 暗示 Akamai 风格），
**可能绑定 host**。这一点只能实测。

本脚本：
  1. 从 HAR 取一条真实签名 URL 作基准
  2. 对若干候选 host 发同一个 Range 请求（仅 1 字节，尽量轻）
  3. 比较状态码 —— 200/206 表示该 host 接受该签名；403 表示签名/host 不匹配

注意：HAR 是 2026-09-18 抓的，deadline 可能已过期。
     若基准 host 本身也返回 403，则说明签名过期，本次实验**无结论**（不能据此判断 host 绑定）。
"""
import json, os, re, ssl, sys, urllib.request, urllib.error, socket

HAR = r"E:\Documents\DSHWork\BiliRawPackFast\2026-09-18-064450.har"

# 候选 host：来自 BiliFast 的分类 + HAR 实际用的
CANDIDATES = [
    # (host, 说明)
    ("upos-sz-mirroraliov.bilivideo.com", "HAR 实际用的（阿里海外）——基准"),
    ("upos-sz-mirrorcosov.bilivideo.com", "腾讯海外 ov"),
    ("upos-sz-mirrorhwov.bilivideo.com",  "华为海外 ov"),
    ("upos-sz-mirrorawsov.bilivideo.com", "AWS 海外 ov"),
    ("upos-hz-mirrorakam.akamaized.net",  "Akamai 港澳台"),
    ("upos-sz-mirrorakam.akamaized.net",  "Akamai 深圳"),
    ("upos-sz-mirrorali.bilivideo.com",   "国内镜像（阿里，对照组）"),
    ("upos-sz-mirror08c.bilivideo.com",   "国内 08c（对照组）"),
]

TIMEOUT = 10


def load_base_url():
    with open(HAR, "r", encoding="utf-8", errors="replace") as f:
        har = json.load(f)
    for e in har["log"]["entries"]:
        u = e["request"]["url"]
        if "bilivideo" in u and ".mp4" in u:
            return u
    raise SystemExit("HAR 里没找到视频 URL")


def probe(url, host, label):
    m = re.match(r'https?://([^/]+)(/.*)$', url, re.S)
    path_and_query = m.group(2)
    new_url = "https://" + host + path_and_query
    req = urllib.request.Request(new_url, method="GET")
    req.add_header("Range", "bytes=0-0")          # 只要 1 字节
    req.add_header("Referer", "https://www.bilibili.com")
    req.add_header("User-Agent",
                   "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
                   "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as r:
            return r.status, r.headers.get("Content-Range", ""), r.headers.get("Server", "")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Range", "") if e.headers else "", \
               (e.headers.get("Server", "") if e.headers else "")
    except Exception as e:
        return None, type(e).__name__, str(e)[:80]


def main():
    url = load_base_url()
    host0 = re.match(r'https?://([^/]+)', url).group(1)
    print("基准 URL host:", host0)
    print("路径:", re.sub(r'^https?://[^/]+', '', url).split("?")[0])
    print()
    print("=" * 74)
    print(f"{'host':<38} {'状态':>6}  {'Server':<12} 说明")
    print("=" * 74)

    results = []
    baseline_ok = None
    for i, (h, label) in enumerate(CANDIDATES):
        if i > 0:
            import time; time.sleep(1.2)          # 别打太密
        st, cr, srv = probe(url, h, label)
        results.append((h, st, label))
        if i == 0:
            baseline_ok = (st in (200, 206))
        mark = ""
        if st in (200, 206):
            mark = "✔ 接受该签名"
        elif st == 403:
            mark = "✗ 403（签名或 host 不匹配）"
        elif st is None:
            mark = f"连接失败: {cr}"
        print(f"{h:<38} {str(st):>6}  {str(srv)[:12]:<12} {label} {mark}")

    print("=" * 74)
    print()
    if baseline_ok:
        print("基准 host 成功 → 签名未过期，本次实验**有效**。")
        ok = [h for h, st, _ in results if st in (200, 206)]
        bad = [h for h, st, _ in results if st == 403]
        print(f"  接受签名的 host：{len(ok)}/{len(results)}")
        for h in ok:
            print(f"    ✔ {h}")
        if bad:
            print(f"  拒绝(403)的 host：")
            for h in bad:
                print(f"    ✗ {h}")
        if len(ok) > 1:
            print("\n  ★ 结论：签名**不绑定 host**，换 CDN 可行 → 阶段 2 可直接改 authority")
        else:
            print("\n  ★ 结论：只有基准 host 接受 → 签名疑似绑定 host，需要另找注入点")
    else:
        print("基准 host 也失败 → 签名很可能已过期（HAR 是 2026-09-18 抓的）。")
        print("本次实验**无结论**，不能据此判断 host 绑定。")
        print("→ 需要一条**新鲜**的 URL 才能做这个判定。")


if __name__ == "__main__":
    main()
