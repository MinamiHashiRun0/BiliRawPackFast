"""
哔哩哔哩 iOS IPA 侦察：解包结构 / Info.plist / Mach-O 头部 / 加密状态 / 依赖库
纯 Python，不依赖 macOS 工具链。
"""
import zipfile, plistlib, struct, io, json, sys, os

IPA = r"E:\Documents\DSHWork\BiliRawPackFast\哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa"
OUT = r"E:\Documents\DSHWork\BiliRawPackFast\_recon"
os.makedirs(OUT, exist_ok=True)

report = {}

z = zipfile.ZipFile(IPA)
names = z.namelist()
report["entry_count"] = len(names)

# ---------- 1. 顶层结构 ----------
tops = sorted({n.split("/")[0] for n in names})
report["top_level"] = tops

# 找 .app
app_dirs = sorted({n.split("/")[1] for n in names if n.startswith("Payload/") and len(n.split("/")) > 1})
report["payload_dirs"] = app_dirs
app = "Payload/" + app_dirs[0] if app_dirs else None
report["app_bundle"] = app

# ---------- 2. Info.plist ----------
info_path = f"{app}/Info.plist"
with z.open(info_path) as f:
    pl = plistlib.load(f)
exe_name = pl.get("CFBundleExecutable")
report["CFBundleExecutable"] = exe_name
report["CFBundleIdentifier"] = pl.get("CFBundleIdentifier")
report["CFBundleShortVersionString"] = pl.get("CFBundleShortVersionString")
report["CFBundleVersion"] = pl.get("CFBundleVersion")
report["MinimumOSVersion"] = pl.get("MinimumOSVersion")
report["DTPlatformVersion"] = pl.get("DTPlatformVersion")
report["DTSDKName"] = pl.get("DTSDKName")
report["UIDeviceFamily"] = pl.get("UIDeviceFamily")
report["CFBundleSupportedPlatforms"] = pl.get("CFBundleSupportedPlatforms")
# URL schemes / ATS
report["CFBundleURLTypes"] = pl.get("CFBundleURLTypes")
report["NSAppTransportSecurity"] = pl.get("NSAppTransportSecurity")
report["UIBackgroundModes"] = pl.get("UIBackgroundModes")
report["LSEnvironment"] = pl.get("LSEnvironment")
report["CFBundleDocumentTypes"] = [
    (d.get("CFBundleTypeName"), d.get("LSItemContentTypes")) for d in pl.get("CFBundleDocumentTypes", [])
][:5] if pl.get("CFBundleDocumentTypes") else None

# ---------- 3. Mach-O ----------
exe_path = f"{app}/{exe_name}"
with z.open(exe_path) as f:
    head = f.read(64)
report["exe_zip_compressed_hint"] = None
info = z.getinfo(exe_path)
report["exe_uncompressed_size"] = info.file_size
report["exe_compressed_size"] = info.compress_size

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_NAMES = {0x0100000C: "arm64", 0x0200000C: "arm64e", 7: "i386", 0x01000007: "x86_64", 12: "arm"}

be_magic = struct.unpack(">I", head[:4])[0]
le_magic = struct.unpack("<I", head[:4])[0]
report["macho_magic_hex"] = f"be={hex(be_magic)} le={hex(le_magic)}"

slices = []
is_fat = be_magic in (FAT_MAGIC, FAT_MAGIC_64)
report["is_fat"] = is_fat
if is_fat:
    nfat = struct.unpack(">I", head[4:8])[0]
    report["fat_arch_count"] = nfat
    for i in range(nfat):
        off = 8 + i * 20
        cputype, cpusubtype, offset, size, align = struct.unpack(">iiIII", head[off:off + 20])
        slices.append({"cputype": cputype, "cpu_name": CPU_NAMES.get(cputype, "?"),
                       "cpusubtype": hex(cpusubtype & 0xFFFFFFFF),
                       "offset": offset, "size": size})
    report["fat_slices"] = slices
    # 读第一个 slice 头部
    with z.open(exe_path) as f:
        f.seek(slices[0]["offset"])
        head = f.read(64)
    le_magic = struct.unpack("<I", head[:4])[0]

