#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从真机 classes.txt 里抽出「我们要 hook 的那些选择子」的真实 encoding，
生成 test_enctypes.c 用的夹具表。

为什么不让 C 测试手写 encoding：手抄一定会抄错，而这个 bug 的性质正是
「encoding 解析错了但没人发现」。夹具必须逐字节来自设备。
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from clsindex import parse  # noqa: E402

# (类名, 选择子, 期望形状) —— 期望形状必须和 BiliProbe.m 里的 expectShapes 一致
TARGETS = [
    # ---- 阶段 2/3：URL 承载点 ----
    ("IJKMediaPlayerItem", "willOpenUrl:", "@"),
    ("IJKMediaPlayerItem", "setUrl:", "@"),
    ("IJKMediaPlayerItem", "updateUrl:resolved:", "@B"),
    ("IJKMediaPlayerItem", "updateUrlInfo:", "@"),
    ("IJKMediaPlayerItem", "callMeteredNetworkUrl:reasonType:", "@q"),
    ("IJKMediaAssetStreamSegment", "initWithUrl:", "@"),
    ("IJKDashStreamItem", "setBaseUrl:", "@"),
    ("IJKDashStreamItem", "setBackupUrl0:", "@"),
    ("IJKDashStreamItem", "setBackupUrl1:", "@"),
    ("IJKDashStreamItem", "initWithStreamId:bandwidth:baseUrl:fileSize:streamType:codecType:", "ii@qii"),
    ("IJKDashStreamBridge", "setUrl:", "@"),
    ("IJKDashStreamBridge", "setBackupUrls:", "@"),
    ("IJKDashStreamBridge", "initWithMediaType:codecId:qn:bandwidth:url:backupUrls:", "qqqq@@"),
    ("IJKFFMoviePlayerController", "initWithContentURL:withOptions:", "@@"),
    ("IJKFFMoviePlayerController", "initWithContentURLString:withOptions:", "@@"),
    ("IJKFFMoviePlayerControllerFFPlay", "initWithContentURL:withOptions:", "@@"),
    ("IJKFFMoviePlayerControllerFFPlay", "initWithContentURLString:withOptions:", "@@"),
    ("IJKFFMoviePlayerControllerFFPlay", "resetWithContentURLString:withOptions:", "@@"),
    ("IJKFFMoviePlayerControllerAVPlayer", "initWithContentURL:", "@"),
    ("IJKFFMoviePlayerControllerAVPlayer", "initWithContentURLString:", "@"),
    ("IJKFFMoviePlayerControllerAVPlayer", "createAssetWithUrl:", "@"),
    ("BBPlayerPreloadNextItem", "setPreloadUrl:", "@"),
    # ---- 阶段 0：播放器生命周期 ----
    ("IJKFFMoviePlayerControllerFFPlay", "play", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "prepareToPlay", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "initUsingItemWithOptions:", "@"),
    ("IJKFFMoviePlayerControllerFFPlay", "initUsingItemWithOptions:withGLView:", "@@"),
    ("IJKFFMoviePlayerControllerFFPlay", "initWithMoreContent:withOptions:withGLView:", "@@@"),
    ("IJKFFMoviePlayerControllerFFPlay", "initWithMoreContentString:withOptions:withGLView:", "@@@"),
    ("IJKFFMoviePlayerController", "play", ""),
    ("IJKFFMoviePlayerController", "prepareToPlay", ""),
    ("IJKFFMoviePlayerController", "initUsingItemWithOptions:", "@"),
    ("IJKFFMoviePlayerController", "initUsingItemWithOptions:withGLView:", "@@"),
    ("IJKFFMoviePlayerControllerAVPlayer", "play", ""),
    ("IJKFFMoviePlayerControllerAVPlayer", "prepareToPlay", ""),
    ("IJKFFMoviePlayerControllerAVPlayer", "initUsingItem", ""),
    ("IJKMediaPlayerWrapper", "start", ""),
    ("IJKMediaPlayerWrapper", "prepareWithItem:", "@"),
    ("IJKMediaPlayerItem", "start", ""),
    ("IJKMediaPlayerItem", "applyTo:", "^"),
    ("BBPlayerViewController", "viewDidAppear:", "B"),
    ("BBPgcPlayerViewController", "viewDidAppear:", "B"),
    # ---- 播放器自报数（阶段 0 轮询用，靠 respondsToSelector 调用，不 hook）----
    ("IJKFFMoviePlayerControllerFFPlay", "isPlaying", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "isPreparedToPlay", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "currentPlaybackTime", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "duration", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "getVideoTcpSpeed", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "getAudioTcpSpeed", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "getTcpSpeed", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "getVideoCachedDuration", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "getAudioCachedDuration", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "getPlayerStatus", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "httpOpenDelegate", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "tcpOpenDelegate", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "rawDataDelegate", ""),
    ("IJKFFMoviePlayerControllerFFPlay", "fileOpenDelegate", ""),
]


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else r"_logs\run9\biliprobe\classes.txt"
    out_path = sys.argv[2] if len(sys.argv) > 2 else r"inject\probe\bsp_enctypes_fixtures.inc"

    classes = parse(src)
    lines = []
    missing = []
    for cls, sel, want in TARGETS:
        d = classes.get(cls)
        enc = None
        if d:
            enc = d["instance"].get(sel) or d["class"].get(sel)
        if not enc:
            missing.append((cls, sel))
            continue
        lines.append('    {"%s", "%s", "%s", "%s"},' % (cls, sel, enc, want))

    body = "\n".join(lines)
    Path(out_path).write_text(body + "\n", encoding="utf-8")
    print("写出 %d 条夹具到 %s" % (len(lines), out_path))
    if missing:
        print("!! 有 %d 条在转储里找不到（会导致 C 测试缺项）：" % len(missing))
        for cls, sel in missing:
            print("   %s :: %s" % (cls, sel))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
