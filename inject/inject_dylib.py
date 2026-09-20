#!/usr/bin/env python3
"""
BiliProbe 注入器 —— 给脱壳后的 bili-universal 追加 LC_LOAD_DYLIB

为什么自己写而不用 insert_dylib：
  已经实测过目标二进制的布局（_recon/inject_layout.json）：
    load command 区终点            = 16,128
    __TEXT 第一个有效 section 起点  = 147,456
    空隙                          = 131,328 字节
  新增一条 LC_LOAD_DYLIB 只需 72 字节 → **完全在空隙内**。
  因此本工具做的是「原地扩展 load command 区」：
    不搬动 __TEXT、不重定位任何指针、不改任何 vmaddr/fileoff。
  这比通用 insert_dylib 的整体下移方案改动面小得多，风险也低得多。
  若某天换了个没有空隙的二进制，本工具会直接报错退出，而不是硬来。

用法:
  python inject_dylib.py --ipa <输入.ipa> --out <输出.ipa>
                         [--dylib-name BiliProbe.dylib] [--force]

缺省安装名: @executable_path/Frameworks/<dylib-name>
"""
import argparse, os, shutil, struct, sys, tempfile, zipfile, json

LC_SEGMENT_64     = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_DYLIB     = 0x0C

MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE  = 0x2


def align(v, a):
    return (v + a - 1) & ~(a - 1)


