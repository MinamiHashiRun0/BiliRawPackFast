"""
组装「预注入版 IPA」：把 BiliProbe.dylib 放进 app 的 Frameworks/，
并给主二进制追加 LC_LOAD_DYLIB。

两种装法（**二选一，不可同时用**）：
  A. 预注入版（本脚本产出）：直接签名安装即可，不需要全能签的插件注入功能。
  B. 裸 dylib + 全能签插件注入：本次之前交付的方式。
  若先用了 A，又在全能签里再注入一次 B，dylib 会被加载两次 ——
  构造函数跑两遍。hook 是幂等的（重复挂会走 already-hooked 分支），
  所以不会崩，但日志会翻倍、排查时容易误判。故必须二选一。

为什么只做「注入 + 放 dylib」而不做签名：
  签名必须在 macOS 上用 codesign 完成，Windows 做不到。
  全能签本来就是签名工具，拿到这个包直接签即可。
  本包注入完成后，主二进制的签名已被破坏（这是必然的），
  全能签重新签名时会一并覆盖，正是它该做的事。
"""
import os, shutil, struct, sys, tempfile, zipfile, importlib.util

ROOT = r"E:\Documents\DSHWork\BiliRawPackFast"
IPA = os.path.join(ROOT, "哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa")
DYLIB = os.path.join(ROOT, "deliver", "BiliProbe.dylib")
OUT_IPA = os.path.join(ROOT, "deliver", "bili-9.12.0-probe-injected.ipa")

APP = "Payload/bili-universal.app"
EXE = f"{APP}/bili-universal"
DYLIB_IN_APP = f"{APP}/Frameworks/BiliProbe.dylib"

LC_LOAD_DYLIB = 0x0C
LC_CODE_SIGNATURE = 0x1D
LC_SEGMENT_64 = 0x19


