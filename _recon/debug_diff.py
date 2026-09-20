"""定位注入演练里那一处意外差异（偏移 16120）。"""
import os, struct, zipfile

ROOT = r"E:\Documents\DSHWork\BiliRawPackFast"
IPA = os.path.join(ROOT, "哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa")
EXE = "Payload/bili-universal.app/bili-universal"

with zipfile.ZipFile(IPA) as z:
    a = z.read(EXE)

ncmds, sizeofcmds = struct.unpack_from("<II", a, 16)
lc_end = 32 + sizeofcmds
print(f"ncmds={ncmds} sizeofcmds={sizeofcmds} lc_end={lc_end}")

# 列出所有 load command 的偏移区间，看 16120 落在哪条里
print("\n--- 各 load command 区间（末尾 6 条）---")
off = 32
cmds = []
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", a, off)
    cmds.append((off, off + cmdsize, cmd, cmdsize))
    off += cmdsize
for (s, e, cmd, sz) in cmds[-6:]:
    print(f"  [{s:6d}, {e:6d})  cmd={hex(cmd):8s} size={sz}")

print(f"\n16120 落在哪条里：", end="")
for (s, e, cmd, sz) in cmds:
    if s <= 16120 < e:
        print(f"[{s},{e}) cmd={hex(cmd)} size={sz}")
        # 如果是 LC_LOAD_DYLIB，看它的字段
        if cmd == 0x0C:
            nameoff, ts, cur, comp = struct.unpack_from("<IIII", a, s + 8)
            nm = a[s + nameoff:s + sz].split(b"\x00")[0].decode("utf-8", "replace")
            print(f"    nameoff={nameoff} timestamp={ts} current={cur} compat={comp}")
            print(f"    name={nm}")
            print(f"    字段布局: cmd@{s} cmdsize@{s+4} nameoff@{s+8}(+12) timestamp@{s+12}(+16)")
        break
else:
    print("不在任何命令内（属命令区与首个 section 之间的填充）")

print("\n--- 16104..16136 的原始字节（原始 IPA）---")
print(" ".join(f"{b:02x}" for b in a[16104:16136]))
print("--- 按 ASCII ---")
print(repr(a[16104:16136]))

# 再看这些字节在重打包后是否变化（读回注入产物）
out = None
import tempfile, subprocess, sys
tmp = tempfile.mkdtemp(prefix="bilidbg_")
try:
    outp = os.path.join(tmp, "o.ipa")
    r = subprocess.run([sys.executable, os.path.join(ROOT, "inject", "inject_dylib.py"),
                        "--ipa", IPA, "--out", outp],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    with zipfile.ZipFile(outp) as z:
        b = z.read(EXE)
    print("\n--- 16104..16136 的字节（注入后）---")
    print(" ".join(f"{x:02x}" for x in b[16104:16136]))
    diffs = [i for i in range(16090, 16130) if a[i] != b[i]]
    print("\n该窗口内差异偏移:", diffs)
    for i in diffs:
        print(f"  偏移 {i}: {a[i]:02x} -> {b[i]:02x}")
finally:
    import shutil; shutil.rmtree(tmp, ignore_errors=True)
