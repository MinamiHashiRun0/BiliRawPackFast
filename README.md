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
| ⑧ 并发分段下载 | 🔶 引擎已写完并编译通过；SIDX 解析器已用夹具实测 | 见下方「已验证 / 未验证」 |

### ⑧ 的验证状态（分层，务必分清）

| 层 | 如何验证 | 状态 |
|---|---|---|
| **纯 C 核心**（SIDX 解析） | Linux runner + clang + 9 个夹具，**真跑** | ✅ **已实测** |
| **并发引擎**（`BSSegmentFetcher`） | macOS runner + 按连接限速的 Range 服务器，**真跑** | ✅ **已实测**（见下） |
| ObjC 外壳（`BSSidxIndex`） | 只做 NSData→核心→结构搬运 | ✅ 编译通过，未单独运行 |
| **真机运行** | — | ❌ **零次** |

并发引擎实测（CI job `verify-segment-fetcher`，macOS）：

```
[1] 20 段并发4：  ✓ 交付严格按段号递增  ✓ 段数完整  ✓ 逐段内容逐字节正确
[2] 并发提速：    并发1 = 13.14s   并发8 = 1.79s   → 实测 7.3×   ✓
[3] 坏 host 降级：✓ 重试后切到备用 host 并完整交付
[4] 全失效：      ✓ 回调用 onFailure   ✓ 未交付任何残缺数据
全部通过 ✅
```

服务端按**连接**限速 256 KiB/s —— 这正是真实场景：B站对单连接限速，
所以"并发能否提速"必须用这种方式验证，而不是在本机回环上看（回环太快，测了没意义）。

> 夹具经历一次设计返工，值得记录：最初夹具按「段号填充常量字节」生成，
> 而测试用不同分段粒度断言，导致所有「逐段内容」检查失败。
> **问题在夹具设计，不在被测引擎**（引擎的按序/段数/重试/降级当时就是通过的）。
> 已改为「按字节位置」编码（第 i 字节 = `i % 251`），与分段方式无关，
> 并新增 `_recon/verify_fixture_recipe.py` 验证该配方在 4KiB/128KiB/1000B 等多种粒度下自洽。

夹具实测结果（CI 日志原文）：

```
✓ v0_all_direct.bin        段数=10  timescale=16000  covered=11665
✓ v1_64bit_offsets.bin     段数=6   timescale=48000  covered=24576
✓ mixed_hier_and_empty.bin 段数=2   （2 直接 + 2 层级 + 1 空段，层级与空段被正确跳过）
✓ hier_only.bin            正确拒绝: NO_SEGMENT     （全层级引用）
✓ unknown_version.bin      正确拒绝: BAD_VERSION    （version=2 不猜）
✓ timescale_zero.bin       正确拒绝: BAD_TIMESCALE
✓ truncated_table.bin      正确拒绝: TRUNCATED
✓ no_sidx.bin              正确拒绝: NO_SIDX
✓ zero_refs.bin            正确拒绝: NO_SEGMENT
全部 9 个夹具通过 ✅
```

每个成功用例还额外自检：段字节和 == `covered_bytes`、段连续无空洞、二分查找抽查命中正确段号。

> **夹具来源必须说清**：IPA 内没有真实 m4s（视频运行时下载），
> 所以**没有真实样本**。这 9 个夹具是按 ISO/IEC 14496-12 自行构造、
> 并经独立 Python 解析器复核的。它能证明「实现与规范一致」，
> **不能**替代真实字节验证 —— 拿到真实 sidx 后应当补一组真实夹具。

### 已交付产物

| 文件 | 大小 | 用途 |
|---|---|---|
| `BiliProbe.dylib`（v3） | 168,480 字节 | 裸 dylib，走全能签「插件注入」 |
| `bili-9.12.0-probe-injected.ipa` | 278,782,765 字节 | 预注入版，只需签名（推荐） |

dylib SHA256 `D4136F092492EEDA18C1E317FD74CCD8425846DE084091B32616FC77A98E5F39`

> v1（恒返回 NO 的行为改动版）与 v2 已废弃并从交付目录移除，只装 v3。

```
Mach-O 64-bit dynamically linked shared library arm64
install name : @executable_path/Frameworks/BiliProbe.dylib
部署目标     : iOS 14.0.0（与 App 主二进制 minos 一致）
依赖         : libobjc.A / Foundation / CoreFoundation / UIKit / AVFoundation / libSystem.B
               —— 6 个全部系统库，零第三方依赖
签名         : ad-hoc
```

### 阶段 2 的 hook 点（从二进制恢复，不依赖真机）

不必等真机日志才动手 —— ObjC 元数据里能恢复出方法名，已挖到这些**具体**候选：

