#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把设备端 classes.txt 解析成可查询的索引。

classes.txt 格式（探针输出）：
    ## ClassName
        - selector    <typeEncoding>
        + selector    <typeEncoding>
        [+类方法]
"""
import re
import sys
from pathlib import Path

HEAD_RE = re.compile(r"^##\s+(\S+)\s*$")
METH_RE = re.compile(r"^\s{4}([-+])\s+(\S+?)\s{2,}(\S+)\s*$")


def parse(path):
    classes = {}
    cur = None
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = HEAD_RE.match(line)
        if m:
            cur = m.group(1)
            classes.setdefault(cur, {"instance": {}, "class": {}})
            continue
        if cur is None:
            continue
        m = METH_RE.match(line)
        if m:
            kind, sel, enc = m.groups()
            bucket = classes[cur]["instance" if kind == "-" else "class"]
            bucket[sel] = enc
    return classes


def main():
    p = sys.argv[1] if len(sys.argv) > 1 else r"E:\Documents\DSHWork\BiliRawPackFast\_logs\run8\biliprobe\classes.txt"
    classes = parse(p)
    print(f"# 解析到 {len(classes)} 个类")

    if len(sys.argv) > 2:
        pat = re.compile(sys.argv[2], re.I)
        hit = [c for c in classes if pat.search(c)]
        key = sys.argv[3] if len(sys.argv) > 3 else None
        kpat = re.compile(key, re.I) if key else None
        print(f"# 类名命中 {len(hit)} 个")
        for c in sorted(hit):
            print(f"\n## {c}")
            for kind in ("instance", "class"):
                for sel, enc in sorted(classes[c][kind].items()):
                    if kpat and not kpat.search(sel):
                        continue
                    sig = "+" if kind == "class" else "-"
                    print(f"    {sig} {sel}    {enc}")


if __name__ == "__main__":
    main()