magic = le_magic          # thin Mach-O 一律按小端读

if magic == MH_MAGIC_64:
    cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack(
        "<iiIIIII", head[4:32]
    )
    report["macho"] = {
        "cputype": cputype,
        "cpu_name": CPU_NAMES.get(cputype, f"unknown({cputype})"),
        "cpusubtype": hex(cpusubtype & 0xFFFFFFFF),
        "filetype": filetype,
        "ncmds": ncmds,
        "sizeofcmds": sizeofcmds,
        "flags": hex(flags),
    }

    # 遍历 load commands
    LC_SEGMENT_64 = 0x19
    LC_ENCRYPTION_INFO_64 = 0x2C
    LC_LOAD_DYLIB = 0xC
    LC_LOAD_WEAK_DYLIB = 0x8000018
    LC_REEXPORT_DYLIB = 0x800001F
    LC_ID_DYLIB = 0xD
    LC_RPATH = 0x8000001C
    LC_BUILD_VERSION = 0x32
    LC_VERSION_MIN_IPHONEOS = 0x25

    with z.open(exe_path) as f:
        if report.get("is_fat"):
            f.seek(slices[0]["offset"])
        data = f.read(sizeofcmds + 32)

    off = 32
    segs, dylibs, enc, rpaths, buildver = [], [], [], [], []
    for _ in range(ncmds):
        if off + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
        body = data[off:off + cmdsize]
        if cmd == LC_SEGMENT_64:
            segname = body[8:24].rstrip(b"\x00").decode("latin1")
            vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", body[24:56])
            maxprot, initprot, nsects, sflags = struct.unpack("<iiII", body[56:72])
            segs.append({
                "name": segname, "vmaddr": hex(vmaddr), "vmsize": vmsize,
                "fileoff": fileoff, "filesize": filesize,
                "initprot": initprot, "nsects": nsects,
            })
        elif cmd == LC_ENCRYPTION_INFO_64:
            cryptoff, cryptsize, cryptid = struct.unpack("<III", body[8:20])
            enc.append({"cryptoff": cryptoff, "cryptsize": cryptsize, "cryptid": cryptid})
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            nameoff = struct.unpack("<I", body[8:12])[0]
            nm = body[nameoff:cmdsize].split(b"\x00")[0].decode("latin1")
            dylibs.append(nm)
        elif cmd == LC_RPATH:
            nameoff = struct.unpack("<I", body[8:12])[0]
            rp = body[nameoff:cmdsize].split(b"\x00")[0].decode("latin1")
            rpaths.append(rp)
        elif cmd == LC_BUILD_VERSION:
            platform, minos, sdk, ntools = struct.unpack("<IIII", body[8:24])
            buildver.append({"platform": platform, "minos": f"{minos>>16}.{(minos>>8)&0xff}.{minos&0xff}",
                             "sdk": f"{sdk>>16}.{(sdk>>8)&0xff}.{sdk&0xff}"})
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            version, sdk = struct.unpack("<II", body[8:16])
            buildver.append({"platform": "iphoneos(legacy)",
                             "minos": f"{version>>16}.{(version>>8)&0xff}.{version&0xff}",
                             "sdk": f"{sdk>>16}.{(sdk>>8)&0xff}.{sdk&0xff}"})
        off += cmdsize

    report["segments"] = segs
    report["encryption_info"] = enc
    report["rpaths"] = rpaths
    report["build_version"] = buildver
    report["dylib_count"] = len(dylibs)
    report["dylibs"] = sorted(dylibs)
else:
    report["macho"] = {"error": f"unexpected magic {hex(magic)}"}

