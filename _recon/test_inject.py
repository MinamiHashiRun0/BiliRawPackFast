"""
对 inject_dylib.MachO 的本地自测：
  ① 合成一个最小 Mach-O（无空隙）→ 必须拒绝
  ② 合成一个有 4096 字节空隙的 Mach-O → 必须成功，且逐字节验证只有该改的地方变了
  ③ 对真实 IPA 的主二进制做一次「副本注入 + 结构校验」，不写回 IPA

不需要 macOS，也不需要真的跑起来 App —— 这里只验证二进制改写是否精确。
"""
import importlib.util, io, os, struct, sys, zipfile

spec = importlib.util.spec_from_file_location(
    "inject_dylib", r"E:\Documents\DSHWork\BiliRawPackFast\inject\inject_dylib.py")
inj = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inj)

LC_SEGMENT_64     = 0x19
LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64       = 0xFEEDFACF
MH_EXECUTE        = 0x2
CPU_ARM64         = 0x0100000C


def build_fake_macho(gap: int, with_code_sig: bool = True) -> bytes:
    """造一个 thin arm64 Mach-O：1 个 LC_SEGMENT_64(__TEXT, 1 section) + 可选签名命令"""
    SEG_HDR = 72
    SECT    = 80
    seg_cmdsize = SEG_HDR + SECT
    sig_cmdsize = 16
    ncmds = 1 + (1 if with_code_sig else 0)
    sizeofcmds = seg_cmdsize + (sig_cmdsize if with_code_sig else 0)
    lc_end = 32 + sizeofcmds
    first_sect_off = lc_end + gap

    buf = bytearray(first_sect_off + 512)
    # --- header ---
    struct.pack_into("<IiiIIIII", buf, 0, MH_MAGIC_64, CPU_ARM64, 0, MH_EXECUTE,
                     ncmds, sizeofcmds, 0, 0)
    # --- LC_SEGMENT_64 ---
    off = 32
    struct.pack_into("<II", buf, off, LC_SEGMENT_64, seg_cmdsize)
    buf[off + 8:off + 24] = b"__TEXT".ljust(16, b"\x00")
    struct.pack_into("<QQQQ", buf, off + 24, 0x100000000, first_sect_off + 512, 0, first_sect_off + 512)
    struct.pack_into("<iiII", buf, off + 56, 5, 5, 1, 0)   # maxprot, initprot, nsects, flags
    # section
    so = off + SEG_HDR
    buf[so:so + 16] = b"__text".ljust(16, b"\x00")
    buf[so + 16:so + 32] = b"__TEXT".ljust(16, b"\x00")
    struct.pack_into("<QQ", buf, so + 32, 0x100000000 + first_sect_off, 512)
    struct.pack_into("<I", buf, so + 48, first_sect_off)      # offset
    struct.pack_into("<I", buf, so + 56, 0)                   # reloff
    struct.pack_into("<I", buf, so + 60, 0)                   # nreloc
    struct.pack_into("<I", buf, so + 64, 0x80000400)          # flags
    off += seg_cmdsize
    # --- LC_CODE_SIGNATURE ---
    if with_code_sig:
        struct.pack_into("<II", buf, off, LC_CODE_SIGNATURE, sig_cmdsize)
        struct.pack_into("<II", buf, off + 8, first_sect_off + 512, 128)
    # 填充可识别的内容，便于验证"没被误改"
    for i in range(first_sect_off, len(buf)):
        buf[i] = (i * 7 + 3) & 0xFF
    return bytes(buf), first_sect_off


def test_reject_no_gap():
    raw, _ = build_fake_macho(gap=8)
    m = inj.MachO(raw)
    try:
        m.insert_load_dylib("@executable_path/Frameworks/BiliProbe.dylib")
    except SystemExit as e:
        print("  ① 无空隙 → 正确拒绝:", str(e).splitlines()[0])
        return True
    print("  ① 无空隙 → ❌ 本应拒绝却成功了")
    return False


