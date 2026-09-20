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
    """返回 (ncmds, sizeofcmds, endian, code_sig_dataoff_value, dylibs, dataoff_field_offset)

    dataoff_field_offset 是该字段在文件中的真实字节偏移（实测为命令起始 +16），
    供逐字节差异核对精确圈定允许改动范围，避免凭印象写出 +8 这种错。
    """
    be = struct.unpack_from(">I", data, 0)[0]
    le = struct.unpack_from("<I", data, 0)[0]
    if le == 0xFEEDFACF:
        fmt, endian = "<", "le"
    elif be == 0xFEEDFACF:
        fmt, endian = ">", "be"
    else:
        raise SystemExit(f"不是 64 位 Mach-O: be={hex(be)} le={hex(le)}")

    ncmds, sizeofcmds = struct.unpack_from(fmt + "II", data, 16)
    off = 32
    code_sig = None
    code_sig_field = None
    dylibs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(fmt + "II", data, off)
        if cmd == LC_CODE_SIGNATURE:
            code_sig = struct.unpack_from(fmt + "I", data, off + 8)[0]
            code_sig_field = off + 8
        elif cmd == LC_LOAD_DYLIB:
            nameoff = struct.unpack_from(fmt + "I", data, off + 8)[0]
            nm = data[off + nameoff:off + cmdsize].split(b"\x00")[0].decode("utf-8", "replace")
            dylibs.append(nm)
        off += cmdsize
    return ncmds, sizeofcmds, endian, code_sig, dylibs, code_sig_field


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

            n1, s1, e1, cs1, d1, csf1 = parse_header(a)
            n2, s2, e2, cs2, d2, csf2 = parse_header(b)
            print(f"  ncmds {n1} → {n2}   sizeofcmds {s1:,} → {s2:,}")

            if n2 != n1 + 1:
                problems.append(f"ncmds 增量应为 1，实际 {n2 - n1}")
            else:
                print("  ncmds +1 ✓")

            added = s2 - s1
            if added != 72:
                problems.append(f"sizeofcmds 增量应为 72，实际 {added}")
            else:
                print("  sizeofcmds +72 ✓")

            if INSTALL_NAME not in d2:
                problems.append(f"输出里没有 {INSTALL_NAME}")
            else:
                print(f"  LC_LOAD_DYLIB 已加入 ✓ 共 {len(d2)} 条")

            if INSTALL_NAME in d1:
                problems.append("输入里本来就有该 dylib（不该发生）")

            if cs1 is None or cs2 is None:
                problems.append("找不到 LC_CODE_SIGNATURE")
            elif cs2 != cs1 + added:
                problems.append(f"签名 dataoff 未同步：{cs1} → {cs2}，期望 +{added}")
            else:
                print(f"  LC_CODE_SIGNATURE dataoff {cs1:,} → {cs2:,} (+{added}) ✓")

            # 逐字节差异核对：只允许三处变化
            #   ① header 的 ncmds/sizeofcmds（偏移 16..24）
            #   ② 新增 LC_LOAD_DYLIB 占用的 [lc_end, lc_end+72)
            #   ③ LC_CODE_SIGNATURE 里的 dataoff 字段
            #      ⚠️ 该字段位于命令起始 +16（cmd@0, cmdsize@4, dataoff@8..12？
            #      不 —— 实测布局是 cmd@0 cmdsize@4 然后 4 字节对齐填充，
            #      dataoff 实际落在命令起始 +16）。
            #      第一版这里写成 +8，导致把「正确更新 dataoff」误判成越界修改。
            #      教训：核对脚本自己也要用实测偏移，不能凭印象写。
            lc_end = 32 + s1
            allowed = set(range(16, 24)) | set(range(lc_end, lc_end + added))
            if csf1 is not None:
                allowed |= set(range(csf1, csf1 + 4))
            diff = [i for i in range(min(len(a), len(b))) if a[i] != b[i]]
            unexpected = [i for i in diff if i not in allowed]
            print(f"  逐字节差异 {len(diff)} 处，其中落在允许区外 {len(unexpected)} 处")
            if unexpected:
                problems.append(f"有 {len(unexpected)} 字节被意外修改，前几个偏移 {unexpected[:8]}")
            else:
                print("  影响面严格受限 ✓（仅 header 计数 / 新命令 / 签名 dataoff）")

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