| 类 / 方法 | 为什么是候选 |
|---|---|
| `BBLivePlayerResolverHelper`<br>`+ _processPlayerInfoWithPlayWrapper:stream:format:resolverModel:streamType:disableP2PCreationBlocK:completeBlock:` | 解析 playurl 的入口，而且**直接带 `disableP2PCreationBlock` 参数** —— 说明 App 自己有「关掉 P2P 创建」的开关，这是最干净的切入点 |
| 同上<br>`+ handlePlayInfoWithResolverModel:requestReason:playInfo:currentQuality:disableP2PCreationBlock:error:completeBlock:` | 同上，另一处同款开关 |
| `BBLivePlayerP2PServerItem`<br>`- initWithURLString:key:usingFmp4Stream:httpHeaderFields:` | P2P 资源项的构造，URL 从这里进入 |
| 同上<br>`- asset:shouldReconnectWithError:connectCount:` / `- assetReadyToResponse:` | 资源加载生命周期回调 |
| `BBRResourceLoaderManager` 家族 | 视频字节主通道（`AVAssetResourceLoaderDelegate`） |

配合已挖到的偏好键（`p2p_pcdn_download_enable`、`p2p_v3_policy_enable`、
`isPCDNBlackList`、`ijkplayer.p2p-disable-whitelist`），所以阶段 2 现在有**两条路**：
1. **配置路**：若这些键生效，改配置即可关 PCDN，成本最低、动静最小；
2. **开关路**：hook `disableP2PCreationBlock:` 传 YES，从 resolver 层直接掐掉 P2P 创建。

两条路都还需要真机确认「哪个真的生效」——但**实现方向不再靠猜**。

工具：`_recon/extract_signatures.py`（从 type encoding 恢复签名，
共 26,856 条疑似编码，按返回类型分布：void 14,855 / 对象 6,495 / BOOL 1,674 …）。

> 已知限制：ObjC 元数据里**方法名与 type encoding 分表存放**，
> 无法可靠地一一配对，所以本文件只给方法名与候选签名，**不假装已精确配对**。
> 精确签名仍需真机 dump 或反汇编确认。

#### 偏好键线索（配置路）

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

**若这些键生效，关掉 PCDN 只需改配置**，不必替换 delegate、也不碰播放逻辑。
待确认：偏好写在哪（NSUserDefaults / 自定义 plist / 服务端下发），
以及启动时是否被服务端配置覆盖。已在 IPA 里找过 `p2p_proxy.json`，**不存在**
（该文件是运行时生成的），所以配置路能否走通必须靠真机确认。

### 真机步骤

**两种装法二选一，不可叠加**（叠加会让 dylib 加载两次，hook 幂等不会崩但日志翻倍）。

**方式 A（推荐，更省事）**：用预注入版 IPA，只需签名
1. 把 `bili-9.12.0-probe-injected.ipa` 传到手机
2. 全能签打开它 → 用自己的证书签名安装（**不要**再启用插件注入）
3. 打开 App，播一个视频，**停留 20 秒以上**
4. 「文件」App → 我的 iPhone → 哔哩哔哩 → `biliprobe/`

**方式 B**：裸 `BiliProbe.dylib` + 全能签「插件注入」。

预注入版 IPA 由 `_recon/build_injected_ipa.py` 生成，对真实 IPA 自校验通过：
dylib 就位且内容一致、原有 2825 个条目全部保留、`LC_LOAD_DYLIB` 就位、
主二进制长度不变。注意它**只注入不签名** —— 签名必须 macOS 的 `codesign`。

### 探针 v3：心跳与结论（把真机往返压到一次）

探针每 15 秒写一行心跳，第 45 秒写一行 `[verdict]` 结论，覆盖四种情况：

| verdict | 含义 | 下一步 |
|---|---|---|
| ✅ | 注入成功且已捕获资源加载链路 | 据此定 stage 2 的 hook 点 |
| ⚠️ | 委托 hook 已挂，但 `shouldWait` 从未触发 | 视频不走此路径 → 改看 `[session]` 行 |
| ⚠️ | `setDelegate` 被调用但钩子没挂上 | 探针自身缺陷，需回报 |
| ❌ | dylib 已加载但 `AVAssetResourceLoader` 完全未被使用 | 看 `[session]` 计数：>0 则换注入点；都为 0 则走的是自研 socket 栈 |

**只发 `trace.log` 就能判断下一步**，不必靠来回猜测。

另外加了一个**高度过滤的兜底观测点**：host 含 `bilivideo`/`mcdn`/`akamai`/`hdslb`/`upos`
的 `NSURLSession` 请求会被记录，其余请求只做一次子串判断随即转发。
上一轮我曾刻意回避 hook `NSURLSession`（怕污染流畅度结论）；这轮改变权衡的理由是：
不做的话，一旦「视频走 AVAssetResourceLoader」这个假设不成立，整轮真机测试就白跑了。

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

## 真机实测结论（2026-09-21，iOS 27.0）

