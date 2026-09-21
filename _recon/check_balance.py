# -*- coding: utf-8 -*-
"""粗检 Objective-C 源文件的括号配平（先剥注释与字符串字面量）。

不是编译器，只用来在推 CI 之前抓明显的漏括号。
"""
import io
import sys


def strip(src):
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if c == '"':
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('S')
            continue
        if c == "'":
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == "'":
                    i += 1
                    break
                i += 1
            out.append('C')
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def main(paths):
    rc = 0
    for p in paths:
        s = strip(io.open(p, encoding='utf-8').read())
        row = []
        for a, b in (('{', '}'), ('(', ')'), ('[', ']')):
            na, nb = s.count(a), s.count(b)
            row.append('%s%s %d/%d %s' % (a, b, na, nb, 'OK' if na == nb else '**MISMATCH**'))
            if na != nb:
                rc = 1
        print('%-40s %s' % (p.split('\\')[-1].split('/')[-1], '   '.join(row)))
        # 花括号深度不能变负
        d = 0
        for ch in s:
            if ch == '{':
                d += 1
            elif ch == '}':
                d -= 1
                if d < 0:
                    print('   ** 花括号提前闭合 **')
                    rc = 1
                    break
        if d != 0:
            print('   ** 花括号未闭合，剩余深度 %d **' % d)
            rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
