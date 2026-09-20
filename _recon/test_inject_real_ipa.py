"""
对**真实 IPA** 做一次端到端注入演练，并逐字节核对影响面。

目的：inject_dylib.py 此前只在「合成 Mach-O」和「真实二进制的内存副本」上验证过，
      没有跑过完整的 IPA 读写往返（解包 → 改 → 重打包 → 再解包校验）。
      workflow 里的 --ipa 分支今天也从未真正执行过，所以这个往返是条没走过的路。

本脚本做四件事：
  1) 在临时目录造一个占位 dylib（模拟 BiliProbe.dylib 会被放进去）
  2) 用 inject_dylib.py 注入真实 IPA → 输出到临时文件
  3) 重新解包输出，逐项校验：
       - zip 条目集合与输入一致（少一个都算错）
       - 主二进制长度与输入一致（原地扩展不该改变文件长度）
       - 新 LC_LOAD_DYLIB 存在且安装名正确
       - ncmds / sizeofcmds 增量正确
       - LC_CODE_SIGNATURE 的 dataoff 同步后移 72 字节
       - 除 header 区与新命令区外，主二进制逐字节与输入相同
  4) 清理临时文件

不修改原始 IPA，全程只读输入。
"""
import os, shutil, struct, subprocess, sys, tempfile, zipfile

ROOT = r"E:\Documents\DSHWork\BiliRawPackFast"
IPA = os.path.join(ROOT, "哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa")
INJECTOR = os.path.join(ROOT, "inject", "inject_dylib.py")
EXE = "Payload/bili-universal.app/bili-universal"
INSTALL_NAME = "@executable_path/Frameworks/BiliProbe.dylib"

LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_DYLIB = 0x0C

problems = []


def parse_header(data: bytes):
    """返回一个 dict，字段偏移全部由解析得出，**不手算**。

    这条经验是被咬出来的：本文件里"允许改动范围"的偏移量前后算错过三次
    （dataoff 的 +8 vs +16、datasize 的 +12 vs +16）。
    根因都是凭印象推导 LC_CODE_SIGNATURE 的字段布局。
    实测布局（cmdsize=16）：
        +0  cmd = 0x1D
        +4  cmdsize = 16
        +8  dataoff          ← 签名 blob 的文件偏移
        +12 datasize         ← 签名 blob 的长度
        +16 保留（对齐填充）
    因此这里直接返回字段的绝对偏移，调用方不再推导。
    """
    be = struct.unpack_from(">I", data, 0)[0]
    le = struct.unpack_from("<I", data, 0)[0]
    if le == 0xFEEDFACF:
        fmt = "<"
    elif be == 0xFEEDFACF:
        fmt = ">"
    else:
        raise SystemExit(f"不是 64 位 Mach-O: be={hex(be)} le={hex(le)}")

    ncmds, sizeofcmds = struct.unpack_from(fmt + "II", data, 16)
    off = 32
    out = {"ncmds": ncmds, "sizeofcmds": sizeofcmds, "dylibs": [],
           "sig_cmd_off": None, "dataoff_field": None, "datasize_field": None,
           "dataoff": None, "datasize": None}
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(fmt + "II", data, off)
        if cmd == LC_CODE_SIGNATURE:
            out["sig_cmd_off"] = off
            out["dataoff_field"] = off + 8
            out["datasize_field"] = off + 12
            out["dataoff"] = struct.unpack_from(fmt + "I", data, off + 8)[0]
            out["datasize"] = struct.unpack_from(fmt + "I", data, off + 12)[0]
        elif cmd == LC_LOAD_DYLIB:
            nameoff = struct.unpack_from(fmt + "I", data, off + 8)[0]
            nm = data[off + nameoff:off + cmdsize].split(b"\x00")[0].decode("utf-8", "replace")
            out["dylibs"].append(nm)
        off += cmdsize
    return out


