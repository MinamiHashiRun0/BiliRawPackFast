import io, re

f = r"E:\Documents\DSHWork\BiliRawPackFast\inject\probe\BiliProbe.m"
t = open(f, encoding="utf-8").read()

# 1) verdict 里声明 dlWithUrl
t = t.replace(
    "    int32_t protoStarts = ProbeRead(&gCntProtocolStart);",
    "    int32_t protoStarts = ProbeRead(&gCntProtocolStart);\n"
    "    int32_t dlWithUrl   = ProbeRead(&gCntDlWithUrl);")

# 2) verdict 计数行加字段
t = t.replace('| 预加载=%d | URLProtocol=%d/%d",',
              '| 预加载=%d | URLProtocol=%d/%d | ★落盘=%d",')
t = t.replace("preloads, protos, protoStarts);",
              "preloads, protos, protoStarts, dlWithUrl);")

# 3) verdict 新增最高优先级分支
branch = (
    '    if (dlWithUrl > 0) {\n'
    '        PLog(@"verdict", @"★★★ 找到了！downloadWithUrl 命中 %d 次 —— "\n'
    '                         @"这是「CDN URL + 落盘路径」的合流点，阶段 2/3 落点就是它"\n'
    '                         @"（真实 host 见 [path] 行）", dlWithUrl);\n'
    '    } else if (protoStarts > 0 || protos > 0) {'
)
t = t.replace("    if (protoStarts > 0 || protos > 0) {", branch)

# 4) 心跳加计数
t = t.replace('| URLProtocol=%d/%d",', '| URLProtocol=%d/%d | 落盘=%d",')
t = t.replace("ProbeRead(&gCntProtocolCanInit), ProbeRead(&gCntProtocolStart));",
              "ProbeRead(&gCntProtocolCanInit), ProbeRead(&gCntProtocolStart),\n"
              "                     ProbeRead(&gCntDlWithUrl));")

open(f, "w", encoding="utf-8", newline="\n").write(t)
print("替换完成")

# 自检
for k in ['int32_t dlWithUrl', '★落盘=%d', 'preloads, protos, protoStarts, dlWithUrl',
          '★★★ 找到了！downloadWithUrl', 'ProbeRead(&gCntDlWithUrl));']:
    print(f"  {'OK ' if k in t else 'MISS'} {k}")
