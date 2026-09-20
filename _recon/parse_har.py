"""
从 Surge 抓的 HAR 里提取视频流请求，重点回答三个阶段 2 的关键问题：

  Q1 m4s 走的是哪些 host？（国内镜像 / 港澳台 / PCDN / akamai）
  Q2 URL 的签名参数长什么样？（upsig / uparams / hdnts / deadline / oi / os / og）
  Q3 这些签名是否与 host 绑定？—— 决定「换 CDN 时能否沿用签名」

不打印完整 token（可能含账号态信息），只打印结构与长度。
"""
import json, re, sys, collections, os

HAR = r"E:\Documents\DSHWork\BiliRawPackFast\2026-09-18-064450.har"
if not os.path.exists(HAR):
    print("找不到 HAR:", HAR); sys.exit(1)

print("读取 HAR（约 9MB，稍等）…")
with open(HAR, "r", encoding="utf-8", errors="replace") as f:
    har = json.load(f)

entries = har["log"]["entries"]
print(f"共 {len(entries)} 条请求\n")

def host_of(url):
    m = re.match(r'https?://([^/]+)', url)
    return m.group(1) if m else "?"

# ---- 分类统计 ----
by_host = collections.Counter()
media = []
for e in entries:
    req = e.get("request", {})
    url = req.get("url", "")
    host = host_of(url)
    by_host[host] += 1
    if re.search(r'\.(m4s|mp4|flv|ts)(\?|$)', url) or "bilivideo" in host or "akamaized" in host or "mcdn" in host:
        media.append(e)

print("=== 全部 host 统计（前 25）===")
for h, c in by_host.most_common(25):
    print(f"  {c:>5}  {h}")

print()
print(f"=== 疑似媒体/视频流请求：{len(media)} 条 ===")
seen_hosts = collections.Counter()
for e in media:
    u = e["request"]["url"]
    seen_hosts[host_of(u)] += 1
for h, c in seen_hosts.most_common():
    print(f"  {c:>5}  {h}")

# ---- 精确定位 m4s ----
m4s = [e for e in entries if re.search(r'\.m4s(\?|$)', e["request"]["url"])]
print()
print(f"=== .m4s 请求：{len(m4s)} 条 ===")
for i, e in enumerate(m4s[:6]):
    u = e["request"]["url"]
    host = host_of(u)
    path = re.sub(r'^https?://[^/]+', '', u).split("?")[0]
    q = u.split("?", 1)[1] if "?" in u else ""
    params = dict(re.findall(r'([^&=]+)=([^&]*)', q))
    print(f"\n--- m4s #{i+1} ---")
    print(f"  host : {host}")
    print(f"  path : {path}")
    print(f"  serverIPAddress: {e['request'].get('serverIPAddress','?')}")
    print(f"  查询参数（{len(params)} 个）:")
    for k in sorted(params):
        v = params[k]
        # token 类只显示结构，不泄露完整值
        if k in ("upsig", "hdnts", "e", "uparams") or len(v) > 60:
            print(f"      {k:<12} = <{len(v)} 字符> 前缀={v[:12]}…")
        else:
            print(f"      {k:<12} = {v}")
    # 请求头里的 Range / Referer / UA
    hs = {h["name"].lower(): h["value"] for h in e["request"].get("headers", [])}
    for k in ("range", "referer", "user-agent", "origin"):
        if k in hs:
            print(f"  header {k}: {hs[k][:110]}")

# ---- 关键判定：是否存在多条不同 host 的同类 m4s（说明 App 自己就在换 CDN） ----
print()
print("=" * 66)
print("=== 判定：同一 cid 的 m4s 在不同 host 上出现过吗？===")
print("=" * 66)
by_cid = collections.defaultdict(set)
for e in m4s:
    u = e["request"]["url"]
    m = re.search(r'/(\d+)-1-(\d+)\.m4s', u)
    if m:
        by_cid[(m.group(1), m.group(2))].add(host_of(u))
multi = {k: v for k, v in by_cid.items() if len(v) > 1}
print(f"  出现的 (cid, 清晰度) 组合: {len(by_cid)}")
for k, hosts in list(by_cid.items())[:12]:
    mark = " ← 多 host" if len(hosts) > 1 else ""
    print(f"    cid={k[0]} qn={k[1]}: {sorted(hosts)}{mark}")
if multi:
    print(f"\n  ★ 有 {len(multi)} 个组合出现在多个 host 上 → App 自己在做 CDN 切换")
else:
    print("\n  所有 m4s 都只用了一个 host")
