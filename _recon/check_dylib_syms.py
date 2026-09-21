#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CI 闸门：dylib 不得在链接期引用 _objc_msgForward。

为什么值得单独设一道闸：
  `extern void _objc_msgForward(void);` 会产生一个**链接期未定义符号**。
  万一某个 iOS 版本不再导出它，dyld 会在加载 dylib 的瞬间直接杀掉进程 ——
  症状是「App 打不开」，而且连构造函数第一行（建日志目录）都跑不到，
  真机上什么都留不下，几乎无法定位。
  正确做法是用 dlsym 在运行时取（bsp_msg_forward()），取不到就拒绝安装 hook，
  dylib 本身照样能加载。这个脚本就是防止有人以后又把它改回 extern 声明。
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from dylib_syms import parse  # noqa: E402

BANNED = {
    "objc_msgForward": "转发入口应改用 dlsym 运行时获取（见 BSPDynamicHook 的 bsp_msg_forward）",
    "objc_msgForward_stret": "同上",
}


def norm(name):
    """Mach-O 符号表里的 C 符号带一个下划线前缀：C 的 _objc_msgForward
    在表里写作 __objc_msgForward。比较前统一去掉，否则闸门会静默失效
    （第一版就踩了这个：字符串写的是 _objc_msgForward，永远匹配不上）。"""
    return name.lstrip("_")

# 只允许来自系统库/框架的未定义符号
ALLOWED_PREFIXES = (
    "_OBJC_CLASS_$_", "_OBJC_METACLASS_$_", "_OBJC_EHTYPE_$_", "_OBJC_IVAR_$_",
    "_$s", "_$S",
)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else r"_artifact\BiliProbe-dylib\BiliProbe.dylib"
    if not Path(path).exists():
        print("找不到 %s" % path)
        return 1

    libs, undef, _ = parse(path)
    names = [n for n, _ in undef]

    print("dylib: %s" % path)
    print("依赖库 %d 个，未定义符号 %d 个" % (len(libs), len(names)))

    bad = 0
    for n in names:
        if norm(n) in BANNED:
            print("  ✗ 链接期引用了 %s（表内名 %s）—— %s" % (norm(n), n, BANNED[norm(n)]))
            bad += 1

    # 依赖必须全是系统库
    for l in libs:
        if not (l.startswith("/usr/lib/") or l.startswith("/System/")):
            print("  ✗ 非系统依赖：%s" % l)
            bad += 1

    if bad == 0:
        print("  ✓ 没有链接期私有符号，依赖全为系统库")
        print("结论：通过 ✅")
        return 0
    print("结论：★ %d 项不合格" % bad)
    return 1


if __name__ == "__main__":
    sys.exit(main())
