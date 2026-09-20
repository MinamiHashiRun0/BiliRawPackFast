# BiliRawPackFast

给**哔哩哔哩官方 iOS 客户端**（`tv.danmaku.bilianime`，App Store ID 736536022）增加
**CDN 重定向**与**并发分段下载**能力。

与 `PiliPlusRDCDN`（改第三方 Flutter 客户端）不同，本项目直接在官方客户端上动手：
官方客户端用原生播放层（AVPlayer/VideoToolbox），没有 Flutter 合成器的开销，
但缺少 CDN/并发可调项 —— 两边短板互补。

---

## 当前状态

**阶段 1：注入探针（进行中）** —— 验证注入可行性 + 抓取真实链路，尚未实现任何功能。

| 里程碑 | 状态 |
|---|---|
| ① 情报侦察（Mach-O / 依赖 / 播放链路 / CDN 逻辑） | ✅ 完成 |
| ② 注入器（原地扩展 LC_LOAD_DYLIB） | ✅ 完成并本地自测通过 |
| ③ 探针 dylib 源码 | ✅ 完成（待 CI 编译） |
| ④ CI 编译 + 可选注入重签 | ✅ 已就绪（待触发） |
| ⑤ 真机验证注入是否加载 | ⏳ 待用户执行 |
| ⑥ CDN 重定向 | ⏳ 未开始 |
| ⑦ 并发分段下载 | ⏳ 未开始 |

---

## 侦察结论（已实测，非推测）

目标：`哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa`，264.8 MiB
SHA256 `7823C7EAA2230F57B127A342D4801F171C96FD6B9BA42BB4DA530B422A1ADD40`

### 二进制

| 项目 | 值 |
|---|---|
| 主可执行 | `Payload/bili-universal.app/bili-universal`（630,083,392 字节） |
| 架构 | arm64 **瘦切片**（非 fat，注入不用 lipo） |
| 加密 | `cryptid = 0` → **已脱壳**，`__TEXT` 可读可改 |
| 部署目标 | iOS 14.0（`LC_BUILD_VERSION` minos） |
| 依赖库 | 97 个，**全部系统库** |
| 内嵌 Frameworks | 仅 `BGM.framework` |
| ATS | `NSAllowsArbitraryLoads = True` → 明文 HTTP 可用 |
| 文件共享 | `UIFileSharingEnabled = True` → 日志可从「文件」App 取 |

### 注入可行性（关键）

```
load command 区终点            = 16,128
__TEXT 第一个有效 section 起点  = 147,456
空隙                          = 131,328 字节
新增一条 LC_LOAD_DYLIB 需要     = 72 字节
```

→ **原地扩展即可**，不搬动 `__TEXT`、不重定位任何指针、不改任何 `vmaddr`/`fileoff`、
**文件总长度不变**。注入风险显著低于通用 `insert_dylib` 的整体下移方案。

### 播放链路（决定 hook 点）

- 播放器：`BFCPlayerControllerV2` + `BFCPlayerAVPlayerRender` → AVPlayer 原生渲染
- 视频数据流：App **自己实现了 `AVAssetResourceLoaderDelegate`**，家族为
  `BBRResourceLoaderManager` / `BBLiveBaseResourceLoaderManager` / `BBUperVIResourceLoaderManager`
  → 视频字节全部流经 App 自己的 delegate，**这是最干净的接管点**
- CDN 逻辑：`_requestCDNNode` / `_checkCDNIp` / `_setCdnFirst:` / `addCDNAddress` /
  `createCDNConnectionV2`
- **App 自带 PCDN/MCDN**（`mcdn.bilivideo.cn`、`P2PCDNConnectionV2/V3`、
  `mCompeteSpeedCDNConnections`、`DynamicParallelEnable`、`mCdnConnAssignWeights`）
- 网络栈：NSURLSession + CFNetwork + 静态链接的 AFNetworking（无第三方网络库）

> **这条改变了目标定义**：官方客户端并不"缺并发"，它有 B站自己的 PCDN/MCDN
> 竞速多连接。海外场景下真正有害的正是 PCDN（连到国内边缘节点）。
> 所以我们要做的不是"加并发"，而是**把 PCDN 拿掉、换成直连优选节点 + 自己的并发**。

### 风险项（待探针实测确认）

| 风险 | 证据 | 状态 |
|---|---|---|
| 证书固定 | 二进制含 `AFSecurityPolicy`、`AFSSLPinningModeCertificate`、`AFSSLPinningModePublicKey`、`SR_SSLPinnedCertificates` | 待确认是否覆盖 `*.bilivideo.com` |
| 越狱/环境检测 | 含 `/User/Applications/`、`/Application/Cydia.app`、`Sileo.app` 路径探测，`,Jailbreaked` | 非越狱自签设备不应命中 |
| 完整性自检 | 含 `csops` / `codeSign` 痕迹 | 待探针确认 |

---

## 目录结构

```
inject/
  inject_dylib.py          自研注入器（原地扩展 LC_LOAD_DYLIB，不搬动 __TEXT）
  probe/
    BiliProbe.m            探针 dylib 源码
    Makefile               Theos 构建（arm64 / iOS 14.0 / 不依赖 Theos 运行时）
_recon/
  recon.py                 IPA 结构与 Mach-O 解析
  strings_scan.py          字符串分组扫描（网络栈/pinning/播放器/CDN/反调试）
  strings_scan2.py         ObjC 方法索引抽取
  inject_layout.py         load command 布局与空隙分析
  test_inject.py           注入器自测（合成 + 真实二进制）
.github/workflows/
  build-probe.yml          macOS runner：编译 dylib + 可选注入重签
```

---

## 怎么用

### 1. 编译 dylib

Actions → `Build BiliProbe` → Run workflow。
产出两个 artifact：

- `BiliProbe-dylib` —— 裸 dylib
- `BiliProbe-for-QuanNengQian` —— 含 README 的插件包

### 2. 装到手机（二选一，**不要同时用**）

- **方式 A（推荐）**：全能签 →「插件注入」选 `BiliProbe.dylib` → 用自己的证书签名。
  不改 IPA 本体，由全能签追加 `LC_LOAD_DYLIB`。
- **方式 B**：workflow 传 `ipa_url` 指向脱壳 IPA 直链，下载
  `BiliBili-injected-ipa` artifact 直接签。

> 同时用会加载两次（构造函数跑两遍；hook 幂等不会崩，但日志翻倍、易误判）。

### 3. 取日志

播放任意视频 10 秒后：
**「文件」App → 我的 iPhone → 哔哩哔哩 → `biliprobe/`**

---

## 已知限制

- 探针会挂 4 个 delegate 观测方法，并让
  `shouldWaitForLoadingOfRequestedResource` 恒返回 NO ——
  **这是行为改动**。因此本轮真机结果只能判定"注入是否可行 + 链路长什么样"，
  **不能**用来比较官方 App 与原版的流畅度。详见 `inject/probe/BiliProbe.m` 头部声明。
- 脱壳包不含 `embedded.mobileprovision`，无法还原原始 entitlements；
  自签用最小集合，全能签签名时会替换成你证书对应值。
- 尚未实现任何 CDN/并发功能。
