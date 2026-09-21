#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 BiliProbe 的 trace.log 摘成一份可读报告。

为什么写这个：日志动辄上千行、里面塞满了带签名的完整 URL，靠肉眼和 grep
翻很容易漏掉关键信号（比如「改写触发了但代理侧只收到 3 个请求」这种
一句话就能定性的事实）。
"""
import re
import sys
import collections
from pathlib import Path

LINE = re.compile(r"^(\d\d:\d\d:\d\d\.\d+)\s+\[([a-z0-9_]+)\]\s?(.*)$")
REWRITE = re.compile(r"★ \[(.+?)\]\s+(\S+)\s+(参数改写|返回值改写)\s+host=(\S+)")
HOOKHIT = re.compile(r"^\s{6}(\S+)\s+(\d+) 次$")


def main():
    path = sys.argv[1]
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()

    tags = collections.Counter()
    rewrites = collections.Counter()
    rewrites_by_host = collections.Counter()
    hook_hits = {}
    verdicts = []
    beats = []
    install = []
    player_state = []
    session_lines = []
    errors = []

    cur_hook_block = False
    for ln in lines:
        m = LINE.match(ln)
        if not m:
            # 续行：hook 命中表的条目
            if cur_hook_block:
                hm = HOOKHIT.match(ln)
                if hm:
                    hook_hits[hm.group(1)] = int(hm.group(2))
                    continue
                if ln.strip() == "":
                    continue
            continue
        ts, tag, body = m.groups()
        tags[tag] += 1
        cur_hook_block = False

        if tag == "rewrite":
            rm = REWRITE.search(body)
            if rm:
                rewrites[(rm.group(1), rm.group(2), rm.group(3))] += 1
                rewrites_by_host[rm.group(4)] += 1
        elif tag == "verdict":
            cur_hook_block = "各 hook 命中次数" in body
            if "各 hook" not in body:
                verdicts.append((ts, body))
        elif tag == "beat":
            beats.append((ts, body))
        elif tag == "hook":
            if "install]" in body or "机制自检" in body or "分组开关" in body or "hook 安装完成" in body:
                install.append((ts, body))
        elif tag == "session":
            session_lines.append((ts, body))
        elif tag in ("boot", "env", "io"):
            if "错误" in body or "失败" in body or "SHA" in body:
                errors.append((ts, tag, body))
        if tag == "beat" or tag == "verdict":
            if "在播=" in body:
                player_state.append((ts, body))

    print("=" * 72)
    print("行数 %d   tag 分布: %s" % (len(lines), dict(tags.most_common())))
    print("=" * 72)

    print("\n【构建 / 自检 / 安装】")
    for ts, b in install:
        print("  %s  %s" % (ts, b))

    print("\n【改写落点分布（按 标签/方法/动作 聚合）】")
    for (label, sel, act), n in rewrites.most_common():
        print("  %-14s %-46s %-8s %d 次" % (label, sel, act, n))
    print("\n【改写涉及的原 host】")
    for h, n in rewrites_by_host.most_common():
        print("  %-46s %d 次" % (h, n))

    print("\n【各 hook 命中次数】")
    if hook_hits:
        for k, v in sorted(hook_hits.items(), key=lambda x: -x[1]):
            print("  %-70s %d" % (k, v))
    else:
        print("  （未找到命中表）")

    print("\n【最后一次结论段】")
    tail = verdicts[-14:]
    for ts, b in tail:
        print("  %s  %s" % (ts, b))

    print("\n【心跳里的播放正证据（最后 6 条）】")
    for ts, b in player_state[-6:]:
        print("  %s  %s" % (ts, b))

    print("\n【[session] 媒体请求】")
    for ts, b in session_lines:
        print("  %s  %s" % (ts, b))

    print("\n【boot/env/io 里的异常】")
    for ts, tag, b in errors:
        print("  %s [%s] %s" % (ts, tag, b))


if __name__ == "__main__":
    main()