class MachO:
    """对单切片（thin）64 位 Mach-O 的最小可写视图；只改头部区域。"""

    def __init__(self, data: bytes):
        self.data = bytearray(data)
        d = self.data
        if struct.unpack_from("<I", d, 0)[0] != MH_MAGIC_64:
            raise SystemExit("✗ 不是小端 64 位 Mach-O（本工具只处理 thin arm64）")
        (self.cputype, self.cpusubtype, self.filetype,
         self.ncmds, self.sizeofcmds, self.flags, _) = struct.unpack_from("<iiIIIII", d, 4)
        if self.filetype != MH_EXECUTE:
            raise SystemExit(f"✗ filetype={self.filetype}，不是可执行文件")
        self._scan()

    def _scan(self):
        d = self.data
        self.lc_end = 32 + self.sizeofcmds
        self.code_sig = None
        self.dylibs = []
        self.first_section_offset = None
        off = 32
        for _ in range(self.ncmds):
            cmd, cmdsize = struct.unpack_from("<II", d, off)
            if cmdsize == 0:
                raise SystemExit("✗ load command cmdsize=0，文件异常")
            if cmd == LC_CODE_SIGNATURE:
                dataoff, datasize = struct.unpack_from("<II", d, off + 8)
                self.code_sig = (off, dataoff, datasize)
            elif cmd == LC_SEGMENT_64:
                _vmaddr, _vmsize, _fileoff, _filesize = struct.unpack_from("<QQQQ", d, off + 24)
                nsects = struct.unpack_from("<I", d, off + 64)[0]
                so = off + 72
                for _s in range(nsects):
                    s_off = struct.unpack_from("<I", d, so + 48)[0]
                    if s_off > 0:
                        if self.first_section_offset is None or s_off < self.first_section_offset:
                            self.first_section_offset = s_off
                    so += 80
            elif cmd == LC_LOAD_DYLIB:
                nameoff = struct.unpack_from("<I", d, off + 8)[0]
                nm = bytes(d[off + nameoff:off + cmdsize]).split(b"\x00")[0].decode("utf-8", "replace")
                self.dylibs.append(nm)
            off += cmdsize
        if off != self.lc_end:
            raise SystemExit(f"✗ 遍历 load command 后偏移 {off} 与 ncmds 推算的 {self.lc_end} 不一致")

    def make_lc_load_dylib(self, install_name: str) -> bytes:
        """构造一条 LC_LOAD_DYLIB（与 ld64 产物同构，8 字节对齐）"""
        name = install_name.encode("utf-8") + b"\x00"
        cmdsize = align(24 + len(name), 8)
        body = name + b"\x00" * (cmdsize - 24 - len(name))
        # cmd, cmdsize, name offset(=24), timestamp, current_version, compatibility_version
        return struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 0, 0x00010000, 0x00010000) + body

    def insert_load_dylib(self, install_name: str) -> int:
        cmdsize = align(24 + len(install_name.encode()) + 1, 8)
        gap = (self.first_section_offset - self.lc_end) if self.first_section_offset else 0
        if gap < cmdsize:
            raise SystemExit(
                f"✗ load command 区后空隙只有 {gap} 字节，放不下本次需要的 {cmdsize} 字节。\n"
                f"  本工具不做整体下移，请改用 insert_dylib 处理该二进制。")

        cmd_bytes = self.make_lc_load_dylib(install_name)
        assert len(cmd_bytes) == cmdsize

        # 1) 把新命令写在旧 load command 区末尾
        self.data[self.lc_end:self.lc_end + cmdsize] = cmd_bytes
        # 2) 更新 header 计数
        self.ncmds += 1
        self.sizeofcmds += cmdsize
        struct.pack_into("<II", self.data, 16, self.ncmds, self.sizeofcmds)
        # 3) 代码签名 blob 在文件里后移了 cmdsize 字节 —— 必须同步 dataoff，
        #    否则注入后签名的定位会错位（后续还要重签，但偏移错了会直接报坏签名）
        if self.code_sig:
            lc_off, dataoff, datasize = self.code_sig
            struct.pack_into("<II", self.data, lc_off + 8, dataoff + cmdsize, datasize)
        return cmdsize

    def bytes(self) -> bytes:
        return bytes(self.data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--dylib-name", default="BiliProbe.dylib")
    ap.add_argument("--executable", default="Payload/bili-universal.app/bili-universal")
    ap.add_argument("--force", action="store_true",
                    help="即使已存在同名 LC_LOAD_DYLIB 也再插一条（默认跳过，防重复加载）")
    args = ap.parse_args()

    install_name = f"@executable_path/Frameworks/{args.dylib_name}"

    with zipfile.ZipFile(args.ipa) as z:
        names = z.namelist()
        if args.executable not in names:
            raise SystemExit(f"✗ IPA 里找不到 {args.executable}")
        raw = z.read(args.executable)
        infos = {i.filename: i for i in z.infolist()}

        macho = MachO(raw)
        print(f"目标二进制   : {args.executable}")
        print(f"大小         : {len(raw):,} 字节")
        print(f"ncmds        : {macho.ncmds}")
        print(f"sizeofcmds   : {macho.sizeofcmds:,}")
        print(f"lc 区终点    : {macho.lc_end:,}")
        print(f"首个 section : {macho.first_section_offset:,}")
        print(f"空隙         : {macho.first_section_offset - macho.lc_end:,} 字节")
        print(f"现有 LC_LOAD_DYLIB: {len(macho.dylibs)} 条")

        if install_name in macho.dylibs:
            if not args.force:
                print(f"\n⚠️  已存在 {install_name}，跳过注入（防重复加载）。")
                print("   如果这是给「全能签注入插件」用的包，本就不需要预注入 —— 这是正确状态。")
                return 0
            print("   --force：仍要再插一条")

        added = macho.insert_load_dylib(install_name)
        print(f"\n✓ 已插入 LC_LOAD_DYLIB: {install_name}  ({added} 字节)")
        print(f"  新 ncmds={macho.ncmds} sizeofcmds={macho.sizeofcmds:,}")
        if macho.code_sig:
            print(f"  LC_CODE_SIGNATURE dataoff 已同步 +{added}")

        new_raw = macho.bytes()

        # 重写 IPA：必须用 ditto 兼容的写法（保持 zip 结构、无额外压缩怪癖）
        # 这里用 ZIP_DEFLATED，并在 macOS 侧再用 ditto 重打一次以适配全能签
        tmp = args.out + ".tmp"
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=6,
                             allowZip64=True) as zo:
            for n in names:
                info = infos[n]
                if n == args.executable:
                    zi = zipfile.ZipInfo(n, date_time=info.date_time)
                    zi.external_attr = info.external_attr
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    zo.writestr(zi, new_raw)
                else:
                    zo.writestr(info, z.read(n))
        shutil.move(tmp, args.out)
        print(f"\n✓ 输出: {args.out}  ({os.path.getsize(args.out):,} 字节)")
        print("\n下一步（必须在 macOS 上）：重签")
        print("  unzip -q out.ipa -d work && cd work")
        print("  codesign -f -s - --entitlements ent.plist Payload/bili-universal.app")
        print("  find Payload/bili-universal.app -name '*.dylib' -o -name '*.framework' \\")
        print("       | xargs -I{} codesign -f -s - {}")
        print("  ditto -c -k --sequesterRsrc --keepParent Payload out-signed.ipa")
    return 0


if __name__ == "__main__":
    sys.exit(main())
