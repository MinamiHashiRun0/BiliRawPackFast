"""
从脱壳二进制的 ObjC 元数据里恢复方法签名（type encoding）。

为什么这件事重要：
  阶段 2/3 要 hook BBRResourceLoaderManager 的委托方法与 _requestCDNNode 之类的
  CDN 选择点。这些是私有方法，头文件里没有，签名（参数个数、类型、返回值）
  只能靠**回传的真机日志**或**从二进制里挖**。
  真机日志一直拿不到，所以这里走第二条路 —— 不需要设备，现在就能做。

  原理：ObjC 的每个方法在 __objc_methlist / __objc_const 里带一个 type encoding
  字符串，例如 "v32@0:8@16@"、"{?=}" / "B@:@@@" 之类。
  它精确描述了返回值与各参数的类型，足够写出正确的 hook 函数指针转换。

做法：
  1. 从已抽取的字符串里筛出「像 type encoding」的串
     （首字符是合法返回类型码，且后面跟着数字偏移，如 "v32@0:"）
  2. 按含 @ / ^ / : 的数量分类，输出可用签名
  3. 另外单独列出所有含 P2P / CDN / 资源加载相关类名的方法名，
     与 type encoding 一起人工配对（ObjC 元数据里两者分表存放，
     位置配不准，所以这里如实标注为"需要人工配对"而不是假装精确）
"""
import os, re, collections, json

OUT = r"E:\Documents\DSHWork\BiliRawPackFast\_recon"
uniq = open(os.path.join(OUT, "strings_all.txt"), encoding="utf-8", errors="replace").read().splitlines()

# ObjC type encoding：以返回类型码开头，随后是 <offset><typecode> 循环
RET_CODES = set("vBcCsSiIlLqQfFdD@#:^?{[()b")
enc_re = re.compile(r'^[vBcCsSiIlLqQfFdD@#:^?{(\[][0-9A-Za-z@#:^?*\[\]{}()=<>_,".]*$')


def looks_like_encoding(s):
    if not s or len(s) < 6 or len(s) > 120:
        return False
    if s[0] not in RET_CODES:
        return False
    if not enc_re.match(s):
        return False
    # 至少要有「位数 + 类型码」的成对结构，避免把普通短串误判
    return bool(re.search(r'\d+[@#:^?*\[{(]', s)) or s.startswith("{") or s.startswith("(")


encodings = [s for s in uniq if looks_like_encoding(s)]
print(f"字符串总量 {len(uniq):,}，其中疑似 type encoding {len(encodings):,} 条")

# 统计常见签名形态
def classify(e):
    if e.startswith("v"):
        return "void 返回"
    if e.startswith("B") or e.startswith("c"):
        return "BOOL/char 返回"
    if e.startswith("@"):
        return "对象返回"
    if e.startswith("^"):
        return "指针返回"
    if e.startswith("{"):
        return "结构体返回"
    return "其它"


buckets = collections.Counter(classify(e) for e in encodings)
print("\n按返回类型分布：")
for k, v in buckets.most_common():
    print(f"  {k:16s} {v:,}")

# 重点：委托方法常见的签名形态
# 注意：编码里的偏移可以是多位数（如 @0:8@16@24Q32），
# 第一版正则写成 \d+ 但只允许单个类型码跟一位数字，导致 miss 掉绝大多数。
# 改为按「位数 + 类型码」的成对结构整体匹配。
print("\n=== 候选签名：0~4 个对象参数（委托方法基本都是这个形态）===")
pair = r'\d+[@#:^?*\[\{(=b]'
shape_re = {
    0: re.compile(r'^([vBcCsSiIlLqQfFdD@^])' + pair + r'$'),
    1: re.compile(r'^([vBcCsSiIlLqQfFdD@^])' + pair + r'\d+[@:$]' + r'$'),
    2: re.compile(r'^([vBcCsSiIlLqQfFdD@^])' + pair + r'\d+[@:$]' + pair + r'$'),
    3: re.compile(r'^([vBcCsSiIlLqQfFdD@^])' + pair + r'\d+[@:$]' + pair + r'\d+[@:$]' + r'$'),
    4: re.compile(r'^([vBcCsSiIlLqQfFdD@^])' + pair + r'\d+[@:$]' + pair + r'\d+[@:$]' + pair + r'$'),
}
candidates = collections.defaultdict(set)
for e in encodings:
    for n, rx in shape_re.items():
        if rx.match(e):
            candidates[n].add(e)
            break
for n in sorted(candidates):
    items = sorted(candidates[n])
    print(f"\n  --- 约 {n} 个参数（{len(items)} 种）---")
    for e in items[:24]:
        print("      ", e)
    if len(items) > 24:
        print(f"       … 另有 {len(items)-24} 种")

# 按「参数个数」直接给出最可能的委托签名（资源加载委托 = 3 参数：self,_cmd,loader,request）
print("\n=== 对照：AVAssetResourceLoaderDelegate 的标准签名（来自 SDK，非二进制）===")
for s in ["B@:@@            resourceLoader:shouldWaitForLoadingOfRequestedResource:",
          "B@:@@            resourceLoader:shouldWaitForRenewalOfRequestedResource:",
          "B@:@@            resourceLoader:shouldWaitForResponseToAuthenticationChallenge:",
          "v@:@@            resourceLoader:didCancelLoadingRequest:"]:
    print("   ", s)

interesting = sorted(set().union(*candidates.values()) if candidates else set())

# 与播放/CDN 相关的方法名（用于人工配对）
print("\n=== CDN / P2P / 资源加载相关的类与方法名（摘自方法索引）===")
REL = re.compile(r'P2P|Pcdn|PCDN|Mcdn|MCDN|ResourceLoader|CDNNode|CDNConn|PlayItem|MediaPlayerItem|playUrl|PlayUrl', re.I)
hits = [s for s in uniq if REL.search(s) and (s.startswith("-") or s.startswith("+"))]
print(f"  共 {len(hits)} 条")
by_class = collections.defaultdict(list)
meth_re = re.compile(r'^([-+])\[([A-Za-z_][A-Za-z0-9_]*)\s+([^\]]+)\]$')
for s in hits:
    m = meth_re.match(s)
    if m:
        by_class[m.group(2)].append(m.group(1) + m.group(3))

for cls in sorted(by_class):
    ms = sorted(set(by_class[cls]))
    print(f"\n  ## {cls}  ({len(ms)} 个方法)")
    for x in ms[:40]:
        print("      ", x[:150])
    if len(ms) > 40:
        print(f"       … 另有 {len(ms)-40} 个")

json.dump({
    "encoding_count": len(encodings),
    "delegate_like_encodings": sorted(set(interesting)),
    "by_class": {k: sorted(set(v)) for k, v in by_class.items()},
    "note": "type encoding 与方法名在 ObjC 元数据里分表存放，此处不假装精确配对；"
            "delegate_like_encodings 给出候选签名，供写 hook 时选择函数指针类型",
}, open(os.path.join(OUT, "objc_signatures.json"), "w", encoding="utf-8"),
   ensure_ascii=False, indent=2)
print("\n已写 _recon/objc_signatures.json")
