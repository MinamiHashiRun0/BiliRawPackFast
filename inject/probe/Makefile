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

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = BiliProbe

BiliProbe_FILES = BiliProbe.m
BiliProbe_FRAMEWORKS = Foundation UIKit AVFoundation
BiliProbe_CFLAGS = -fobjc-arc -O2 -Wall -Wno-unused-parameter
BiliProbe_LDFLAGS = -Wl,-install_name,@executable_path/Frameworks/BiliProbe.dylib

include $(THEOS_MAKE_PATH)/library.mk
