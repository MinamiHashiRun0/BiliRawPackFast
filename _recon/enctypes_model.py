#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bsp_enctypes.c 的等价 Python 模型 + 夹具预检。

本机没有 C 编译器，CI 又要排队。先用 Python 把同一套解析逻辑和**同一份
夹具文件**跑一遍，确认 test_enctypes.c 里的期望值都对 —— 免得 CI 红了
分不清是代码错还是我算错。（上一轮的教训：调度器的理论值就是这么先核对过的。）
"""
import re
import sys
from pathlib import Path

QUAL = set("rnNoORV")


def skip_aggregate(s, i):
    open_c = s[i]
    close_c = {"{": "}", "(": ")", "[": "]"}[open_c]
    depth = 0
    while i < len(s):
        if s[i] == open_c:
            depth += 1
        elif s[i] == close_c:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def consume_type(s, i):
    while i < len(s) and s[i] in QUAL:
        i += 1
    if i >= len(s):
        return "?", i
    c = s[i]
    if c in "{[(":
        return c, skip_aggregate(s, i)
    if c == "^":
        while i < len(s) and s[i] == "^":
            i += 1
        if i < len(s) and s[i] in "{[(":
            i = skip_aggregate(s, i)
        elif i < len(s):
            i += 1
        return "^", i
    if c == "@":
        i += 1
        if i < len(s) and s[i] == "?":
            return "?", i + 1
        if i < len(s) and s[i] == '"':
            i += 1
            while i < len(s) and s[i] != '"':
                i += 1
            if i < len(s):
                i += 1
            return "@", i
        return "@", i
    if c == "b":
        i += 1
        while i < len(s) and s[i] in "01":
            i += 1
        return "b", i
    return c, i + 1


def shapes(enc, cap=64):
    i = 0
    idx = 0
    out = []
    while i < len(enc):
        before = i
        sh, i = consume_type(enc, i)
        while i < len(enc) and enc[i].isdigit():
            i += 1
        if i == before:
            break
        if idx >= 3:
            if len(out) + 1 >= cap:
                return None
            out.append(sh)
        idx += 1
    return "".join(out)


def arg_count(enc):
    i = 0
    idx = 0
    while i < len(enc):
        before = i
        _, i = consume_type(enc, i)
        while i < len(enc) and enc[i].isdigit():
            i += 1
        if i == before:
            break
        idx += 1
    return idx - 1 if idx > 0 else 0


def return_type(enc):
    return consume_type(enc, 0)[0]


FIX = Path("inject/probe/bsp_enctypes_fixtures.inc")
ROW = re.compile(r'\{"([^"]*)",\s*"([^"]*)",\s*"([^"]*)",\s*"([^"]*)"\}')


def main():
    bad = 0
    rows = ROW.findall(FIX.read_text(encoding="utf-8"))
    print("夹具 %d 条" % len(rows))
    for cls, sel, enc, want in rows:
        got = shapes(enc)
        if got != want:
            bad += 1
            print("  ✗ %s::%s  enc=%s  得到 %r 期望 %r" % (cls, sel, enc, got, want))
    print("夹具校验：%s" % ("全部通过" if bad == 0 else "%d 条不符" % bad))

    print("\n回归样本：")
    cases = [
        ("v24@0:8@16", "@"), ("v16@0:8", ""), ("B28@0:8@16B24", "@B"),
        ("@32@0:8@16@24", "@@"), ("@40@0:8@16@24@32", "@@@"),
        ("@48@0:8i16i20@24q32i40i44", "ii@qii"),
        ("@64@0:8q16q24q32q40@48@56", "qqqq@@"),
        ("v20@0:8B16", "B"), ("@32@0:8@16q24", "@q"),
        ("v100@0:8@16@24@32@40@48@56@64@72@80@88@96", "@" * 11),
        ("@16@0:8", ""),
        ("v24@0:8^{IjkMediaPlayer=}16", "^"),
        ("@32@0:8@16@?24", "@?"),
        ("v32@0:8@16^{DashDataSource=iiiiii[20{ijk=iii}]iii}24", "@^"),
        ("v48@0:8@16@24@32^v40", "@@@^"),
        ("@24@0:8r*16", "*"),
        ('@24@0:8@"NSString"16', "@"),
        ("v20@0:8n@16", "@"),
        ("v24@0:8O@16", "@"),
        ("v24@0:8#16", "#"),
        ("v24@0:8:16", ":"),
        ("{DashStreamInfo=ii[20i][20i]ii}16@0:8i16", "i"),
        ("", ""),
    ]
    for enc, want in cases:
        got = shapes(enc)
        flag = "✓" if got == want else "✗"
        if got != want:
            bad += 1
        print("  %s %-52s -> %-12r 期望 %r" % (flag, enc, got, want))

    print("\n返回值 / 参数个数（arg_count 含 self 与 _cmd）：")
    for enc, rt, ac in [("v24@0:8@16", "v", 3), ("@24@0:8@16", "@", 3),
                        ("B28@0:8@16B24", "B", 4), ("q16@0:8", "q", 2),
                        ("d16@0:8", "d", 2), ("v16@0:8", "v", 2),
                        ("@48@0:8i16i20@24q32i40i44", "@", 8),
                        ("{DashStreamInfo=ii[20i][20i]ii}16@0:8", "{", 2)]:
        r, a = return_type(enc), arg_count(enc)
        flag = "✓" if (r == rt and a == ac) else "✗"
        if not (r == rt and a == ac):
            bad += 1
        print("  %s %-44s ret=%s(%s) args=%d(%d)" % (flag, enc, r, rt, a, ac))

    print("\n健壮性（不得死循环）：")
    for enc in ["{{{{", "^^^^", "12345", "@@@@", "v99999999999999999999@0:8", "9999"]:
        print("  %-32s -> %r" % (enc, shapes(enc)))

    print("\n结论：%s" % ("全部通过 ✅" if bad == 0 else "★ %d 项不符" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
