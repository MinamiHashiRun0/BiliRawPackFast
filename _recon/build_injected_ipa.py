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
        print("  3. 打开 App → 播一个视频 → 等 10 秒")
        print("  4. 文件 App → 我的 iPhone → 哔哩哔哩 → biliprobe/")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
