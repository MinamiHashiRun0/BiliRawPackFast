# -*- coding: utf-8 -*-
"""把 BSPProxyServer.m 里的 -runBenchmark 整段换成 _recon/bench_new.m。

用花括号配对找函数结尾，不依赖行号（前面已经改过好几处，行号会漂）。
"""
import io
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'inject', 'probe', 'BSPProxyServer.m')
NEW = os.path.join(ROOT, '_recon', 'bench_new.m')

ANCHOR = '- (void)runBenchmark\n'

src = io.open(SRC, encoding='utf-8').read()
new = io.open(NEW, encoding='utf-8').read()

start = src.index(ANCHOR)
brace = src.index('{', start)
depth = 0
i = brace
while i < len(src):
    c = src[i]
    if c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            break
    i += 1

end = i + 1
old_len = end - start
out = src[:start] + new.rstrip('\n') + src[end:]
io.open(SRC, 'w', encoding='utf-8', newline='\n').write(out)

print('replaced %d bytes with %d bytes' % (old_len, len(new.rstrip('\n'))))
print('file: %d -> %d bytes' % (len(src), len(out)))
