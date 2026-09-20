"""
判断能否用 insert_dylib 注入 —— 关键是 load command 区是否有足够余量。
本脚本不修改 IPA，只报告布局。

判定逻辑（与 insert_dylib 的实际行为对齐）：
  * 若 (sizeofcmds + 32) 之后到第一个 section 的文件偏移之间有空隙
    → 可在原地扩展 load command 区，不需要搬动整个 __TEXT
  * 否则需要整体下移（insert_dylib 会处理，但我们先知道会发生什么）
  另外报告 LC_CODE_SIGNATURE 的 status/offset/size，供注入后处理签名用。
"""
import zipfile, struct, os, json, sys

IPA = r"E:\Documents\DSHWork\BiliRawPackFast\哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa"
EXE = "Payload/bili-universal.app/bili-universal"

LC_SEGMENT_64        = 0x19
LC_CODE_SIGNATURE    = 0x1D
LC_ENCRYPTION_INFO_64= 0x2C
LC_LOAD_DYLIB        = 0x0C
LC_LOAD_WEAK_DYLIB   = 0x8000018
LC_REEXPORT_DYLIB    = 0x800001F
LC_ID_DYLIB          = 0x0D

with zipfile.ZipFile(IPA) as z:
    with z.open(EXE) as f:
        # 只需要头部区域，但为拿 section 细节多读一点
        head = f.read(1 << 20)

if struct.unpack("<I", head[:4])[0] != 0xFEEDFACF:
    print("不是小端 64 位 Mach-O，退出")
    sys.exit(1)

cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack("<iiIIIII", head[4:32])
print("ncmds        =", ncmds)
print("sizeofcmds   =", sizeofcmds, "字节")
print("header+cmds  =", 32 + sizeofcmds, "字节")

segments = []
sections = []
code_sig = None
dylib_count = 0
off = 32
for i in range(ncmds):
    cmd, cmdsize = struct.unpack("<II", head[off:off + 8])
    if cmd == LC_SEGMENT_64:
        segname = head[off + 8:off + 24].rstrip(b"\x00").decode("latin1")
        vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", head[off + 24:off + 56])
        nsects = struct.unpack("<I", head[off + 64:off + 68])[0]
        segments.append(dict(name=segname, vmaddr=vmaddr, vmsize=vmsize,
                             fileoff=fileoff, filesize=filesize, nsects=nsects))
        # 解析 sections: segname[16] sectname[16] addr[8] size[8] offset[4] align[4] reloff[4] nreloc[4] flags[4] ...
        so = off + 72
        for _s in range(nsects):
            sectname = head[so:so + 16].rstrip(b"\x00").decode("latin1")
            sgname   = head[so + 16:so + 32].rstrip(b"\x00").decode("latin1")
            addr, size = struct.unpack("<QQ", head[so + 32:so + 48])
            soff = struct.unpack("<I", head[so + 48:so + 52])[0]
            sections.append(dict(seg=sgname, name=sectname, addr=addr, size=size, offset=soff))
            so += 80
    elif cmd == LC_CODE_SIGNATURE:
        dataoff, datasize = struct.unpack("<II", head[off + 8:off + 16])
        code_sig = dict(dataoff=dataoff, datasize=datasize)
    elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
        dylib_count += 1
    off += cmdsize

print("\n段:")
for s in segments:
    print(f"  {s['name']:<14} fileoff={s['fileoff']:>12,} filesize={s['filesize']:>12,} "
          f"nsects={s['nsects']}")

print("\nLC_CODE_SIGNATURE:", code_sig)
print("LC_LOAD_DYLIB 数量:", dylib_count)

# 已占用的 load command 区终点
lc_end = 32 + sizeofcmds
print(f"\nload command 区终点 = {lc_end:,}")

# 找 fileoff 字段非 0 的最小值（真正的第一个文件内容起点）
real_offsets = [s["fileoff"] for s in segments if s["fileoff"] > 0]
first_content = min(real_offsets) if real_offsets else None
print("第一个有文件内容的段起点 =", f"{first_content:,}" if first_content else "无")

# 只看 __TEXT 段里的第一个真正落在文件里的 section
text_sects = [s for s in sections if s["seg"] == "__TEXT" and s["offset"] > 0]
text_sects.sort(key=lambda s: s["offset"])
if text_sects:
    fs = text_sects[0]
    print(f"\n__TEXT 里第一个有效 section = {fs['name']}  offset={fs['offset']:,}  size={fs['size']:,}")

gap = None
if text_sects:
    gap = text_sects[0]["offset"] - lc_end
    print(f"\n★ load command 区之后到第一个 section 之间的空隙 = {gap:,} 字节")
    new_lc_size = 24 + len("@executable_path/Frameworks/BiliProbe.dylib") + 1
    new_lc_size = (new_lc_size + 7) & ~7
    print(f"  新增一条 LC_LOAD_DYLIB 需要 {new_lc_size} 字节")
    if gap >= new_lc_size:
        print("  ✅ 空隙足够 —— 可原地扩展 load command 区，无需搬动 __TEXT")
    else:
        print("  ⚠️ 空隙不足 —— 需要整体下移 __TEXT（insert_dylib 会处理，但改动面更大）")
else:
    print("找不到 __TEXT 的有效 section")

print("\n__TEXT 段内前 12 个 section（按 offset）:")
for s in text_sects[:12]:
    print(f"   {s['name']:<28} offset={s['offset']:>12,} size={s['size']:>12,}")

os.makedirs(r"E:\Documents\DSHWork\BiliRawPackFast\_recon", exist_ok=True)
with open(r"E:\Documents\DSHWork\BiliRawPackFast\_recon\inject_layout.json", "w", encoding="utf-8") as f:
    json.dump(dict(ncmds=ncmds, sizeofcmds=sizeofcmds, lc_end=lc_end,
                   code_signature=code_sig, dylib_count=dylib_count,
                   gap=gap, segments=segments,
                   first_text_sections=text_sects[:12]), f, ensure_ascii=False, indent=2)
print("\n布局已写入 _recon/inject_layout.json")