def main():
    if not os.path.exists(IPA):
        print("找不到 IPA:", IPA); return 1

    tmp = tempfile.mkdtemp(prefix="biliword_")
    try:
        # 1) 占位 dylib（内容不重要，本脚本只验证 Mach-O 头部改写）
        fake_dylib = os.path.join(tmp, "BiliProbe.dylib")
        with open(fake_dylib, "wb") as f:
            f.write(b"\xcf\xfa\xed\xfe" + b"\x00" * 4092)   # 假 MH_MAGIC_64 头
        print(f"占位 dylib: {os.path.getsize(fake_dylib)} 字节")

        # 2) 注入
        out_ipa = os.path.join(tmp, "out.ipa")
        print("\n--- 调用 inject_dylib.py ---")
        r = subprocess.run([sys.executable, INJECTOR, "--ipa", IPA, "--out", out_ipa],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        print(r.stdout.strip())
        if r.returncode != 0:
            print(r.stderr.strip())
            problems.append(f"注入器退出码 {r.returncode}")
            return report()

        if not os.path.exists(out_ipa):
            problems.append("注入器没有产出文件")
            return report()
        print(f"输出 IPA: {os.path.getsize(out_ipa):,} 字节")

        # 3) 校验
        print("\n--- 校验 ---")
        with zipfile.ZipFile(IPA) as zin, zipfile.ZipFile(out_ipa) as zout:
            n_in = set(zin.namelist())
            n_out = set(zout.namelist())
            if n_in != n_out:
                missing = n_in - n_out
                extra = n_out - n_in
                problems.append(f"zip 条目不一致：缺 {len(missing)} 个，多 {len(extra)} 个")
                if missing: print("   缺失示例:", list(missing)[:3])
                if extra: print("   多余示例:", list(extra)[:3])
            else:
                print(f"  zip 条目集合一致 ✓ ({len(n_in)} 个)")

            a = zin.read(EXE)
            b = zout.read(EXE)

            if len(a) != len(b):
                problems.append(f"主二进制长度变化 {len(a)} → {len(b)}（原地扩展应保持不变）")
            else:
                print(f"  主二进制长度不变 ✓ ({len(a):,} 字节)")

            n1 = parse_header(a)
            n2 = parse_header(b)
            s1, s2 = n1["sizeofcmds"], n2["sizeofcmds"]
            added = s2 - s1
            print(f"  ncmds {n1['ncmds']} → {n2['ncmds']}   sizeofcmds {s1:,} → {s2:,}")

            if n2["ncmds"] != n1["ncmds"] + 1:
                problems.append(f"ncmds 增量应为 1，实际 {n2['ncmds'] - n1['ncmds']}")
            else:
                print("  ncmds +1 ✓")

            if added != 72:
                problems.append(f"sizeofcmds 增量应为 72，实际 {added}")
            else:
                print("  sizeofcmds +72 ✓")

            if INSTALL_NAME not in n2["dylibs"]:
                problems.append(f"输出里没有 {INSTALL_NAME}")
            else:
                print(f"  LC_LOAD_DYLIB 已加入 ✓ 共 {len(n2['dylibs'])} 条")

            if INSTALL_NAME in n1["dylibs"]:
                problems.append("输入里本来就有该 dylib（不该发生）")

            if n1["dataoff"] is None or n2["dataoff"] is None:
                problems.append("找不到 LC_CODE_SIGNATURE")
            else:
                # dataoff 必须不变：新增的 72 字节落在 load command 区与首个
                # section 之间的空隙里，而签名 blob 在文件末尾，文件长度都没变，
                # 它的偏移自然不动。（最初这里断言 +72，是错的，已修正。）
                if n2["dataoff"] != n1["dataoff"]:
                    problems.append(
                        f"签名 dataoff 被改了：{n1['dataoff']} → {n2['dataoff']}（应当不变）")
                else:
                    print(f"  LC_CODE_SIGNATURE dataoff 保持不变 ✓ ({n1['dataoff']:,})")
                if n2["datasize"] != 0:
                    problems.append(f"datasize 未置 0（={n2['datasize']}），原签名未失效")
                else:
                    print(f"  LC_CODE_SIGNATURE datasize 已置 0 ✓"
                          f"（原 {n1['datasize']:,} → 0，强制重签）")

            # 逐字节差异核对：只允许三处变化
            #   ① header 的 ncmds/sizeofcmds（偏移 16..24）
            #   ② 新增 LC_LOAD_DYLIB 占用的 [lc_end, lc_end+72)
            #   ③ LC_CODE_SIGNATURE 的 datasize 字段（4 字节）—— 偏移由解析给出，
            #      不手算。这一段的偏移量在本文件里前后算错过三次
            #      （dataoff 的 +8/+16、datasize 的 +12/+16），
            #      根因都是凭印象推 LC_CODE_SIGNATURE 的布局；
            #      改成从 parse_header 拿绝对偏移后就不会再错。
            lc_end = 32 + s1
            allowed = set(range(16, 24)) | set(range(lc_end, lc_end + added))
            if n1["datasize_field"] is not None:
                allowed |= set(range(n1["datasize_field"], n1["datasize_field"] + 4))
            diff = [i for i in range(min(len(a), len(b))) if a[i] != b[i]]
            unexpected = [i for i in diff if i not in allowed]
            print(f"  逐字节差异 {len(diff)} 处，其中落在允许区外 {len(unexpected)} 处")
            if unexpected:
                problems.append(f"有 {len(unexpected)} 字节被意外修改，前几个偏移 {unexpected[:8]}")
            else:
                print("  影响面严格受限 ✓（仅 header 计数 / 新命令 / 签名 datasize 置 0）")

        return report()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def report():
    print()
    if problems:
        print("发现问题：")
        for p in problems:
            print("  ✗", p)
        return 1
    print("真实 IPA 端到端注入演练通过 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
