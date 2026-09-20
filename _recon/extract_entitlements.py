"""
从脱壳 IPA 的主二进制里抽取原始 entitlements。

背景：脱壳包不含 embedded.mobileprovision，所以拿不到 provisioning 里的授权。
      但 Mach-O 的 LC_CODE_SIGNATURE 指向一个 SuperBlob，里面通常含有
      原始签名的 entitlements plist。若能抽出来，重签时就能沿用 B站原本申请的
      权限（keychain 组、associated domains 等），而不是退化成最小集合。

顺带回答一个 workflow 里的悬空问题：
  CI 里那句 `codesign -d --entitlements :-` 到底能不能拿到东西？
  在这里先把答案找出来，省得在 macOS 上反复试。

本脚本只读 IPA，不修改任何文件。
"""
import os, struct, json, zipfile, plistlib

ROOT = r"E:\Documents\DSHWork\BiliRawPackFast"
IPA = os.path.join(ROOT, "哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa")
EXE = "Payload/bili-universal.app/bili-universal"
OUT = os.path.join(ROOT, "_recon")

LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64 = 0xFEEDFACF

# SuperBlob 里的 magic（大端）
CSSLOT_CODEDIRECTORY = 0
CSSLOT_REQUIREMENTS = 2
CSSLOT_ENTITLEMENTS = 5
CSSLOT_DER_ENTITLEMENTS = 7
CSSLOT_SIGNATURESLOT = 0x10000


def parse_superblob(blob: bytes):
    """返回 {slot: 子 blob 字节}"""
    if len(blob) < 12:
        return {}
    magic, length, count = struct.unpack_from(">III", blob, 0)
    if magic != 0xFADE0CC0:      # CSMAGIC_EMBEDDED_SIGNATURE
        return {"_magic": magic, "_note": "不是嵌入式签名 SuperBlob"}
    out = {}
    for i in range(count):
        off = 12 + i * 8
        if off + 8 > len(blob):
            break
        slot, offset = struct.unpack_from(">II", blob, off)
        if offset + 8 > len(blob):
            continue
        bmagic, blen = struct.unpack_from(">II", blob, offset)
        if offset + blen > len(blob) or blen < 8:
            continue
        out[slot] = blob[offset:offset + blen]
    return out


def main():
    if not os.path.exists(IPA):
        print("找不到 IPA"); return 1

    with zipfile.ZipFile(IPA) as z:
        raw = z.read(EXE)

    if struct.unpack_from("<I", raw, 0)[0] != MH_MAGIC_64:
        print("不是小端 64 位 Mach-O"); return 1

    ncmds, sizeofcmds = struct.unpack_from("<II", raw, 16)
    off = 32
    sig = None
    total_sig = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", raw, off)
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<II", raw, off + 8)
            sig = (dataoff, datasize)
        off += cmdsize
    total_sig = sum(1 for _ in [0])

    print(f"主二进制 {len(raw):,} 字节")
    if not sig:
        print("没有 LC_CODE_SIGNATURE —— 该 dump 可能已剥离签名")
        return 0
    dataoff, datasize = sig
    print(f"LC_CODE_SIGNATURE: offset={dataoff:,} size={datasize:,}")

    if dataoff + datasize > len(raw):
        print("签名 blob 越界（文件被截断？）")
        return 1

    blob = raw[dataoff:dataoff + datasize]
    slots = parse_superblob(blob)
    print(f"\nSuperBlob 内槽位: {sorted(k for k in slots if isinstance(k, int))}")
    if "_note" in slots:
        print("  注意:", slots["_note"], hex(slots["_magic"]))

    result = {"ipa": os.path.basename(IPA), "exe_size": len(raw),
              "code_signature": {"offset": dataoff, "size": datasize},
              "slots_present": sorted(k for k in slots if isinstance(k, int))}

    # --- entitlements ---
    ent = None
    if CSSLOT_ENTITLEMENTS in slots:
        sb = slots[CSSLOT_ENTITLEMENTS]
        bmagic, blen = struct.unpack_from(">II", sb, 0)
        payload = sb[8:blen]
        try:
            ent = plistlib.loads(payload)
            print("\n✅ 抽出 entitlements（XML plist）:")
            for k, v in sorted(ent.items()):
                sv = str(v)
                print(f"    {k} = {sv[:110]}")
            result["entitlements"] = {k: str(v) for k, v in ent.items()}
        except Exception as e:
            print(f"\n⚠️ entitlements 槽存在但解析失败: {e}")
            result["entitlements_error"] = str(e)
            with open(os.path.join(OUT, "entitlements.raw"), "wb") as f:
                f.write(payload)
            print("   原始内容已存 _recon/entitlements.raw 供人工检查")
    else:
        print("\n❌ 没有 entitlements 槽（CSSLOT_ENTITLEMENTS）")
        print("   → 结论：这个脱壳包**无法**还原原始 entitlements，")
        print("     重签只能用最小集合。CI 里的 codesign -d --entitlements 也拿不到东西，")
        print("     应当走兜底分支。")

    if CSSLOT_DER_ENTITLEMENTS in slots:
        print("  （存在 DER 编码的 entitlements 槽，槽位 7）")

    # --- CodeDirectory 里的信息 ---
    if CSSLOT_CODEDIRECTORY in slots:
        sb = slots[CSSLOT_CODEDIRECTORY]
        magic, length, version, flags, hashOffset, identOffset = struct.unpack_from(">IIIIII", sb, 0)
        ident = sb[identOffset:sb.index(b"\x00", identOffset)].decode("utf-8", "replace")
        print(f"\nCodeDirectory: version={version} flags={hex(flags)} identifier={ident}")
        result["code_directory"] = {"version": version, "flags": hex(flags), "identifier": ident}

    with open(os.path.join(OUT, "entitlements_probe.json"), "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print("\n结果已写 _recon/entitlements_probe.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
