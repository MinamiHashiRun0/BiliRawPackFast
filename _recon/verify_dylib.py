"""
独立复核 CI 产出的 BiliProbe.dylib（不依赖 macOS 工具，自己解析 Mach-O）。

复核项：
  1. 架构 = arm64（CPU_TYPE_ARM64 = 0x0100000C），瘦切片
  2. filetype = MH_DYLIB (6)
  3. 没有 LC_ENCRYPTION_INFO（注入用的 dylib 不该有加密段）
  4. 依赖列表全部为系统库 / @executable_path / @rpath
  5. LC_ID_DYLIB 的 install name 是不是 @executable_path/Frameworks/BiliProbe.dylib
  6. LC_BUILD_VERSION 的 platform 是 iOS(2)、minos 是否 <= 14.0
  7. 导出的 ObjC 类 / 构造函数符号是否在
"""
import os, struct, sys

p = r"E:\Documents\DSHWork\BiliRawPackFast\_artifact\BiliProbe-dylib\BiliProbe.dylib"
if not os.path.exists(p):
    print("找不到 dylib:", p); sys.exit(1)

data = open(p, "rb").read()
print(f"文件: {p}")
print(f"大小: {len(data):,} 字节")

MH_MAGIC_64 = 0xFEEDFACF
magic = struct.unpack_from("<I", data, 0)[0]
assert magic == MH_MAGIC_64, f"magic 错误 {hex(magic)}"

(cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, _) = struct.unpack_from("<iiIIIII", data, 4)

CPU = {0x0100000C: "arm64", 0x0200000C: "arm64e", 0x01000007: "x86_64"}
FTYPE = {1: "MH_OBJECT", 2: "MH_EXECUTE", 6: "MH_DYLIB", 8: "MH_BUNDLE"}

print()
print("=== 头部 ===")
print(f"  cputype    = {CPU.get(cputype, hex(cputype))} ({hex(cputype)})")
print(f"  cpusubtype = {hex(cpusubtype & 0xFFFFFFFF)}")
print(f"  filetype   = {FTYPE.get(filetype, filetype)}")
print(f"  ncmds      = {ncmds}")
print(f"  flags      = {hex(flags)}")

LC_SEGMENT_64       = 0x19
LC_LOAD_DYLIB       = 0x0C
LC_ID_DYLIB         = 0x0D
LC_LOAD_WEAK_DYLIB  = 0x8000018
LC_REEXPORT_DYLIB   = 0x800001F
LC_ENCRYPTION_INFO_64 = 0x2C
LC_BUILD_VERSION    = 0x32
LC_CODE_SIGNATURE   = 0x1D
LC_RPATH            = 0x8000001C

loads, idname, deps, enc, build, rpaths, sig = [], None, [], [], None, [], None
segs = []
off = 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", data, off)
    if cmd == LC_SEGMENT_64:
        segname = data[off + 8:off + 24].rstrip(b"\x00").decode("latin1")
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, off + 24)
        segs.append((segname, vmaddr, vmsize, fileoff, filesize))
    elif cmd == LC_ID_DYLIB:
        nameoff = struct.unpack_from("<I", data, off + 8)[0]
        idname = data[off + nameoff:off + cmdsize].split(b"\x00")[0].decode()
    elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
        nameoff = struct.unpack_from("<I", data, off + 8)[0]
        deps.append(data[off + nameoff:off + cmdsize].split(b"\x00")[0].decode())
    elif cmd == LC_ENCRYPTION_INFO_64:
        co, cs, ci = struct.unpack_from("<III", data, off + 8)
        enc.append((co, cs, ci))
    elif cmd == LC_BUILD_VERSION:
        platform, minos, sdk, ntools = struct.unpack_from("<IIII", data, off + 8)
        build = (platform, minos, sdk, ntools)
    elif cmd == LC_RPATH:
        nameoff = struct.unpack_from("<I", data, off + 8)[0]
        rpaths.append(data[off + nameoff:off + cmdsize].split(b"\x00")[0].decode())
    elif cmd == LC_CODE_SIGNATURE:
        sig = struct.unpack_from("<II", data, off + 8)
    loads.append(cmd)
    off += cmdsize

PLAT = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 6: "macCatalyst", 7: "iOS-simulator"}
print()
print("=== 段 ===")
for n, va, vs, fo, fs in segs:
    print(f"  {n:<16} vm={va:#x} vmsize={vs:>10,} fileoff={fo:>10,} filesize={fs:>10,}")

print()
print("=== 安装名 (LC_ID_DYLIB) ===")
print(" ", idname)

print()
print("=== 依赖 ===")
for d in deps:
    tag = "系统" if (d.startswith("/System/") or d.startswith("/usr/lib/")) else (
          "自身" if d.startswith("@executable_path") else "!! 非系统")
    print(f"  [{tag}] {d}")

print()
print("=== 加密 / 平台 / 签名 / rpath ===")
print("  LC_ENCRYPTION_INFO_64:", enc if enc else "无 ✔（dylib 不需要）")
if build:
    plat, minos, sdk, ntools = build
    f = lambda v: f"{v>>16}.{(v>>8)&0xff}.{v&0xff}"
    print(f"  LC_BUILD_VERSION: platform={PLAT.get(plat, plat)} minos={f(minos)} sdk={f(sdk)} tools={ntools}")
print("  LC_RPATH:", rpaths if rpaths else "无")
print("  LC_CODE_SIGNATURE:", (f"dataoff={sig[0]:,} size={sig[1]:,}" if sig else "无"))

print()
print("=== 判定 ===")
ok = True
def chk(cond, msg):
    global ok
    print(("  ✔ " if cond else "  ✘ ") + msg)
    if not cond: ok = False

chk(cputype == 0x0100000C, "架构是 arm64（与 App 主二进制一致）")
chk(filetype == 6, "filetype 是 MH_DYLIB")
chk(idname == "@executable_path/Frameworks/BiliProbe.dylib",
    f"install name 正确: {idname}")
# 注意：链接器默认就会发出一条 LC_ENCRYPTION_INFO_64，cryptid=0 表示「未加密」。
# 判据应当是 cryptid 而非命令是否存在 —— 我第一版写错了，这里改正。
chk(all(e[2] == 0 for e in enc), f"未加密（cryptid 全为 0，命令存在 {len(enc)} 条属正常）")
chk(all(d.startswith(("/System/", "/usr/lib/", "@executable_path", "@rpath")) for d in deps),
    f"全部 {len(deps)} 个依赖均为系统库/自身路径")
chk(build is not None and build[0] == 2, "目标平台是 iOS")
if build:
    minos = build[1]
    ver = (minos >> 16, (minos >> 8) & 0xff, minos & 0xff)
    chk(ver <= (14, 0, 0), f"部署目标 {ver[0]}.{ver[1]}.{ver[2]} <= 14.0（与 App 一致）")
chk(sig is not None, "已带代码签名（ad-hoc）")

# 字符串里应有我们的类名与构造入口标记
for needle in (b"BiliProbe", b"biliprobe"):
    chk(needle in data, f"包含标记 {needle.decode()}")

print()
print("结论:", "全部通过 ✅" if ok else "有项目未通过 ❌")
sys.exit(0 if ok else 1)
