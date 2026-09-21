# BiliFast.dylib —— 哔哩哔哩官方客户端「多 CDN 并发加速」正式模块
#
# 与探针（inject/probe）分离：
#   * 探针：装一堆观测点、做类枚举、写 classes.txt/encodings.txt，用于逆向取证
#   * 本模块：只保留真机验证过的那条链路（URL 改写 + 回环代理），日志只有会话报告
#
# 复用探针目录下的公共实现（hook 器 / CDN 池 / 代理 / 调度核心 / encoding 解析），
# 它们各自都有 CI 单测或端到端测试覆盖，不在这里复制一份。

ARCHS = arm64
TARGET = iphone:clang:latest:14.0

override TARGET_CODESIGN = codesign
override TARGET_CODESIGN_FLAGS = --force --sign -

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = BiliFast

BiliFast_FILES = BiliFast.m \
                 ../probe/BSPDynamicHook.m \
                 ../probe/BSPCdnPool.m \
                 ../probe/BSPProxyServer.m \
                 ../probe/bsp_ms_core.c \
                 ../probe/bsp_enctypes.c
BiliFast_FRAMEWORKS = Foundation UIKit
BiliFast_CFLAGS = -fobjc-arc -O2 -Wall -Wno-unused-parameter -I../probe
BiliFast_LDFLAGS = -Wl,-install_name,@executable_path/Frameworks/BiliFast.dylib

BUILD_SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_TIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
BiliFast_CFLAGS += -DFAST_BUILD_SHA='"$(BUILD_SHA)"' -DFAST_BUILD_TIME='"$(BUILD_TIME)"'

include $(THEOS_MAKE_PATH)/library.mk
