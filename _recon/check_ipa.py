#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立校验「预注入版 IPA」是否真的带着 dylib 且主二进制里有对应 LC_LOAD_DYLIB。

为什么单独写一个：用户签的就是这个文件。之前出过一次「注入工具的注入步骤静默失败、
App 照常运行但什么都不发生」的情况 —— 症状和「代码有 bug」一模一样，极难分辨。
与其让用户去猜安装工具，不如我们自己保证交付物是对的，并让用户跳过注入那一步。

用法：python _recon/check_ipa.py deliver/bili-9.12.0-probe-injected.ipa [期望的dylib路径]
"""
import struct
import sys
import zipfile
from pathlib import Path

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF


def thin_slices(data):
    """返回 [(offset, size, cputype)]，处理 FAT 与 thin 两种情况。"""
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        is64 = magic == FAT_MAGIC_64
        nfat = struct.unpack_from(">I", data, 4)[0]
        out = []
        ent = 32 if is64 else 20
        for i in range(nfat):
            o = 8 + i * ent
            cputype = struct.unpack_from(">i", data, o)[0]
            if is64:
                off, size = struct.unpack_from(">QQ", data, o + 8)
            else:
                off, size = struct.unpack_from(">II", data, o + 8)
            out.append((off, size, cputype))
        return out
    le = struct.unpack_from("<I", data, 0)[0]
    if le == MH_MAGIC_64:
        return [(0, len(data), struct.unpack_from("<i", data, 4)[0])]
    raise SystemExit("无法识别的 Mach-O magic")


def dylibs_of_slice(data, off, size):
    magic = struct.unpack_from("<I", data, off)[0]
    if magic != MH_MAGIC_64:
        return None
    ncmds = struct.unpack_from("<I", data, off + 16)[0]
    p = off + 32
    end = off + size
    out = []
    for _ in range(ncmds):
        if p + 8 > end:
            break
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmdsize < 8:
            break
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            name_off = struct.unpack_from("<I", data, p + 8)[0]
            s = p + name_off
            e = data.index(b"\x00", s)
            out.append((data[s:e].decode("utf-8", "replace"),
                        cmd == LC_LOAD_WEAK_DYLIB))
        p += cmdsize
    return out


CPU_NAMES = {0x0100000C: "arm64", 0x01000007: "x86_64", 7: "i386", 12: "arm"}


def main():
    ipa = sys.argv[1] if len(sys.argv) > 1 else "deliver/bili-9.12.0-probe-injected.ipa"
    f = Path(ipa)
    if not f.exists():
        raise SystemExit("找不到 %s" % ipa)

    print("IPA: %s  (%.1f MiB)" % (f.name, f.stat().st_size / 1048576))

    ok = True
    with zipfile.ZipFile(f) as z:
        names = z.namelist()
        # app 根目录（形如 "Payload/xxx.app"）—— 后面所有路径都基于它，避免
        # 误选到子目录里的同名文件
        roots = sorted({"/".join(n.split("/")[:2]) for n in names
                        if n.startswith("Payload/") and n.split("/")[1].endswith(".app")})
        if not roots:
            print("✗ 这个包里没有 .app 目录")
            return 1
        app_dir = roots[0]
        app = app_dir.split("/")[1]
        print("App bundle: %s" % app_dir)

        # 1) dylib 是否就位
        dylib_entries = [n for n in names if n.startswith("Payload/%s/Frameworks/" % app)
                         and n.endswith(".dylib")]
        print("\n[1] Frameworks 下的 dylib：%d 个" % len(dylib_entries))
        for n in dylib_entries:
            print("    %s  (%d 字节)" % (n.split("/")[-1], z.getinfo(n).file_size))
        probe = [n for n in dylib_entries if "BiliProbe" in n]
        if not probe:
            print("    ✗ 没找到 BiliProbe.dylib —— 这个包不该发给用户")
            ok = False
        else:
            print("    ✓ BiliProbe.dylib 已就位")

        # 2) 主二进制里有没有指向它的 LC_LOAD_DYLIB
        exe = "%s/%s" % (app_dir, app[:-4])
        if exe not in names:
            cands = [n for n in names if n.startswith("%s/" % app_dir)
                     and n.count("/") == 2 and not n.endswith("/")]
            exe = cands[0] if cands else None
        if not exe:
            print("\n[2] ✗ 找不到主二进制")
            return 1
        print("\n[2] 主二进制：%s" % exe)
        data = z.read(exe)
        print("    长度 %d 字节" % len(data))

        found = False
        for off, size, cputype in thin_slices(data):
            dl = dylibs_of_slice(data, off, size)
            if dl is None:
                continue
            name = CPU_NAMES.get(cputype, hex(cputype))
            hits = [(d, w) for d, w in dl if "BiliProbe" in d]
            print("    切片 %s：共 %d 条 LC_LOAD_DYLIB，其中 BiliProbe %d 条"
                  % (name, len(dl), len(hits)))
            for d, weak in hits:
                print("        %s%s" % (d, "  (weak)" if weak else ""))
                if not weak:
                    found = True
        if found:
            print("    ✓ 主二进制已引用 BiliProbe.dylib（强链接，缺失会导致启动崩溃）")
        else:
            print("    ✗ 主二进制没有引用 BiliProbe.dylib —— dylib 不会加载")
            ok = False

        # 3) Info.plist 的 Documents 共享开关（决定用户能否在「文件」App 里看到日志）
        # 注意：必须精确选 app 根目录下那一个。子目录（Frameworks/PlugIns/appex）
        # 里也有同名文件，按名字排序会先命中它们 —— 上一版就因此误报「两个键都没开」。
        info = "%s/Info.plist" % app_dir
        if info in names:
            import plistlib
            try:
                pl = plistlib.loads(z.read(info))
                fs = pl.get("UIFileSharingEnabled")
                oi = pl.get("LSSupportsOpeningDocumentsInPlace")
                print("\n[3] Info.plist（%s）：UIFileSharingEnabled=%s  "
                      "LSSupportsOpeningDocumentsInPlace=%s" % (info, fs, oi))
                if not (fs or oi):
                    print("    ✗ 两个都没开 —— 用户看不到 Documents 下的日志目录")
                    ok = False
                else:
                    print("    ✓ 日志目录可以在「文件」App 里看到")
            except Exception as e:  # noqa: BLE001
                print("\n[3] Info.plist 解析失败：%s" % e)
                ok = False
        else:
            print("\n[3] ✗ app 根目录下没有 Info.plist")
            ok = False

    print("\n结论：%s" % ("全部通过 ✅" if ok else "★ 有问题，不要发给用户"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
