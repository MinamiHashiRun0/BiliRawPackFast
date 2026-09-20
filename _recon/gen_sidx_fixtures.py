"""
生成 BSSidxIndex 的测试夹具（sidx 二进制 + 期望段表 JSON）。

坦白说明夹具来源：
  IPA 内没有真实 m4s（视频运行时下载），所以**没有**真实样本可用。
  本脚本按 ISO/IEC 14496-12 的 sidx 定义**自行构造**字节，
  并以独立的 Python 解析器（_recon 版）复核一遍。
  因此它能验证的只是「ObjC 解析器与规范/与独立实现一致」，
  **不能**替代真实字节验证 —— 这一点在输出与文档里都明确标注。

构造覆盖的边界：
  1. v0 + 全直接媒体段（最常见）
  2. v1 + 64 位 earliest/first_offset
  3. 含层级引用（reference_type=1）——必须被跳过而不是当段用
  4. 含 size==0 的空段 ——必须被跳过
  5. 截断（段表不完整）——解析器必须返回失败而不是给半成品
  6. timescale==0 ——必须失败
  7. 未知 version ——必须失败
  8. 无 sidx（只有 ftyp/moov）——必须失败
"""
import json, os, struct, sys

OUT = r"E:\Documents\DSHWork\BiliRawPackFast\_recon\sidx_fixtures"
os.makedirs(OUT, exist_ok=True)


def box(btype: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload) + 8) + btype + payload


def make_sidx(version, timescale, earliest, first_offset, refs, hdr_pad=b""):
    """refs: [(type, size, duration, sap)]"""
    flags = 0
    body = struct.pack(">I", 0x00000001)              # reference_ID
    body += struct.pack(">I", timescale)
    if version == 0:
        body += struct.pack(">II", earliest, first_offset)
    else:
        body += struct.pack(">QQ", earliest, first_offset)
    body += struct.pack(">HH", 0, len(refs))          # reserved + reference_count
    for (t, size, dur, sap) in refs:
        word = ((t & 1) << 31) | (size & 0x7FFFFFFF)
        body += struct.pack(">III", word, dur, sap)
    full = bytes([version]) + struct.pack(">I", flags)[1:] + body
    return box(b"sidx", full)


def python_parse_sidx(buf: bytes):
    """独立实现，用来复核夹具本身"""
    off = 0
    while off + 8 <= len(buf):
        size = struct.unpack_from(">I", buf, off)[0]
        btype = buf[off + 4:off + 8]
        hlen = 8
        if size == 1:
            size = struct.unpack_from(">Q", buf, off + 8)[0]; hlen = 16
        elif size == 0:
            size = len(buf) - off
        if size < hlen or off + size > len(buf):
            return None
        if btype == b"sidx":
            p = off + hlen
            version = buf[p]
            if version not in (0, 1):
                return None
            q = p + 4
            ts = struct.unpack_from(">I", buf, q + 4)[0]
            if ts == 0:
                return None
            if version == 0:
                earliest = struct.unpack_from(">I", buf, q + 8)[0]
                first_off = struct.unpack_from(">I", buf, q + 12)[0]
                r = q + 16
            else:
                earliest = struct.unpack_from(">Q", buf, q + 8)[0]
                first_off = struct.unpack_from(">Q", buf, q + 16)[0]
                r = q + 24
            ref_count = struct.unpack_from(">H", buf, r + 2)[0]
            r += 4
            if r + ref_count * 12 > off + size:
                return None
            entries, cur, t, total = [], first_off, 0, 0
            for i in range(ref_count):
                word, dur, sap = struct.unpack_from(">III", buf, r + i * 12)
                rtype, ssz = (word >> 31) & 1, word & 0x7FFFFFFF
                if rtype != 0 or ssz == 0:
                    continue
                entries.append({"offset": cur, "size": ssz,
                                "startTime": earliest + t, "duration": dur})
                cur += ssz; t += dur; total += ssz
            if not entries:
                return None
            return {"version": version, "timescale": ts, "earliest": earliest,
                    "boxOffset": off, "count": len(entries),
                    "coveredBytes": total, "entries": entries}
        off += size
    return None


CASES = []


def add_case(name, buf, expect_ok, note=""):
    parsed = python_parse_sidx(buf)
    if expect_ok:
        assert parsed is not None, f"{name}: 夹具自身解析失败"
        assert parsed["count"] > 0
    else:
        assert parsed is None, f"{name}: 夹具本应解析失败却成功了"
    path = os.path.join(OUT, name + ".bin")
    with open(path, "wb") as f:
        f.write(buf)
    CASES.append({"name": name, "file": name + ".bin", "bytes": len(buf),
                  "expect_ok": expect_ok, "note": note,
                  "expected": parsed})
    print(f"  {name:<28} {len(buf):>6} 字节  {'应成功' if expect_ok else '应失败'}  {note}")


print("构造夹具：")

