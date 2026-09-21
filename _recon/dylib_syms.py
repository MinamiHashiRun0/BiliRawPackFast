#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""检查 dylib 的未定义符号，以及它们是否来自允许的系统库。

为什么要查这个：如果 dylib 引用了 dyld 解析不出来的符号，App 会在**加载 dylib
的瞬间**崩掉 —— 症状正是「Documents 下连日志文件夹都没建出来」，因为构造函数
压根没机会执行。之前 verify_dylib.py 只查了 otool -L（依赖哪些库），
没查符号表，所以这类问题能溜过去。
"""
import struct
import sys
from pathlib import Path

LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018

N_UNDF = 0x0
N_TYPE = 0x0E
N_EXT = 0x01
N_STAB = 0xE0


def parse(path):
    data = Path(path).read_bytes()
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0xFEEDFACF:
        raise SystemExit("不是 64 位小端 Mach-O：magic=0x%08X" % magic)

    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    symtab = None
    libs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", data, off + 8)
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            end = data.index(b"\x00", off + name_off)
            libs.append(data[off + name_off:end].decode("utf-8", "replace"))
        off += cmdsize

    if not symtab:
        raise SystemExit("没有 LC_SYMTAB")

    symoff, nsyms, stroff, strsize = symtab
    undef, defined = [], []
    for i in range(nsyms):
        o = symoff + i * 16
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, o)
        if n_type & N_STAB:
            continue
        if n_strx == 0:
            continue
        end = data.index(b"\x00", stroff + n_strx)
        name = data[stroff + n_strx:end].decode("utf-8", "replace")
        if (n_type & N_TYPE) == N_UNDF:
            undef.append((name, n_desc))
        else:
            defined.append(name)
    return libs, undef, defined


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else r"_artifact\BiliProbe-dylib\BiliProbe.dylib"
    libs, undef, _ = parse(path)

    print("文件: %s" % path)
    print("\n依赖库（%d）：" % len(libs))
    for l in libs:
        tag = "系统" if (l.startswith("/usr/lib/") or l.startswith("/System/")) else "!! 非系统"
        print("  [%s] %s" % (tag, l))

    print("\n未定义符号（%d）：" % len(undef))

    # 分类：ObjC 运行时的私有转发符号要特别标出来
    interesting = []
    for name, n_desc in sorted(undef):
        flags = []
        if n_desc & 0x0008:
            flags.append("weak")
        if name in ("_objc_msgForward", "_objc_msgForward_stret"):
            flags.append("★ ObjC 转发入口")
        if name.startswith("_$s") or name.startswith("_$S"):
            flags.append("Swift")
        if flags:
            interesting.append("  %-48s %s" % (name, " ".join(flags)))

    print("  其中需要重点确认的：")
    if interesting:
        for l in interesting:
            print(l)
    else:
        print("    （无）")

    groups = {}
    for name, _ in undef:
        if name.startswith("_OBJC_CLASS_$_"):
            groups.setdefault("ObjC 类", []).append(name[14:])
        elif name.startswith("_OBJC_METACLASS_$_"):
            groups.setdefault("ObjC 元类", []).append(name[17:])
        elif name.startswith("_objc_"):
            groups.setdefault("ObjC 运行时", []).append(name)
        elif name.startswith("_"):
            groups.setdefault("C 函数/其它", []).append(name)
    for k in sorted(groups):
        v = sorted(groups[k])
        print("\n  [%s] %d 个" % (k, len(v)))
        for x in v[:40]:
            print("      %s" % x)
        if len(v) > 40:
            print("      …（还有 %d 个）" % (len(v) - 40))

    return 0


if __name__ == "__main__":
    sys.exit(main())
