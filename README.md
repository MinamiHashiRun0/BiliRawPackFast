# BiliRawPackFast

给**哔哩哔哩官方 iOS 客户端**（`tv.danmaku.bilianime`，App Store ID 736536022）增加
**CDN 重定向**与**并发分段下载**能力。

与 `PiliPlusRDCDN`（改第三方 Flutter 客户端）不同，本项目直接在官方客户端上动手：
官方客户端用原生播放层（AVPlayer/VideoToolbox），没有 Flutter 合成器的开销，
但缺少 CDN/并发可调项 —— 两边短板互补。

---

## 当前状态

**阶段 1：注入探针** —— 探针已构建并交付，等真机验证。尚未实现任何 CDN/并发功能。

| 里程碑 | 状态 | 证据 |
|---|---|---|
| ① 情报侦察（Mach-O / 依赖 / 播放链路 / CDN 逻辑） | ✅ 完成 | `_recon/*.json`、本文档 |
| ② 注入器（原地扩展 LC_LOAD_DYLIB） | ✅ 完成 | `_recon/test_inject.py` 三项自测通过 |
| ③ 探针 dylib 源码 | ✅ 完成 | `inject/probe/BiliProbe.m` |
| ④ CI 编译 + 发布 | ✅ 完成 | run 35523168173 全绿，release `probe-4` |
| ⑤ 产物独立复核 | ✅ 完成 | `_recon/verify_dylib.py` 全项通过 |
| ⑥ **真机验证注入是否加载** | ⏳ **等用户执行** | 见下方「真机步骤」 |
| ⑦ CDN 重定向 | ⏳ 未开始 | 已定位 hook 点与候选配置键 |
| ⑧ 并发分段下载 | 🔶 算法已验证，待移植 | `_recon/segment_fetcher_ref.py` 4/4 通过 |

### 已交付产物

`BiliProbe.dylib`（**v2**，真·只读版），114,688 字节
SHA256 `0E28FF6F8CC37F1D0A48796700841F016A6AF3418CB546941282C09E8503182D`

> v1 曾让 `shouldWaitForLoading` 恒返回 NO（行为改动），已废弃并从交付目录移除。
> 只装 v2。

```
Mach-O 64-bit dynamically linked shared library arm64
install name : @executable_path/Frameworks/BiliProbe.dylib
部署目标     : iOS 14.0.0（与 App 主二进制 minos 一致）
依赖         : libobjc.A / Foundation / CoreFoundation / UIKit / AVFoundation / libSystem.B
               —— 6 个全部系统库，零第三方依赖
签名         : ad-hoc
```

### 阶段 2 的线索：PCDN 可能是「配置开关」而非硬编码

在二进制里发现成组的 P2P/MCDN 偏好键，其中几个直接决定 PCDN 是否启用：

| 键 | 推断含义 |
|---|---|
| `p2p_pcdn_download_enable` | PCDN 下载总开关 |
| `p2p_v3_policy_enable` | P2P v3 策略总开关 |
| `p2p_is_open` / `isEnableP2P:` / `isSupportP2P` | 启用判定入口 |
| `isPCDNBlackList` / `setIsPCDNBlackList:` | PCDN 黑名单 |
| `ijkplayer.p2p-disable-whitelist` | IJK 层 P2P 禁用白名单 |
| `ijkplayer.p2p_download` / `ijkplayer.p2p_upload` | IJK 层下载/上传开关 |
| `p2p_close_stun_reflex_ports` / `p2p_local_connect_enable` | NAT/UDP 相关 |

**这意味着阶段 2 可能有一条成本远低于 hook 的路径**：直接改写偏好值即可关掉 PCDN，
不必替换 delegate、也不碰播放逻辑。探针日志出来后可以两种做法对照：
若偏好开关生效，就用配置；不生效再退回 delegate 替换。

待探针确认的具体问题：偏好写在哪（NSUserDefaults / 自定义 plist / 服务端下发配置），
以及 App 是否在启动时用服务端配置覆盖本地值。

### 真机步骤

1. 把 `BiliProbe.dylib` 传到手机（文件 / 微信 / 局域网均可）
2. 全能签 → 插件（或「注入插件」）→ 导入 `BiliProbe.dylib`
3. 对哔哩哔哩 IPA 启用该插件 → 用你自己的证书签名安装
4. 打开 App，**随便播一个视频，等 10 秒**
5. 「文件」App → 我的 iPhone → 哔哩哔哩 → `biliprobe/`

### 需要拿回来的东西（按重要性排序）

| 文件 | 用途 | 是否必须有 |
|---|---|---|
| `environment.txt` | 判断注入是否真的加载、有没有踩越狱检测 | **必须** |
| `trace.log` | 视频 URL 的真实 scheme / host / Range | **必须** |
| `cdn-selectors.txt` | CDN 选择点落在哪个类（决定重定向怎么写） | 重要 |
| `resloader-delegates.txt` | 资源加载 delegate 的实现者清单 | 重要 |
| `classes.txt` | 定向 class-dump，用于定后续 hook 点 | 有更好 |

另外请回答三个问题：
1. App 能正常启动吗？还是一启动就闪退？
2. **视频能正常播放吗？**（探针改了 delegate 的返回值，理论上不影响，
   但如果黑屏/转圈，这条信息同样关键）
3. 有没有弹窗报错或异常提示？

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

- ~~探针会让 `shouldWaitForLoadingOfRequestedResource` 恒返回 NO~~ ——
  **已在探针 v2 消除**。改为「原 IMP 查表 + 转发」：观测方法把原实现的真实
  返回值带回，因此探针不改变 App 的任何行为，真机结果可直接用于判断
  官方 App 注入后是否依然流畅。详见 `inject/probe/BiliProbe.m` 头部声明。
- 探针仍会把 4 个 delegate 方法的实现换成路由器，并多打一行日志。
  日志走异步队列、不阻塞调用方；且 `shouldWaitForLoading` 由 AVFoundation
  控制调用频率（非每帧），因此不应引入可观测卡顿 —— 但这一点**尚未真机验证**。
- **注入可行性本身完全未验证。** 迄今所有结论都在二进制层（Mach-O 结构、依赖、
  签名、字符串）与算法层（Python 参考实现），**没有一次真机运行**。
  App 会不会被自身完整性检查干掉、dylib 能否被加载，只有装上才知道。
- 注入版 IPA 那条路（workflow 的 `--ipa` 分支）**从未真正执行过** ——
  今天没有可用的 IPA 直链，该步骤被跳过。
- 脱壳包不含 `embedded.mobileprovision`，无法还原原始 entitlements；
  自签用最小集合，全能签签名时会替换成你证书对应值。
  workflow 会先尝试用 `codesign -d --entitlements :-` 从原签名里抽原始值。
- 并发分段下载只有 **Python 参考实现**，Objective-C 版尚未编写；
  CDN 重定向完全未开始。
