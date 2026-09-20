"""
侦察用户提供的两个第三方 IPA，回答一个关键问题：
  「那些注入 dylib 去广告的分发包是怎么做的、dylib 从哪来」

对每个包输出：
  * app bundle 名、可执行名、Bundle ID、版本
  * 架构 / 加密状态 / 依赖库（有无第三方网络库、有无被注入的 dylib）
  * 内嵌 Frameworks 清单（第三方包很可能带自己的 dylib）
  * 关键词命中（hook / pcdn / cdn / ad / 去广告 等）
"""
import zipfile, plistlib, struct, os, json, re, collections, sys

ROOT = r"E:\Documents\DSHWork\BiliRawPackFast"
TARGETS = [
    ("哔哩哔哩_1.0.23_轻量版本.ipa", "light"),
    ("哔哩哔哩_9.12.0_彭于晏Crack.ipa", "crack"),
]
OUT = os.path.join(ROOT, "_thirdparty")
os.makedirs(OUT, exist_ok=True)

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_NAMES = {0x0100000C: "arm64", 0x0200000C: "arm64e", 0x01000007: "x86_64"}
LC_SEGMENT_64 = 0x19
LC_ENCRYPTION_INFO_64 = 0x2C
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x8000018
LC_REEXPORT_DYLIB = 0x800001F
LC_BUILD_VERSION = 0x32


def analyze(ipa_name, tag):
    path = os.path.join(ROOT, ipa_name)
    if not os.path.exists(path):
        print(f"跳过（不存在）: {ipa_name}")
        return None
    print("=" * 78)
    print(f"【{tag}】{ipa_name}   {os.path.getsize(path):,} 字节")
    print("=" * 78)

    rep = {"ipa": ipa_name, "size": os.path.getsize(path)}
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        apps = sorted({n.split("/")[1] for n in names
                       if n.startswith("Payload/") and len(n.split("/")) > 1})
        rep["apps"] = apps
        print(f"条目数 {len(names)}，Payload 下的 app: {apps}")
        if not apps:
            print("  ★ 没有 Payload/*.app —— 可能不是标准 IPA")
            return rep
        app = "Payload/" + apps[0]
        rep["app"] = app

        try:
            with z.open(f"{app}/Info.plist") as f:
                pl = plistlib.load(f)
        except Exception as e:
            print("  Info.plist 读取失败:", e)
            return rep
        for k in ("CFBundleExecutable", "CFBundleIdentifier", "CFBundleShortVersionString",
                  "CFBundleName", "MinimumOSVersion", "DTPlatformVersion", "DTSDKName"):
            rep[k] = pl.get(k)
            print(f"  {k:28} = {pl.get(k)}")

        exe = pl.get("CFBundleExecutable")
        exe_path = f"{app}/{exe}"
        if exe_path not in names:
            print(f"  ★ 找不到可执行文件 {exe_path}")
            return rep

        with z.open(exe_path) as f:
            head = f.read(64)
        be = struct.unpack(">I", head[:4])[0]
        le = struct.unpack("<I", head[:4])[0]
        rep["encrypted_binary"] = None
        slices = []
        if be in (FAT_MAGIC, FAT_MAGIC_64):
            n = struct.unpack(">I", head[4:8])[0]
            for i in range(n):
                ct, cs, off, sz, al = struct.unpack(">iiIII", head[8+i*20:28+i*20])
                slices.append({"cpu": CPU_NAMES.get(ct, hex(ct)), "offset": off, "size": sz})
            print(f"  fat 二进制，{n} 个切片: {[s['cpu'] for s in slices]}")
            rep["fat"] = slices
            with z.open(exe_path) as f:
                f.seek(slices[0]["offset"])
                head = f.read(64)
            le = struct.unpack("<I", head[:4])[0]

        if le == MH_MAGIC_64:
            ct, cs, ft, ncmds, sizeofcmds, flags, _ = struct.unpack("<iiIIIII", head[4:32])
            rep["cpu"] = CPU_NAMES.get(ct, hex(ct))
            rep["ncmds"] = ncmds
            print(f"  架构 {rep['cpu']}  ncmds={ncmds}")
            with z.open(exe_path) as f:
                if slices:
                    f.seek(slices[0]["offset"])
                data = f.read(sizeofcmds + 32)
            off = 32
            dylibs, enc, rpaths = [], [], []
            for _ in range(ncmds):
                cmd, cmdsize = struct.unpack("<II", data[off:off+8])
                body = data[off:off+cmdsize]
                if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
                    no = struct.unpack("<I", body[8:12])[0]
                    dylibs.append(body[no:cmdsize].split(b"\x00")[0].decode("latin1"))
                elif cmd == LC_ENCRYPTION_INFO_64:
                    co, csz, cid = struct.unpack("<III", body[8:20])
                    enc.append({"cryptid": cid, "cryptsize": csz})
                elif cmd == 0x8000001C:
                    no = struct.unpack("<I", body[8:12])[0]
                    rpaths.append(body[no:cmdsize].split(b"\x00")[0].decode("latin1"))
                off += cmdsize
            rep["encryption"] = enc
            rep["dylibs"] = dylibs
            rep["rpaths"] = rpaths
            print(f"  加密: {enc if enc else '无 LC_ENCRYPTION_INFO_64'}")
            syscount = sum(1 for d in dylibs if d.startswith(("/System/", "/usr/lib/", "@rpath", "@executable_path")))
            print(f"  依赖动态库 {len(dylibs)} 个（系统/自身 {syscount}）")
            # 非系统依赖 = 第三方注入的库
            for d in dylibs:
                if not d.startswith(("/System/", "/usr/lib/")):
                    print(f"    ★ 非系统依赖: {d}")
            print(f"  rpaths: {rpaths}")

        # 内嵌 Frameworks / dylib
        fw, dy = {}, {}
        for n in names:
            if n.startswith(f"{app}/Frameworks/"):
                rel = n[len(f"{app}/Frameworks/"):]
                top = rel.split("/")[0]
                fw.setdefault(top, 0)
                fw[top] += z.getinfo(n).file_size
            if n.startswith(f"{app}/") and n.endswith(".dylib") and n.count("/") == 2:
                dy[n.split("/")[-1]] = z.getinfo(n).file_size
        rep["frameworks"] = fw
        rep["root_dylibs"] = dy
        print(f"  内嵌 Frameworks: {len(fw)} 个")
        for k, v in sorted(fw.items(), key=lambda kv: -kv[1])[:20]:
            print(f"    {k:52} {v:>12,}")
        if dy:
            print(f"  app 根目录下的 dylib: {dy}")

        # 关键词扫描（只看条目路径，速度快）
        KEY = ["pcdn", "mcdn", "cdn", "adblock", "blockad", "crack", "hook", "tweak",
               "patch", "cracked", "去广告", "deblock"]
        hits = collections.Counter()
        for n in names:
            low = n.lower()
            for k in KEY:
                if k in low:
                    hits[k] += 1
        rep["keyword_hits"] = dict(hits)
        if hits:
            print(f"  路径关键词命中: {dict(hits)}")

    with open(os.path.join(OUT, f"recon_{tag}.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=2)
    return rep


for nm, tg in TARGETS:
    analyze(nm, tg)
    print()