**注入可行性：已验证 ✅** —— 这是整个方案最大的未知，现在解决了。

```
[boot] ================ BiliProbe 已加载 ================
[boot] 主程序=/private/var/containers/Bundle/Application/08A1B80B-…/bili-universal.app/bili-universal
[hook] ✓ 已替换 AVAssetResourceLoader :: setDelegate:queue:
[hook] ✓ 已替换 NSURLSession :: dataTaskWithRequest:completionHandler:
[hook] ✓ 已替换 NSURLSession :: dataTaskWithRequest:
[env]  系统 iOS 27.0 / 加载镜像 1283 个
```

- **越狱/反调试检测未触发**：9 个痕迹路径（Cydia / MobileSubstrate / sshd / apt / bash / User Applications …）全部「不存在」
- **运行时侦察成功**：枚举 148,961 个类，写出 4,000 个类的定向 dump
- **确认 15 个 `AVAssetResourceLoaderDelegate` 实现者**，含
  `BBRResourceLoaderManager`、`BBLiveBaseResourceLoaderManager`、`BBUperVIResourceLoaderManager`

### 抓到的 CDN 选择点真实签名（此前只有方法名，签名是空白）

| 类 | 选择子 | 签名 |
|---|---|---|
| `BBLiveBCQualityComponent` | `_requestCDNNode` | `v16@0:8`（void，无参） |
| `BBLiveBCQualityComponent` | `_requestCDNNodeV2` | `v16@0:8` |
| `BGMFragmentContext` | `_startCDNDownloadWithPlayItem:` | `v24@0:8@16` |
| `BGMFragmentContext` | `_sendCDNRequestWithFragment:` | `v24@0:8@16` |
| `BGMFragmentDownloader` | `_downloadCDNDataWithFragment:` | `v24@0:8@16` |
| `BGMMasterListProcessor` | `_setCdnFirst:` | `v24@0:8@16` |
| `BFCBandwidthManager` | `bfcURLProtocolInjectorTransferRequest:` | `@24@0:8@16` |
| `BFCBandwidthManager` | `bfcURLProtocolInjectorTransferRequest:response:` | `@32@0:8@16@24` |

### 待解决（下一轮真机）

首轮日志**没有任何视频数据请求**：`shouldWait = 0`，`[session]` 命中的全是
`i0.hdslb.com` 的静态资源（png/svg/zip/json），没有 m4s。
且**心跳与 `[verdict]` 一行都没有** —— 探针缺陷：`dispatch_source` 定时器在真机上
一次都没触发（其它日志正常，说明不是写盘问题）。

两处已修：心跳改 `NSTimer` + 结论改为不依赖定时器的三处强制写；
并新增**第三观测点 `NSURLRequest` 构造**，使下次无论视频走哪条路都能定性：

| 命中情况 | 含义 | 阶段 2 落点 |
|---|---|---|
| `AVAssetResourceLoader` 有 | 走资源加载委托 | 接委托 |
| `NSURLSession` 有 | 走系统网络栈 | 在 session 层重定向 |
| `NSURLRequest` 有 | 只在请求构造层可见 | 在构造层重定向 |
| 三者全零（且确实播了视频） | 走自研 socket 栈 | 需换思路 |

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
  签名、字符串）、算法层（纯 C 夹具 + ObjC 真跑 + Python 参考实现），
  **没有一次真机运行**。App 会不会被自身完整性检查干掉、dylib 能否被加载，
  只有装上才知道。
- 注入版 IPA 那条路（workflow 的 `--ipa` 分支）**仍未在 CI 里执行过** ——
  今天没有可用的 IPA 直链，该步骤一直跳过。
  不过其核心改写逻辑已用**真实 IPA** 做了端到端演练
  （`_recon/test_inject_real_ipa.py`）：2825 个 zip 条目一致、主二进制长度不变、
  ncmds +1、sizeofcmds +72、`dataoff` 保持不变、`datasize` 置 0、
  逐字节差异 54 处且**允许区外 0 处**。缺的只是 macOS 上 `codesign` 那一步。
- **自签会丢掉一批 entitlements**（实测本包完整保留原始值）：
  `application-identifier` 带的是 B站 Team ID `746845GC96`，与你的证书不符。
  预注入包已剥离主二进制原有签名以避免被沿用（沿用会导致**一启动就闪退**，
  极易误判成注入失败）。另外 `extended-virtual-addressing` /
  `increased-memory-limit`（JIT 相关）、`aps-environment`、
  `associated-domains` 等自签本来也拿不到，见交付目录里的说明文件。
- SIDX 只处理文件里的**第一个** sidx；多 sidx / 层级索引不支持。
- SIDX 夹具是**按规范自行构造**的（IPA 内无真实 m4s），
  能证明实现与规范一致，**不能**替代真实字节验证。
- CDN 重定向完全未开始。
