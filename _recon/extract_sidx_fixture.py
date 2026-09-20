"""
从官方 IPA 里挖出真实的 SIDX 结构，作为 Objective-C 解析器的测试夹具。

为什么要做这件事：
  BSSidxIndex.m 是从 Dart 版移植过来的，**从未用真实字节跑过**。
  上一会话记录的 sidx 位置（video sidx@936 size=4564, 377 段）来自
  **另一个视频**，不能当作本 IPA 的证据 —— 直接拿来当断言就是编数据。

  正确做法：先在 IPA 内真实存在的媒体文件里定位 sidx box，解析出段表，
  再把「字节偏移 + 期望段数/段大小/时长」一起导出为夹具。
  这样夹具本身来自真实数据，ObjC 解析器将来可以用它对拍。

  注意：若 IPA 内媒体文件是加密/非 m4s 结构，则如实报告"未找到"，
  不伪造夹具。
"""
import os, struct, zipfile, json, io

ROOT = r"E:\Documents\DSHWork\BiliRawPackFast"
IPA = os.path.join(ROOT, "哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa")
OUT = os.path.join(ROOT, "_recon")
os.makedirs(OUT, exist_ok=True)

MEDIA_EXT = (".m4s", ".mp4", ".m4a", ".m4v", ".mpd", ".ts")


def find_boxes(buf, start, end, want, depth=0, maxdepth=4):
    """在 [start,end) 内递归找 want 类型的 box，返回 [(offset,size,header_len)]"""
    hits = []
    off = start
    while off + 8 <= end:
        size = struct.unpack_from(">I", buf, off)[0]
        btype = buf[off + 4:off + 8]
        hlen = 8
        if size == 1:
            if off + 16 > end:
                break
            size = struct.unpack_from(">Q", buf, off + 8)[0]
            hlen = 16
        elif size == 0:
            size = end - off
        if size < hlen or off + size > end:
            break
        if btype == want:
            hits.append((off, size, hlen))
        elif btype in (b"moov", b"trak", b"mdia", b"minf", b"stbl", b"moof", b"traf") and depth < maxdepth:
            hits.extend(find_boxes(buf, off + hlen, off + size, want, depth + 1, maxdepth))
        off += size
    return hits


def parse_sidx(buf, off, size, hlen):
    """按 ISO BMFF 解析 sidx，返回 (version, timescale, earliest, first_offset, refs)"""
    p = off + hlen
    version = buf[p]
    q = p + 4                      # 跳过 version + flags
    timescale = struct.unpack_from(">I", buf, q + 4)[0]
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
    refs = []
    for i in range(ref_count):
        e = r + i * 12
        if e + 12 > off + size:
            break
        word, dur, sap = struct.unpack_from(">III", buf, e)
        refs.append({"type": (word >> 31) & 1, "size": word & 0x7FFFFFFF,
                     "duration": dur, "sap": sap})
    return version, timescale, earliest, first_off, refs


def main():
    if not os.path.exists(IPA):
        print("找不到 IPA"); return 1

    found = []
    with zipfile.ZipFile(IPA) as z:
        media = [n for n in z.namelist() if n.lower().endswith(MEDIA_EXT)]
        print(f"IPA 内候选媒体文件 {len(media)} 个")
        for n in media[:40]:
            print("   ", n, z.getinfo(n).file_size)

        if not media:
            print("\nIPA 内没有 .m4s/.mp4 之类的媒体文件 —— 视频是运行时下载的，")
            print("因此无法从 IPA 直接取得真实 SIDX。这是如实结论，不构造假夹具。")
            # 退一步：扫所有文件的前 64KB 找 sidx，可能有打包进去的示例媒体
            print("\n退一步：扫描所有条目开头 64KiB，找是否嵌有 sidx box …")
            for n in z.namelist():
                info = z.getinfo(n)
                if info.file_size < 256 or info.file_size > 200 * 1024 * 1024:
                    continue
                if not n.lower().endswith((".dat", ".bin", ".json", ".bundle", ".cache")):
                    continue
                try:
                    with z.open(n) as f:
                        head = f.read(65536)
                except Exception:
                    continue
                if b"sidx" in head:
                    print(f"   命中: {n} ({info.file_size:,} 字节)")
            return 0

        for n in media[:40]:
            try:
                with z.open(n) as f:
                    data = f.read()
            except Exception as e:
                print(f"  读取 {n} 失败: {e}")
                continue
            hits = find_boxes(data, 0, len(data), b"sidx")
            if not hits:
                continue
            for (off, size, hlen) in hits[:3]:
                version, ts, earliest, first_off, refs = parse_sidx(data, off, size, hlen)
                direct = [r for r in refs if r["type"] == 0]
                total = sum(r["size"] for r in direct)
                found.append({
                    "file": n, "file_size": len(data),
                    "sidx_offset": off, "sidx_size": size, "version": version,
                    "timescale": ts, "earliest": earliest, "first_offset": first_off,
                    "ref_count": len(refs), "direct_count": len(direct),
                    "sum_direct_bytes": total,
                    "first_refs": direct[:5],
                    "last_ref": direct[-1] if direct else None,
                })
                print(f"\n  {n}: sidx@{off} size={size} v{version} timescale={ts}")
                print(f"    引用数={len(refs)} 直接媒体段={len(direct)} 段字节合计={total:,}")
                print(f"    首段偏移={first_off} 前 5 段={[(r['size'], r['duration']) for r in direct[:5]]}")
                if direct:
                    print(f"    末段={direct[-1]}")

    with open(os.path.join(OUT, "sidx_fixtures.json"), "w", encoding="utf-8") as f:
        json.dump(found, f, ensure_ascii=False, indent=2)

    print()
    if found:
        print(f"导出 {len(found)} 组真实 SIDX 夹具 → _recon/sidx_fixtures.json")
        print("这些夹具可用于将来对拍 BSSidxIndex.m（在 macOS 上跑）")
    else:
        print("未在 IPA 内找到含 SIDX 的真实媒体文件（视频为运行时下载）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
