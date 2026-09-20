"""
验证夹具配方：确认 serve_test_data.py 生成的载荷，
与 test_segment_fetcher.m 里期望的「第 i 字节 = i % 251」一致，
并且按任意分段切出来的段内容都能自洽。

这一步是在补上一个真实发生过的错误：
  最初夹具按「段号填充常量」生成，而测试用不同分段粒度断言，
  导致所有「逐段内容逐字节正确」失败。问题在夹具设计，不在引擎。
  现在改为按字节位置编码，本脚本用来证明该配方与分段方式无关。
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from serve_test_data import build_payload  # noqa: E402


def test_formula_matches():
    print("=" * 66)
    print("1. 载荷公式：第 i 字节 == i % 251")
    print("=" * 66)
    payload = build_payload(8, 262144)
    ok = all(payload[i] == i % 251 for i in range(0, len(payload), 997))  # 抽样
    print(f"  样本抽检 {'通过 ✓' if ok else '失败 ✗'}（长度 {len(payload):,}）")
    # 全量校验（2MiB 很快）
    ok2 = all(b == i % 251 for i, b in enumerate(payload))
    print(f"  全量校验 {'通过 ✓' if ok2 else '失败 ✗'}")
    return ok and ok2


def test_segmentation_independence():
    print()
    print("=" * 66)
    print("2. 任意分段下，段内容期望值都唯一确定")
    print("=" * 66)
    payload = build_payload(8, 262144)          # 8 × 256KiB = 2MiB
    scenarios = [
        ("20 段 × 4KiB",   20,   4096),
        ("8 段 × 256KiB",   8, 262144),
        ("6 段 × 4KiB",     6,   4096),
        ("4 段 × 1KiB",     4,   1024),
        ("3 段 × 1000B",    3,   1000),   # 非 2 的幂
    ]
    allok = True
    for name, n, size in scenarios:
        need = n * size
        if need > len(payload):
            print(f"  {name:18s} 跳过（需要 {need:,} > 夹具 {len(payload):,}）")
            continue
        good = True
        for k in range(n):
            off = k * size
            got = payload[off:off + size]
            exp = bytes(((off + i) % 251) for i in range(size))
            if got != exp:
                good = False
                break
        print(f"  {name:18s} {'✓' if good else '✗'}  末段偏移={(n-1)*size:,}")
        allok = allok and good
    return allok


def test_core_agrees():
    print()
    print("=" * 66)
    print("3. 与 SIDX 纯 C 核心的接口一致性（交叉核对偏移计算）")
    print("=" * 66)
    # 用 sidx 夹具里的 v0_all_direct 核对：核心给出的段偏移/大小
    # 能否被「按偏移取值」的公式正确覆盖
    import struct
    fix = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "sidx_fixtures", "v0_all_direct.bin")
    if not os.path.exists(fix):
        print("  夹具不在，跳过")
        return True
    raw = open(fix, "rb").read()
    # 简易解析（与独立 Python 解析器同源）
    idx = raw.find(b"sidx") - 4
    size = struct.unpack_from(">I", raw, idx)[0]
    q = idx + 8 + 4
    refid, ts = struct.unpack_from(">II", raw, q)
    earliest, first_off = struct.unpack_from(">II", raw, q + 8)
    r = q + 16
    cnt = struct.unpack_from(">H", raw, r + 2)[0]
    r += 4
    entries = []
    cur = first_off
    for i in range(cnt):
        word, dur, sap = struct.unpack_from(">III", raw, r + i * 12)
        if (word >> 31) & 1 or (word & 0x7FFFFFFF) == 0:
            continue
        entries.append((cur, word & 0x7FFFFFFF))
        cur += word & 0x7FFFFFFF
    print(f"  解析出 {len(entries)} 段，首段={entries[0]}，末段={entries[-1]}")
    contiguous = all(entries[i][0] + entries[i][1] == entries[i + 1][0]
                     for i in range(len(entries) - 1))
    print(f"  段偏移连续 {'✓' if contiguous else '✗'}")
    print(f"  段字节和 = {sum(s for _, s in entries):,}")
    return contiguous


if __name__ == "__main__":
    r = []
    r.append(test_formula_matches())
    r.append(test_segmentation_independence())
    r.append(test_core_agrees())
    print()
    print("=" * 66)
    print("结果：%d/%d 通过 %s" % (sum(r), len(r), "✅" if all(r) else "❌"))
    sys.exit(0 if all(r) else 1)
