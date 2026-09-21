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

# 要打包哪个 dylib：
#   python build_injected_ipa.py              -> BiliProbe（探针，取证用）
#   python build_injected_ipa.py BiliFast     -> BiliFast（正式模块，日常用）
MODULE = sys.argv[1] if len(sys.argv) > 1 else "BiliProbe"
if MODULE not in ("BiliProbe", "BiliFast"):
    raise SystemExit("模块名只能是 BiliProbe 或 BiliFast，收到: %r" % MODULE)

DYLIB = os.path.join(ROOT, "deliver", MODULE + ".dylib")
if MODULE == "BiliProbe":
    OUT_IPA = os.path.join(ROOT, "deliver", "bili-9.12.0-probe-injected.ipa")
else:
    OUT_IPA = os.path.join(ROOT, "deliver", "bili-9.12.0-BiliFast-injected.ipa")

APP = "Payload/bili-universal.app"
EXE = f"{APP}/bili-universal"
DYLIB_IN_APP = f"{APP}/Frameworks/{MODULE}.dylib"

LC_LOAD_DYLIB = 0x0C
LC_CODE_SIGNATURE = 0x1D
LC_SEGMENT_64 = 0x19


def dylib_install_names(buf: bytes) -> list:
    """直接扫 load command 列出全部 LC_LOAD_DYLIB 安装名。
    为什么要单独一个函数：MachO 对象里的 dylibs 是**构造时**的快照，
    insert_load_dylib 之后不会自动刷新 —— 拿它做自校验会误报"没有 LC_LOAD_DYLIB"。
    （本轮就是这么误报的：明明注入成功，报告却说没有。）"""
    if len(buf) < 32 or struct.unpack_from("<I", buf, 0)[0] != 0xFEEDFACF:
        return []
    ncmds = struct.unpack_from("<I", buf, 16)[0]
    out, off = [], 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmd == LC_LOAD_DYLIB:
            nameoff = struct.unpack_from("<I", buf, off + 8)[0]
            out.append(bytes(buf[off + nameoff:off + cmdsize])
                       .split(b"\x00")[0].decode("utf-8", "replace"))
        off += cmdsize
    return out


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


def check_dylib_is_current(dylib_path: str) -> bool:
    """确认 deliver 下的 dylib 就是当前 HEAD 编出来的那个。

    为什么必须查：本轮就出过事 —— 从 CI 下载了新构建，却忘了复制到 deliver/，
    于是打出来的 IPA 里装的还是**上一版** dylib（没有 4K 修复、没有设置面板），
    而所有校验都是绿的（文件在、路径对、结构合法）。只有哈希对不上，
    但没人会去比对哈希。
    dylib 里编进了构建时的 git short sha，直接在里面找当前 HEAD 的 sha 即可。
    """
    import subprocess
    try:
        head = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"],
                                       cwd=ROOT, stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        print("  ⚠ 拿不到当前 git HEAD，跳过新鲜度检查")
        return True
    blob = open(dylib_path, "rb").read()
    if head.encode() in blob:
        print(f"  dylib 新鲜度 ✓（内含当前 HEAD {head}）")
        return True
    print(f"  ✗ dylib 里找不到当前 HEAD {head} —— 这很可能是**旧构建**：")
    print(f"    请先把 CI 产物复制到 deliver/{MODULE}.dylib 再打包。")
    return False


