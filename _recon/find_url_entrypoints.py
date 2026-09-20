"""
从本地类转储里系统性地找出「视频 URL 的入口」

不再逐个猜类名。做法：
  1. 遍历 classes.txt 里所有类，筛出自有的（BB/BFC/BGM/Bili/IJK/srcs）
  2. 对每个类，找出**接收 URL 的方法**（选择子含 URL/Url/url 且形如 init/set/create/play）
  3. 按"离播放最近"排序输出

这就是「挖本地静态文件」该做的事 —— 一次把所有候选入口列全。
"""
import os, re, collections, sys

CAND_DIRS = [
    r"E:\Documents\DSHWork\BiliRawPackFast\_biliprobe7\biliprobe",
    r"E:\Documents\DSHWork\BiliRawPackFast\_biliprobe6\biliprobe",
]
src = None
for d in CAND_DIRS:
    p = os.path.join(d, "classes.txt")
    if os.path.exists(p):
        src = p
        break
if not src:
    print("找不到 classes.txt"); sys.exit(1)
print(f"读取 {src}  ({os.path.getsize(src):,} 字节)\n")

lines = open(src, encoding="utf-8", errors="replace").read().split("\n")

# 解析成 {类名: [方法行]}
classes = {}
cur = None
for ln in lines:
    m = re.match(r"^## (.+?)\s*$", ln)
    if m:
        cur = m.group(1)
        classes[cur] = []
        continue
    if cur and ln.strip().startswith(("-", "+")):
        classes[cur].append(ln.strip())
print(f"解析出 {len(classes)} 个类\n")

OWN = re.compile(r"^(BB|BFC|BGM|Bili|IJK|MAD|srcs|Cloud|LPAudio|LPVideo)")
own = {k: v for k, v in classes.items() if OWN.match(k)}
print(f"其中自有类 {len(own)} 个\n")

# --- 1) 接收 URL 的方法 ---
URL_M = re.compile(r"[-+]\s*\(([^)]*)\)\s*([A-Za-z0-9_]*(?:URL|Url|url)[A-Za-z0-9_]*)")
PRIORITY = [
    # (正则, 权重, 说明)
    (r"initWithContentURL", 100, "播放器内容 URL（最可能的主入口）"),
    (r"initWithURLString:",   95, "字符串形式的 URL 入口"),
    (r"initWithURL:",         90, "URL 对象入口"),
    (r"createAssetWith",      85, "创建 AVAsset（URL → 播放）"),
    (r"setURL:|setUrl:",      70, "设置 URL"),
    (r"assetWithURL|URLAssetWithURL", 65, "构造 AVURLAsset"),
    (r"resolver|Resolver",    60, "playurl 解析（URL 从此产生）"),
    (r"downloadTask.*Offset", 55, "段级下载（真正的字节入口）"),
    (r"startLoading|openSocket|connect", 50, "底层开始加载"),
    (r"URL",                  10, "其它含 URL 的方法"),
]

rows = []
for cls, meths in own.items():
    for m in meths:
        mm = URL_M.search(m)
        if not mm:
            continue
        sel = mm.group(2)
        score, note = 1, "含 URL"
        for pat, w, desc in PRIORITY:
            if re.search(pat, sel, re.I):
                if w > score:
                    score, note = w, desc
        rows.append((score, cls, m, note))

rows.sort(key=lambda r: (-r[0], r[1]))
print("=" * 100)
print("接收 URL 的方法（按'离播放最近'排序）")
print("=" * 100)
seen = set()
for score, cls, m, note in rows[:70]:
    key = (cls, m)
    if key in seen:
        continue
    seen.add(key)
    print(f"  [{score:3d}] {cls}")
    print(f"        {m}")
    print(f"        → {note}")

# --- 2) 专门列「播放器」相关类的全部入口 ---
print()
print("=" * 100)
print("播放器相关自有类（类名含 Player/player）")
print("=" * 100)
pl = sorted(k for k in own if re.search(r"player|Player", k))
print(f"共 {len(pl)} 个\n")
for k in pl:
    ents = [m for m in own[k]
            if re.search(r"initWith|createAsset|setDataSource|setURL|setUrl|prepare|open|start|load", m, re.I)]
    if ents:
        print(f"  ## {k}")
        for e in ents[:14]:
            print(f"      {e}")

# --- 3) 输出到文件备用 ---
out = r"E:\Documents\DSHWork\BiliRawPackFast\_recon\url_entrypoints.txt"
with open(out, "w", encoding="utf-8") as f:
    for score, cls, m, note in rows:
        f.write(f"[{score:3d}] {cls}\t{m}\t{note}\n")
print(f"\n完整结果已写 {out}（{len(rows)} 条）")
