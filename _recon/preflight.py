"""
构建前本地闸门：把能在 Windows 上验证的东西全部验证掉，避免浪费 macOS CI 额度。
检查项：
  1. workflow YAML 可解析、无 secrets-in-if、heredoc 闭合、artifact 不静默失败
  2. Makefile：不能有 // 注释；recipe 行必须是 TAB 缩进；关键变量齐全
  3. 所有将进 CI 的文本文件：LF 行尾（CRLF 会让 bash 脚本在 macOS 上报
     `bad interpreter: /bin/bash^M`）
  4. Python 文件语法可编译
"""
import os, re, subprocess, sys, py_compile

ROOT = r"E:\Documents\DSHWork\BiliRawPackFast"
problems = []


def check_workflow():
    import yaml
    p = os.path.join(ROOT, ".github", "workflows", "build-probe.yml")
    d = yaml.safe_load(open(p, encoding="utf-8").read())
    if d.get("name") != "Build BiliProbe":
        problems.append("workflow name 不是 Build BiliProbe（可能解析成了文件路径）")
    on = d.get(True, d.get("on"))
    if not isinstance(on, dict) or "workflow_dispatch" not in on:
        problems.append("workflow_dispatch 未声明")
    for s in d["jobs"]["build"]["steps"]:
        if "if" in s and "secrets." in str(s["if"]):
            problems.append("if 中引用 secrets: %s" % s.get("name"))
        if "run" in s and not s["run"].strip():
            problems.append("空 run 块: %s" % s.get("name"))
        body = s.get("run", "")
        for m in re.finditer(r"<<'([A-Za-z_]+)'", body):
            if not re.search(r"^%s$" % re.escape(m.group(1)), body, re.M):
                problems.append("heredoc %s 未闭合: %s" % (m.group(1), s.get("name")))
        if str(s.get("uses", "")).startswith("actions/upload-artifact"):
            if s.get("with", {}).get("if-no-files-found") != "error":
                problems.append("upload-artifact 未设 if-no-files-found=error: %s" % s.get("name"))
    return len(d["jobs"]["build"]["steps"])


def check_makefile():
    p = os.path.join(ROOT, "inject", "probe", "Makefile")
    lines = open(p, encoding="utf-8").read().split("\n")
    for i, ln in enumerate(lines, 1):
        stripped = ln.strip()
        if stripped.startswith("//"):
            problems.append("Makefile:%d 用了 // 注释（Make 只认 #）: %s" % (i, stripped[:60]))
        if ln.startswith(" ") and stripped and not stripped.startswith("#"):
            problems.append("Makefile:%d 以空格开头（recipe 必须 TAB）: %r" % (i, ln[:60]))
    text = "\n".join(lines)
    for var in ("LIBRARY_NAME", "BiliProbe_FILES", "TARGET", "ARCHS"):
        if not re.search(r"^%s\s*=" % var, text, re.M):
            problems.append("Makefile 缺少变量 %s" % var)
    if "include $(THEOS)/makefiles/common.mk" not in text:
        problems.append("Makefile 缺少 Theos common.mk 引入")
    return len(lines)


def check_line_endings():
    exts = (".py", ".m", ".h", ".yml", ".yaml", ".sh", ".txt", ".md", "Makefile")
    skip_dirs = {".git", "_recon", "_session_extract", "dist", ".theos"}
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in skip_dirs]
        for fn in filenames:
            if not (fn.endswith(exts) or fn == "Makefile"):
                continue
            fp = os.path.join(dirpath, fn)
            data = open(fp, "rb").read()
            if b"\r\n" in data:
                rel = os.path.relpath(fp, ROOT)
                n = data.count(b"\r\n")
                problems.append("CRLF 行尾(%d 处): %s  → 会让 CI 上 bash 报坏解释器" % (n, rel))


def check_python():
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "chk.pyc")
        for dirpath, dirnames, filenames in os.walk(ROOT):
            dirnames[:] = [d for d in dirnames if d not in {".git", "_session_extract"}]
            for fn in filenames:
                if fn.endswith(".py"):
                    fp = os.path.join(dirpath, fn)
                    try:
                        py_compile.compile(fp, doraise=True, cfile=out)
                    except py_compile.PyCompileError as e:
                        problems.append("Python 语法错误: %s\n    %s"
                                        % (os.path.relpath(fp, ROOT), e))


def check_no_duplicate_parser():
    """
    防分叉闸门：SIDX 解析逻辑必须只有一份（BSSidxCore.c）。
    一旦 ObjC 外壳里又长出 box 解析代码，被 Linux CI 验证的核心就与出货代码分叉了，
    那些夹具测试立刻变成摆设。这是真实存在过的风险，故用闸门钉住。
    """
    core = os.path.join(ROOT, "inject", "probe", "BSSidxCore.c")
    if not os.path.exists(core):
        problems.append("找不到 BSSidxCore.c（SIDX 解析核心）")
        return
    pattern = re.compile(r"rd32|RD32|BOX_SIDX|kBoxSIDX|reference_count|refCount|0x73696478")
    suspects = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, "inject", "probe")):
        dirnames[:] = [d for d in dirnames if d not in {".theos"}]
        for fn in filenames:
            if not fn.endswith((".m", ".h")) or fn == "BSSidxCore.h":
                continue
            fp = os.path.join(dirpath, fn)
            for i, line in enumerate(open(fp, encoding="utf-8", errors="replace"), 1):
                if pattern.search(line):
                    suspects.append("%s:%d %s" % (fn, i, line.strip()[:60]))
    if suspects:
        for s in suspects:
            problems.append("SIDX 解析逻辑疑似重复实现（应只在 BSSidxCore.c）: " + s)


print("=" * 66)
print("构建前本地闸门")
print("=" * 66)
n = check_workflow()
print("1. workflow YAML      ✓  %d 个步骤" % n)
m = check_makefile()
print("2. Makefile           ✓  %d 行" % m)
check_line_endings()
print("3. 行尾检查           %s" % ("✓" if not any("CRLF" in p for p in problems) else "✗"))
check_python()
print("4. Python 语法        %s" % ("✓" if not any("Python 语法" in p for p in problems) else "✗"))
check_no_duplicate_parser()
print("5. 解析逻辑唯一性     %s" % ("✓" if not any("重复实现" in p for p in problems) else "✗"))
print()
if problems:
    print("发现问题 %d 个：" % len(problems))
    for p in problems:
        print("  ✗", p)
    sys.exit(1)
print("全部通过 ✅ 可以推送")
