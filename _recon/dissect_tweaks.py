"""
解剖第三方注入的 tweak dylib，回答「他们是怎么写出来的」：
  * 依赖哪些 hook 框架（CydiaSubstrate / fishhook）
  * 导入了哪些宿主符号（这些就是他们 hook 的类/方法！）
  * 内部类/方法名（如果没被 strip）
  * 字符串里的 hook 目标、URL、类名

对最关心的 BiliBiliTweak.dylib / BiliNoAds.dylib / B站空降助手.dylib 各做一遍。
"""
import zipfile, struct, os, re, collections, json

ROOT = r"E:\Documents\DSHWork\BiliRawPackFast"
IPA = os.path.join(ROOT, "哔哩哔哩_9.12.0_彭于晏Crack.ipa")
OUT = os.path.join(ROOT, "_thirdparty")
os.makedirs(OUT, exist_ok=True)

TARGETS = [
    "Payload/bili-universal.app/Frameworks/BiliBiliTweak.dylib",
    "Payload/bili-universal.app/Frameworks/BiliNoAds.dylib",
    "Payload/bili-universal.app/Frameworks/B站空降助手-v1.2.2.dylib",
]

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x8000018
LC_REEXPORT_DYLIB = 0x800001F
LC_SEGMENT_64 = 0x19


def strings_from(buf, minlen=4):
    return [m.group().decode("latin1") for m in
            re.finditer(rb"[\x20-\x7e]{%d,}" % minlen, buf)]


def parse_macho(buf):
    if struct.unpack_from("<I", buf, 0)[0] != MH_MAGIC_64:
        return None
    ct, cs, ft, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<iiIIIII", buf, 4)
    off = 32
    dylibs, segs = [], []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            no = struct.unpack_from("<I", buf, off + 8)[0]
            dylibs.append(buf[off+no:off+cmdsize].split(b"\x00")[0].decode("latin1"))
        elif cmd == LC_SEGMENT_64:
            name = buf[off+8:off+24].rstrip(b"\x00").decode("latin1")
            fo, fs = struct.unpack_from("<QQ", buf, off + 40)[0:2] if False else \
                     (struct.unpack_from("<Q", buf, off + 40)[0], struct.unpack_from("<Q", buf, off + 48)[0])
            segs.append((name, fo, fs))
        off += cmdsize
    return {"ncmds": ncmds, "dylibs": dylibs, "segs": segs, "filetype": ft}


with zipfile.ZipFile(IPA) as z:
    names = z.namelist()
    for t in TARGETS:
        if t not in names:
            print(f"跳过（不存在）: {t}")
            continue
        base = t.split("/")[-1]
        print("=" * 78)
        print(f"【{base}】{z.getinfo(t).file_size:,} 字节")
        print("=" * 78)
        buf = z.read(t)

        mi = parse_macho(buf)
        if not mi:
            print("  不是标准 thin arm64 Mach-O")
            continue
        print(f"  filetype={mi['filetype']} ncmds={mi['ncmds']}")
        print("  依赖：")
        for d in mi["dylibs"]:
            mark = "  ★ hook框架" if any(k in d for k in ("Substrate", "substrate", "ellekit", "Orion")) else \
                   ("  (系统)" if d.startswith(("/System/", "/usr/lib/")) else "  ★ 第三方")
            print(f"    {d}{mark}")

        # 抽字符串（按段限定，减少噪声）
        text = b""
        for nm, fo, fs in mi["segs"]:
            if nm in ("__TEXT", "__DATA", "__DATA_CONST", "__LINKEDIT"):
                text += buf[fo:fo+fs]
        ss = strings_from(text)
        uniq = sorted(set(ss))
        print(f"  字符串 {len(uniq):,} 条（去重）")

        # 1) 被 hook 的宿主选择子：ObjC 方法名形态
        sel = sorted({s for s in uniq if re.fullmatch(r"[a-zA-Z_][A-Za-z0-9_]{2,}[:A-Za-z0-9_]*", s)
                      and s.count(":") >= 1 and len(s) < 90})
        # 2) 类名（B站自有前缀）
        cls = sorted({s for s in uniq if re.fullmatch(r"(BB|BFC|BGM|Bili|BAPI)[A-Za-z0-9_]{3,60}", s)})
        # 3) hook 框架 API
        api = sorted({s for s in uniq if re.search(r"MSHook|MSGet|MSFind|hook_|fishhook|rebind|swizzl", s, re.I)})

        print(f"\n  --- hook 框架 API（{len(api)}）---")
        for s in api[:25]:
            print("     ", s)

        print(f"\n  --- 命中的 B站自有类名（{len(cls)}）---")
        for s in cls[:60]:
            print("     ", s)
        if len(cls) > 60:
            print(f"      … 另有 {len(cls)-60}")

        # 4) 关键词定位
        print(f"\n  --- 关键词定位 ---")
        for kw in ("pcdn", "PCDN", "mcdn", "MCDN", "cdn", "CDN", "ad", "Ad", "splash",
                   "danmaku", "playurl", "PlayURL", "bilivideo", "http"):
            hit = [s for s in uniq if kw in s and len(s) < 100]
            if hit:
                print(f"     [{kw}] {len(hit)} 条，示例：{hit[:4]}")

        with open(os.path.join(OUT, base.replace("/", "_") + ".strings.txt"),
                  "w", encoding="utf-8", errors="replace") as f:
            f.write("\n".join(uniq))
        print()
