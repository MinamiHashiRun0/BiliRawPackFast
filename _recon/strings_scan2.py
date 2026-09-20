"""
在已抽取字符串的基础上做第二轮定向分析：
  ① 抽 ObjC 方法索引（-[Class sel] / +[Class sel]），统计类
  ② 定位 playurl 解析链路（决定 CDN 重定向 hook 点）
  ③ 定位 AVAssetResourceLoader / NSURLProtocol（决定并发 hook 点）
  ④ 检查是否已有 CDN 优选/多节点逻辑（决定工作量）
"""
import re, os, json, collections

OUT = r"E:\Documents\DSHWork\BiliRawPackFast\_recon"
with open(os.path.join(OUT, "strings_all.txt"), "r", encoding="utf-8", errors="replace") as f:
    uniq = f.read().splitlines()
print("载入字符串:", len(uniq))

meth_re = re.compile(r"^([-+])\[([A-Za-z_][A-Za-z0-9_]*)\s+([^\]]+)\]$")
methods = collections.defaultdict(list)
for s in uniq:
    m = meth_re.match(s)
    if m:
        methods[m.group(2)].append((m.group(1), m.group(3)))

print("含方法签名的类数:", len(methods))
print("方法签名总数:", sum(len(v) for v in methods.values()))

# --- ① 找出与播放/网络/CDN 相关的类 ---
KEYS = ["player", "Player", "playurl", "PlayUrl", "Play", "cdn", "CDN", "Cdn", "url", "URL", "Url",
        "media", "Media", "download", "Download", "asset", "Asset", "stream", "Stream", "proxy", "Proxy"]
rel = {}
for cls, ms in methods.items():
    if any(k in cls for k in KEYS):
        rel[cls] = ms
print("\n相关类数:", len(rel))

with open(os.path.join(OUT, "objc_methods.tsv"), "w", encoding="utf-8") as f:
    for cls in sorted(rel):
        for sign, sel in sorted(rel[cls]):
            f.write(f"{sign}[{cls} {sel}]\n")
print("方法索引 ->", os.path.join(OUT, "objc_methods.tsv"))

def show(clsname, limit=200):
    if clsname in methods:
        print(f"\n--- {clsname} ({len(methods[clsname])} 条) ---")
        for sign, sel in sorted(methods[clsname])[:limit]:
            print(f"   {sign}[{clsname} {sel}]")
        return True
    return False

# --- ② playurl 链路 ---
print("\n\n########## playurl / PlayUrl 相关类 ##########")
for cls in sorted(methods):
    if re.search(r"playurl|PlayUrl|Playurl|PLAYURL", cls, re.I):
        show(cls, 120)

print("\n\n########## 含 PlayUrl 选择子的类 ##########")
n = 0
for cls in sorted(methods):
    hit = [(s, sel) for s, sel in methods[cls] if re.search(r"playurl|play_url", sel, re.I)]
    if hit:
        print(f"\n--- {cls} ---")
        for s, sel in sorted(hit)[:60]:
            print(f"   {s}[{cls} {sel}]")
        n += 1
    if n > 40:
        break

# --- ③ 资源加载器 / NSURLProtocol ---
print("\n\n########## AVAssetResourceLoader / NSURLProtocol ##########")
for cls in sorted(methods):
    if re.search(r"ResourceLoader|ResourceLoading|URLProtocol|AssetResource", cls):
        show(cls, 100)
for s in uniq:
    if re.search(r"NSURLProtocol|URLProtocol|registerClass|canInitWithRequest|canonicalRequest", s) and len(s) < 160:
        print("   str:", s)

# --- ④ 已有 CDN 相关类 ---
print("\n\n########## CDN 相关类（前 60）##########")
cdn_classes = [c for c in sorted(methods) if re.search(r"cdn|CDN|Cdn", c)]
print("总数:", len(cdn_classes))
for c in cdn_classes[:60]:
    print("   ", c, f"({len(methods[c])})")

print("\n\n########## BFCPlayer / BBAVPlayer 家族 ##########")
for c in sorted(methods):
    if re.search(r"BFCPlayer|BBAVPlayer|BBPlayer", c):
        print(f"   {c} ({len(methods[c])})")

# --- ⑤ 镜像/多 host 逻辑（说明 App 已自带优选？）---
print("\n\n########## host / mirror / 优选 相关选择子 ##########")
for cls in sorted(methods):
    hit = [(s, sel) for s, sel in methods[cls]
           if re.search(r"host|mirror|backup|preferred|optimal|best", sel, re.I)]
    if hit and re.search(r"player|cdn|url|host|media|net|config", cls, re.I):
        print(f"\n--- {cls} ---")
        for s, sel in sorted(hit)[:40]:
            print(f"   {s}[{cls} {sel}]")
