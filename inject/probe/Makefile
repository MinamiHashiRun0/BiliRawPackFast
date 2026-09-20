# BiliProbe.dylib —— 哔哩哔哩官方客户端注入探针（阶段 1）
#
# 构建约束（都是为了让「全能签 / Sideloadly / TrollStore」能干净地注入）：
#   * 目标架构 arm64（App 主二进制是 arm64 瘦切片，不一致就加载不起来）
#   * 部署目标 iOS 14.0（与 App 主二进制的 LC_BUILD_VERSION minos 一致）
#   * 不以 theos_ 开头 → 不链 libsubstrate/orion，减少注入后的未知交互，
#     只用系统框架
#   * 名字固定 BiliProbe.dylib，注入工具按文件名认

ARCHS = arm64
TARGET = iphone:clang:latest:14.0

# 显式指定 ad-hoc 签名，不吃 Theos 的默认值。
# 原因：Darwin 上 Theos 默认 TARGET_CODESIGN ?= ldid（flags -S），
# runner 上没有 ldid 时会以裸命令名调用 → Error 127，
# 且报错点出现在 "Generating debug symbols" 之后，很容易误判。
# macOS 自带 codesign，ad-hoc（--sign -）对「后续还要整包重签」的 dylib 完全够用。
# 用 override 是为了让命令行传参也无法覆盖，保证 CI 与本机行为一致。
override TARGET_CODESIGN = codesign
override TARGET_CODESIGN_FLAGS = --force --sign -

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = BiliProbe

BiliProbe_FILES = BiliProbe.m BSSidxIndex.m BSSegmentFetcher.m
BiliProbe_FRAMEWORKS = Foundation UIKit AVFoundation
BiliProbe_CFLAGS = -fobjc-arc -O2 -Wall -Wno-unused-parameter
BiliProbe_LDFLAGS = -Wl,-install_name,@executable_path/Frameworks/BiliProbe.dylib

include $(THEOS_MAKE_PATH)/library.mk