def find_code_signature_cmd(buf: bytes):
    """返回 (命令偏移, dataoff, datasize, datasize字段偏移)；找不到返回 None

    实测布局（cmdsize=16）: +0 cmd | +4 cmdsize | +8 dataoff | +12 datasize
    这里把 datasize 字段的绝对偏移一并返回，调用方不必再手算 ——
    本文件与 test_inject_real_ipa.py 都因为手算这个偏移错过三次。
    """
    if struct.unpack_from("<I", buf, 0)[0] != 0xFEEDFACF:
        return None
    ncmds = struct.unpack_from("<I", buf, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<II", buf, off + 8)
            return (off, dataoff, datasize, off + 12)
        off += cmdsize
    return None


def parse_superblob_has_entitlements(buf: bytes, dataoff: int, datasize: int) -> bool:
    """签名 blob 里是否含 entitlements 槽（槽位 5）"""
    if datasize < 12 or dataoff + datasize > len(buf):
        return False
    blob = buf[dataoff:dataoff + datasize]
    magic, _length, count = struct.unpack_from(">III", blob, 0)
    if magic != 0xFADE0CC0:
        return False
    for i in range(count):
        o = 12 + i * 8
        if o + 8 > len(blob):
            break
        slot, offset = struct.unpack_from(">II", blob, o)
        if slot == 5:
            return True
    return False


def load_injector():
    spec = importlib.util.spec_from_file_location(
        "inject_dylib", os.path.join(ROOT, "inject", "inject_dylib.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    for p, what in ((IPA, "脱壳 IPA"), (DYLIB, "BiliProbe.dylib")):
        if not os.path.exists(p):
            print(f"找不到{what}: {p}")
            return 1

    inj = load_injector()
    print(f"源 IPA     : {os.path.getsize(IPA):,} 字节")
    print(f"待注入 dylib: {os.path.getsize(DYLIB):,} 字节")

    tmp = tempfile.mkdtemp(prefix="biliinject_")
    try:
        # 1) 先把 dylib 放进 app bundle，产出中间 IPA
        mid = os.path.join(tmp, "mid.ipa")
        with zipfile.ZipFile(IPA) as zin, \
             zipfile.ZipFile(mid, "w", zipfile.ZIP_DEFLATED, compresslevel=6,
                             allowZip64=True) as zout:
            names = zin.namelist()
            if EXE not in names:
                print(f"IPA 里找不到 {EXE}")
                return 1
            if DYLIB_IN_APP in names:
                print("⚠️ IPA 里已经有 BiliProbe.dylib，将覆盖")
            added = 0
            for n in names:
                info = zin.getinfo(n)
                zout.writestr(info, zin.read(n))
            # 追加 dylib（IPA 里原本没有这个条目）
            zi = zipfile.ZipInfo(DYLIB_IN_APP, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o755 << 16          # 可执行权限
            with open(DYLIB, "rb") as f:
                dylib_bytes = f.read()
            zout.writestr(zi, dylib_bytes)
        print(f"① 已把 dylib 放入 {DYLIB_IN_APP}")

        # 2) 给主二进制追加 LC_LOAD_DYLIB
        final = os.path.join(tmp, "final.ipa")
        with zipfile.ZipFile(mid) as z:
            raw = z.read(EXE)
        macho = inj.MachO(raw)
        name = "@executable_path/Frameworks/BiliProbe.dylib"
        if name in macho.dylibs:
            print("② 主二进制已含该 LC_LOAD_DYLIB，跳过")
            added_lc = 0
        else:
            added_lc = macho.insert_load_dylib(name)
            print(f"② 已追加 LC_LOAD_DYLIB（{added_lc} 字节），"
                  f"ncmds {macho.ncmds} sizeofcmds {macho.sizeofcmds:,}")
        new_raw = macho.bytes()

        # 记下 LC_CODE_SIGNATURE 命令位置与剥离前的状态，供第 3.5 步与自校验用
        # 注意：注入器现在**故意**把 datasize 置 0（让原签名失效），
        # 所以想看原始签名内容必须从**未注入的源数据**里读 —— 从 new_raw 读不到。
        cs_src = find_code_signature_cmd(raw)
        if cs_src:
            _, src_dataoff, src_datasize, _ = cs_src
            had_ent = parse_superblob_has_entitlements(raw, src_dataoff, src_datasize)
            print(f"   源二进制签名 blob: offset={src_dataoff:,} size={src_datasize:,} "
                  f"含 entitlements 槽={had_ent}")

        cs = find_code_signature_cmd(new_raw)
        if cs is None:
            print("⚠️ 找不到 LC_CODE_SIGNATURE，跳过签名剥离")
            csoff = None
            cs_dataoff = None
            cs_datasize = 0
            cs_datasize_field = None
        else:
            csoff, cs_dataoff, cs_datasize_now, cs_datasize_field = cs
            cs_datasize = src_datasize if cs_src else cs_datasize_now
            print(f"   注入后：dataoff={cs_dataoff:,} datasize={cs_datasize_now}（已被置 0）")

        # 3) 写出最终 IPA
        with zipfile.ZipFile(mid) as zin, \
             zipfile.ZipFile(final, "w", zipfile.ZIP_DEFLATED, compresslevel=6,
                             allowZip64=True) as zout:
            for info in zin.infolist():
                if info.filename == EXE:
                    zi = zipfile.ZipInfo(EXE, date_time=info.date_time)
                    zi.external_attr = info.external_attr
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    zout.writestr(zi, new_raw)
                else:
                    zout.writestr(info, zin.read(info.filename))
        shutil.move(final, OUT_IPA)
        print(f"③ 输出: {OUT_IPA}  ({os.path.getsize(OUT_IPA):,} 字节)")

        # 3.5) 剥离原始 entitlements —— 这一步关系到能不能装上
        # 实测本脱壳包仍完整保留原始 entitlements，其中
        #   application-identifier = 746845GC96.tv.danmaku.bilianime  ← B站的 Team ID
        # 自签用的是用户自己的证书，team ID 必然不同。
        # 若把这些 entitlements 原样留在包里，某些签名工具会一并带过去，
        # 结果是「一启动就闪退」——而用户会以为是注入失败，白白浪费一轮真机测试。
        # 因此这里把主二进制的签名整体抹掉，强制签名工具重新生成。
        stripped = bytearray(new_raw)
        if csoff is not None:
            # 只把 datasize 置 0，dataoff 保持不变（签名 blob 在文件末尾，
            # 原地扩展没有移动它）。偏移由 find_code_signature_cmd 给出。
            struct.pack_into("<I", stripped, cs_datasize_field, 0)
        # 上面只置空了 LC_CODE_SIGNATURE 指向的范围，文件尾部的 blob 留着
        # （不影响加载，签名工具重签时会覆盖或忽略）
        with zipfile.ZipFile(OUT_IPA) as zin, \
             zipfile.ZipFile(OUT_IPA + ".tmp", "w", zipfile.ZIP_DEFLATED,
                             compresslevel=6, allowZip64=True) as zout:
            for info in zin.infolist():
                if info.filename == EXE:
                    zi = zipfile.ZipInfo(EXE, date_time=info.date_time)
                    zi.external_attr = info.external_attr
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    zout.writestr(zi, bytes(stripped))
                else:
                    zout.writestr(info, zin.read(info.filename))
        shutil.move(OUT_IPA + ".tmp", OUT_IPA)
        print("④ 已剥离主二进制原有签名（避免 B站 Team ID 的 entitlements 被带过去）")
        print("   原 entitlements 见 _recon/entitlements_probe.json，仅供查阅")
        with open(os.path.join(ROOT, "deliver", "ORIGINAL-ENTITLEMENTS-PLEASE-READ.txt"),
                  "wb") as f:
            f.write(
                "重要：请不要让签名工具沿用包内原有的 entitlements\n"
                "================================================\n\n"
                "这个脱壳包原本带的是 B站 的 entitlements，其中\n"
                "  application-identifier = 746845GC96.tv.danmaku.bilianime\n"
                "里的 Team ID 是 B站的（746845GC96），而你是用自己的证书签名，\n"
                "Team ID 必然不同。\n\n"
                "若签名工具把这些 entitlements 原样带过去，典型症状是\n"
                "**一启动就闪退**。这会让人误以为是注入失败。\n\n"
                "本包已经剥离了主二进制的原有签名以尽量避免这种情况，\n"
                "但不同签名工具行为不一，所以：\n"
                "  * 如果全能签里可以选，请让它「使用自己的证书重新生成 entitlements」\n"
                "  * 如果 App 一启动就闪退，请先怀疑这一点，而不是先怀疑注入\n\n"
                "另外这些权限自签本来也拿不到（需要 Apple 下发的 provisioning）：\n"
                "  extended-virtual-addressing / increased-memory-limit（JIT 相关，视频类 App 常用）\n"
                "  aps-environment=production（推送）\n"
                "  associated-domains / applesignin / multicast / siri\n"
                "失去它们会影响相应功能，但不影响注入验证本身。\n"
                .encode("utf-8"))       # 显式 UTF-8 + LF：Windows 上文本模式会写成 CRLF

        # 4) 自校验
        print("\n--- 自校验 ---")
        problems = []
        with zipfile.ZipFile(OUT_IPA) as z:
            n_out = set(z.namelist())
            with zipfile.ZipFile(IPA) as z0:
                n_in = set(z0.namelist())
            if DYLIB_IN_APP not in n_out:
                problems.append("输出里没有 dylib")
            else:
                got = z.read(DYLIB_IN_APP)
                want = open(DYLIB, "rb").read()
                if got != want:
                    problems.append("dylib 内容不一致")
                else:
                    print(f"  dylib 已就位且内容一致 ✓ ({len(got):,} 字节)")
            missing = n_in - n_out
            if missing:
                problems.append(f"丢了 {len(missing)} 个原条目")
            else:
                print(f"  原有 {len(n_in)} 个条目全部保留 ✓（共 {len(n_out)} 个）")

            b = z.read(EXE)
            m2 = inj.MachO(b)
            if name not in m2.dylibs:
                problems.append("主二进制里没有 LC_LOAD_DYLIB")
            else:
                print(f"  LC_LOAD_DYLIB 就位 ✓ 共 {len(m2.dylibs)} 条")
            if len(b) != len(raw):
                problems.append("主二进制长度变了")
            else:
                print(f"  主二进制长度未变 ✓ ({len(b):,} 字节)")

            # 签名剥离必须真的生效，否则 B站 Team ID 的 entitlements 可能被带过去
            cs2 = find_code_signature_cmd(b)
            if cs2 is None:
                problems.append("输出里找不到 LC_CODE_SIGNATURE")
            else:
                _, do2, ds2, _ = cs2
                if ds2 != 0:
                    problems.append(f"签名未被剥离（datasize={ds2}）")
                elif do2 != cs_dataoff:
                    problems.append(f"dataoff 被误改：{cs_dataoff} → {do2}")
                else:
                    print(f"  原有签名已剥离 ✓（datasize=0，dataoff 保持 {do2:,} 不变）")
                # dataoff 未被改动，说明尾部原本的签名 blob 还留在原处，
                # 仍然可以读出原始 entitlements（不可用，仅供查阅）
                if parse_superblob_has_entitlements(b, do2, cs_datasize):
                    print("  尾部原始签名 blob 仍在原处，可读出原始 entitlements ✓")

        if problems:
            print("\n发现问题：")
            for p in problems:
                print("  ✗", p)
            return 1
        print("\n预注入版 IPA 组装完成 ✅")
        print("\n下一步（在手机上）：")
        print(f"  1. 把 {os.path.basename(OUT_IPA)} 传到手机")
        print("  2. 全能签打开它 → 用自己的证书签名安装")
        print("     （**不要**再启用插件注入 BiliProbe.dylib，否则加载两次）")
        print("  3. 打开 App → 播一个视频 → **停留 45 秒以上**（探针 45 秒才写结论）")
        print("  4. 文件 App → 我的 iPhone → 哔哩哔哩 → biliprobe/")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
