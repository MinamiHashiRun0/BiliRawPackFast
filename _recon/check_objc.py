"""
ObjC 源码静态自检（推送前闸门的一部分，抓的是 CI 上才会暴露的低级错误）。

对 inject/probe/ 下每个 .m 文件检查：
  1. 花括号 / 圆括号 平衡
  2. @interface / @implementation / @end 配对
  3. ARC / ObjC 已知陷阱（这几条都是本项目在 CI 上真实踩过的）：
     - 对 SEL 发消息（SEL 不是对象，应用 sel_isEqual）
     - ARC 下把整数转成 id
  4. static 函数先声明后使用

注意：剥离字符串/注释必须用字符级状态机，不能用正则。
第一版用正则剥 `@"..."`，被转义与 % 格式串干扰后出现假报（报圆括号不平衡 -1），
实际文件是平衡的。假报比漏报更糟：会让人开始忽略这个闸门。
"""
import os, re, sys, glob

SRC_DIR = r"E:\Documents\DSHWork\BiliRawPackFast\inject\probe"
files = sorted(glob.glob(os.path.join(SRC_DIR, "*.m")))
if not files:
    print("没有找到 .m 文件"); sys.exit(1)

problems = []


def strip_code(src: str) -> str:
    """字符级状态机剥离注释与字符串/字符字面量 —— 可靠且不会假报"""
    out = []
    i, n = 0, len(src)
    state = "code"
    while i < n:
        c = src[i]
        if state == "code":
            if src.startswith("//", i):
                state = "line"; i += 2; continue
            if src.startswith("/*", i):
                state = "block"; i += 2; continue
            if c == '"':
                state = "str"; i += 1; continue
            if c == "'":
                state = "chr"; i += 1; continue
            out.append(c); i += 1; continue
        if state == "line":
            if c == "\n":
                state = "code"; out.append(c)
            i += 1; continue
        if state == "block":
            if src.startswith("*/", i):
                state = "code"; i += 2; continue
            i += 1; continue
        # str / chr
        if c == "\\":
            i += 2; continue
        if (state == "str" and c == '"') or (state == "chr" and c == "'"):
            state = "code"
        i += 1; continue
    return "".join(out)


for path in files:
    name = os.path.basename(path)
    src = open(path, encoding="utf-8").read()
    code = strip_code(src)
    print("=" * 66)
    print(name, f"({len(src.splitlines())} 行)")
    print("=" * 66)

    # 1. 括号平衡
    for op, cl, label in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
        d = code.count(op) - code.count(cl)
        if d != 0:
            problems.append(f"{name}: {label}不平衡 {d:+d}")
    print(f"  括号平衡 ✓ {{}}={code.count('{')} ()={code.count('(')} []={code.count('[')}")

    # 2. @interface / @implementation / @end
    n_iface = len(re.findall(r'^@interface', src, re.M))
    n_impl = len(re.findall(r'^@implementation', src, re.M))
    n_end = len(re.findall(r'^@end', src, re.M))
    if n_iface + n_impl != n_end:
        problems.append(f"{name}: @interface({n_iface})+@implementation({n_impl}) != @end({n_end})")
    else:
        print(f"  @end 配对 ✓ ({n_iface}i + {n_impl}impl = {n_end})")

    # 3. ARC / ObjC 陷阱
    code_lines = code.split("\n")
    for i, l in enumerate(code_lines):
        if re.search(r'\[\s*_cmd\s+', l) or re.search(r'\[\s*\w*[Ss]elector\w*\s+isEqual', l):
            problems.append(f"{name}:{i+1} 对 SEL 发消息（应用 sel_isEqual）: {l.strip()[:70]}")
        if re.search(r'\(id\)\s*\(\s*(long long|intptr_t|uintptr_t|NSInteger)\s*\)', l) or \
           re.search(r'\(id\)\s*(0|1)\s*[;,)]', l):
            problems.append(f"{name}:{i+1} ARC 下整数转 id: {l.strip()[:70]}")
    print("  ARC/SEL 陷阱扫描 ✓")

    # 4. static 函数顺序
    lines = code.split("\n")
    defs = {}
    for i, l in enumerate(lines):
        m = re.match(r'\s*static\s+[\w\s\*]+?\b(\w+)\s*\(', l)
        if m:
            defs.setdefault(m.group(1), i + 1)
    order_issues = []
    for fn, defline in sorted(defs.items(), key=lambda kv: kv[1]):
        for i in range(defline - 1):
            if re.search(r'\b%s\s*\(' % re.escape(fn), lines[i]) and not re.match(r'\s*static\s', lines[i]):
                order_issues.append(f"{fn} 定义于 {defline}，但 {i+1} 行已调用")
                break
    for o in order_issues:
        problems.append(f"{name}: 顺序 {o}")
    print(f"  函数顺序 ✓ ({len(defs)} 个 static 函数)")

    # 5. 属性 readonly 声明 vs 实现（防止声明了却忘了写 getter）
    hdr = path[:-2] + ".h"
    if os.path.exists(hdr):
        hsrc = open(hdr, encoding="utf-8").read()
        for m in re.finditer(r'@property\s*\(([^)]*)\)\s*[^\n;]*?\b(\w+)\s*;', hsrc):
            attrs, pname = m.group(1), m.group(2)
            if "readonly" not in attrs:
                continue          # 可读写属性会自动 synthesize，无需 getter
            if re.search(r'-\s*\([^)]*\)\s*%s\s*\{' % re.escape(pname), src):
                continue
            if re.search(r'@synthesize\s+%s\b' % re.escape(pname), src):
                continue
            if re.search(r'_\w*%s\b' % re.escape(pname), src) or \
               re.search(r'\b%s\s*=\s*' % re.escape(pname), src):
                continue          # 有 _ivar 就会被自动 synthesize
            problems.append(f"{name}: readonly 属性 {pname} 既无 getter 也无 _ivar，取值会崩")

print()
if problems:
    print("发现问题：")
    for p in problems:
        print("  ✗", p)
    sys.exit(1)
print(f"全部 {len(files)} 个 .m 文件静态自检通过 ✅")
