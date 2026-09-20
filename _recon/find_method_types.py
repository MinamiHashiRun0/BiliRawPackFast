"""
从脱壳二进制里读**真实的方法 type encoding**，用于写正确的 hook 函数签名。

为什么必须这么做：
  给 class_replaceMethod 传的 types 只是元数据，**不会校验实现**。
  若我按猜测的签名写 C 函数（例如把 int 参数当对象），运行期会对垃圾指针
  objc_retain → EXC_BAD_ACCESS。这正是本轮真机闪退的同类原因
  （前一个是 performSelector 取整数返回值当对象）。

  本项目对 IJK 那几个类只有**方法名**（来自运行时 class dump），没有 type encoding。
  而 type encoding 就在二进制里 —— __objc_methlist / __objc_const。

做法：
  解析 Mach-O 的 __objc_methlist section（在 __TEXT 里），
  它是 method_list_t 数组：每项 { int32 entsizeAndFlags; int32 count; 然后 count 个 method_t }
  method_t = { SEL name(VmAddr); const char* types(VmAddr); IMP imp }
  用 vmaddr - __TEXT.vmaddr 换算成文件偏移，再读字符串。

  先只针对目标类的方法找，避免全量输出。

用法：python find_method_types.py [类名关键词...]
"""
import struct, sys, re, os, collections

IPA = r"E:\Documents\DSHWork\BiliRawPackFast\哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa"
EXE = "Payload/bili-universal.app/bili-universal"
CACHE = r"E:\Documents\DSHWork\BiliRawPackFast\_recon\_exe_cache.bin"

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19

def load_exe():
    if os.path.exists(CACHE):
        print(f"用缓存 {CACHE}")
        return open(CACHE, "rb").read()
    import zipfile
    print("从 IPA 读取主二进制（约 630MB，稍等）…")
    with zipfile.ZipFile(IPA) as z:
        b = z.read(EXE)
    open(CACHE, "wb").write(b)
    print(f"已缓存到 {CACHE}")
    return b


def parse_segments(buf):
    ncmds = struct.unpack_from("<I", buf, 16)[0]
    off = 32
    segs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmd == LC_SEGMENT_64:
            name = buf[off+8:off+24].rstrip(b"\x00").decode("latin1")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", buf, off+24)
            nsects = struct.unpack_from("<I", buf, off+64)[0]
            sects = []
            so = off + 72
            for _s in range(nsects):
                sname = buf[so:so+16].rstrip(b"\x00").decode("latin1")
                addr, size = struct.unpack_from("<QQ", buf, so+32)
                soff = struct.unpack_from("<I", buf, so+48)[0]
                sects.append((sname, addr, size, soff))
                so += 80
            segs.append((name, vmaddr, vmsize, fileoff, filesize, sects))
        off += cmdsize
    return segs


def main():
    keys = sys.argv[1:] or ["parseDash", "initWithStreamId", "prepareWithItem",
                            "preloadItems", "initWithURL:cacheWorker",
                            "downloadTaskFromOffset", "__cstring"]
    buf = load_exe()
    segs = parse_segments(buf)

    # 建立 vmaddr -> file offset 的映射（用 __TEXT 与 __DATA 段）
    def vm2off(vmaddr):
        for name, vma, vmsize, fo, fs, sects in segs:
            if vma <= vmaddr < vma + max(vmsize, fs):
                return fo + (vmaddr - vma)
        return None

    def read_cstr(vmaddr, limit=200):
        o = vm2off(vmaddr)
        if o is None or o >= len(buf):
            return None
        end = buf.find(b"\x00", o, o + limit)
        if end < 0:
            return None
        try:
            return buf[o:end].decode("utf-8")
        except UnicodeDecodeError:
            return None

    # 找 __objc_methlist section
    methlist = None
    for name, vma, vmsize, fo, fs, sects in segs:
        for sname, addr, size, soff in sects:
            if sname == "__objc_methlist":
                methlist = (addr, size, soff)
                print(f"找到 __objc_methlist: addr={addr:#x} size={size:,} fileoff={soff:,}")
    if not methlist:
        print("找不到 __objc_methlist"); return 1

    base_vm = None
    for name, vma, vmsize, fo, fs, sects in segs:
        if fo == 0:
            base_vm = vma
            break
    print(f"镜像基址 = {base_vm:#x}\n")

    addr, size, soff = methlist
    end = soff + size
    pos = soff
    found = collections.defaultdict(list)
    n_lists = 0
    n_rel = 0
    while pos + 8 <= end:
        entsize_flags, count = struct.unpack_from("<ii", buf, pos)
        rel = bool(entsize_flags & 0x80000000)
        entsize = entsize_flags & 0xFFFF
        if count <= 0 or count > 20000:
            pos += 8
            continue
        if rel:
            # 相对偏移格式（新工具链默认）：
            # method_t = { int32 nameRelOff; int32 typesRelOff; int32 impRelOff }
            # 三者的目标地址 = &该字段 + 该值
            n_rel += 1
            step = 12
            if entsize not in (0, 12):
                step = entsize if 12 <= entsize <= 64 else 12
            n_lists += 1
            for i in range(count):
                mo = pos + 8 + i * step
                if mo + 12 > end:
                    break
                name_rel, types_rel, imp_rel = struct.unpack_from("<iii", buf, mo)
                name_vm = (mo + 0) + name_rel
                types_vm = (mo + 4) + types_rel
                sel = read_cstr(name_vm)
                if not sel:
                    continue
                for k in keys:
                    if k in sel:
                        te = read_cstr(types_vm) or "?"
                        # imp: mo+8 处是 imp 字段
                        imp_off = vm2off((mo + 8) + imp_rel)
                        found[k].append((sel, te, imp_off))
                        break
            pos += 8 + count * step
        else:
            # 绝对指针格式：method_t = { SEL; const char*; IMP }
            step = entsize if entsize >= 24 else 24
            n_lists += 1
            for i in range(count):
                mo = pos + 8 + i * step
                if mo + 24 > end:
                    break
                name_vm, types_vm, imp = struct.unpack_from("<QQQ", buf, mo)
                sel = read_cstr(name_vm)
                if not sel:
                    continue
                for k in keys:
                    if k in sel:
                        te = read_cstr(types_vm) or "?"
                        found[k].append((sel, te, imp))
                        break
            pos += 8 + count * step

    print(f"扫描了 {n_lists} 个 method list（其中相对偏移格式 {n_rel} 个）\n")
    print("=" * 90)
    print("找到的方法签名（type encoding 为二进制中真实值）")
    print("=" * 90)
    for k in keys:
        items = found.get(k, [])
        if not items:
            continue
        print(f"\n--- 关键词 [{k}]  共 {len(items)} 条 ---")
        seen = set()
        for sel, te, imp in items:
            if (sel, te) in seen:
                continue
            seen.add((sel, te))
            print(f"  {sel}")
            print(f"      types = {te}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