def main():
    for p, what in ((IPA, "脱壳 IPA"), (DYLIB, MODULE + ".dylib")):
        if not os.path.exists(p):
            print(f"找不到{what}: {p}")
            return 1

    inj = load_injector()
    print(f"源 IPA     : {os.path.getsize(IPA):,} 字节")
    print(f"待注入 dylib: {os.path.getsize(DYLIB):,} 字节")
    if not check_dylib_is_current(DYLIB):
        return 1

    tmp = tempfile.mkdtemp(prefix="biliinject_")
    try:
        # 1) 只做前置检查
        #    （早期版本在这里先写一个带 dylib 的 mid.ipa，第 4 步再整包重写一遍 ——
        #      等于凭空多一轮 265MB 读写加一份内存拷贝，在内存偏低的机器上会 OOM。
        #      现在合并为第 4 步一次写出。）
        with zipfile.ZipFile(IPA) as zin:
            names = zin.namelist()
            if EXE not in names:
                print(f"IPA 里找不到 {EXE}")
                return 1
        print(f"① 源 IPA 含 {len(names)} 个条目，主二进制与 dylib 均存在")

        # 2) 读取主二进制并追加 LC_LOAD_DYLIB
        # 内存注意：主二进制 630MB，需避免同时持有 bytes + bytearray 多份副本。
        # 早期版本同时存在 raw(bytes) + MachO 内部副本 + stripped(bytearray) 三份，
        # 在可用内存偏低的机器上直接 MemoryError。现在只保留一份 bytearray。
        final = os.path.join(tmp, "final.ipa")
        with zipfile.ZipFile(IPA) as z:
            raw = bytearray(z.read(EXE))       # 只此一份

        # 在改动之前先记录 LC_CODE_SIGNATURE 的位置与原始大小
        cs_src = find_code_signature_cmd(raw)
        if cs_src:
            _, src_dataoff, src_datasize, _ = cs_src
            had_ent = parse_superblob_has_entitlements(raw, src_dataoff, src_datasize)
            print(f"   源二进制签名 blob: offset={src_dataoff:,} size={src_datasize:,} "
                  f"含 entitlements 槽={had_ent}")

        macho = inj.MachO(raw)
        name = "@executable_path/Frameworks/%s.dylib" % MODULE
        if name in macho.dylibs:
            print("② 主二进制已含该 LC_LOAD_DYLIB，跳过")
            added_lc = 0
            csoff, cs_dataoff, cs_datasize_now, cs_datasize_field = (
                find_code_signature_cmd(raw) or (None, None, 0, None))
        else:
            added_lc = macho.insert_load_dylib(name)
            print(f"② 已追加 LC_LOAD_DYLIB（{added_lc} 字节），"
                  f"ncmds {macho.ncmds} sizeofcmds {macho.sizeofcmds:,}")
            cs = find_code_signature_cmd(macho.data)
            if cs is None:
                csoff = cs_dataoff = cs_datasize_field = None
                cs_datasize_now = 0
            else:
                csoff, cs_dataoff, cs_datasize_now, cs_datasize_field = cs
            print(f"   注入后：dataoff={cs_dataoff:,} datasize={cs_datasize_now}（已被置 0）")

        cs_datasize = src_datasize if cs_src else cs_datasize_now

        # 3) 剥离原始签名 —— 这一步关系到能不能装上
        # 实测本脱壳包仍完整保留原始 entitlements，其中
        #   application-identifier = 746845GC96.tv.danmaku.bilianime  ← B站的 Team ID
        # 自签用的是用户自己的证书，team ID 必然不同。
        # 若把这些 entitlements 原样留在包里，某些签名工具会一并带过去，
        # 结果是「一启动就闪退」——而用户会以为是注入失败，白白浪费一轮真机测试。
        # 做法：把 LC_CODE_SIGNATURE 的 datasize 置 0。
        #   dataoff 保持不变（签名 blob 在文件末尾，原地扩展没有移动它）；
        #   尾部 blob 本体留着（读不到，但不破坏结构），仍可用于查阅原始 entitlements。
        # 就地改这一份 bytearray，不再拷第二份。
        if csoff is not None:
            struct.pack_into("<I", macho.data, cs_datasize_field, 0)
            print("③ 已剥离主二进制原有签名（datasize=0）")

        # 4) 一次性写出最终 IPA（读原 IPA → 替换主二进制 → 追加 dylib）
        #    内存策略：主二进制 630MB，全程只保留 macho.data 这一份 bytearray。
        #    写出时用 ZipFile.open(zi,'w') 流式写，**不再** exec_bytes = bytes(...)
        #    那样会多出一份 630MB 副本 —— 在可用内存 2.6GB 的机器上直接 MemoryError。
        #    自校验也从 macho.data 读，避免再复制。
        orig_exe_len = len(macho.data)
        with zipfile.ZipFile(IPA) as zin, \
             zipfile.ZipFile(final, "w", zipfile.ZIP_DEFLATED, compresslevel=6,
                             allowZip64=True) as zout:
            names = zin.namelist()
            if DYLIB_IN_APP in names:
                print("⚠️ 原 IPA 里已有 %s.dylib，将覆盖" % MODULE)
            # 先写 dylib 之外的所有条目
            for info in zin.infolist():
                if info.filename == EXE or info.filename == DYLIB_IN_APP:
                    continue
                zout.writestr(info, zin.read(info.filename))
            # 主二进制：流式写入（避免第二份 630MB 副本）
            zi = zipfile.ZipInfo(EXE, date_time=(2026, 1, 1, 0, 0, 0))
            zi.external_attr = 0o755 << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            with zout.open(zi, "w") as dst:
                view = memoryview(macho.data)
                step = 8 << 20                     # 8MB 一块
                for off in range(0, len(view), step):
                    dst.write(view[off:off + step])
                del view
            # dylib
            zi2 = zipfile.ZipInfo(DYLIB_IN_APP, date_time=(2026, 1, 1, 0, 0, 0))
            zi2.compress_type = zipfile.ZIP_DEFLATED
            zi2.external_attr = 0o755 << 16
            with open(DYLIB, "rb") as f:
                zout.writestr(zi2, f.read())
        shutil.move(final, OUT_IPA)
        print(f"④ 输出: {OUT_IPA}  ({os.path.getsize(OUT_IPA):,} 字节)")

        # 5) 自校验（全部从已读入内存的 macho.data 判断，不再读回 630MB）
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
                with open(DYLIB, "rb") as f:
                    want = f.read()
                if got != want:
                    problems.append("dylib 内容不一致")
                else:
                    print(f"  dylib 已就位且内容一致 ✓ ({len(got):,} 字节)")
            missing = n_in - n_out
            if missing:
                problems.append(f"丢了 {len(missing)} 个原条目")
            else:
                print(f"  原有 {len(n_in)} 个条目全部保留 ✓（共 {len(n_out)} 个）")

            # 用直接扫描而不是 macho.dylibs —— 后者是构造时快照，注入后已过期
            names_now = dylib_install_names(macho.data)
            if name not in names_now:
                problems.append("主二进制里没有 LC_LOAD_DYLIB")
            else:
                print(f"  LC_LOAD_DYLIB 就位 ✓ 共 {len(names_now)} 条")
            if len(macho.data) != orig_exe_len:
                problems.append(f"主二进制长度异常: {len(macho.data):,}")
            else:
                print(f"  主二进制长度未变 ✓ ({orig_exe_len:,} 字节)")

            cs2 = find_code_signature_cmd(macho.data)
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
                if parse_superblob_has_entitlements(macho.data, do2, cs_datasize):
                    print("  尾部原始签名 blob 仍在原处，可读出原始 entitlements ✓")


        if problems:
            print("\n发现问题：")
            for p in problems:
                print("  ✗", p)
            return 1
        print("\n预注入版 IPA 组装完成 ✅")
        print("\n下一步（在手机上）：")
        print("  1. 全能签打开该 IPA → 用自己的证书签名安装")
        print("     （**不要**再启用插件注入 %s.dylib，否则加载两次）" % MODULE)
        print("  2. 打开 App → 播一个视频 → **停留 60 秒以上**（中途别切出去）")
        if MODULE == "BiliProbe":
            print("  3. 文件 App → 我的 iPhone → 哔哩哔哩 → biliprobe/ → 发 trace.log")
        else:
            print("  3. 文件 App → 我的 iPhone → 哔哩哔哩 → %s/ → 看 report.txt" % MODULE)
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
