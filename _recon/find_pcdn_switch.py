"""
定向搜索：P2P / MCDN 是否有「开关型」偏好键。
如果有，阶段 2 的「绕开 PCDN」可能只需写一个偏好值，而不必 hook 代码 ——
那会是成本最低、也最不容易被完整性检查发现的路径。

同时把 BiliFast（已有的 Surge 模块）里的 CDN 重写实现读一遍，
确认「换 host 后 upsig/hdnts 签名还能不能用」这个关键问题。
"""
import os, re

OUT = r"E:\Documents\DSHWork\BiliRawPackFast\_recon"
strings_path = os.path.join(OUT, "strings_all.txt")
uniq = open(strings_path, encoding="utf-8", errors="replace").read().splitlines()

# ---- 1. 偏好键形式的候选（snake_case，且含 p2p/mcdn/cdn/player 语义）----
key_re = re.compile(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+){1,7}$')
candidates = []
for s in uniq:
    if not key_re.match(s):
        continue
    if re.search(r'p2p|mcdn|pcdn|cdn|preload|prefetch|multi|concurren|parallel|buffer|cache_|_enable|_switch', s):
        candidates.append(s)

print("=== 偏好键形式候选（去重、按名排序）===")
for c in sorted(set(candidates)):
    print("  ", c)
print(f"共 {len(set(candidates))} 个")

# ---- 2. 只关心「开关」语义的 ----
print()
print("=== 带 enable/disable/switch/open/close 语义的候选 ===")
sw = [c for c in sorted(set(candidates)) if re.search(r'enable|disable|switch|open|close|only|forbid|ban', c)]
for c in sw:
    print("  ", c)
print(f"共 {len(sw)} 个")

# ---- 3. p2p / mcdn 全量（不限键形式，看有没有中文或驼峰开关）----
print()
print("=== 含 p2p / mcdn / pcdn 的全部字符串（长度<80）===")
seen = set()
for s in uniq:
    if len(s) < 80 and re.search(r'p2p|mcdn|pcdn|P2P|MCDN|PCDN', s):
        if s not in seen:
            seen.add(s)
for s in sorted(seen):
    print("  ", s)
print(f"共 {len(seen)} 个")

# ---- 4. BiliFast 的 playurl 重写实现 ----
print()
print("=" * 70)
print("=== BiliFast/bili-playurl.js 里的 CDN 重写逻辑 ===")
print("=" * 70)
bf = r"E:\Documents\DSHWork\BiliFast\bili-playurl.js"
if os.path.exists(bf):
    src = open(bf, encoding="utf-8", errors="replace").read()
    print(f"文件大小 {len(src)} 字符")
    # 找与 host/域名替换、签名参数相关的片段
    for pat, title in [
        (r'.{0,120}(base_url|baseUrl|backup_url|backupUrl).{0,200}', "base_url / backup_url 处理"),
        (r'.{0,120}(upsig|uparams|hdnts|deadline|oi=|trid).{0,160}', "签名参数处理"),
        (r'.{0,120}(host|Host|domain|replace).{0,160}', "host 替换"),
    ]:
        hits = re.findall(pat, src)
        print(f"\n--- {title}（{len(hits)} 处）---")
        for h in hits[:12]:
            print("   ", h.replace("\n", " ")[:260])
else:
    print("找不到", bf)

print()
print("=" * 70)
print("=== BiliFast/bili-cdn.js 概览 ===")
bf2 = r"E:\Documents\DSHWork\BiliFast\bili-cdn.js"
if os.path.exists(bf2):
    src2 = open(bf2, encoding="utf-8", errors="replace").read()
    for pat, title in [
        (r'.{0,100}(upos|akam|hw|mcdn|bilivideo).{0,140}', "CDN 域名"),
        (r'.{0,100}(thread|concurren|parallel|Promise\.all).{0,140}', "并发相关"),
    ]:
        hits = re.findall(pat, src2)
        print(f"\n--- {title}（{len(hits)} 处）---")
        for h in hits[:10]:
            print("   ", h.replace("\n", " ")[:230])
else:
    print("找不到", bf2)