# ---------- 4. Frameworks / PlugIns 概览 ----------
def bundle_stats(prefix):
    """列出 dir 下的 .framework/.dylib/.bundle 名字 + 该 bundle 内主二进制的体积"""
    out = {}
    for n in names:
        if not n.startswith(prefix):
            continue
        rest = n[len(prefix):]
        parts = rest.split("/")
        if not parts or not parts[0]:
            continue
        top = parts[0]
        if not (top.endswith(".framework") or top.endswith(".dylib") or top.endswith(".bundle")
                or top.endswith(".app") or top.endswith(".appex")):
            continue
        # 主二进制 = <bundle>/<basename without ext>
        if top.endswith(".framework") or top.endswith(".bundle") or top.endswith(".app") or top.endswith(".appex"):
            binname = top.rsplit(".", 1)[0]
            cand = f"{prefix}{top}/{binname}"
        else:
            cand = f"{prefix}{top}"
        if n == cand:
            out[top] = z.getinfo(n).file_size
        else:
            out.setdefault(top, None)
    return out

fw_dir = f"{app}/Frameworks/"
plugins_dir = f"{app}/PlugIns/"
fw = bundle_stats(fw_dir)
plugins = bundle_stats(plugins_dir)
report["embedded_frameworks"] = {k: v for k, v in sorted(fw.items())}
report["embedded_plugins"] = {k: v for k, v in sorted(plugins.items())}
report["top_level_app_files"] = sorted({
    n[len(app) + 1:].split("/")[0] for n in names if n.startswith(app + "/")
})

# ---------- 5. 关键：找网络栈 / 播放器 / 反调试线索 ----------
KEYWORDS = ["ttnet", "TTNetwork", "cronet", "Cronet", "grpc", "GRPC", "protobuf", "alamofire", "Alamofire",
            "AFNetworking", "libmpv", "ijk", "IJK", "ffmpeg", "FFmpeg", "vlc", "VLC", "tars", "mars",
            "marsxlog", "BDAutoTrack", "bugly", "Bugly", "fishhook", "substrate", "cydia", "jailbreak",
            "Jailbreak", "ptrace", "sysctl", "swift", "Swift"]
hits = {k: 0 for k in KEYWORDS}
for n in names:
    low = n.lower()
    for k in KEYWORDS:
        if k.lower() in low:
            hits[k] += 1
report["keyword_hits_in_paths"] = {k: v for k, v in hits.items() if v}

with open(os.path.join(OUT, "recon.json"), "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)

# 控制台摘要
print("=== IPA 结构 ===")
print("条目数:", report["entry_count"], "| 顶层:", tops, "| app:", app)
print()
print("=== Info.plist 关键项 ===")
for k in ("CFBundleExecutable", "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
          "MinimumOSVersion", "DTPlatformVersion", "DTSDKName", "UIDeviceFamily"):
    print(f"  {k}: {report.get(k)}")
print("  ATS:", report.get("NSAppTransportSecurity"))
print("  URLTypes:", (report.get("CFBundleURLTypes") or [{}])[0].get("CFBundleURLSchemes") if report.get("CFBundleURLTypes") else None)
print()
print("=== Mach-O ===")
print("  fat:", report.get("is_fat"), "| slices:", report.get("fat_slices"))
print("  header:", json.dumps(report.get("macho"), ensure_ascii=False))
print("  build:", report.get("build_version"))
print("  rpaths:", report.get("rpaths"))
print("  encryption_info:", report.get("encryption_info") or "（无 LC_ENCRYPTION_INFO_64 —— 已脱壳或未加密）")
print()
print("=== 段表 ===")
for s in report.get("segments", []):
    print(f"  {s['name']:<12} vm={s['vmsize']:>12} file={s['filesize']:>12} off={s['fileoff']:>12} prot={s['initprot']}")
print()
print("=== 依赖动态库 (%d) ===" % report.get("dylib_count", 0))
for d in report.get("dylibs", []):
    print("  ", d)
print()
print("=== 内嵌 Frameworks (%d) ===" % len(fw))
for x, sz in sorted(fw.items()):
    print(f"   {x:<45} {sz if sz is None else format(sz, ',')}")
print()
print("=== 内嵌 PlugIns (%d) ===" % len(plugins))
for x, sz in sorted(plugins.items()):
    print(f"   {x:<45} {sz if sz is None else format(sz, ',')}")
print()
print("=== 路径关键词命中 ===")
for k, v in report["keyword_hits_in_paths"].items():
    print(f"  {k}: {v}")
print()
print("报告已写入:", os.path.join(OUT, "recon.json"))