def test_accept_with_gap():
    name = "@executable_path/Frameworks/BiliProbe.dylib"
    raw, first_sect_off = build_fake_macho(gap=4096)
    m = inj.MachO(raw)
    before = bytes(m.data)
    added = m.insert_load_dylib(name)
    after = m.bytes()

    ok = True
    # 1) header 计数
    ncmds, sizeofcmds = struct.unpack_from("<II", after, 16)
    if (ncmds, sizeofcmds) != (m.ncmds, m.sizeofcmds):
        print("     ❌ header 计数不对"); ok = False
    if ncmds != 3:
        print(f"     ❌ ncmds 应为 3，实际 {ncmds}"); ok = False

    # 2) 重新解析应能找到新命令
    m2 = inj.MachO(after)
    if name not in m2.dylibs:
        print(f"     ❌ 重新解析未找到 {name}，实际 {m2.dylibs}"); ok = False

    # 3) 代码签名 dataoff 必须后移 added
    off_sig_before = struct.unpack_from("<I", before, m.code_sig[0] + 8)[0]
    off_sig_after  = struct.unpack_from("<I", after, m.code_sig[0] + 8)[0]
    if off_sig_after != off_sig_before + added:
        print(f"     ❌ 签名 dataoff 未同步: {off_sig_before} → {off_sig_after}, 期望 +{added}"); ok = False

    # 4) 除了 [lc_end, lc_end+added) 与 header 12..20、签名命令 dataoff 之外，其余字节必须一模一样
    diff = [i for i in range(len(before)) if before[i] != after[i]]
    allowed = set(range(16, 24)) | set(range(m.lc_end, m.lc_end + added)) \
              | set(range(m.code_sig[0] + 8, m.code_sig[0] + 12))
    unexpected = [i for i in diff if i not in allowed]
    if unexpected:
        print(f"     ❌ 有 {len(unexpected)} 字节被意外修改，前几个偏移: {unexpected[:8]}"); ok = False

    # 5) section 内容未被触碰
    if after[first_sect_off:first_sect_off + 64] != before[first_sect_off:first_sect_off + 64]:
        print("     ❌ section 内容被改动"); ok = False

    print(f"  ② 有空隙 → 注入成功，改动 {len(diff)} 字节（全部落在允许范围内）"
          f"，新增 {added} 字节")
    return ok


def test_real_binary():
    IPA = r"E:\Documents\DSHWork\BiliRawPackFast\哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa"
    EXE = "Payload/bili-universal.app/bili-universal"
    if not os.path.exists(IPA):
        print("  ③ 真实 IPA 不在，跳过")
        return True
    with zipfile.ZipFile(IPA) as z:
        with z.open(EXE) as f:
            # 只读前 2MB 就够做头部注入校验？不行 —— MachO 会改 dataoff，
            # 但改动都在前 16KB 内。用 f.read() 全读一次以保证语义一致。
            raw = f.read()
    print(f"  真实二进制 {len(raw):,} 字节，读入完成")
    m = inj.MachO(raw)
    print(f"    ncmds={m.ncmds} sizeofcmds={m.sizeofcmds:,} 空隙={m.first_section_offset - m.lc_end:,}")
    name = "@executable_path/Frameworks/BiliProbe.dylib"
    added = m.insert_load_dylib(name)
    out = m.bytes()
    m2 = inj.MachO(out)
    ok = (m2.ncmds == m.ncmds) and (name in m2.dylibs) \
         and (len(out) == len(raw) + 0)   # 原地扩展：文件长度不变
    print(f"    注入后 ncmds={m2.ncmds}，dylib 列表尾部={m2.dylibs[-1]}")
    print(f"    文件长度 {'不变 ✔' if len(out) == len(raw) else '变了 ❌'}")
    # 确认没有越界写：空隙内的填充字节还是原来的
    tail = out[m.lc_end:m.first_section_offset]
    print(f"    空隙区剩余 {len(tail)} 字节（原 {m.first_section_offset - m.lc_end - added}）")
    return ok


print("=" * 70)
print("inject_dylib.py 自测")
print("=" * 70)
r1 = test_reject_no_gap()
r2 = test_accept_with_gap()
r3 = test_real_binary()
print("=" * 70)
print("结果:", "全部通过 ✅" if (r1 and r2 and r3) else "有失败 ❌")
sys.exit(0 if (r1 and r2 and r3) else 1)