# 1. v0 全直接段（10 段，段长递增）
refs = [(0, 1000 + i * 37, 16000 // 4, 0x90000000) for i in range(10)]
buf1 = box(b"ftyp", b"iso5" + struct.pack(">I", 512) + b"iso5dash") + \
       box(b"moov", b"\x00" * 64) + \
       make_sidx(0, 16000, 0, 1000, refs)
add_case("v0_all_direct", buf1, True, "10 个直接媒体段")

# 2. v1 + 64 位字段 + 大偏移
refs2 = [(0, 4096, 24000, 0) for _ in range(6)]
buf2 = box(b"ftyp", b"iso5" + struct.pack(">I", 512) + b"iso5dash") + \
       make_sidx(1, 48000, 1234567890123, 0x1_0000_0000, refs2)
add_case("v1_64bit_offsets", buf2, True, "64 位 earliest/first_offset")

# 3. 混合：层级引用 + 空段 + 直接段（层级与空段都必须跳过）
refs3 = [(1, 5000, 100, 0), (0, 2048, 200, 0), (0, 0, 0, 0),
         (1, 999, 100, 0), (0, 3072, 300, 0)]
buf3 = box(b"ftyp", b"iso5" + struct.pack(">I", 512) + b"iso5dash") + \
       make_sidx(0, 16000, 0, 800, refs3)
add_case("mixed_hier_and_empty", buf3, True, "2 直接 + 2 层级 + 1 空段 → 应只剩 2 段")

# 4. 只有层级引用 → 没有可用段 → 必须失败
refs4 = [(1, 5000, 100, 0), (1, 6000, 100, 0)]
buf4 = box(b"ftyp", b"iso5" + struct.pack(">I", 512) + b"iso5dash") + \
       make_sidx(0, 16000, 0, 900, refs4)
add_case("hier_only", buf4, False, "全是层级引用 → 无可用段")

# 5. 未知 version
buf5 = box(b"ftyp", b"iso5" + struct.pack(">I", 512) + b"iso5dash") + \
       make_sidx(2, 16000, 0, 1000, refs2)
add_case("unknown_version", buf5, False, "version=2 不应猜")

# 6. timescale == 0
buf6 = box(b"ftyp", b"iso5" + struct.pack(">I", 512) + b"iso5dash") + \
       make_sidx(0, 0, 0, 1000, refs2)
add_case("timescale_zero", buf6, False, "时基为 0")

# 7. 截断：声明 100 段但数据不足
#    注意：reference_count 的偏移必须从真实字节里定位，不能手算 ——
#    前两版分别漏了 box header(8B) 和 reserved(2B)，都是被断言抓出来的。
#    这里改成：解析出 sidx 的 hlen 与 version，按版本算出 count 字段位置，
#    并用断言确认读到的是已知值（3），确认后才改。
full = make_sidx(0, 16000, 0, 1000, [(0, 1024, 100, 0)] * 3)
buf7 = bytearray(
    box(b"ftyp", b"iso5" + struct.pack(">I", 512) + b"iso5dash") + full)

idx = buf7.find(b"sidx") - 4          # 指向 sidx box 的 size 字段
size = struct.unpack_from(">I", buf7, idx)[0]
hlen = 16 if size == 1 else 8
version = buf7[idx + hlen]
p = idx + hlen + 4                    # 跳过 version+flags
rc_off = p + 4 + 4 + (8 if version == 0 else 16) + 2   # refid + timescale + earliest/first + reserved
before = struct.unpack_from(">H", buf7, rc_off)[0]
assert before == 3, f"夹具推导失败：reference_count 偏移算错（读到 {before}）"
struct.pack_into(">H", buf7, rc_off, 100)
buf7 = bytes(buf7)
add_case("truncated_table", buf7, False, "声明 100 段但段表数据不足")

# 8. 没有 sidx
buf8 = box(b"ftyp", b"iso5" + struct.pack(">I", 512) + b"iso5dash") + box(b"moov", b"\x00" * 128)
add_case("no_sidx", buf8, False, "只有 ftyp+moov")

# 9. 零段
buf9 = box(b"ftyp", b"iso5" + struct.pack(">I", 512) + b"iso5dash") + \
       make_sidx(0, 16000, 0, 1000, [])
add_case("zero_refs", buf9, False, "reference_count=0")

with open(os.path.join(OUT, "cases.json"), "w", encoding="utf-8") as f:
    json.dump({"source": "构造（非真实 m4s）",
               "disclaimer": "IPA 内无真实媒体，夹具按 ISO 14496-12 自行构造，"
                             "并经独立 Python 解析器复核；不能替代真实字节验证",
               "cases": CASES}, f, ensure_ascii=False, indent=2)

print()
print(f"共 {len(CASES)} 个夹具 → {OUT}")
print(f"  {sum(1 for c in CASES if c['expect_ok'])} 个应解析成功，"
      f"{sum(1 for c in CASES if not c['expect_ok'])} 个应失败")
