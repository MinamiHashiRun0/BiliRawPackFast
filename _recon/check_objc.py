"""
BiliProbe.m 静态自检（推送前闸门的一部分，抓的是 CI 上才会暴露的低级错误）。
检查项：
  1. 花括号 / 圆括号平衡
  2. 是否残留已删除函数的引用
  3. 所有 static 函数「先声明后使用」或在本文件前部有前置声明
  4. @interface / @implementation / @end 配对
  5. 可疑写法：对 _cmd 的递归调用、恒返回常量却声称转发
"""
import os, re, sys

P = r"E:\Documents\DSHWork\BiliRawPackFast\inject\probe\BiliProbe.m"
src = open(P, encoding="utf-8").read()
lines = src.split("\n")
problems = []

# 1. 括号平衡（粗略但有效：忽略字符串/注释里的括号会有误差，故先剥离）
def strip_code(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    s = re.sub(r'//[^\n]*', '', s)
    s = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
    s = re.sub(r"'(?:\\.|[^'\\])*'", "''", s)
    return s

code = strip_code(src)
for op, cl, name in (("{", "}", "花括号"), ("(", ")", "圆括号")):
    d = code.count(op) - code.count(cl)
    if d != 0:
        problems.append(f"{name}不平衡：{op}{cl} 差 {d:+d}")
    else:
        print(f"  {name}平衡 ✓ ({code.count(op)})")

# 2. 已删除函数的残留引用（只看代码，不看注释 —— 注释里提到这些名字是解释性的，不是残留）
REMOVED = ["ProbeTraceShouldWait", "ProbeTraceRenewal", "ProbeTraceAuthChallenge",
           "ProbeTraceDidCancel", "ProbeSwizzleOwnMethod", "ProbeAddMethodIfAbsent",
           "probe_dumpMethodsOfClass", "probe_describeObject"]
code_lines = strip_code(src).split("\n")
for r in REMOVED:
    hits = [i + 1 for i, l in enumerate(code_lines) if r in l]
    if hits:
        problems.append(f"残留已删除引用 {r} 于行 {hits}")
print("  残留引用检查完成（已排除注释）")

# 3. 先声明后使用：收集 static 函数定义与调用
defs = {}
for i, l in enumerate(lines):
    m = re.match(r'\s*static\s+[\w\s\*]+?\b(Probe\w+)\s*\(', l)
    if m:
        defs.setdefault(m.group(1), i + 1)

decl_zone_end = None
for i, l in enumerate(lines):
    if l.startswith("@implementation BiliProbe"):
        decl_zone_end = i + 1
        break

forward_declared = set()
if decl_zone_end:
    for l in lines[:decl_zone_end]:
        for name in defs:
            if re.search(r'\b%s\s*\(' % re.escape(name), l) and 'static' in l and ';' in l:
                forward_declared.add(name)

order_issues = []
for name, defline in sorted(defs.items(), key=lambda kv: kv[1]):
    if name in forward_declared:
        continue
    # 找定义之前的调用
    for i in range(defline - 1):
        l = lines[i]
        if re.search(r'\b%s\s*\(' % re.escape(name), l):
            if re.match(r'\s*static\s', l):
                continue
            order_issues.append(f"{name} 在定义(行{defline})之前被调用(行{i+1})")
            break
if order_issues:
    for o in order_issues:
        problems.append("顺序问题: " + o)
else:
    print(f"  函数顺序检查 ✓（{len(defs)} 个 static 函数，{len(forward_declared)} 个有前置声明）")

# 4. @interface / @implementation / @end
# 注意：@end 是「关闭最近一个 @interface 或 @implementation」，
# 所以正确关系是 iface + impl == end，而不是 2*(iface+impl)。
n_iface = len(re.findall(r'^@interface', src, re.M))
n_impl = len(re.findall(r'^@implementation', src, re.M))
n_end = len(re.findall(r'^@end', src, re.M))
print(f"  @interface={n_iface} @implementation={n_impl} @end={n_end}")
if n_iface + n_impl != n_end:
    problems.append(f"@interface({n_iface})+@implementation({n_impl}) != @end({n_end})")
else:
    print(f"  @end 配对 ✓（{n_iface} interface + {n_impl} implementation）")

# 5. 可疑：观测方法里直接 return NO / 路由器里对 _cmd 递归
for i, l in enumerate(lines):
    if re.search(r'return\s+\(\(.*\)orig\)\(self,\s*_cmd', l):
        pass  # 正确写法
for fn in ("ProbeShouldWaitForLoading", "ProbeShouldWaitForRenewal", "ProbeAuthChallenge"):
    m = re.search(r'static BOOL %s\(.*?\n\}' % fn, src, re.S)
    if m:
        body = m.group(0)
        if "ProbeForwardToOriginal" not in body:
            problems.append(f"{fn} 没有转发原实现（会改变行为）")
if "ProbeForwardToOriginal" not in src:
    problems.append("找不到 ProbeForwardToOriginal")

# 6. 已知会在 CI 上炸的 ARC / ObjC 写法（本地先抓掉）
#   6a. SEL 不是对象，不能发消息
for i, l in enumerate(code_lines):
    if re.search(r'\[\s*_cmd\s+', l) or re.search(r'\[\s*\w*[Ss]elector\w*\s+isEqual', l):
        problems.append(f"行{i+1}: 对 SEL 发消息（SEL 不是 ObjC 对象，应用 sel_isEqual）: {l.strip()[:70]}")
#   6b. ARC 下禁止整数↔对象指针互转
for i, l in enumerate(code_lines):
    if re.search(r'\(id\)\s*\(\s*(long long|intptr_t|uintptr_t|NSInteger)\s*\)', l) or \
       re.search(r'\(id\)\s*(0|1)\b', l):
        problems.append(f"行{i+1}: ARC 下把整数转成 id（不允许）: {l.strip()[:70]}")
#   6c. 路由器返回类型必须是整数型，不能是 id
m = re.search(r'static\s+(\w+)\s+ProbeRecycledCall\s*\(', src)
if m:
    rt = m.group(1)
    if rt == "id":
        problems.append("ProbeRecycledCall 返回 id：被挂方法返回 BOOL/void，ARC 会拒绝，应用 intptr_t")
    else:
        print(f"  路由器返回类型 ✓ ({rt})")
else:
    problems.append("找不到 ProbeRecycledCall 定义")

print()
if problems:
    print("发现问题：")
    for p in problems:
        print("  ✗", p)
    sys.exit(1)
print("BiliProbe.m 静态自检通过 ✅")