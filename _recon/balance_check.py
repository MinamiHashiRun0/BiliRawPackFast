#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""粗粒度括号配平检查（跳过字符串/注释）。用于在没有 C 编译器的机器上
先挡掉最低级的语法错误，真正编译仍走 CI。"""
import sys
from pathlib import Path

BS = chr(92)


def scan(path):
    s = Path(path).read_text(encoding="utf-8")
    i, n = 0, len(s)
    line = 1
    instr = False
    inchr = False
    comment = None
    stack = []
    bad = []
    pairs = {"{": "}", "(": ")", "[": "]"}
    closers = {v: k for k, v in pairs.items()}
    while i < n:
        c = s[i]
        if c == "\n":
            line += 1
        if comment == "line":
            if c == "\n":
                comment = None
            i += 1
            continue
        if comment == "block":
            if s.startswith("*/", i):
                comment = None
                i += 2
                continue
            i += 1
            continue
        if instr:
            if c == BS:
                i += 2
                continue
            if c == '"':
                instr = False
            i += 1
            continue
        if inchr:
            # 字符字面量：case '{': case '}': ... 里面的括号不能被当代码
            if c == BS:
                i += 2
                continue
            if c == "'":
                inchr = False
            i += 1
            continue
        if s.startswith("//", i):
            comment = "line"
            i += 2
            continue
        if s.startswith("/*", i):
            comment = "block"
            i += 2
            continue
        if c == '"':
            instr = True
            i += 1
            continue
        if c == "'":
            inchr = True
            i += 1
            continue
        if c in pairs:
            stack.append((c, line))
        elif c in closers:
            if not stack or stack[-1][0] != closers[c]:
                bad.append((line, c, stack[-1] if stack else None))
            else:
                stack.pop()
        i += 1
    return stack, bad, (instr or inchr)


def main():
    rc = 0
    for f in sys.argv[1:]:
        stack, bad, instr = scan(f)
        ok = not stack and not bad and not instr
        print("%-42s %s  unclosed=%d mismatched=%d unterminated_string=%s"
              % (f, "OK" if ok else "BAD", len(stack), len(bad), instr))
        for item in stack[:5]:
            print("     未闭合 %r 起于第 %d 行" % item)
        for item in bad[:5]:
            print("     多余/错配 %s 在第 %s 行（栈顶 %s）" % (item[0], item[1], item[2]))
        if not ok:
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
