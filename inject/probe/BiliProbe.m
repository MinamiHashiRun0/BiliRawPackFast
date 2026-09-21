//==============================================================================
// BiliProbe —— 哔哩哔哩 iOS 官方客户端（tv.danmaku.bilianime 9.12.0）注入探针
//
// 阶段 1 目标（观测为主；本轮已消除上一版的行为改动）：
//   ① 证明 dylib 注入 + 重签 在真机能加载（整个方案的前提）
//   ② 抓视频数据流真实链路：AVAssetResourceLoader 的 delegate 是谁、URL 长什么样
//   ③ 抓 CDN 选择点：_requestCDNNode / addCDNAddress 等落在哪个类、什么签名
//   ④ 运行时类侦察，等于在设备上做一次定向 class-dump，供离线定 hook 点
//   ⑤ 自检反调试/越狱痕迹，判断注入会不会被 App 自身保护干掉
//
// 行为改动声明（**已消除**，保留记录以便对照）：
//   上一版探针让 `shouldWaitForLoadingOfRequestedResource` 恒返回 NO，
//   属于行为改动，会限制真机结论的适用范围。
//   本版改为「原 IMP 查表 + 转发」：观测方法把原实现的真实返回值带回，
//   因此探针**不再改变 App 的任何行为**，真机结果可以直接用于
//   「官方 App 在注入后是否依然流畅」的判断。
//   仍然存在、但不改变行为的改动只有一类：把 4 个 delegate 方法的实现
//   换成路由器，并在调用链上多打一行日志（有固定开销，见下）。
//
// 开销声明：每次资源加载请求会多一次日志落盘（异步队列，不阻塞调用方）。
//   `shouldWaitForLoadingOfRequestedResource` 由 AVFoundation 控制调用频率，
//   不是每帧调用，故不会引入可观测卡顿；但为稳妥，日志是批量异步写而非同步。
//
// 设计约束（决定探针可信度，务必遵守）：
//   * 不 hook NSURLSession / NSURLProtocol 这类全网热路径 —— 避免探针自身
//     引入卡顿或行为变化，污染"官方 App 是否流畅"的判断。
//   * 每个 hook 前检查类/方法存在性，不存在就跳过并记录；不抛异常。
//   * 不申请权限、不联网、不写 Documents 以外的位置。
//
// 日志落点：{App Documents}/biliprobe/
//   Info.plist 已含 UIFileSharingEnabled=true → 「文件」App 里直接取走。
//==============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#include <stdatomic.h>
#include <string.h>

#import "BSPDynamicHook.h"
#import "BSPCdnPool.h"
#import "BSPProxyServer.h"
#import "bsp_enctypes.h"

// 构建身份由 Theos Makefile 通过 -D 传入。这里给兜底，
// 使本文件在 Theos 之外（例如 macOS 上直接用 clang 编译做语法检查）也能编译。
#ifndef PROBE_BUILD_SHA
#define PROBE_BUILD_SHA "local"
#endif
#ifndef PROBE_BUILD_TIME
#define PROBE_BUILD_TIME "local"
#endif

//------------------------------------------------------------------------------
#pragma mark - 日志
//------------------------------------------------------------------------------
static NSString *const kProbeDirName = @"biliprobe";
static NSString *const kLogTrace     = @"trace.log";
static NSString *const kLogClasses   = @"classes.txt";
static NSString *const kLogEnv       = @"environment.txt";
static NSString *const kLogCdnSel    = @"cdn-selectors.txt";
static NSString *const kLogResDeleg  = @"resloader-delegates.txt";

static const unsigned long long kMaxLogBytes = 8ULL * 1024 * 1024;
static const NSUInteger         kMaxClassDump = 4000;

static dispatch_queue_t gLogQueue;
static NSString        *gLogDir;

static void ProbeLogv(NSString *tag, NSString *fmt, va_list ap) {
    @autoreleasepool {
        NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                          [df stringFromDate:[NSDate date]], tag, body];
        NSLog(@"[BiliProbe] %@", line);          // 同时进系统日志（Console.app 可见）

        dispatch_async(gLogQueue, ^{
            @autoreleasepool {
                if (!gLogDir) return;
                NSString *path = [gLogDir stringByAppendingPathComponent:kLogTrace];
                NSFileManager *fm = NSFileManager.defaultManager;

                NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
                if (attr && [attr[NSFileSize] unsignedLongLongValue] > kMaxLogBytes) {
                    [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
                }
                if (![fm fileExistsAtPath:path]) {
                    [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
                    return;
                }
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
                if (!fh) return;
                @try {
                    [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                } @catch (__unused NSException *e) {
                    // 落盘失败静默，绝不递归记录（否则写失败会滚成日志风暴）
                } @finally {
                    [fh closeFile];
                }
            }
        });
    }
}

static void PLog(NSString *tag, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    ProbeLogv(tag, fmt, ap);
    va_end(ap);
}

/// 同步落盘的日志：只用于「装 hook」这种一旦崩掉就必须留下痕迹的关键节点。
/// 普通 PLog 是异步的，进程若在几毫秒内死掉，最后几行会丢 —— 而偏偏就是那几行
/// 能告诉我们崩在哪里。
static void PLogSync(NSString *tag, NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                          [df stringFromDate:[NSDate date]], tag, body];
        NSLog(@"[BiliProbe] %@", line);
        if (gLogDir) {
            NSString *path = [gLogDir stringByAppendingPathComponent:kLogTrace];
            NSFileManager *fm = NSFileManager.defaultManager;
            if (![fm fileExistsAtPath:path])
                [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
            else {
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
                if (fh) {
                    @try {
                        [fh seekToEndOfFile];
                        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                    } @catch (__unused NSException *e) {
                    } @finally {
                        [fh closeFile];
                    }
                }
            }
        }
    }
}

static void ProbeWriteFile(NSString *name, NSString *content) {
    if (!gLogDir || !name) return;
    NSString *path = [gLogDir stringByAppendingPathComponent:name];
    NSError *err = nil;
    if (![content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        PLog(@"io", @"✗ 写 %@ 失败: %@", name, err.localizedDescription);
    } else {
        PLog(@"io", @"✓ 已写 %@ (%lu 字节)", name, (unsigned long)content.length);
    }
}

//------------------------------------------------------------------------------
#pragma mark - 安全 hook 原语
//------------------------------------------------------------------------------
// 注：这里刻意不提供 method_exchangeImplementations 的通用封装。
// 已删除的 ProbeSwizzle / ProbeSwizzleOwnMethod / ProbeAddMethodIfAbsent 属死代码：
// 它们是为「分类 + probe_ 选择子」那套写法准备的，而那套写法已在
// 「原 IMP 查表 + 回收站」方案落地后全部弃用（注释见 ProbeInstallOne）。
// 留死代码会让人误以为还有两条 hook 路径，故一并删掉。

/// 直接把某个方法的实现换成 C 函数，并把原 IMP 交给调用方保存。
/// 相比 method_exchangeImplementations + 分类的写法，这里不需要在 ObjC 侧
/// 声明 probe_ 选择子，因此不会出现「在 C 函数里对 id 调未声明选择子」的编译错误；
/// 也不再依赖 ARC 生成 thunk。原实现通过保存下来的 IMP 转发，不可能递归。
static IMP ProbeReplaceMethod(Class cls, SEL sel, IMP newImp, const char *types) {
    if (!cls) {
        PLog(@"hook", @"✗ class 为 nil，跳过 %@", NSStringFromSelector(sel));
        return NULL;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        PLog(@"hook", @"✗ %@ 上 %@ 不存在，跳过",
             NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    IMP old = method_getImplementation(m);
    class_replaceMethod(cls, sel, newImp, types);
    PLog(@"hook", @"✓ 已替换 %@ :: %@", NSStringFromClass(cls), NSStringFromSelector(sel));
    return old;
}

//------------------------------------------------------------------------------
#pragma mark - 探针
//------------------------------------------------------------------------------
@interface BiliProbe : NSObject
+ (void)bootstrap;
+ (void)probe_installDelegateHooksOnClass:(Class)cls;
+ (void)probe_noteRecycleMiss:(NSString *)clsName sel:(NSString *)selName;
+ (void)probe_installStage23;
+ (void)probe_installPositiveControls;
@end

/// 观测计数（供心跳使用）。
/// 为什么需要：如果 hook 挂了但一直没被调用，日志里会几乎没有内容，
/// 用户拿回来也看不出是"注入失败"还是"App 没走这条路径"。
/// 有了计数 + 心跳，这两种情况可以区分开。
/// 用 C11 原子操作而非 OSAtomicIncrement32（后者 iOS 10 起已弃用，
/// 在开告警即错误的构建里会直接挂掉）。
static _Atomic(int32_t) gCntSetDelegate        = 0;
static _Atomic(int32_t) gCntShouldWait         = 0;
static _Atomic(int32_t) gCntRenewal            = 0;
static _Atomic(int32_t) gCntAuthChallenge      = 0;
static _Atomic(int32_t) gCntDidCancel          = 0;
static _Atomic(int32_t) gCntDelegateClassHooked = 0;

// 阶段 2/3：URL 重写相关计数
static _Atomic(int32_t) gCntMediaUrlSeen   = 0;   // 看见媒体 URL 的次数
static _Atomic(int32_t) gCntMediaUrlRewrite = 0;  // 真正改写成回环代理的次数
static _Atomic(int32_t) gCntUrlHookFired   = 0;   // 任一 URL 承载 hook 被调用的次数

// 播放正证据 + 全网观测（见文件末尾「阶段 0：仪器自证」）
static _Atomic(int32_t) gCntPlayerLifecycle = 0;  // 播放器生命周期方法命中次数
static _Atomic(int32_t) gCntTaskResume      = 0;  // 全部 NSURLSessionTask.resume（不论怎么建出来的）
static _Atomic(int32_t) gCntPlayerVCAppear  = 0;  // 播放器视图控制器出现次数
static NSHashTable     *gLivePlayers        = nil; // 弱引用：活着的播放器实例
static NSMutableDictionary<NSString *, NSNumber *> *gTaskHostHist = nil; // host -> 次数

// 每个 hook 被调用的次数（键 = "类::选择子"）。放在这里是为了让结论段也能打印，
// 从而一眼看出「哪些落点真的响了、哪些一次都没响」。
static NSMutableDictionary<NSString *, NSNumber *> *gUrlHookHits = nil;

static inline void ProbeBump(_Atomic(int32_t) *p) {
    atomic_fetch_add_explicit(p, 1, memory_order_relaxed);
}
static inline int32_t ProbeRead(_Atomic(int32_t) *p) {
    return atomic_load_explicit(p, memory_order_relaxed);
}

/// 原 IMP 查表（按「类名 + 选择子名」）。
/// 不能用共享选择子做键：多个 delegate 类会撞车，各自的原实现会互相覆盖。
static void        ProbeRegSet(NSString *cls, NSString *sel, IMP imp);
static IMP         ProbeFetchOriginal(Class cls, SEL sel);

/// 读出所有活着的播放器实例当前状态（定义在「阶段 0：仪器先自证」一节）。
/// 「是否真的在播」只能以它为准，不能拿「我的 hook 有没有响」去推断。
static NSString   *ProbePlayerSnapshot(void);

/// 改写落点汇总（定义在阶段 2/3 一节，结论段要用，故前置声明）
static NSString   *ProbeRewriteSummary(void);

/// 统一转发：查回原实现并调用它，把真实返回值带回。
/// 探针「零行为改动」就靠这个函数 —— 调用方拿到的就是 App 原本会拿到的结果。
static BOOL        ProbeForwardToOriginal(id self, SEL cmd, id a1, id a2);

/// 被挂的 delegate 方法实现（路由器）。返回类型必须是 intptr_t 而非 id：
/// 被挂方法返回 BOOL/void，用 id 会被 ARC 拒绝（见定义处注释）。
static intptr_t    ProbeRecycledCall(id self, SEL _cmd, id a1, id a2);

static void        ProbeSetResourceLoaderDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue);
static BOOL        ProbeShouldWaitForLoading(id self, SEL _cmd, id loader, id request);
static BOOL        ProbeShouldWaitForRenewal(id self, SEL _cmd, id loader, id request);
static BOOL        ProbeAuthChallenge(id self, SEL _cmd, id loader, id challenge);
static void        ProbeDidCancelLoading(id self, SEL _cmd, id loader, id request);

static BOOL        ProbeIsOwnClass(NSString *name);
static void        ProbeDumpClasses(void);
static void        ProbeFindCdnSelectors(void);
static void        ProbeFindResourceLoaderDelegates(void);
static void        ProbeLogEnvironment(void);
static void        ProbeInstallOne(Class cls, SEL sel, NSString *tag);

// 备选观测点（NSURLSession 媒体请求兜底）
static NSURLSessionDataTask *ProbeDataTaskWithRequestCompletion(id self, SEL _cmd,
                                                               NSURLRequest *request,
                                                               void (^handler)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionDataTask *ProbeDataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request);

// AVAsset / resourceLoader 真实类探测（ProbeNoteLoaderClass 里要用到，故前置声明）
static void        ProbeSetResourceLoaderDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue);
static id          ProbeAssetLoaderGetter(id self, SEL _cmd);
static id          ProbeAssetInitURL(id self, SEL _cmd, NSURL *URL, NSDictionary *options);

// 预加载与缓存盘点
static void        ProbePreloadItems(id self, SEL _cmd, id items, BOOL unite);
static void        ProbeDumpCaches(void);

// NSURLProtocol / NSURLConnection / AVURLAsset 类方法（覆盖面最广的一层）
static BOOL        ProbeProtoCanInitWithRequest(id self, SEL _cmd, NSURLRequest *request);
static void        ProbeProtoStartLoading(id self, SEL _cmd);
static id          ProbeConnInitWithRequest(id self, SEL _cmd, NSURLRequest *request,
                                            id delegate, BOOL startImmediately);
static id          ProbeAssetClassWithURL(id self, SEL _cmd, NSURL *URL, NSDictionary *options);
static void        ProbeScanTree(NSString *root, NSString *label, int topN);

// 缓存路径 provider（②h）—— 只涉及对象参数，签名无歧义
static id          ProbeP2pConfigPath(id self, SEL _cmd);
static id          ProbeSavedFolder(id self, SEL _cmd);
static void        ProbeDownloadWithUrl(id self, SEL _cmd, id url, id savedPath, id relativePath);

@implementation BiliProbe

//=== 0. 转发与路由 ============================================================
static BOOL ProbeForwardToOriginal(id self, SEL cmd, id a1, id a2) {
    IMP orig = ProbeFetchOriginal(object_getClass(self), cmd);
    if (orig) {
        return ((BOOL (*)(id, SEL, id, id))orig)(self, cmd, a1, a2);
    }
    [BiliProbe probe_noteRecycleMiss:NSStringFromClass(object_getClass(self))
                                 sel:NSStringFromSelector(cmd)];
    return NO;
}

/// 路由器：按 _cmd 分派到对应观测方法；观测方法内部再转发原实现。
///
/// 两个必须注意的 ABI / 语言细节（都是 CI 上才会暴露的坑）：
///  ① 返回类型用 intptr_t 而不是 id。
///     被挂的四个方法返回 BOOL 或 void，不是对象指针；返回 id 会触发
///     「cast of 'long long' to 'id' is disallowed with ARC」。
///     intptr_t 与 BOOL 在 arm64 上同在 x0 返回，ABI 一致。
///  ② 比较选择子必须用 sel_isEqual()，不能用 [_cmd isEqual:]
///     —— SEL 不是 Objective-C 对象，发消息会报 bad receiver type 'SEL'。
///     选择子比较每次只做一次静态注册，避免热路径上反复调用 sel_isEqual。
static intptr_t ProbeRecycledCall(id self, SEL _cmd, id a1, id a2) {
    static SEL sWait, sRenew, sAuth, sCancel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sWait   = NSSelectorFromString(@"resourceLoader:shouldWaitForLoadingOfRequestedResource:");
        sRenew  = NSSelectorFromString(@"resourceLoader:shouldWaitForRenewalOfRequestedResource:");
        sAuth   = NSSelectorFromString(@"resourceLoader:shouldWaitForResponseToAuthenticationChallenge:");
        sCancel = NSSelectorFromString(@"resourceLoader:didCancelLoadingRequest:");
    });

    if (sel_isEqual(_cmd, sWait)) {
        return (intptr_t)ProbeShouldWaitForLoading(self, _cmd, a1, a2);
    }
    if (sel_isEqual(_cmd, sRenew)) {
        return (intptr_t)ProbeShouldWaitForRenewal(self, _cmd, a1, a2);
    }
    if (sel_isEqual(_cmd, sAuth)) {
        return (intptr_t)ProbeAuthChallenge(self, _cmd, a1, a2);
    }
    if (sel_isEqual(_cmd, sCancel)) {
        ProbeDidCancelLoading(self, _cmd, a1, a2);
        return 0;
    }
    // 未登记的方法：直接转发，绝不影响行为
    return (intptr_t)ProbeForwardToOriginal(self, _cmd, a1, a2);
}

//=== 1. AVAssetResourceLoader 的 delegate 是指谁 ==============================
// 视频字节从这里流经 App 自己的 delegate（B站靠它塞 PCDN/MCDN）。
//
// 本节的观测方式（关键设计，决定探针可信度）：
//   被挂的 delegate 方法实现 → ProbeRecycledCall（路由器）
//   路由器按 _cmd 分派到 ProbeTrace*（只打日志）
//   ProbeTrace* 再查表调「原实现」并把真实返回值带回
// ⇒ 返回值与原实现完全一致，探针零行为改动。
//
// 为什么不用 method_exchangeImplementations + 共享 C 函数：
//   交换后那个 C 函数的 IMP 会被多个类/选择子共用，无法按类区分
//   「原实现是谁」，多个 delegate 类之间会互相串味。改用 IMP 查表。

/// AVAssetResourceLoader 原始 setDelegate:queue: 的 IMP（bootstrap 时抓取）
static IMP gOrigSetRLDelegate = NULL;

static void ProbeSetResourceLoaderDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    ProbeBump(&gCntSetDelegate);
    PLog(@"resloader", @"setDelegate:queue: → 宿主=%@ delegate=%@ queue=%s",
         NSStringFromClass([self class]),
         delegate ? NSStringFromClass([delegate class]) : @"(nil)",
         queue ? "有" : "NULL");

    if (delegate) {
        [BiliProbe probe_installDelegateHooksOnClass:[delegate class]];
    }

    // 直接调原始 IMP。self 是 id，编译器看不到分类里声明的 probe_ 选择子；
    // 且用抓下来的 IMP 保证逻辑上不可能递归（它就是原实现本身）。
    if (gOrigSetRLDelegate) {
        ((void (*)(id, SEL, id, dispatch_queue_t))gOrigSetRLDelegate)(self, _cmd, delegate, queue);
    } else {
        PLog(@"resloader", @"⚠️ 未抓到原始 IMP，本次不转发（delegate 可能未生效）");
    }
}

// --- 观测方法：只打日志，不转发。转发统一由 ProbeForwardToOriginal 负责 ---

static BOOL ProbeShouldWaitForLoading(id self, SEL _cmd,
                                      AVAssetResourceLoader *loader,
                                      AVAssetResourceLoadingRequest *request) {
    ProbeBump(&gCntShouldWait);
    @autoreleasepool {
        NSURLRequest *r = request.request;
        NSURL *u = r.URL;
        NSDictionary *h = r.allHTTPHeaderFields;

        static NSMutableSet *schemes = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ schemes = [NSMutableSet set]; });
        NSString *scheme = u.scheme ?: @"(nil)";
        BOOL firstTime = ![schemes containsObject:scheme];
        if (firstTime) [schemes addObject:scheme];

        PLog(@"resloader", @"shouldWait%@ delegate=%@\n          scheme=%@ host=%@\n          Range=%@\n          URL=%.420@",
             firstTime ? @"【发现新 scheme】" : @"",
             NSStringFromClass([self class]),
             scheme, u.host ?: @"(nil)", h[@"Range"] ?: @"(无)", u.absoluteString ?: @"(nil)");

        AVAssetResourceLoadingDataRequest *dr = request.dataRequest;
        if (dr) {
            PLog(@"resloader", @"      dataRequest offset=%lld length=%lld allToEnd=%d",
                 dr.requestedOffset, dr.requestedLength, (int)dr.requestsAllDataToEndOfResource);
        }
        AVAssetResourceLoadingContentInformationRequest *ci = request.contentInformationRequest;
        if (ci) {
            PLog(@"resloader", @"      contentInfo type=%@ length=%lld byteRangeAccess=%d",
                 ci.contentType ?: @"(nil)", ci.contentLength, (int)ci.byteRangeAccessSupported);
        }
    }
    return ProbeForwardToOriginal(self, _cmd, loader, request);
}

static BOOL ProbeShouldWaitForRenewal(id self, SEL _cmd,
                                      AVAssetResourceLoader *loader,
                                      AVAssetResourceRenewalRequest *request) {
    ProbeBump(&gCntRenewal);
    PLog(@"resloader", @"shouldWaitForRenewal URL=%.300@", request.request.URL.absoluteString ?: @"(nil)");
    return ProbeForwardToOriginal(self, _cmd, loader, request);
}

static BOOL ProbeAuthChallenge(id self, SEL _cmd,
                               AVAssetResourceLoader *loader,
                               NSURLAuthenticationChallenge *challenge) {
    ProbeBump(&gCntAuthChallenge);
    PLog(@"pinning", @"⚠️ 资源加载器收到认证挑战 method=%@ host=%@ realm=%@  ← 有值=存在 TLS 校验链路",
         challenge.protectionSpace.authenticationMethod ?: @"(nil)",
         challenge.protectionSpace.host ?: @"(nil)",
         challenge.protectionSpace.realm ?: @"(nil)");
    return ProbeForwardToOriginal(self, _cmd, loader, challenge);
}

static void ProbeDidCancelLoading(id self, SEL _cmd,
                                  AVAssetResourceLoader *loader,
                                  AVAssetResourceLoadingRequest *request) {
    ProbeBump(&gCntDidCancel);
    PLog(@"resloader", @"didCancelLoading URL=%.200@", request.request.URL.absoluteString ?: @"(nil)");
    (void)ProbeForwardToOriginal(self, _cmd, loader, request);
}

//=== 2. 备选观测点：NSURLSession 上的媒体请求 ==================================
// 为什么需要：主观测点假设「视频字节经 AVAssetResourceLoaderDelegate」。
// 若这个假设不成立（App 用自研 socket 栈或别的路径），主观测点会一条日志都没有，
// 我们就完全瞎了。这里补一个**高度过滤**的观测点作为兜底：
//   * 只对 host 含 bilivideo / mcdn / akamai 的请求展开记录
//   * 其余请求立即原样转发，不做任何额外工作
// 之所以敢碰 NSURLSession（上一轮我曾刻意回避它）：过滤足够窄，
// 非媒体请求的额外开销只有一次字符串包含判断。
// 仍需注意：这是真·全 App 热路径，若日志出现明显增长要能立刻收窄或撤掉。

static _Atomic(int32_t) gCntSessionMediaReq = 0;

static BOOL ProbeHostLooksLikeMedia(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host;
    if (host.length == 0) return NO;
    static NSArray<NSString *> *needles = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 加入回环地址：IJKP2PManager 有 +getHttpServerPort，说明 P2P 在本地起 HTTP 服务，
        // 播放器从 127.0.0.1:<port> 读数据。此前的过滤器把它排除在外，
        // 于是即使有请求也不会被记录 —— 这是之前一直"什么都抓不到"的可能原因之一。
        needles = @[@"bilivideo", @"mcdn", @"akamai", @"hdslb", @"upos",
                    @"127.0.0.1", @"localhost", @"::1"];
    });
    for (NSString *n in needles) {
        if ([host rangeOfString:n options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

/// 原始 IMP，不调 _cmd，避免 initializer 类方法递归
static NSURLSessionDataTask *(*gOrigDataTaskCR)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)) = NULL;
static IMP gOrigDataTaskC = NULL;
static IMP gOrigDataTaskD = NULL;

/// 代理自己发出的上游分片请求带这个头，探针要主动无视它们，
/// 否则一次播放会写上千行 [session] 日志，把真正有用的信息淹掉。
static BOOL ProbeIsOurProxyUpstream(NSURLRequest *request) {
    return [request valueForHTTPHeaderField:@"X-BSP-Upstream"] != nil;
}

static NSURLSessionDataTask *ProbeDataTaskWithRequestCompletion(id self, SEL _cmd,
                                                               NSURLRequest *request,
                                                               void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    if (gOrigDataTaskCR == NULL && gOrigDataTaskC) {
        gOrigDataTaskCR = (NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)))gOrigDataTaskC;
    }
    if (ProbeIsOurProxyUpstream(request)) {
        if (gOrigDataTaskCR) return gOrigDataTaskCR(self, _cmd, request, handler);
        return nil;
    }
    if (ProbeHostLooksLikeMedia(request.URL)) {
        ProbeBump(&gCntSessionMediaReq);
        PLog(@"session", @"媒体请求 method=%@ host=%@ range=%@\n          URL=%.360@",
             request.HTTPMethod ?: @"?",
             request.URL.host ?: @"?",
             [request valueForHTTPHeaderField:@"Range"] ?: @"(无)",
             request.URL.absoluteString ?: @"?");
    }
    if (gOrigDataTaskCR) return gOrigDataTaskCR(self, _cmd, request, handler);
    return nil;
}

static NSURLSessionDataTask *ProbeDataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    if (ProbeIsOurProxyUpstream(request)) {
        if (gOrigDataTaskD) {
            return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *))gOrigDataTaskD)(self, _cmd, request);
        }
        return nil;
    }
    if (ProbeHostLooksLikeMedia(request.URL)) {
        ProbeBump(&gCntSessionMediaReq);
        PLog(@"session", @"媒体请求(无回调) method=%@ host=%@ range=%@\n          URL=%.360@",
             request.HTTPMethod ?: @"?",
             request.URL.host ?: @"?",
             [request valueForHTTPHeaderField:@"Range"] ?: @"(无)",
             request.URL.absoluteString ?: @"?");
    }
    if (gOrigDataTaskD) {
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *))gOrigDataTaskD)(self, _cmd, request);
    }
    return nil;
}

//=== 2b. 第三观测点：NSURLRequest 的构造 ======================================
// 为什么还要这一层：前两个观测点都假设请求最终经 NSURLSession 发出。
// 若视频走自研 socket 栈（B站确有 P2P/MCDN 的自研传输），前两层可能都抓不到。
// 而 NSURLRequest 是**更上游**的构造点 —— 只要 App 用 AVPlayer/NSURLSession
// 系 API 发起媒体请求，URL 在这里必然出现一次。
// 同样只对媒体域名记录，其余请求仅一次子串判断。

static _Atomic(int32_t) gCntRequestConstructed = 0;

static IMP gOrigReqInitURL = NULL;
static IMP gOrigReqClassURL = NULL;
static IMP gOrigReqInitURLString = NULL;

static id ProbeRequestInitWithURL(id self, SEL _cmd, NSURL *URL) {
    if (ProbeHostLooksLikeMedia(URL)) {
        ProbeBump(&gCntRequestConstructed);
        PLog(@"request", @"NSURLRequest initWithURL host=%@\n          URL=%.400@",
             URL.host ?: @"?", URL.absoluteString ?: @"?");
    }
    if (gOrigReqInitURL) {
        return ((id (*)(id, SEL, id))gOrigReqInitURL)(self, _cmd, URL);
    }
    return nil;
}

/// 类方法构造：requestWithURL: —— 很多代码走这条而不是 alloc/init
static id ProbeRequestClassWithURL(id self, SEL _cmd, NSURL *URL) {
    if (ProbeHostLooksLikeMedia(URL)) {
        ProbeBump(&gCntRequestConstructed);
        PLog(@"request", @"NSURLRequest requestWithURL host=%@\n          URL=%.400@",
             URL.host ?: @"?", URL.absoluteString ?: @"?");
    }
    if (gOrigReqClassURL) {
        return ((id (*)(id, SEL, id))gOrigReqClassURL)(self, _cmd, URL);
    }
    return nil;
}

/// initWithURL: 的字符串变体
static id ProbeRequestInitWithURLString(id self, SEL _cmd, NSString *s) {
    NSURL *URL = s.length ? [NSURL URLWithString:s] : nil;
    if (ProbeHostLooksLikeMedia(URL)) {
        ProbeBump(&gCntRequestConstructed);
        PLog(@"request", @"NSURLRequest initWithURL(String) host=%@\n          URL=%.400@",
             URL.host ?: @"?", s ?: @"?");
    }
    if (gOrigReqInitURLString) {
        return ((id (*)(id, SEL, id))gOrigReqInitURLString)(self, _cmd, s);
    }
    return nil;
}

//=== 3b. BBRMediaDownloader：视频字节的实际下载器 ==============================
// 为什么钩它（依据来自 classes.txt 的真实方法表，不是猜的）：
//   BBRResourceLoaderManager  + assetURLWithURL:
//                             - resourceLoader:shouldWaitForLoadingOfRequestedResource:
//   BBRResourceLoader         - initWithURL: / startWorkerWithRequest:
//                             - mediaDownloader
//   BBRMediaDownloader        - initWithURL:cacheWorker:
//                             - downloadTaskFromOffset:length:toEnd:   ← 段级下载入口
//   BGMFragmentP2pDownloader2 - startWithCdnFetchHandle:               ← P2P 分支
// 这一层比 AVAssetResourceLoader 更靠近字节：无论上层用不用自定义 scheme，
// 只要走这个下载器，URL 与 Range 就在这里。若它也一直为 0，
// 就能断定竖屏播放器走的是 P2P 分支（BGMFragmentP2pDownloader2）。

static _Atomic(int32_t) gCntMediaDownloaderInit  = 0;
static _Atomic(int32_t) gCntMediaDownloadTask    = 0;

static IMP gOrigDLInitURL = NULL;
static IMP gOrigDLTask    = NULL;

/// URL 太长会刷屏，这里只记 host + 路径尾段 + 参数键（不记 token 值）
static NSString *ProbeSummarizeURL(NSURL *url) {
    if (!url) return @"(nil)";
    NSString *path = url.path ?: @"";
    NSString *tail = path.length > 60 ? [path substringFromIndex:path.length - 60] : path;
    NSArray<NSString *> *keys = nil;
    if (url.query.length) {
        NSMutableArray *ks = [NSMutableArray array];
        for (NSString *pair in [url.query componentsSeparatedByString:@"&"]) {
            NSString *k = [pair componentsSeparatedByString:@"="].firstObject;
            if (k.length) [ks addObject:k];
        }
        keys = ks;
    }
    return [NSString stringWithFormat:@"host=%@ pathTail=…%@ 参数键=[%@]",
            url.host ?: @"?", tail,
            keys.count ? [keys componentsJoinedByString:@","] : @"无"];
}

static id ProbeDLInitWithURL(id self, SEL _cmd, NSURL *url, id cacheWorker) {
    ProbeBump(&gCntMediaDownloaderInit);
    PLog(@"mediadl", @"BBRMediaDownloader initWithURL → %@", ProbeSummarizeURL(url));
    if (gOrigDLInitURL) {
        return ((id (*)(id, SEL, id, id))gOrigDLInitURL)(self, _cmd, url, cacheWorker);
    }
    return nil;
}

static void ProbeDLTaskFromOffset(id self, SEL _cmd,
                                  unsigned long long offset,
                                  unsigned long long length,
                                  BOOL toEnd) {
    ProbeBump(&gCntMediaDownloadTask);
    PLog(@"mediadl", @"★ downloadTaskFromOffset=%llu length=%llu toEnd=%d  ← 段级下载（多 CDN 并发的落点）",
         offset, length, (int)toEnd);
    if (gOrigDLTask) {
        ((void (*)(id, SEL, unsigned long long, unsigned long long, BOOL))gOrigDLTask)
            (self, _cmd, offset, length, toEnd);
    }
}

//=== 2c. AVAsset 与 resourceLoader 的真实类 ====================================
// 排掉一个会让前面所有结论失效的盲区：
//   我只在 AVAssetResourceLoader **这个类**上替换了 setDelegate:queue:。
//   若运行时对象其实是它的**私有子类**（如 AVAssetResourceLoaderInternal），
//   那么消息会走子类的实现，我的 ProbeSetResourceLoaderDelegate 永远不会被调用，
//   setDelegate 计数恒为 0 —— 看起来像"App 没用 AVPlayer"，其实只是没钩到真正的类。
//   这两条 hook 用来定性：既证明播放器是不是 AVPlayer 系，也拿到 resourceLoader 的真实类。

static _Atomic(int32_t) gCntAssetInit    = 0;
static _Atomic(int32_t) gCntLoaderClass  = 0;

static IMP gOrigAssetInitURL = NULL;
static IMP gOrigAssetLoaderGet = NULL;

/// 只记一次每个真实类名，避免刷屏
static void ProbeNoteLoaderClass(Class c) {
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *n = c ? NSStringFromClass(c) : @"(nil)";
    @synchronized (seen) {
        if ([seen containsObject:n]) return;
        [seen addObject:n];
    }
    ProbeBump(&gCntLoaderClass);
    PLog(@"asset", @"resourceLoader 的真实类 = %@  ← 若它不是 AVAssetResourceLoader，"
                   @"则必须在**这个类**上挂 setDelegate:queue: 才有效", n);
    // 顺手在这个真实类上也挂一遍（幂等）
    if (c && c != NSClassFromString(@"AVAssetResourceLoader")) {
        IMP prev = ProbeReplaceMethod(c, @selector(setDelegate:queue:),
                                      (IMP)ProbeSetResourceLoaderDelegate, "v@:@@");
        PLog(@"asset", @"  已在真实类 %@ 上挂 setDelegate:queue:（原 IMP=%p）", n, prev);
    }
}

/// AVURLAsset.resourceLoader —— 拿到真实对象与其类
static id ProbeAssetLoaderGetter(id self, SEL _cmd) {
    id loader = nil;
    if (gOrigAssetLoaderGet) {
        loader = ((id (*)(id, SEL))gOrigAssetLoaderGet)(self, _cmd);
    }
    ProbeNoteLoaderClass(object_getClass(loader));
    return loader;
}

/// AVURLAsset initWithURL:options: —— 证明播放器是否创建 AVAsset
/// 做法与原探针不同：这次保存原 IMP 并调用它，返回**真实资产**（不再返回替代对象，
/// 因为上一版分析过那样会打断资源创建；这里靠保存 IMP 既能观测又不破坏行为）。
static id ProbeAssetInitURL(id self, SEL _cmd, NSURL *URL, NSDictionary *options) {
    ProbeBump(&gCntAssetInit);
    PLog(@"asset", @"AVURLAsset initWithURL scheme=%@ host=%@\n          URL=%.300@",
         URL.scheme ?: @"?", URL.host ?: @"?", URL.absoluteString ?: @"?");
    if (gOrigAssetInitURL) {
        return ((id (*)(id, SEL, id, id))gOrigAssetInitURL)(self, _cmd, URL, options);
    }
    return nil;
}

//=== 3c. 缓存目录盘点 + 预加载 ================================================
// 依据：真机三次会话里，视频在播但 BBRMediaDownloader 从未被创建（init=0）。
// 最可能的解释是「视频在点进去之前已被预下载」，于是播放走本地缓存、不产生网络下载。
// 若成立，则任何网络层 hook 都不会触发 —— 必须往**上游（预加载）**找。
// 这两条观测点用来定性：
//   ① 直接列出 App 沙盒里的缓存目录，看有没有视频字节落盘、多大
//   ② 钩 BBPlayerPreload.preloadItems:unite: 看预加载是否在跑

static _Atomic(int32_t) gCntPreloadCall = 0;
static IMP gOrigPreloadItems = NULL;

static void ProbePreloadItems(id self, SEL _cmd, id items, BOOL unite) {
    ProbeBump(&gCntPreloadCall);
    PLog(@"preload", @"★ BBPlayerPreload preloadItems:unite:%d items=%@",
         (int)unite, items ? [NSString stringWithFormat:@"<%@>", NSStringFromClass([items class])] : @"(nil)");
    if (gOrigPreloadItems) {
        ((void (*)(id, SEL, id, BOOL))gOrigPreloadItems)(self, _cmd, items, unite);
    }
}

/// 逐层统计：对 root 下每个一级子目录递归求和并计数，输出 Top N。
/// 上一次盘点只看了顶层，结果 636MB 的 Library 里装了什么完全看不到；
/// 这次递归下去，直接定位视频缓存在哪个子目录。
static void ProbeScanTree(NSString *root, NSString *label, int topN) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        PLog(@"cache", @"%@ 不存在或非目录: %@", label, root);
        return;
    }
    NSError *err = nil;
    NSArray<NSString *> *subs = [fm contentsOfDirectoryAtPath:root error:&err];
    if (err) { PLog(@"cache", @"%@ 列举失败: %@", label, err.localizedDescription); return; }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSString *name in subs) {
        NSString *full = [root stringByAppendingPathComponent:name];
        BOOL sub = NO;
        [fm fileExistsAtPath:full isDirectory:&sub];
        unsigned long long bytes = 0;
        NSUInteger files = 0;
        if (sub) {
            NSDirectoryEnumerator *e = [fm enumeratorAtPath:full];
            NSString *rel;
            while ((rel = [e nextObject])) {
                NSDictionary *a = [e fileAttributes];
                if ([a[NSFileType] isEqual:NSFileTypeDirectory]) continue;
                bytes += [a[NSFileSize] unsignedLongLongValue];
                files++;
            }
        } else {
            NSDictionary *a = [fm attributesOfItemAtPath:full error:NULL];
            bytes = [a[NSFileSize] unsignedLongLongValue];
            files = 1;
        }
        [rows addObject:@{@"name": name, @"bytes": @(bytes), @"files": @(files), @"dir": @(sub)}];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"bytes"] compare:a[@"bytes"]];
    }];

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"===== %@ =====\n 路径: %@\n", label, root];
    unsigned long long grand = 0;
    for (NSDictionary *r in rows) grand += [r[@"bytes"] unsignedLongLongValue];
    [out appendFormat:@" 合计 %.2f MB，%lu 个一级项\n", (double)grand / 1048576.0,
                      (unsigned long)rows.count];
    NSUInteger shown = 0;
    for (NSDictionary *r in rows) {
        if (shown++ >= (NSUInteger)topN) { [out appendString:@"  …\n"]; break; }
        [out appendFormat:@"  %@ %-40@ %12llu 字节  %lu 个文件\n",
                          [r[@"dir"] boolValue] ? @"[目录]" : @"[文件]",
                          r[@"name"],
                          [r[@"bytes"] unsignedLongLongValue],
                          (unsigned long)[r[@"files"] unsignedIntegerValue]];
    }
    PLog(@"cache", @"%@", out);
}

/// 盘点与视频缓存有关的目录（用官方 API 取路径，不再猜）
static void ProbeDumpCaches(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;

        // 1) 官方 API 拿 Caches —— 上一版手工拼路径，拼错了两层，结果什么都没看到
        NSArray<NSString *> *cacheDirs =
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *caches = cacheDirs.firstObject;

        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = docs.firstObject ?: @"";
        NSString *lib = [doc stringByDeletingLastPathComponent];
        NSString *container = [lib stringByDeletingLastPathComponent];

        PLog(@"cache", @"路径：container=%@  library=%@  caches=%@", container, lib, caches);

        // 2) Library 下逐层统计（636MB 在哪一目了然）
        ProbeScanTree(lib, @"Library 下各一级项", 20);

        // 2b) 关键：把 Library 一级子目录**分别再扫一层**，并按体积列出最大文件。
        //     上一版只列了一级，看到 Library=639MB 但不知道在哪个子目录里；
        //     而 Caches 只有 31MB —— 说明视频缓存不在 Caches。
        NSArray<NSString *> *subs = [fm contentsOfDirectoryAtPath:lib error:NULL];
        for (NSString *name in subs) {
            NSString *p = [lib stringByAppendingPathComponent:name];
            BOOL sub = NO;
            [fm fileExistsAtPath:p isDirectory:&sub];
            if (!sub) continue;
            if ([name isEqualToString:@"Caches"]) continue;   // 上面已扫
            ProbeScanTree(p, [@"Library/" stringByAppendingString:name], 12);
        }

        // 2c) 全沙盒找最大的 40 个文件（只按体积，不看路径猜测）
        {
            NSMutableArray<NSDictionary *> *big = [NSMutableArray array];
            NSDirectoryEnumerator *e = [fm enumeratorAtPath:container];
            NSString *rel; NSUInteger scanned = 0;
            while ((rel = [e nextObject]) && scanned < 60000) {
                scanned++;
                NSDictionary *a = [e fileAttributes];
                if ([a[NSFileType] isEqual:NSFileTypeDirectory]) continue;
                unsigned long long sz = [a[NSFileSize] unsignedLongLongValue];
                if (sz < 256 * 1024) continue;               // 只看 >=256KB
                [big addObject:@{@"path": rel, @"bytes": @(sz),
                                 @"mtime": a[NSFileModificationDate] ?: [NSDate date]}];
            }
            [big sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
                return [y[@"bytes"] compare:x[@"bytes"]];
            }];
            NSMutableString *o = [NSMutableString string];
            [o appendFormat:@"===== 沙盒内最大文件 Top 40（>=256KB，扫了 %lu 个）=====\n",
                             (unsigned long)scanned];
            NSUInteger k = 0;
            for (NSDictionary *r in big) {
                if (k++ >= 40) break;
                [o appendFormat:@"  %12llu 字节  %@  （改于 %@）\n",
                 [r[@"bytes"] unsignedLongLongValue], r[@"path"],
                 r[@"mtime"]];
            }
            if (big.count == 0) [o appendString:@"  (没有 >=256KB 的文件)\n"];
            PLog(@"cache", @"%@", o);
        }

        // 2d) p2p_proxy.json 内容（判断 PCDN/MCDN 是否被启用）
        if (caches.length) {
            NSString *pj = [caches stringByAppendingPathComponent:@"p2p_config/p2p_proxy.json"];
            if ([fm fileExistsAtPath:pj]) {
                NSString *c = [NSString stringWithContentsOfFile:pj encoding:NSUTF8StringEncoding error:NULL];
                PLog(@"cache", @"p2p_proxy.json 内容：%@", [c substringToIndex:MIN((NSUInteger)600, c.length)]);
            }
        }
        // 3) Caches 再往下钻一层
        if (caches.length) {
            ProbeScanTree(caches, @"Caches 下各一级项", 25);
            for (NSString *name in [fm contentsOfDirectoryAtPath:caches error:NULL]) {
                NSString *p = [caches stringByAppendingPathComponent:name];
                BOOL sub = NO;
                [fm fileExistsAtPath:p isDirectory:&sub];
                if (sub) ProbeScanTree(p, [@"Caches/" stringByAppendingString:name], 15);
            }
        }
        // 4) Documents 也看一眼（部分实现把缓存放这）
        ProbeScanTree(doc, @"Documents 下各一级项", 15);

        PLog(@"cache", @"缓存盘点完成");
    }
}

//=== 2d. NSURLProtocol —— 我此前不该漏的一层 ==================================
// 承认失误：前几轮我刻意避开 NSURLProtocol，理由是"保持零行为改动"。
// 但真机证据是：用户点进竖屏视频刷了 90 秒，而 NSURLSession / NSURLRequest /
// AVAssetResourceLoader / BBRMediaDownloader / 预加载 **全部为零**。
// 那字节必然走了别处，而 NSURLProtocol 是覆盖面最广的一层：
//   * 任何经 NSURLSession / NSURLConnection 的请求都会先问 canInitWithRequest:
//   * 若 App 注册了自定义 protocol（二进制里确实存在 BFCFeVideoURLProtocol /
//     BFCFeFileURLProtocol / BWAFileURLProtocol / TXYHyURLProtocol），
//     请求会进它的 startLoading
// 纯观测：记录后立即原样转发，不做任何改写。
// 教训：在链路尚未定位之前，观测覆盖面的优先级高于"零改动的洁癖"。

static _Atomic(int32_t) gCntProtocolCanInit = 0;
static _Atomic(int32_t) gCntProtocolStart   = 0;
static _Atomic(int32_t) gCntConnection      = 0;

static IMP gOrigProtoCanInit   = NULL;
static IMP gOrigProtoStart     = NULL;
static IMP gOrigConnInit       = NULL;
static IMP gOrigAssetClassURL  = NULL;

static BOOL ProbeProtoCanInitWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    BOOL r = NO;
    if (gOrigProtoCanInit) {
        r = ((BOOL (*)(id, SEL, id))gOrigProtoCanInit)(self, _cmd, request);
    }
    // 只在"该 protocol 认领了这个请求"时记录，避免刷屏
    if (r && ProbeHostLooksLikeMedia(request.URL)) {
        ProbeBump(&gCntProtocolCanInit);
        PLog(@"protocol", @"★ %@ 认领了媒体请求 host=%@\n          URL=%.400@",
             NSStringFromClass([self class]), request.URL.host ?: @"?",
             request.URL.absoluteString ?: @"?");
    }
    return r;
}

static void ProbeProtoStartLoading(id self, SEL _cmd) {
    ProbeBump(&gCntProtocolStart);
    NSURLRequest *req = nil;
    @try { req = [self valueForKey:@"request"]; } @catch (__unused NSException *e) {}
    PLog(@"protocol", @"★ %@ startLoading host=%@\n          URL=%.400@",
         NSStringFromClass([self class]), req.URL.host ?: @"?",
         req.URL.absoluteString ?: @"?");
    if (gOrigProtoStart) {
        ((void (*)(id, SEL))gOrigProtoStart)(self, _cmd);
    }
}

static id ProbeConnInitWithRequest(id self, SEL _cmd, NSURLRequest *request,
                                   id delegate, BOOL startImmediately) {
    if (ProbeHostLooksLikeMedia(request.URL)) {
        ProbeBump(&gCntConnection);
        PLog(@"conn", @"NSURLConnection host=%@ URL=%.360@",
             request.URL.host ?: @"?", request.URL.absoluteString ?: @"?");
    }
    if (gOrigConnInit) {
        return ((id (*)(id, SEL, id, id, BOOL))gOrigConnInit)
            (self, _cmd, request, delegate, startImmediately);
    }
    return nil;
}

/// AVURLAsset 还有类方法构造这条路径（此前只钩了实例 init）
static id ProbeAssetClassWithURL(id self, SEL _cmd, NSURL *URL, NSDictionary *options) {
    ProbeBump(&gCntAssetInit);
    PLog(@"asset", @"AVURLAsset URLAssetWithURL scheme=%@ host=%@\n          URL=%.300@",
         URL.scheme ?: @"?", URL.host ?: @"?", URL.absoluteString ?: @"?");
    if (gOrigAssetClassURL) {
        return ((id (*)(id, SEL, id, id))gOrigAssetClassURL)(self, _cmd, URL, options);
    }
    return nil;
}

//=== 3d. 缓存路径 provider ====================================================
// 见 bootstrap ②h：动机是"找缓存写法"而非"找下载者"，
// 且这些方法**只涉及对象参数**，不存在把整数当对象的崩溃风险。

static _Atomic(int32_t) gCntDlWithUrl   = 0;
static _Atomic(int32_t) gCntSavedFolder = 0;

static IMP gOrigP2pConfigPath   = NULL;
static IMP gOrigSavedFolder     = NULL;
static IMP gOrigDownloadWithUrl = NULL;

static id ProbeP2pConfigPath(id self, SEL _cmd) {
    id r = nil;
    if (gOrigP2pConfigPath) {
        r = ((id (*)(id, SEL))gOrigP2pConfigPath)(self, _cmd);
    }
    PLog(@"path", @"IJKP2PServerResolver getAndCreateP2pConfigPath → %@", r ?: @"(nil)");
    return r;
}

static id ProbeSavedFolder(id self, SEL _cmd) {
    id r = nil;
    if (gOrigSavedFolder) {
        r = ((id (*)(id, SEL))gOrigSavedFolder)(self, _cmd);
    }
    ProbeBump(&gCntSavedFolder);
    PLog(@"path", @"★ BBPlayerInteractiveResourcePreload savedFolder → %@", r ?: @"(nil)");
    return r;
}

static void ProbeDownloadWithUrl(id self, SEL _cmd, id url, id savedPath, id relativePath) {
    ProbeBump(&gCntDlWithUrl);
    NSString *u = [url isKindOfClass:NSString.class] ? url :
                  ([url isKindOfClass:NSURL.class] ? [(NSURL *)url absoluteString] : [url description]);
    NSURL *nu = u.length ? [NSURL URLWithString:u] : nil;
    PLog(@"path", @"★★ downloadWithUrl ← 下载 + 落盘合流点\n"
                  @"     host = %@\n"
                  @"     url  = %.200@\n"
                  @"     savedPath    = %@\n"
                  @"     relativePath = %@",
         nu.host ?: @"?", u ?: @"(nil)", savedPath ?: @"(nil)", relativePath ?: @"(nil)");
    if (gOrigDownloadWithUrl) {
        ((void (*)(id, SEL, id, id, id))gOrigDownloadWithUrl)(self, _cmd, url, savedPath, relativePath);
    }
}

//=== 3. AVURLAsset ============================================================
// 刻意「不」hook AVURLAsset 的 initWithURL:options:。
// 原因：它是 initializer，交换实现后原实现会被挪到 probe 选择子上，
// 探针方法里既不能回调 _cmd（无限递归），也无法在不持有原 IMP 的情况下
// 正确构造返回值 —— 返回任何替代对象都会直接打断 App 创建播放资源。
// 而 delegate hook 里已经能拿到完整 URL，这里零收益、高风险，故不做。
// 若将来确需 AVURLAsset 的 URL，正确做法是用 class_addMethod + 保存原 IMP，
// 而不是 method_exchangeImplementations。

//=== 3. 运行时 Enumeration ====================================================
static BOOL ProbeIsOwnClass(NSString *name) {
    // 只看自有类：系统框架类量大且对我们无价值
    static NSArray<NSString *> *sysPrefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sysPrefixes = @[@"NS", @"UI", @"AV", @"CA", @"CF", @"_", @"Swift", @"OS_", @"WK", @"MK",
                        @"SK", @"CL", @"CN", @"MP", @"MTL", @"GC", @"PK", @"QL", @"RP", @"UN",
                        @"HK", @"HM", @"IN", @"JS", @"LA", @"MC", @"NE", @"NW", @"PH", @"SA",
                        @"SF", @"SL", @"TU", @"TV", @"VN", @"WC", @"AC", @"AD", @"AS", @"AU"];
    });
    for (NSString *p in sysPrefixes) {
        if ([name hasPrefix:p]) return NO;
    }
    return YES;
}

/// 枚举全部自有类，把命中关键词的类的完整方法表写文件（设备端定向 class-dump）
static void ProbeDumpClasses(void) {
    @autoreleasepool {
        int count = objc_getClassList(NULL, 0);
        if (count <= 0) { PLog(@"classes", @"objc_getClassList 返回 %d", count); return; }
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        if (!classes) return;
        count = objc_getClassList(classes, count);

        NSArray<NSString *> *keywords = @[@"Player", @"CDN", @"Cdn", @"URLProtocol", @"UrlProtocol",
                                          @"ResourceLoader", @"MediaPlayerItem", @"PlayItem",
                                          @"PlayUrl", @"PlayURL", @"Connector", @"BFCNet", @"BFCHttp",
                                          @"P2P", @"Mcdn", @"MCDN", @"Stream", @"Download"];
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"# BiliProbe 运行时类侦察\n# 时间 %@\n# 枚举类总数 %d\n"
                          "# 规则：仅记录类名命中关键词的自有类，列出全部实例方法 + 类方法\n\n",
                          [NSDate date], count];

        NSUInteger kept = 0;
        for (int i = 0; i < count && kept < kMaxClassDump; i++) {
            Class c = classes[i];
            const char *cn = class_getName(c);
            if (!cn) continue;
            NSString *name = @(cn);
            if (!ProbeIsOwnClass(name)) continue;

            BOOL hit = NO;
            for (NSString *k in keywords) {
                if ([name rangeOfString:k].location != NSNotFound) { hit = YES; break; }
            }
            if (!hit) continue;
            kept++;

            [out appendFormat:@"\n## %@\n", name];
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            for (unsigned int j = 0; j < mc; j++) {
                [out appendFormat:@"    - %@    %s\n",
                 NSStringFromSelector(method_getName(ms[j])),
                 method_getTypeEncoding(ms[j]) ?: "?"];
            }
            if (ms) free(ms);

            unsigned int mmc = 0;
            Method *mms = class_copyMethodList(object_getClass(c), &mmc);
            if (mmc) {
                [out appendString:@"    [+类方法]\n"];
                for (unsigned int j = 0; j < mmc; j++) {
                    [out appendFormat:@"    + %@\n", NSStringFromSelector(method_getName(mms[j]))];
                }
            }
            if (mms) free(mms);
        }
        free(classes);

        PLog(@"classes", @"类侦察完成：枚举 %d 个类，命中记录 %lu 个", count, (unsigned long)kept);
        ProbeWriteFile(kLogClasses, out);
    }
}

/// 定位 CDN 节点选择 / 注入点相关选择子落在哪个类（CDN 重定向的首选 hook 点）
static void ProbeFindCdnSelectors(void) {
    @autoreleasepool {
        NSArray<NSString *> *targets = @[@"_requestCDNNode", @"_checkCDNIp", @"_setCdnFirst",
                                         @"addCDNAddress", @"createCDNConnectionV2",
                                         @"_startCDNDownloadWithPlayItem", @"_downloadCDNDataWithFragment",
                                         @"_sendCDNRequestWithFragment", @"bfcURLProtocolInjectorTransferRequest",
                                         @"hitNewBackupExperiment", @"checkBestUposHost"];
        NSMutableString *out = [NSMutableString stringWithString:@"# 定向选择子定位（CDN / 注入点候选）\n"];

        int count = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        if (!classes) return;
        count = objc_getClassList(classes, count);

        for (int i = 0; i < count; i++) {
            Class c = classes[i];
            const char *cn = class_getName(c);
            if (!cn) continue;
            NSString *name = @(cn);
            if (!ProbeIsOwnClass(name)) continue;

            NSMutableArray<NSString *> *found = [NSMutableArray array];

            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            for (unsigned int j = 0; j < mc; j++) {
                NSString *sel = NSStringFromSelector(method_getName(ms[j]));
                for (NSString *t in targets) {
                    if ([sel hasPrefix:t]) {
                        [found addObject:[NSString stringWithFormat:@"    - %@    %s", sel,
                                          method_getTypeEncoding(ms[j]) ?: "?"]];
                        break;
                    }
                }
            }
            if (ms) free(ms);

            unsigned int mmc = 0;
            Method *mms = class_copyMethodList(object_getClass(c), &mmc);
            for (unsigned int j = 0; j < mmc; j++) {
                NSString *sel = NSStringFromSelector(method_getName(mms[j]));
                for (NSString *t in targets) {
                    if ([sel hasPrefix:t]) {
                        [found addObject:[NSString stringWithFormat:@"    + %@", sel]];
                        break;
                    }
                }
            }
            if (mms) free(mms);

            if (found.count) {
                [out appendFormat:@"\n## %@\n%@\n", name, [found componentsJoinedByString:@"\n"]];
                PLog(@"cdn", @"命中: %@ (%lu 个选择子)", name, (unsigned long)found.count);
            }
        }
        free(classes);
        ProbeWriteFile(kLogCdnSel, out);
    }
}

/// 找出所有实现 AVAssetResourceLoaderDelegate 的自有类（视频链路候选接管点）
static void ProbeFindResourceLoaderDelegates(void) {
    @autoreleasepool {
        Protocol *p = @protocol(AVAssetResourceLoaderDelegate);
        if (!p) { PLog(@"resloader", @"协议 AVAssetResourceLoaderDelegate 不存在"); return; }

        NSMutableString *out = [NSMutableString stringWithString:@"# 实现 AVAssetResourceLoaderDelegate 的自有类\n\n"];
        int count = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        if (!classes) return;
        count = objc_getClassList(classes, count);

        for (int i = 0; i < count; i++) {
            Class c = classes[i];
            const char *cn = class_getName(c);
            if (!cn) continue;
            NSString *name = @(cn);
            if (!ProbeIsOwnClass(name)) continue;
            if (class_conformsToProtocol(c, p)) {
                [out appendFormat:@"  %@\n", name];
                PLog(@"resloader", @"  ✔ 实现者: %@", name);
            }
        }
        free(classes);
        ProbeWriteFile(kLogResDeleg, out);
    }
}

//=== 4. 结论与心跳 ============================================================
// 教训（真机实测踩到）：第一版用 dispatch_source 定时器，结果**一次都没触发** ——
// 真机上约两分钟的会话里 [beat] 与 [verdict] 全部为 0。
// 具体原因无法在无设备条件下确证（可能是 App 进出后台时该队列上的定时器被挂起），
// 因此这里不再依赖单一机制，改成双保险：
//   ① 结论：侦察结束时在后台线程**立即**写一次（不依赖定时器）
//   ② 心跳：用 NSTimer 挂主 runloop 的 common modes 重复触发（iOS 上最常规的写法）
// 并且结论只写一次，避免重复。

static _Atomic(bool) gVerdictWritten = false;

/// 只负责输出结论文本，不关心是否已写过、也不改状态
static void ProbeEmitVerdict(NSString *phase) {
    int32_t hookClasses = ProbeRead(&gCntDelegateClassHooked);
    int32_t setDel      = ProbeRead(&gCntSetDelegate);
    int32_t waits       = ProbeRead(&gCntShouldWait);
    int32_t sessMedia   = ProbeRead(&gCntSessionMediaReq);
    int32_t reqBuilt    = ProbeRead(&gCntRequestConstructed);
    int32_t dlInit      = ProbeRead(&gCntMediaDownloaderInit);
    int32_t dlTask      = ProbeRead(&gCntMediaDownloadTask);
    int32_t assetInit   = ProbeRead(&gCntAssetInit);
    int32_t loaderCls   = ProbeRead(&gCntLoaderClass);
    int32_t preloads    = ProbeRead(&gCntPreloadCall);
    int32_t protos      = ProbeRead(&gCntProtocolCanInit);
    int32_t protoStarts = ProbeRead(&gCntProtocolStart);
    int32_t dlWithUrl   = ProbeRead(&gCntDlWithUrl);
    int32_t urlHooks    = ProbeRead(&gCntUrlHookFired);
    int32_t urlSeen     = ProbeRead(&gCntMediaUrlSeen);
    int32_t urlRewrote  = ProbeRead(&gCntMediaUrlRewrite);
    // 注：renewal / authChallenge / cancel 三个计数仍在采集（心跳里用得上），
    // 但结论行不再逐个列出 —— 上一版把它们留成了未使用变量，被 -Werror 拦下。

    PLog(@"verdict", @"=========== 结论 [%@] ===========", phase);
    PLog(@"verdict", @"计数：委托类=%d setDelegate=%d shouldWait=%d | NSURLSession=%d "
                     @"NSURLRequest=%d | 下载器init=%d 段级下载=%d | AVURLAsset=%d 加载器类=%d "
                     @"| 预加载=%d | URLProtocol=%d/%d | ★落盘=%d",
         hookClasses, setDel, waits, sessMedia, reqBuilt, dlInit, dlTask, assetInit, loaderCls,
         preloads, protos, protoStarts, dlWithUrl);
    PLog(@"verdict", @"阶段2/3：URL承载hook触发=%d 见到媒体URL=%d 已改写=%d", urlHooks, urlSeen, urlRewrote);
    PLog(@"verdict", @"%@", [[BSPProxyServer shared] throughputLine]);
    PLog(@"verdict", @"改写落点汇总：%@", ProbeRewriteSummary());

    // ── 播放正证据：不再靠推断「有没有在播」 ──
    PLog(@"verdict", @"播放正证据：播放器生命周期命中=%d 播放页出现=%d | 全网任务 resume=%d",
         ProbeRead(&gCntPlayerLifecycle), ProbeRead(&gCntPlayerVCAppear),
         ProbeRead(&gCntTaskResume));
    PLog(@"verdict", @"播放器当前状态：\n%@", ProbePlayerSnapshot());

    // ── 每个 hook 的命中次数：一眼看出哪些落点真的响了、哪些一次都没响 ──
    if (gUrlHookHits.count) {
        NSArray<NSString *> *keys = [gUrlHookHits.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                return [gUrlHookHits[b] compare:gUrlHookHits[a]];
            }];
        NSMutableString *t = [NSMutableString string];
        for (NSString *k in keys) {
            [t appendFormat:@"      %-72@ %@ 次\n", k, gUrlHookHits[k]];
        }
        PLog(@"verdict", @"各 hook 命中次数（%lu 个响过）：\n%@", (unsigned long)keys.count, t);
    } else {
        PLog(@"verdict", @"各 hook 命中次数：**一个都没响过**");
    }

    // ── 全网任务 host 直方图：看 App 到底在请求谁 ──
    if (gTaskHostHist.count) {
        NSArray<NSString *> *hosts = [gTaskHostHist.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                return [gTaskHostHist[b] compare:gTaskHostHist[a]];
            }];
        NSMutableString *h = [NSMutableString string];
        for (NSUInteger i = 0; i < hosts.count && i < 25; i++) {
            [h appendFormat:@"      %-46@ %@ 次\n", hosts[i], gTaskHostHist[hosts[i]]];
        }
        PLog(@"verdict", @"全网 NSURLSessionTask 目标 host Top%lu（共 %lu 个 host）：\n%@",
             (unsigned long)MIN(hosts.count, (NSUInteger)25), (unsigned long)hosts.count, h);
    }

    if (urlRewrote > 0) {
        PLog(@"verdict", @"★★★ 阶段 3 已生效！媒体 URL 已被改写进回环代理，"
                         @"播放器字节现在走本地并发抓取。CDN 分担情况：\n%@",
             [[BSPProxyServer shared] statsReport]);
    } else if (ProbeRead(&gCntPlayerLifecycle) == 0 && ProbeRead(&gCntTaskResume) < 5) {
        PLog(@"verdict", @"⚠ 播放器生命周期 0 次命中、全网任务也几乎为零 —— "
                         @"这**不能**说明「没播视频」（上一版我就是这么误判的）。"
                         @"它说明我的观测点没覆盖到实际链路，请以「播放器当前状态」那几行为准。");
    } else if (urlHooks > 0) {
        PLog(@"verdict", @"★★ URL 承载 hook 已被调用 %d 次，但没识别出 B 站媒体 URL —— "
                         @"说明调用链对了、URL 特征没匹配上（看 [rewrite]/[hook] 行）", urlHooks);
    } else if (dlWithUrl > 0) {
        PLog(@"verdict", @"★★★ 找到了！downloadWithUrl 命中 %d 次 —— "
                         @"这是「CDN URL + 落盘路径」的合流点，阶段 2/3 落点就是它"
                         @"（真实 host 见 [path] 行）", dlWithUrl);
    } else if (protoStarts > 0 || protos > 0) {
        PLog(@"verdict", @"★★ 找到了！NSURLProtocol 认领=%d 启动=%d", protos, protoStarts);
    } else if (dlTask > 0) {
        PLog(@"verdict", @"OK 已抓到视频段级下载（%d 次）→ 落点 BBRMediaDownloader", dlTask);
    } else if (preloads > 0) {
        PLog(@"verdict", @"★ 预加载在跑（%d 次）但无段级下载 → 视频是提前预下载的，"
                         @"落点应上移到预加载/下载层", preloads);
    } else if (hookClasses > 0 && waits > 0) {
        PLog(@"verdict", @"OK 视频数据经 AVAssetResourceLoaderDelegate（shouldWait=%d）", waits);
    } else {
        PLog(@"verdict", @"未命中 全部观测点仍为零（含 NSURLProtocol/NSURLConnection）。"
                         @"AVURLAsset=%d 预加载=%d —— 若确实在播视频，"
                         @"说明字节完全不经 URL 系 API，属真正的自研传输栈",
             assetInit, preloads);
    }
    PLog(@"verdict", @"=======================================");
}

/// phase: "启动即写，仅供参考" / "侦察完成" / "45 秒"
/// force: 是否无视「只写一次」的限制
static void ProbeWriteVerdict(NSString *phase, bool force) {
    if (force) {
        gVerdictWritten = true;
        ProbeEmitVerdict(phase);
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(&gVerdictWritten, &expected, true)) return;
    ProbeEmitVerdict(phase);
}


//=== 6. 环境 / 反调试自检 =====================================================
static void ProbeLogEnvironment(void) {
    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"BiliProbe 启动自检\n"];
        [s appendFormat:@"时间        : %@\n", [NSDate date]];
        [s appendFormat:@"设备        : %@\n", UIDevice.currentDevice.model];
        [s appendFormat:@"系统        : %@ %@\n", UIDevice.currentDevice.systemName,
                          UIDevice.currentDevice.systemVersion];
        [s appendFormat:@"PID         : %d\n", getpid()];
        [s appendFormat:@"可执行路径  : %@\n", NSBundle.mainBundle.executablePath];
        [s appendFormat:@"Bundle ID   : %@\n", NSBundle.mainBundle.bundleIdentifier];
        [s appendFormat:@"日志目录    : %@\n", gLogDir];

        [s appendString:@"\n--- DYLD / 调试相关环境变量 ---\n"];
        extern char **environ;
        int n = 0;
        for (char **ep = environ; ep && *ep; ep++) {
            NSString *kv = @(*ep);
            if ([kv hasPrefix:@"DYLD"] || [kv hasPrefix:@"MallocStackLogging"] ||
                [kv hasPrefix:@"NSUnbufferedIO"]) {
                [s appendFormat:@"  %@\n", kv];
                if (++n >= 15) break;
            }
        }
        if (n == 0) [s appendString:@"  (无)\n"];

        [s appendString:@"\n--- 越狱痕迹路径（只读探测）---\n"];
        NSArray *paths = @[@"/Applications/Cydia.app", @"/Library/MobileSubstrate/MobileSubstrate.dylib",
                           @"/usr/sbin/sshd", @"/etc/apt", @"/bin/bash", @"/usr/bin/ssh",
                           @"/User/Applications/", @"/var/lib/dpkg/status", @"/private/var/lib/apt"];
        for (NSString *p in paths) {
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:p];
            [s appendFormat:@"  %-56@ %@\n", p, exists ? @"存在 ⚠️" : @"不存在 ✔"];
        }

        [s appendString:@"\n--- 已加载镜像中的可疑模块 ---\n"];
        uint32_t imgCount = _dyld_image_count();
        int suspicious = 0;
        for (uint32_t i = 0; i < imgCount; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (!nm) continue;
            NSString *ip = @(nm);
            for (NSString *needle in @[@"Substrate", @"frida", @"cycript", @"BiliProbe", @"ellekit", @"TweakInject"]) {
                if ([ip rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [s appendFormat:@"  %@\n", ip];
                    suspicious++;
                    break;
                }
            }
        }
        if (!suspicious) [s appendString:@"  (无)\n"];
        [s appendFormat:@"\n已加载镜像总数: %u\n", imgCount];

        ProbeWriteFile(kLogEnv, s);
        PLog(@"env", @"自检完成：系统 %@ %@ / 镜像 %u 个",
             UIDevice.currentDevice.systemName, UIDevice.currentDevice.systemVersion, imgCount);
    }
}

//=== 5. 给 delegate 类挂观测点（真·只读：转发原实现并回传其真实返回值）===
// 关键点：绝不用 method_exchangeImplementations 配一个共享 C 函数来挂多个类。
// 若那样做，交换后该 C 函数的 IMP 会被多个类/选择子共用，
// 就无法按类区分「原实现是谁」，多个 delegate 类之间会互相串味。
//
// 正确做法（本函数采用）：把原 IMP 存进每类一张的方法表，再装一个
// 「回收站」方法，其实现里查表转发。这样：
//   * 每个类保有各自的原始 IMP，互不干扰
//   * 观测方法的返回值 = 原实现的返回值 → 探针零行为改动
//   * 原 IMP 不再挂在任何可达选择子上 → 查找表失败即 nil 调用，只会崩自己，
//     不会静默走错实现

/// 每类一张 <选择子名, 原 IMP> 表
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSValue *> *> *gOrigImps = nil;
static NSMutableSet<NSString *> *gHookedClasses = nil;
static NSString *const kProbeMethodNamePrefix = @"biliprobe_recycle_";

static void ProbeRegSet(NSString *cls, NSString *sel, IMP imp) {
    NSMutableDictionary *m = gOrigImps[cls];
    if (!m) { m = [NSMutableDictionary dictionary]; gOrigImps[cls] = m; }
    m[sel] = [NSValue valueWithPointer:imp];
}

static IMP ProbeRegGet(NSString *cls, NSString *sel) {
    return (IMP)[gOrigImps[cls][sel] pointerValue];
}

/// 取原 IMP（未挂过则 nil）
static IMP ProbeFetchOriginal(Class cls, SEL sel) {
    return ProbeRegGet(NSStringFromClass(cls), NSStringFromSelector(sel));
}

static void ProbeInstallOne(Class cls, SEL sel, NSString *tag) {
    NSString *clsName = NSStringFromClass(cls);
    NSString *selName = NSStringFromSelector(sel);

    // 原实现优先取「本类自己的」方法；取不到再退回 class_getInstanceMethod（含继承）。
    // 用 class_copyMethodList 判定本类是否自实现，避免误抓父类实现后
    // 把父类行为按子类名义记账（多 delegate 类场景下会串味）。
    IMP orig = NULL;
    unsigned int mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    for (unsigned int i = 0; i < mc; i++) {
        if (method_getName(ms[i]) == sel) { orig = method_getImplementation(ms[i]); break; }
    }
    if (ms) free(ms);

    Method m = class_getInstanceMethod(cls, sel);
    if (!orig) {
        if (!m) {
            PLog(@"hook", @"· %@ 未实现 %@（未参与 AVAssetResourceLoader 接管），跳过", clsName, selName);
            return;
        }
        orig = method_getImplementation(m);
    }

    // ★ 关键：必须先把「观测方法」登记成安装选择子（recycle）的实现。
    // 因为下面会把真实选择子的实现换成路由器，而路由器正是按 _cmd 查表转发；
    // 若表里存的是原实现，那条经过真实选择子的调用链就会绕过观测方法 —— 白挂。
    NSString *recycleName = [kProbeMethodNamePrefix stringByAppendingString:selName];
    SEL recycleSel = NSSelectorFromString(recycleName);
    Method recycleMethod = class_getInstanceMethod(cls, recycleSel);
    IMP observerImp = recycleMethod ? method_getImplementation(recycleMethod) : NULL;

    if (!observerImp) {
        PLog(@"hook", @"✗ %@ 上找不到观测方法 %@，跳过（探针自身缺陷，请回报）", clsName, recycleName);
        return;
    }

    // 原实现搬进回收站选择子，真实选择子指向路由器
    if (!recycleMethod) {
        class_addMethod(cls, recycleSel, orig, method_getTypeEncoding(m));
    } else {
        method_setImplementation(recycleMethod, orig);
    }
    method_setImplementation(m, (IMP)ProbeRecycledCall);

    // 表里存「观测方法」，供路由器二次转发到原实现
    ProbeRegSet(clsName, selName, observerImp);
    PLog(@"hook", @"✓ %@ :: %@ 已挂（观测=%@，原实现入回收站）", clsName, selName, recycleName);
}

+ (void)probe_installDelegateHooksOnClass:(Class)cls {
    if (!cls) return;
    NSString *key = NSStringFromClass(cls);
    if ([gHookedClasses containsObject:key]) return;
    [gHookedClasses addObject:key];
    ProbeBump(&gCntDelegateClassHooked);

    PLog(@"resloader", @"为 delegate %@ 安装只读观测点", key);

    ProbeInstallOne(cls, @selector(resourceLoader:shouldWaitForLoadingOfRequestedResource:), @"resloader");
    ProbeInstallOne(cls, @selector(resourceLoader:shouldWaitForRenewalOfRequestedResource:), @"resloader");
    ProbeInstallOne(cls, @selector(resourceLoader:shouldWaitForResponseToAuthenticationChallenge:), @"pinning");
    ProbeInstallOne(cls, @selector(resourceLoader:didCancelLoadingRequest:), @"resloader");

    // 顺便把这个 delegate 的完整方法表记下来 —— 后续要接管时按它写
    unsigned int mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < mc; i++) {
        [names addObject:NSStringFromSelector(method_getName(ms[i]))];
    }
    if (ms) free(ms);
    PLog(@"resloader", @"%@ 共 %u 个方法：%@", key, mc, [names componentsJoinedByString:@", "]);
}

/// 校验通过后，记录调用次数，便于判断"委托到底有没有被调用"。
/// 若真机上 trace.log 里一条 resloader 都没有，说明视频走的不是这条路。
+ (void)probe_noteRecycleMiss:(NSString *)clsName sel:(NSString *)selName {
    PLog(@"hook", @"✗ 回收站未登记 %@ :: %@ —— 查找表缺项（探针自身缺陷，请回报）", clsName, selName);
}

+ (void)bootstrap {
    @autoreleasepool {
        PLog(@"boot", @"================ BiliProbe 已加载 ================");
        // 版本自报：日志必须能自证是哪个构建产出的。
        // 起因：已经因"用户装的构建 ≠ 我以为的构建"白跑过两轮真机测试。
        PLog(@"boot", @"构建 SHA=%s  构建时间=%s  编译于 %s %s",
             PROBE_BUILD_SHA, PROBE_BUILD_TIME, __DATE__, __TIME__);
        PLog(@"boot", @"观测点清单：AVAssetResourceLoader / NSURLSession×2 / "
                      @"NSURLRequest×3 / BBRMediaDownloader×2");
        PLog(@"boot", @"主程序=%@ PID=%d", NSBundle.mainBundle.executablePath, getpid());

        ProbeLogEnvironment();

        // ① AVAssetResourceLoader：视频链路的咽喉
        Class rl = NSClassFromString(@"AVAssetResourceLoader");
        if (rl) {
            gOrigSetRLDelegate = ProbeReplaceMethod(rl, @selector(setDelegate:queue:),
                                                    (IMP)ProbeSetResourceLoaderDelegate, "v@:@@");
        } else {
            PLog(@"hook", @"✗ AVAssetResourceLoader 不在运行时");
        }

        // ② 备选观测点：NSURLSession 上的媒体请求（高度过滤，仅作兜底）
        Class sess = NSClassFromString(@"NSURLSession");
        if (sess) {
            gOrigDataTaskC = ProbeReplaceMethod(
                sess, @selector(dataTaskWithRequest:completionHandler:),
                (IMP)ProbeDataTaskWithRequestCompletion, "@@:@@@");
            gOrigDataTaskD = ProbeReplaceMethod(
                sess, @selector(dataTaskWithRequest:),
                (IMP)ProbeDataTaskWithRequest, "@@:@@");
        } else {
            PLog(@"hook", @"✗ NSURLSession 不在运行时（异常）");
        }

        // ②b 第三观测点：NSURLRequest 构造（更上游，能覆盖不经 NSURLSession 的路径）
        Class reqCls = NSClassFromString(@"NSURLRequest");
        if (reqCls) {
            // 三条独立的构造路径，各挂各的（注意：不能把同一个选择子换两次 ——
            // 第二次会覆盖第一次，而第一次抓到的"原 IMP"就变成了我们自己的函数，
            // 结果是无限递归。这是本次差点写错的地方，记下来。）
            gOrigReqInitURL = ProbeReplaceMethod(reqCls, @selector(initWithURL:),
                                                 (IMP)ProbeRequestInitWithURL, "@@:@@");
            // 字符串变体是**另一个**选择子。
            // 注意：这里必须把返回的原 IMP 存下来 —— 若漏掉，
            // ProbeRequestInitWithURLString 里的 gOrigReqInitURLString 会是 NULL，
            // 于是每次字符串构造都返回 nil，直接打断 App 建请求。
            gOrigReqInitURLString = ProbeReplaceMethod(reqCls, @selector(initWithURLString:),
                                                       (IMP)ProbeRequestInitWithURLString, "@@:@@");
            // 类方法构造
            gOrigReqClassURL = ProbeReplaceMethod(object_getClass(reqCls),
                                                  @selector(requestWithURL:),
                                                  (IMP)ProbeRequestClassWithURL, "@@:@@");
        } else {
            PLog(@"hook", @"✗ NSURLRequest 不在运行时（异常）");
        }

        // ②d 证明播放器是否使用 AVPlayer 系，并拿到 resourceLoader 的真实类
        //     （用于排除"没钩到私有子类"这个盲区）
        Class auCls = NSClassFromString(@"AVURLAsset");
        if (auCls) {
            gOrigAssetInitURL = ProbeReplaceMethod(auCls, @selector(initWithURL:options:),
                                                   (IMP)ProbeAssetInitURL, "@@:@@");
            gOrigAssetLoaderGet = ProbeReplaceMethod(auCls, @selector(resourceLoader),
                                                     (IMP)ProbeAssetLoaderGetter, "@@:");
        } else {
            PLog(@"hook", @"✗ AVURLAsset 不在运行时");
        }

        // ②e 预加载（若视频是提前下好的，网络层 hook 永远不会触发）
        Class plCls = NSClassFromString(@"BBPlayerPreload");
        if (plCls) {
            gOrigPreloadItems = ProbeReplaceMethod(plCls, @selector(preloadItems:unite:),
                                                   (IMP)ProbePreloadItems, "v@:@@B");
        } else {
            PLog(@"hook", @"· BBPlayerPreload 不在运行时");
        }
        // 缓存盘点延后 3 秒，等 App 初始化写入完毕
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            ProbeDumpCaches();
        });

        // ②f NSURLProtocol / NSURLConnection / AVURLAsset 类方法
        //     覆盖面最广的一层，此前被我以"保持零行为改动"为由跳过了
        Class protoCls = NSClassFromString(@"NSURLProtocol");
        if (protoCls) {
            gOrigProtoCanInit = ProbeReplaceMethod(protoCls, @selector(canInitWithRequest:),
                                                   (IMP)ProbeProtoCanInitWithRequest, "B@:@@");
            gOrigProtoStart = ProbeReplaceMethod(protoCls, @selector(startLoading),
                                                 (IMP)ProbeProtoStartLoading, "v@:");
        } else {
            PLog(@"hook", @"✗ NSURLProtocol 不在运行时（异常）");
        }
        Class connCls = NSClassFromString(@"NSURLConnection");
        if (connCls) {
            gOrigConnInit = ProbeReplaceMethod(connCls,
                                               @selector(initWithRequest:delegate:startImmediately:),
                                               (IMP)ProbeConnInitWithRequest, "@@:@@@B");
        }
        if (auCls) {
            gOrigAssetClassURL = ProbeReplaceMethod(object_getClass(auCls),
                                                    @selector(URLAssetWithURL:options:),
                                                    (IMP)ProbeAssetClassWithURL, "@@:@@");
        }
        // 列出运行时里所有 NSURLProtocol 子类 —— 直接看 App 注册了哪些自定义协议
        {
            int n = objc_getClassList(NULL, 0);
            Class *cs = (Class *)malloc(sizeof(Class) * (size_t)n);
            if (cs) {
                n = objc_getClassList(cs, n);
                NSMutableArray<NSString *> *subs = [NSMutableArray array];
                Class base = NSClassFromString(@"NSURLProtocol");
                for (int i = 0; i < n; i++) {
                    Class c = cs[i];
                    if (c == base) continue;
                    Class s = class_getSuperclass(c);
                    while (s) { if (s == base) { [subs addObject:NSStringFromClass(c)]; break; } s = class_getSuperclass(s); }
                }
                free(cs);
                PLog(@"hook", @"运行时 NSURLProtocol 子类 %lu 个：%@",
                     (unsigned long)subs.count,
                     subs.count ? [subs componentsJoinedByString:@", "] : @"(无)");
            }
        }

        // ②h 缓存路径 provider（换思路定位落点，且结构上不可能崩）
        //
        // 为什么换思路：前七次真机都在找"谁在下载视频字节"，全部网络层观测点为零。
        // 而缓存盘点证明字节**确实落到本地**：
        //   Library/Application Support  595 MB / 13,171 文件
        //   tmp/dash_cache               3.8 MB / 10 文件
        //   tmp/ijkvideo、tmp/p2p_cache  均为 0（P2P 未启用）
        // 所以更可靠的切入点是"缓存文件写在哪、谁提供这个路径"。
        //
        // 安全性论证（这是选它的关键理由）：
        //   这批方法只接收/返回**对象**（路径字符串），参数个数固定，
        //   **不存在"把整数当对象"的风险** —— 那正是上一个包一启动就闪退的原因。
        //   因此即使我对签名的理解有偏差，也不会像多参数 C 函数那样读错寄存器
        //   并对垃圾指针 objc_retain。
        //
        // 其中 downloadWithUrl:savedPath:relativePath: 最关键：
        //   它同时给出 **CDN URL 与落盘路径**，是"下载 + 落盘"的合流点。
        {
            Class p2pSrv = NSClassFromString(@"IJKP2PServerResolver");
            if (p2pSrv) {
                gOrigP2pConfigPath = ProbeReplaceMethod(
                    p2pSrv, @selector(getAndCreateP2pConfigPath),
                    (IMP)ProbeP2pConfigPath, "@@:");
                PLog(@"hook", @"✓ 已挂 IJKP2PServerResolver :: getAndCreateP2pConfigPath");
            } else {
                PLog(@"hook", @"· IJKP2PServerResolver 不在运行时");
            }

            Class pre = NSClassFromString(@"BBPlayerInteractiveResourcePreload");
            if (pre) {
                // savedFolder 是类方法
                gOrigSavedFolder = ProbeReplaceMethod(
                    object_getClass(pre), @selector(savedFolder),
                    (IMP)ProbeSavedFolder, "@@:");
                gOrigDownloadWithUrl = ProbeReplaceMethod(
                    pre, @selector(downloadWithUrl:savedPath:relativePath:),
                    (IMP)ProbeDownloadWithUrl, "v@:@@@");
                PLog(@"hook", @"✓ 已挂 BBPlayerInteractiveResourcePreload :: savedFolder / "
                              @"downloadWithUrl:savedPath:relativePath:");
            } else {
                PLog(@"hook", @"· BBPlayerInteractiveResourcePreload 不在运行时");
            }
        }

        // ②g IJK 播放链路
        //
        // ⚠️ 重要决策（记录原因，避免以后又"顺手加回来"）：
        //   下面三个 hook 的 type encoding 是我**从 class dump 推的**，
        //   无法确认真实值（二进制里是 arm64e 打包的相对 method list，解析未成功）。
        //   而 class_replaceMethod 的 types 只是元数据、**不校验实现** ——
        //   若真实签名与假设不同（例如某参数其实是对象而非 int），
        //   我的 C 函数会按错误方式读参数并对垃圾指针 objc_retain → 崩溃。
        //   这些类在 t=0 就被 hook，一旦 IJK 在启动期初始化即可导致**一启动就闪退**
        //   —— 这正是上一个包发生的事（那次是 performSelector 取整数当对象）。
        //
        //   因此这里**只做安全的类存在性探测，不替换任何方法**。
        //   落点已经由静态分析确定（IJKDashStreamItem.baseUrl / backupUrl0/1），
        //   后续实现阶段会先拿到真实 type encoding（在真机上用 method_getTypeEncoding
        //   打印一次即可，或修正二进制解析），再挂 hook。
        for (NSString *cn in @[@"IJKDashStreamItem", @"IJKMediaPlayerItem",
                               @"IJKMediaPlayerWrapper", @"IJKFFMoviePlayerController",
                               @"IJKFFMoviePlayerControllerAVPlayer", @"IJKP2PManager",
                               @"IJKP2PGRPCClient", @"IJKDashStreamBridge"]) {
            Class c = NSClassFromString(cn);
            PLog(@"hook", @"· %@ %@", cn, c ? @"存在" : @"不在运行时");
        }
        Class p2pMgr = NSClassFromString(@"IJKP2PManager");
        if (p2pMgr) {
            BOOL responds = [p2pMgr respondsToSelector:NSSelectorFromString(@"getHttpServerPort")];
            PLog(@"hook", @"· IJKP2PManager 响应 getHttpServerPort=%@"
                          @"（响应即说明有本地 HTTP 服务；刻意不取数值，签名未知）",
                 responds ? @"YES" : @"NO");
        }

        // ②c 视频字节下载器（若走 BBRMediaDownloader 这条路）
        Class dlCls = NSClassFromString(@"BBRMediaDownloader");
        if (dlCls) {
            gOrigDLInitURL = ProbeReplaceMethod(dlCls, @selector(initWithURL:cacheWorker:),
                                                (IMP)ProbeDLInitWithURL, "@@:@@@");
            gOrigDLTask = ProbeReplaceMethod(dlCls, @selector(downloadTaskFromOffset:length:toEnd:),
                                             (IMP)ProbeDLTaskFromOffset, "v@:QQB");
        } else {
            PLog(@"hook", @"✗ BBRMediaDownloader 不在运行时（可能尚未初始化）");
        }
        // P2P 分支：若视频走 P2P，则上面那个下载器不会触发
        Class p2pCls = NSClassFromString(@"BGMFragmentP2pDownloader2");
        if (p2pCls) {
            PLog(@"hook", @"· BGMFragmentP2pDownloader2 存在（P2P 分支可用，若 mediadl 计数为 0 则视频走它）");
        } else {
            PLog(@"hook", @"· BGMFragmentP2pDownloader2 不在运行时");
        }

        // ③ 阶段 0：播放正证据 + 全网观测。必须最先装 ——
        //    它决定了后面那些结论到底能不能被信任。
        //    每装完一段就**同步**写一行日志：万一某一步把 App 搞崩，
        //    真机上至少留下「崩在哪一段」的痕迹，而不是什么都没有。
        PLogSync(@"hook", @"[install] 开始安装阶段 0（正证据 + 全网观测）");
        @try {
            [self probe_installPositiveControls];
            PLogSync(@"hook", @"[install] 阶段 0 完成");
        } @catch (NSException *ex) {
            PLogSync(@"hook", @"★★★ 阶段 0 抛异常：%@ — %@", ex.name, ex.reason);
        }

        // ④ 阶段 2/3：回环代理 + URL 改写 hook。
        //    放在这里（而不是延后）的原因：IJK 播放内核与 DASH 分片对象可能在
        //    用户点开视频前就被初始化，hook 必须尽早装。
        PLogSync(@"hook", @"[install] 开始安装阶段 2/3（代理 + URL 改写）");
        @try {
            [self probe_installStage23];
            PLogSync(@"hook", @"[install] 阶段 2/3 完成 —— 安装阶段全部走完，未崩溃");
        } @catch (NSException *ex) {
            PLogSync(@"hook", @"★★★ 阶段 2/3 抛异常：%@ — %@", ex.name, ex.reason);
        }

        // ⑤ 重型枚举延后 2 秒：此时主程序初始化基本完成，类注册更全，
        //    且不占用冷启动路径
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                PLog(@"scan", @"开始运行时侦察…");
                ProbeFindResourceLoaderDelegates();
                ProbeFindCdnSelectors();
                ProbeDumpClasses();
                PLog(@"scan", @"运行时侦察完成。日志目录：%@", gLogDir);
                // 侦察完**强制**写一份结论（覆盖启动时那份）：
                // 此时类枚举已完成，「已挂委托类」等计数若仍为 0，
                // 就能确定性地判定视频没有走 AVAssetResourceLoader
                ProbeWriteVerdict(@"侦察完成", true);
            }
        });

        PLog(@"boot", @"探针安装完毕，等待播放器触发…");

        // ---- 心跳 + 结论 ----
        // 目的：把「注入失败」「hook 没被调用」「一切正常」三种情况区分开。
        //
        // 真机实测教训：第一版用 dispatch_source 定时器，在两分钟会话里
        // **一次都没触发**（[beat]/[verdict] 全为 0），而日志其他部分正常，
        // 说明不是写盘问题而是定时器没跑。故改为双保险：
        //   ① 不依赖定时器：启动时、侦察结束时各强制写一份结论
        //   ② 心跳改 NSTimer 挂主 runloop 的 common modes —— iOS 上最常规的写法

        __block int beats = 0;
        NSTimer *beatTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                             repeats:YES
                                                               block:^(NSTimer *t) {
            @autoreleasepool {
                beats++;
                PLog(@"beat", @"第 %d 次心跳（约 %d 秒）| 委托类=%d setDelegate=%d "
                              @"shouldWait=%d | NSURLSession=%d NSURLRequest=%d | "
                              @"下载器=%d 段级下载=%d | 预加载=%d | URLProtocol=%d/%d | ★落盘=%d "
                              @"| 代理请求=%lu 改写=%d",
                     beats, beats * 15,
                     ProbeRead(&gCntDelegateClassHooked), ProbeRead(&gCntSetDelegate),
                     ProbeRead(&gCntShouldWait),
                     ProbeRead(&gCntSessionMediaReq), ProbeRead(&gCntRequestConstructed),
                     ProbeRead(&gCntMediaDownloaderInit), ProbeRead(&gCntMediaDownloadTask),
                     ProbeRead(&gCntPreloadCall),
                     ProbeRead(&gCntProtocolCanInit), ProbeRead(&gCntProtocolStart),
                     ProbeRead(&gCntDlWithUrl),
                     (unsigned long)[BSPProxyServer shared].totalRequests,
                     ProbeRead(&gCntMediaUrlRewrite));
                // 每次心跳都把「播放器自己报的状态」打出来。
                // 这是整份日志里唯一能证明「确实在播」的东西，不能只在结论里出现一次。
                PLog(@"beat", @"  播放正证据：生命周期=%d 播放页=%d 全网任务=%d\n%@",
                     ProbeRead(&gCntPlayerLifecycle), ProbeRead(&gCntPlayerVCAppear),
                     ProbeRead(&gCntTaskResume), ProbePlayerSnapshot());
                // 代理吞吐逐次心跳打一行：这是判断「到底有没有变快」的唯一量化依据。
                PLog(@"beat", @"  %@", [[BSPProxyServer shared] throughputLine]);

                // 第 3 次心跳（约 45 秒）补写一次结论：此时用户多半已播放过视频
                if (beats == 3) ProbeWriteVerdict(@"45 秒", true);
            }
        }];
        // 加进 common modes，避免滚动/拖拽时主 runloop 切模式导致定时器停摆
        [[NSRunLoop mainRunLoop] addTimer:beatTimer forMode:NSRunLoopCommonModes];
        PLog(@"boot", @"心跳已启动：每 15 秒一次；侦察结束时与 45 秒后各强制写一份结论");

        // 最后写一份「启动态」结论。放在心跳启动之后，日志顺序读起来才顺。
        // 这份只是保底（此时必然还没播放），信息量在侦察完成那份与 45 秒那份。
        ProbeWriteVerdict(@"启动即写（此时尚未播放，仅供参考）", true);
    }
}

//=== 7. 阶段 2/3：CDN 重定向 + 并发分段 ======================================
//
// 之前七次真机都没抓到视频字节经过 NSURL 系 API，因为 IJK 是自研 FFmpeg 内核，
// 走自己的 socket。所以唯一能同时掌握「URL」和「字节」的位置，就是
// **把播放器要打开的 CDN URL 换成回环代理地址，让播放器自己连过来**。
//
// 本版新增两件事：
//   A. 一套「按运行时真实 type encoding 安装」的安全 hook（BSPDynamicHook）。
//      之前的崩溃正是因为 class_replaceMethod 的 types 只是元数据、不校验实现，
//      签名猜错就会按错误布局读参数。现在 encoding 由真机 classes.txt 给出，
//      且安装前会用 expectShapes 再校验一次参数形状，不符就拒绝安装。
//   B. 回环 HTTP 代理（BSPProxyServer）：把 Range 切成 256 KiB 分片，
//      按「实测速度 + 在途数」评分并发派发到多个 CDN host，按序写回；
//      3 次失败的节点拉黑；首片超时或全挂则 302 回源（fail-open）。
//      （曾尝试「每主机令牌桶 + AIMD 自适应」，但它会因为我们主动对一台 CDN
//        并发多分片、单分片实测速率偏低而误判「这台慢」并下调上限，自锁成瓶颈。
//        现在每主机不限速，靠评分里的 load_factor 自然摊开，见 BSPProxyServer.m。）
//
// 关闭开关：往 {Documents}/biliprobe/mode.txt 写 direct 即可完全不改写。

typedef NS_ENUM(NSInteger, BSPUrlArgMode) {
    BSPUrlArgIn    = 0,   // 改参数（第 argIndex 个，0=self 1=_cmd）
    BSPUrlArgOut   = 1,   // 改返回值（after 阶段）
    BSPUrlArgWatch = 2,   // 只看不改
};

static void ProbeBumpHookHit(NSString *key) {
    @synchronized (gUrlHookHits) {
        NSNumber *n = gUrlHookHits[key];
        gUrlHookHits[key] = @(n.integerValue + 1);
    }
}

//------------------------------------------------------------------------------
#pragma mark - 直连观测：NSURLSessionTask.resume
//------------------------------------------------------------------------------
// 签名 v16@0:8（零参数），所以 void f(id, SEL) 是**严格对应**的，不存在读错
// 寄存器的问题 —— 这与之前那次「猜签名」的崩溃有本质区别。
// 用直连而不是转发，是因为 NSURLSessionTask 是系统 class cluster，
// 转发链会被具体类（__NSCFURLSessionTask）遮住并导致崩溃（真机已复现）。
static void (*gOrigTaskResume)(id, SEL) = NULL;

static void ProbeTaskResume(id self, SEL _cmd) {
    @autoreleasepool {
        NSURLRequest *r = nil;
        if ([self respondsToSelector:@selector(originalRequest)]) r = [self originalRequest];
        if ([r isKindOfClass:NSURLRequest.class] && !ProbeIsOurProxyUpstream(r)) {
            NSString *host = r.URL.host.lowercaseString ?: @"(无host)";
            ProbeBump(&gCntTaskResume);
            @synchronized (gTaskHostHist) {
                gTaskHostHist[host] = @([gTaskHostHist[host] integerValue] + 1);
            }
            if (ProbeHostLooksLikeMedia(r.URL)) {
                PLog(@"session", @"★ 任务 resume 命中媒体 host=%@ method=%@ range=%@\n          URL=%.300@",
                     host, r.HTTPMethod ?: @"?", [r valueForHTTPHeaderField:@"Range"] ?: @"(无)",
                     r.URL.absoluteString ?: @"?");
            }
        }
    }
    if (gOrigTaskResume) gOrigTaskResume(self, _cmd);
}

/// 改写日志去重：同一条 URL 只详细打一次，之后只计数。
/// 真机日志里 62 条改写塞满了带签名的完整 URL（每条 400+ 字符），
/// 把「代理跑了多少、多快」这类关键信息全淹了 —— 这是上一版最影响判读的问题。
static NSMutableSet        *gRewriteLogged = nil;
static NSMutableDictionary *gRewriteCounts = nil;

static void ProbeLogRewrite(NSString *tag, NSString *hookKey, NSString *label, NSString *orig)
{
    if (!gRewriteLogged) gRewriteLogged = [NSMutableSet set];
    if (!gRewriteCounts) gRewriteCounts = [NSMutableDictionary dictionary];
    @synchronized (gRewriteLogged) {
        NSNumber *n = gRewriteCounts[hookKey];
        gRewriteCounts[hookKey] = @(n.integerValue + 1);
        if ([gRewriteLogged containsObject:orig]) return;
        [gRewriteLogged addObject:orig];
        // %@ 不支持精度修饰符（-Wformat 会报 error），先自己截断
        {
            NSString *brief = orig.length > 70 ? [[orig substringToIndex:70] stringByAppendingString:@"…"] : orig;
            PLog(@"rewrite", @"★ [%@] %@ 改写主机 %@ → 127.0.0.1:%u（%@）",
                 label, hookKey, [BSPCdnPool hostOf:orig] ?: @"?",
                 (unsigned)[BSPProxyServer shared].port, brief);
        }
    }
}

/// 改写落点汇总，写进结论段：哪个落点命中多少次一目了然
static NSString *ProbeRewriteSummary(void)
{
    NSMutableString *s;
    NSArray *keys;
    if (!gRewriteCounts.count) return @"（还没有任何改写）";
    keys = [gRewriteCounts.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [gRewriteCounts[b] compare:gRewriteCounts[a]];
    }];
    s = [NSMutableString string];
    for (NSString *k in keys) {
        [s appendFormat:@"\n      %-64@ %@ 次", k, gRewriteCounts[k]];
    }
    return s;
}

/// 改写返回值时的保命池。
/// NSInvocation **不会** retain 返回值，而 ARC 会在 after 块作用域结束时释放局部
/// 强引用 —— 那样调用方拿到的是野指针，一用就崩。这里用一个有上限的强引用池
/// 把对象兜住，直到调用方确实取走。
static NSMutableArray *gReturnKeepAlive = nil;
static void ProbeKeepReturnAlive(id obj) {
    static const NSUInteger kCap = 256;
    if (!obj) return;
    if (!gReturnKeepAlive) gReturnKeepAlive = [NSMutableArray array];
    @synchronized (gReturnKeepAlive) {
        [gReturnKeepAlive addObject:obj];
        while (gReturnKeepAlive.count > kCap) [gReturnKeepAlive removeObjectAtIndex:0];
    }
}

//------------------------------------------------------------------------------
#pragma mark - hook 分组开关
//------------------------------------------------------------------------------
// {Documents}/biliprobe/hooks.txt，每行 "组名=on|off"（# 开头为注释）。
// 组名：player（播放器生命周期/正证据）、url（URL 改写）、net（系统网络类）。
//
// 为什么要这个：真机一打开就闪退时，唯一能做的就是**二分**。有了这个文件，
// 你不用等我重新出包，自己把可疑的那组改成 off 再启动一次就能定位。
//
// 缺省值：player=on url=on net=off。
//   net 默认为 off 是有意的 —— 它挂的是 NSURLSessionTask.resume 这种
//   系统类、启动瞬间就会被大量调用的选择子，是「一打开就崩」的头号嫌疑。
//   而 player / url 才是我们真正需要的数据，先保证 App 能起来。
static BOOL ProbeGroupEnabled(NSString *group) {
    static NSMutableDictionary<NSString *, NSNumber *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                 @YES, @"player", @YES, @"url", @NO, @"net", nil];
        NSString *path = [[BSPProxyServer logDir] stringByAppendingPathComponent:@"hooks.txt"];
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding error:NULL];
        if (text.length) {
            for (NSString *raw in [text componentsSeparatedByCharactersInSet:
                                   [NSCharacterSet newlineCharacterSet]]) {
                NSString *line = [raw stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceCharacterSet]];
                NSRange eq;
                if (!line.length || [line hasPrefix:@"#"]) continue;
                eq = [line rangeOfString:@"="];
                if (eq.location == NSNotFound) continue;
                {
                    NSString *k = [[line substringToIndex:eq.location] lowercaseString];
                    NSString *v = [[line substringFromIndex:NSMaxRange(eq)] lowercaseString];
                    cache[k] = @([v hasPrefix:@"on"] || [v hasPrefix:@"1"] || [v hasPrefix:@"yes"]);
                }
            }
        }
    });
    NSNumber *n = cache[group];
    return n ? n.boolValue : YES;
}

static NSString *ProbeGroupsDescription(void) {
    return [NSString stringWithFormat:@"player=%@ url=%@ net=%@",
            ProbeGroupEnabled(@"player") ? @"on" : @"off",
            ProbeGroupEnabled(@"url")    ? @"on" : @"off",
            ProbeGroupEnabled(@"net")    ? @"on" : @"off"];
}

//------------------------------------------------------------------------------
#pragma mark - hook 机制自检
//------------------------------------------------------------------------------
// 这个自检是拿两次真机事故换来的，务必保留：
//
// 事故一：encoding 解析器把「大小/偏移」数字当成类型字符 -> 所有 hook 被自己的
//         形状校验拒绝 -> 整个包空转，日志只剩一片 ✗。
// 事故二：装上第一个转发 hook 时会**自己**给类加 forwardInvocation:，第二个 hook
//         的「类自带 forwardInvocation:」检查把**我们自己加的那个**误判成冲突 ->
//         每个类只能装上第一个 hook（22 个 URL hook 只装上 4 个）。
//
// 两个事故的共同点：安装逻辑本身坏了，而日志只显示「没装上」，看不出为什么。
// 所以在装真实 hook 之前，先在一个临时类上把整条链路跑通：
//   ① 同一个类连挂两个 hook —— 必须都成功（覆盖事故二）
//   ② 真的给这个类发一次消息 —— 必须能正常走到原实现（覆盖转发链路本身）
// 任一项失败就大声喊出来。

static NSInteger gSelfTestHits = 0;
static void bspSelfTestNoop(id self, SEL _cmd) { (void)self; (void)_cmd; gSelfTestHits++; }

static BOOL ProbeHookSelfTest(void) {
    Class scratch = objc_allocateClassPair([NSObject class], "BSPHookSelfTestClass", 0);
    BOOL a = NO, b = NO, invoked = NO;
    if (!scratch) {
        PLogSync(@"hook", @"★★★ hook 自检失败：无法创建临时类，请把日志发回");
        return NO;
    }
    class_addMethod(scratch, NSSelectorFromString(@"bspSelfTest1"), (IMP)bspSelfTestNoop, "v@:");
    class_addMethod(scratch, NSSelectorFromString(@"bspSelfTest2"), (IMP)bspSelfTestNoop, "v@:");
    objc_registerClassPair(scratch);

    a = [BSPDynamicHook hookClass:@"BSPHookSelfTestClass" selector:@"bspSelfTest1"
                     expectShapes:@"" before:nil after:nil];
    b = [BSPDynamicHook hookClass:@"BSPHookSelfTestClass" selector:@"bspSelfTest2"
                     expectShapes:@"" before:nil after:nil];

    if (a && b) {
        // 真发一次消息：走 _objc_msgForward -> forwardInvocation: -> invokeUsingIMP:
        // 这一条要是崩了，说明转发链路本身不可用 —— 那比「没装上」严重得多，
        // 而且现在就能发现，不用等真正播放时才发现。
        id obj = [[scratch alloc] init];
        gSelfTestHits = 0;
        @try {
            ((void (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(@"bspSelfTest1"));
            ((void (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(@"bspSelfTest2"));
            invoked = (gSelfTestHits == 2);
        } @catch (NSException *ex) {
            PLogSync(@"hook", @"★★★ hook 自检：调用被 hook 的方法抛异常 %@ — %@", ex.name, ex.reason);
        }
    }

    PLogSync(@"hook", @"%@ hook 机制自检：同类双挂=%s/%s 转发调用=%s",
             (a && b && invoked) ? @"✓" : @"★★★ 失败",
             a ? "✓" : "✗", b ? "✓" : "✗", invoked ? "✓" : "✗");
    if (!(a && b && invoked)) {
        PLogSync(@"hook", @"★★★ hook 机制自检失败 —— 真实 hook 很可能大面积装不上或转发不可用，"
                          @"请把整份日志发回，不要继续测播放。");
    }
    return a && b && invoked;
}

/// 把 inv 里第 idx 个参数（或返回值）取出字符串表示
static NSString *ProbeStringFromArg(NSInvocation *inv, NSUInteger idx, BOOL isReturn) {
    __unsafe_unretained id obj = nil;
    @try {
        if (isReturn) {
            const char *rt = inv.methodSignature.methodReturnType;
            if (!rt || strcmp(rt, "@") != 0) return nil;
            [inv getReturnValue:&obj];
        } else {
            [inv getArgument:&obj atIndex:idx];
        }
    } @catch (__unused NSException *ex) { return nil; }

    if ([obj isKindOfClass:NSString.class])  return obj;
    if ([obj isKindOfClass:NSURL.class])     return [(NSURL *)obj absoluteString];
    return nil;
}

/// 「这个落点收到的参数不是字符串」—— 只记第一次，把真实类型/内容 dump 出来。
/// 上一版 willOpenUrl: 命中 2 次却毫无输出，就是缺了这一条。
static void ProbeDescribeUnhandledArg(NSInvocation *inv, NSUInteger idx,
                                      NSString *hookKey, NSString *label)
{
    static NSMutableSet *seen = nil;
    __unsafe_unretained id obj = nil;
    if (!seen) seen = [NSMutableSet set];
    @synchronized (seen) {
        if ([seen containsObject:hookKey]) return;
        [seen addObject:hookKey];
    }
    @try { [inv getArgument:&obj atIndex:idx]; } @catch (__unused NSException *ex) { obj = nil; }

    if (!obj) {
        PLog(@"rewrite", @"· [%@] %@ 收到了 nil（无可改写）", label, hookKey);
        return;
    }
    if ([obj isKindOfClass:NSArray.class]) {
        NSArray *a = obj;
        NSMutableString *d = [NSMutableString string];
        for (NSUInteger i = 0; i < a.count && i < 6; i++) {
            // 注意：%@ 不支持精度修饰符（appendFormat: 有格式检查，会报 -Wformat error），
            // 这里自己截断。PLog 那边没做格式注解所以 %.400@ 能过，但同样不规范。
            NSString *desc = [a[i] description] ?: @"";
            if (desc.length > 160) desc = [[desc substringToIndex:160] stringByAppendingString:@"…"];
            [d appendFormat:@"\n        [%lu] <%@> %@", (unsigned long)i,
             NSStringFromClass([a[i] class]), desc];
        }
        PLog(@"rewrite", @"· [%@] %@ 收到的是数组（%lu 项），不是 URL：%@",
             label, hookKey, (unsigned long)a.count, d);
        return;
    }
    {
        NSString *desc = [obj description] ?: @"";
        if (desc.length > 240) desc = [[desc substringToIndex:240] stringByAppendingString:@"…"];
        PLog(@"rewrite", @"· [%@] %@ 收到的是 <%@>，不是 URL：%@",
             label, hookKey, NSStringFromClass([obj class]), desc);
    }
}

/// 若字符串是 B 站媒体 URL，返回应替换成的等价对象（保持原类型）
static id ProbeRewriteIfMedia(NSString *s, id original, NSString **outOriginal) {    NSString *local;
    if (![BSPCdnPool isMediaURL:s]) return nil;

    ProbeBump(&gCntMediaUrlSeen);
    if (outOriginal) *outOriginal = s;

    if (![BSPProxyServer rewriteEnabled]) return nil;
    local = [[BSPProxyServer shared] localURLFor:s];
    if (!local) return nil;

    ProbeBump(&gCntMediaUrlRewrite);
    if ([original isKindOfClass:NSURL.class]) return [NSURL URLWithString:local];
    return local;
}

/// 给一个「承载媒体 URL 的方法」装改写 hook。
/// shapes 来自真机 classes.txt 的 method_getTypeEncoding，装前再校验一次。
+ (BOOL)probe_hookUrlCarrier:(NSString *)clsName
                    selector:(NSString *)selName
                        mode:(BSPUrlArgMode)mode
                    argIndex:(NSUInteger)argIndex
                      shapes:(NSString *)shapes
                       label:(NSString *)label
{
    BOOL ok;
    NSString *hitKey = [NSString stringWithFormat:@"%@::%@", clsName, selName];

    BSPHookHandler before = nil;
    BSPHookAfter   after  = nil;

    if (mode == BSPUrlArgOut) {
        after = ^(NSInvocation *inv) {
            NSString *s = ProbeStringFromArg(inv, 0, YES);
            NSString *orig = nil;
            id repl;
            if (!s) return;
            repl = ProbeRewriteIfMedia(s, s, &orig);
            if (!repl) return;
            ProbeBumpHookHit(hitKey);
            // 必须先兜住生命周期再写回：NSInvocation 不 retain 返回值，
            // 局部强引用出了作用域就释放，调用方拿到的是野指针。
            ProbeKeepReturnAlive(repl);
            {
                __unsafe_unretained id keep = repl;
                [inv setReturnValue:&keep];
            }
            ProbeLogRewrite(@"rewrite", hitKey, label, orig);
        };
    } else {
        before = ^(NSInvocation *inv, BOOL *skip) {
            NSString *s;
            NSString *orig = nil;
            id repl;
            (void)skip;
            ProbeBump(&gCntUrlHookFired);
            ProbeBumpHookHit(hitKey);

            s = ProbeStringFromArg(inv, argIndex, NO);
            if (!s) {
                // 参数不是字符串/URL。第一次遇到时把它的真实类型记下来 ——
                // 上一版 willOpenUrl: 命中 2 次却一片空白，就是因为这里悄悄返回了。
                ProbeDescribeUnhandledArg(inv, argIndex, hitKey, label);
                return;
            }
            repl = ProbeRewriteIfMedia(s, s, &orig);
            if (!repl) return;

            {
                __unsafe_unretained id keep = repl;   /* 不改引用计数，只保证生命周期 */
                [inv setArgument:&keep atIndex:argIndex];
            }
            ProbeLogRewrite(@"rewrite", hitKey, label, orig);
        };
    }

    // 同步落盘：如果某个 hook 让 App 立刻崩掉，这一行就是现场的最后一块拼图。
    // （异步日志在进程几毫秒内死掉时会丢，那正是最需要它的时候。）
    PLogSync(@"hook", @"… [阶段2/3] 正在安装 %@ :: %@（%@）", clsName, selName, label);
    ok = [BSPDynamicHook hookClass:clsName selector:selName expectShapes:shapes
                            before:before after:after];
    if (ok) {
        PLogSync(@"hook", @"✓ [阶段2/3] %@ :: %@  enc=%@", clsName, selName,
                 [BSPDynamicHook typeEncodingOfClass:clsName selector:selName] ?: @"?");
    } else {
        PLogSync(@"hook", @"✗ [阶段2/3] %@ :: %@ 未安装（原因见上一行）", clsName, selName);
    }
    return ok;
}

+ (void)probe_installStage23 {
    PLog(@"hook", @"──── 阶段 2/3：CDN 重定向 + 并发分段 ────");

    if (!gUrlHookHits) gUrlHookHits = [NSMutableDictionary dictionary];

    // 回环代理先起来；起不来就完全不改写（宁可不加速，也不能砸播放）
    {
        // 代理侧日志必须进 trace.log：NSLog 在侧载 App 里不进 Documents，
        // 「代理跑了多少、多快」这条唯一能量化效果的线索会整条丢失。
        BSPProxySetLogSink(^(NSString *msg) { PLog(@"proxy", @"%@", msg); });

        BSPProxyServer *p = [BSPProxyServer shared];
        BOOL started = [p start];
        if (started) {
            PLog(@"proxy", @"✓ 回环代理已启动 http://127.0.0.1:%u/bsp/<token>（改写开关=%@）",
                 (unsigned)p.port, [BSPProxyServer rewriteEnabled] ? @"开" : @"关(mode.txt=direct)");
        } else {
            PLog(@"proxy", @"✗ 回环代理启动失败 —— 本版不会改写任何 URL");
        }
    }

    // ---- 表：类 / 选择子 / 模式 / 参数位置 / 期望参数形状 / 标签 ----
    // shapes 全部来自真机 classes.txt 的 method_getTypeEncoding() 输出。
    {
        struct { const char *cls; const char *sel; BSPUrlArgMode mode; NSUInteger idx;
                 const char *shapes; const char *label; } tbl[] = {
            // IJKMediaPlayerItem：URL 真正进入播放内核的地方
            //
            // willOpenUrl: 上一版只命中了 2 次、且一个字都没改写 —— 说明它收到的
            // **不是** URL 字符串（我的 ProbeStringFromArg 对非字符串返回 nil，
            // 而且当时连「收到了什么」都没记）。这里补一个只观测不干预的 dump，
            // 把参数的真实类型与内容打出来，下一轮就有依据了。
            {"IJKMediaPlayerItem", "willOpenUrl:",       BSPUrlArgIn, 2, "@",      "IJK即将打开"},
            {"IJKMediaPlayerItem", "setUrl:",            BSPUrlArgIn, 2, "@",      "IJK设置URL"},
            {"IJKMediaPlayerItem", "updateUrl:resolved:",BSPUrlArgIn, 2, "@B",     "IJK更新URL"},
            {"IJKMediaPlayerItem", "updateUrlInfo:",     BSPUrlArgIn, 2, "@",      "IJK更新URL信息"},
            {"IJKMediaPlayerItem", "callMeteredNetworkUrl:reasonType:", BSPUrlArgOut, 0, "@q", "IJK计费URL"},

            // DASH 分片对象：静态分析确定的 URL 字段
            {"IJKMediaAssetStreamSegment", "initWithUrl:", BSPUrlArgIn, 2, "@",    "IJK分片"},
            {"IJKDashStreamItem", "setBaseUrl:",     BSPUrlArgIn, 2, "@",           "DASH主URL"},
            {"IJKDashStreamItem", "setBackupUrl0:",  BSPUrlArgIn, 2, "@",           "DASH备URL0"},
            {"IJKDashStreamItem", "setBackupUrl1:",  BSPUrlArgIn, 2, "@",           "DASH备URL1"},
            {"IJKDashStreamItem", "initWithStreamId:bandwidth:baseUrl:fileSize:streamType:codecType:",
                                  BSPUrlArgIn, 4, "ii@qii",                         "DASH构造"},
            {"IJKDashStreamBridge", "setUrl:",       BSPUrlArgIn, 2, "@",           "DASH桥URL"},
            {"IJKDashStreamBridge", "setBackupUrls:",BSPUrlArgIn, 2, "@",           "DASH桥备URL"},
            {"IJKDashStreamBridge", "initWithMediaType:codecId:qn:bandwidth:url:backupUrls:",
                                  BSPUrlArgIn, 6, "qqqq@@",                         "DASH桥构造"},

            // 播放器入口（IJK FFmpeg 内核 与 AVPlayer 包装两条路都挂）
            {"IJKFFMoviePlayerController", "initWithContentURL:withOptions:",       BSPUrlArgIn, 2, "@@", "播放器FFmpeg"},
            {"IJKFFMoviePlayerController", "initWithContentURLString:withOptions:", BSPUrlArgIn, 2, "@@", "播放器FFmpegStr"},
            {"IJKFFMoviePlayerControllerFFPlay", "initWithContentURL:withOptions:",       BSPUrlArgIn, 2, "@@", "播放器FFPlay"},
            {"IJKFFMoviePlayerControllerFFPlay", "initWithContentURLString:withOptions:", BSPUrlArgIn, 2, "@@", "播放器FFPlayStr"},
            {"IJKFFMoviePlayerControllerFFPlay", "resetWithContentURLString:withOptions:", BSPUrlArgIn, 2, "@@", "播放器FFPlay重置"},
            {"IJKFFMoviePlayerControllerAVPlayer", "initWithContentURL:",       BSPUrlArgIn, 2, "@", "播放器AVP"},
            {"IJKFFMoviePlayerControllerAVPlayer", "initWithContentURLString:", BSPUrlArgIn, 2, "@", "播放器AVPStr"},
            {"IJKFFMoviePlayerControllerAVPlayer", "createAssetWithUrl:",       BSPUrlArgIn, 2, "@", "播放器AVP建Asset"},

            // 预加载
            {"BBPlayerPreloadNextItem", "setPreloadUrl:", BSPUrlArgIn, 2, "@", "预加载URL"},

            // ---- 读侧兜底：直接改写 getter 的返回值 ----
            //
            // 为什么还要挂读侧：上一版实测发现 IJKDashStreamItem 的 setBackupUrl0:
            // 命中了 21 次、setBaseUrl: 却一次没命中 —— 说明 baseUrl 不是走 setter
            // 赋值的（可能是 KVC、__NSCFType 桥接或 protobuf 直填）。
            // 只挂写侧就会漏掉这类字段。而**读侧是终点**：不管当初怎么赋的值，
            // 谁来读都会经过 getter，在那里换掉最稳。
            {"IJKDashStreamItem", "baseUrl",     BSPUrlArgOut, 0, "",  "DASH主URL读"},
            {"IJKDashStreamItem", "backupUrl0",  BSPUrlArgOut, 0, "",  "DASH备URL0读"},
            {"IJKDashStreamItem", "backupUrl1",  BSPUrlArgOut, 0, "",  "DASH备URL1读"},
            {"IJKMediaPlayerItem", "url",        BSPUrlArgOut, 0, "",  "IJK当前URL读"},
            {"IJKDashStreamBridge", "url",       BSPUrlArgOut, 0, "",  "DASH桥URL读"},
        };

        NSUInteger total = sizeof(tbl) / sizeof(tbl[0]);
        NSUInteger installed = 0;
        for (NSUInteger i = 0; i < total; i++) {
            NSString *cn = tbl[i].cls ? [NSString stringWithUTF8String:tbl[i].cls] : nil;
            NSString *sn = tbl[i].sel ? [NSString stringWithUTF8String:tbl[i].sel] : nil;
            if (!cn.length || !sn.length) continue;
            if (!NSClassFromString(cn)) {
                PLog(@"hook", @"· [阶段2/3] %@ 不在运行时，跳过", cn);
                continue;
            }
            if ([self probe_hookUrlCarrier:cn selector:sn mode:tbl[i].mode
                                  argIndex:tbl[i].idx
                                    shapes:tbl[i].shapes ? [NSString stringWithUTF8String:tbl[i].shapes] : @""
                                     label:tbl[i].label ? [NSString stringWithUTF8String:tbl[i].label] : @""]) {
                installed++;
            }
        }
        PLog(@"hook", @"阶段 2/3 hook 安装完成：%lu/%lu", (unsigned long)installed, (unsigned long)total);
        PLog(@"hook", @"已安装的转发 hook 全表：\n      %@",
             [[BSPDynamicHook installedHooks] componentsJoinedByString:@"\n      "]);
    }

    // 落一份「真机真实签名」清单，便于离线核对（探针最大的价值之一）
    {
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"# 真机运行时 method type encoding（由 method_getTypeEncoding 直接读出）\n"];
        [s appendFormat:@"# 时间 %@\n\n", [NSDate date]];
        for (NSString *cn in @[@"IJKMediaPlayerItem", @"IJKDashStreamItem", @"IJKDashStreamBridge",
                               @"IJKMediaPlayerWrapper", @"IJKFFMoviePlayerController",
                               @"IJKFFMoviePlayerControllerFFPlay",
                               @"IJKFFMoviePlayerControllerAVPlayer", @"IJKP2PManager",
                               @"IJKP2PServerResolver", @"IJKP2PConfig", @"BBRResourceLoaderManager",
                               @"BBRResourceLoader", @"BBRMediaDownloader",
                               @"BBPlayerInteractiveResourcePreload",
                               @"BBPlayerPreload", @"BBPlayerPreloadNextItem",
                               @"IJKMediaAssetStreamSegment", @"BBResolverMediaPlayerItem"]) {
            Class c = NSClassFromString(cn);
            if (!c) { [s appendFormat:@"## %@ (不在运行时)\n\n", cn]; continue; }
            [s appendFormat:@"## %@\n", cn];
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            for (unsigned int i = 0; i < mc && i < 400; i++) {
                const char *t = method_getTypeEncoding(ms[i]);
                [s appendFormat:@"    - %-60s %s\n", sel_getName(method_getName(ms[i])), t ?: "?"];
            }
            if (ms) free(ms);
            [s appendString:@"\n"];
        }
        ProbeWriteFile(@"encodings.txt", s);
    }
}

//=== 8. 阶段 0：仪器先自证 ====================================================
//
// 为什么必须加这一段（把错误记下来，避免以后再犯）：
//   之前所有结论都建立在「我挂的目标 hook 有没有响」上。目标选错时，日志会
//   退化成「一片零」，而我却把这读成「用户没播视频」—— 这是拿仪器的不确定性
//   去质疑被观测者，方法上就是错的。
//   实际上我自己的分析早就得出「IJK 是自研 FFmpeg 内核，字节不走 NSURL 系 API」，
//   那么观测点全零**恰恰是视频正常播放时应有的样子**。两句话自相矛盾，我没发现。
//
// 现在改成让播放器自己报数，这些方法的 type encoding 全部来自真机 classes.txt：
//   isPlaying (B) / currentPlaybackTime (d)         -> 是否在播、播到第几秒
//   getVideoTcpSpeed / getTcpSpeed (q)              -> 视频字节**此刻**速率，>0 即硬证据
//   getVideoCachedDuration (q)                      -> 已缓冲时长
//   httpOpenDelegate / tcpOpenDelegate /
//   rawDataDelegate / fileOpenDelegate (@)          -> IJK 究竟用哪条 IO 通道取字节
// 最后一项尤其关键：若 httpOpenDelegate 非空，说明 IJK 把网络完全交给了 App 自己
// 的实现，这能一次性解释「为什么 NSURL 系观测点全为零」。

+ (void)probe_hookPlayerLifecycle:(NSString *)clsName
                         selector:(NSString *)selName
                           shapes:(NSString *)shapes
                            label:(NSString *)label
{
    Class c = NSClassFromString(clsName);
    if (!c) {
        PLog(@"hook", @"· [播放器] %@ 不在运行时", clsName);
        return;
    }
    // 打印继承链：IJKFFMoviePlayerController 与 FFPlay / AVPlayer 方法表高度重合，
    // 若是父子关系，「先挂父类再挂子类」会踩到 _objc_msgForward 当原实现的陷阱。
    // 与其离线猜，不如每次启动把它打出来。
    {
        static NSMutableSet *logged = nil;
        if (!logged) logged = [NSMutableSet set];
        @synchronized (logged) {
            if (![logged containsObject:clsName]) {
                [logged addObject:clsName];
                NSMutableArray<NSString *> *chain = [NSMutableArray array];
                for (Class k = c; k && chain.count < 8; k = class_getSuperclass(k))
                    [chain addObject:NSStringFromClass(k)];
                PLog(@"hook", @"· [播放器] 继承链 %@", [chain componentsJoinedByString:@" → "]);
            }
        }
    }
    {
        NSString *key = [NSString stringWithFormat:@"%@::%@", clsName, selName];
        __block BOOL firstLogged = NO;

        BSPHookHandler before = ^(NSInvocation *inv, BOOL *skip) {
            (void)skip;
            ProbeBump(&gCntPlayerLifecycle);
            ProbeBumpHookHit(key);
            if (!firstLogged) {
                firstLogged = YES;
                PLog(@"player", @"▶ 播放器生命周期首次命中：%@（%@）", key, label);
            }
        };
        BSPHookAfter after = ^(NSInvocation *inv) {
            id t = inv.target;
            if (!t) return;
            @synchronized (gLivePlayers) { [gLivePlayers addObject:t]; }
        };

        // 装之前先写一行同步日志：万一这个 hook 自身就把 App 搞崩，
        // 日志会停在「正在安装 X」—— 直接点名，不用猜。
        PLogSync(@"hook", @"… [播放器] 正在安装 %@ :: %@（%@）", clsName, selName, label);
        BOOL ok = [BSPDynamicHook hookClass:clsName selector:selName expectShapes:shapes
                                     before:before after:after];
        PLogSync(@"hook", @"%@ [播放器] %@ :: %@  %@", ok ? @"✓" : @"✗", clsName, selName, label);
    }
}

/// 读出所有活着的播放器实例当前状态。这是「是否真的在播」的唯一权威来源。
static NSString *ProbePlayerSnapshot(void) {
    NSArray *live;
    NSMutableString *out = [NSMutableString string];

    if (!gLivePlayers) return @"播放器实例=0（正证据模块未启用）";
    @synchronized (gLivePlayers) { live = gLivePlayers.allObjects; }
    if (live.count == 0) {
        return @"播放器实例=0 —— 播放器对象从未在本进程创建。"
               @"若你确实在播视频，那就说明播放器跑在**另一个进程**里。";
    }

    for (id p in live) {
        Class c = object_getClass(p);
        BOOL playing = NO, prepared = NO;
        double t = 0, dur = 0;
        long long vs = 0, as = 0, ts = 0, vc = 0, ac = 0, st = 0;
        id httpD = nil, tcpD = nil, rawD = nil, fileD = nil;

        if ([p respondsToSelector:@selector(isPlaying)])
            playing = ((BOOL (*)(id, SEL))objc_msgSend)(p, @selector(isPlaying));
        if ([p respondsToSelector:@selector(isPreparedToPlay)])
            prepared = ((BOOL (*)(id, SEL))objc_msgSend)(p, @selector(isPreparedToPlay));
        if ([p respondsToSelector:@selector(currentPlaybackTime)])
            t = ((double (*)(id, SEL))objc_msgSend)(p, @selector(currentPlaybackTime));
        if ([p respondsToSelector:@selector(duration)])
            dur = ((double (*)(id, SEL))objc_msgSend)(p, @selector(duration));
        if ([p respondsToSelector:@selector(getVideoTcpSpeed)])
            vs = ((long long (*)(id, SEL))objc_msgSend)(p, @selector(getVideoTcpSpeed));
        if ([p respondsToSelector:@selector(getAudioTcpSpeed)])
            as = ((long long (*)(id, SEL))objc_msgSend)(p, @selector(getAudioTcpSpeed));
        if ([p respondsToSelector:@selector(getTcpSpeed)])
            ts = ((long long (*)(id, SEL))objc_msgSend)(p, @selector(getTcpSpeed));
        if ([p respondsToSelector:@selector(getVideoCachedDuration)])
            vc = ((long long (*)(id, SEL))objc_msgSend)(p, @selector(getVideoCachedDuration));
        if ([p respondsToSelector:@selector(getAudioCachedDuration)])
            ac = ((long long (*)(id, SEL))objc_msgSend)(p, @selector(getAudioCachedDuration));
        if ([p respondsToSelector:@selector(getPlayerStatus)])
            st = ((long long (*)(id, SEL))objc_msgSend)(p, @selector(getPlayerStatus));
        if ([p respondsToSelector:@selector(httpOpenDelegate)])
            httpD = ((id (*)(id, SEL))objc_msgSend)(p, @selector(httpOpenDelegate));
        if ([p respondsToSelector:@selector(tcpOpenDelegate)])
            tcpD = ((id (*)(id, SEL))objc_msgSend)(p, @selector(tcpOpenDelegate));
        if ([p respondsToSelector:@selector(rawDataDelegate)])
            rawD = ((id (*)(id, SEL))objc_msgSend)(p, @selector(rawDataDelegate));
        if ([p respondsToSelector:@selector(fileOpenDelegate)])
            fileD = ((id (*)(id, SEL))objc_msgSend)(p, @selector(fileOpenDelegate));

        [out appendFormat:@"  <%@ %p> 在播=%@ 已就绪=%@ 进度=%.1fs/%.1fs 状态=%lld\n",
             NSStringFromClass(c), p, playing ? @"是" : @"否", prepared ? @"是" : @"否",
             t, dur, st];
        [out appendFormat:@"      视频TCP速率=%.1f KiB/s  音频=%.1f KiB/s  合计=%.1f KiB/s\n",
             (double)vs / 1024.0, (double)as / 1024.0, (double)ts / 1024.0];
        [out appendFormat:@"      缓冲：视频 %lld ms  音频 %lld ms\n", vc, ac];
        [out appendFormat:@"      IO 通道：http=%@ tcp=%@ rawData=%@ file=%@\n",
             httpD ? NSStringFromClass(object_getClass(httpD)) : @"(空)",
             tcpD  ? NSStringFromClass(object_getClass(tcpD))  : @"(空)",
             rawD  ? NSStringFromClass(object_getClass(rawD))  : @"(空)",
             fileD ? NSStringFromClass(object_getClass(fileD)) : @"(空)"];
    }
    return out;
}

+ (void)probe_installPositiveControls
{
    // hook 器的诊断必须进 trace.log。上一版它们走 NSLog（侧载 App 里不进文件），
    // 于是「22 个 hook 全部拒绝安装」这件事在真机日志里只剩一片 ✗，看不出原因。
    // hook 器的诊断必须进 trace.log。上一版它们走 NSLog（侧载 App 里不进文件），
    // 于是「22 个 hook 全部拒绝安装」这件事在真机日志里只剩一片 ✗，看不出原因。
    // 这里刻意用**同步**写：崩在安装阶段时，拒绝原因必须活下来。
    BSPDynamicHookSetLogSink(^(NSString *msg) { PLogSync(@"hook", @"%@", msg); });

    PLog(@"hook", @"──── 阶段 0：播放正证据 + 全网观测 ────");
    PLogSync(@"hook", @"hook 分组开关：%@（可在 biliprobe/hooks.txt 里改）", ProbeGroupsDescription());

    // ---- 解析器自检（金丝雀）----
    //
    // 上一版整个包空转，根因就是 encoding 解析器有 bug，而它**从来没有被验证过**。
    // 现在解析器有了 Linux 单测（55 条真机夹具），这里再加一道运行时金丝雀：
    // 每次启动拿几条真机 encoding 过一遍，不对就当场喊出来。
    {
        struct { const char *enc; const char *want; } canary[] = {
            {"v24@0:8@16",                "@"},        /* 单对象参数 */
            {"v16@0:8",                   ""},         /* 无参数 */
            {"B28@0:8@16B24",             "@B"},       /* 对象 + BOOL */
            {"@48@0:8i16i20@24q32i40i44", "ii@qii"},   /* DASH 构造，六参混合 */
            {"v20@0:8B16",                "B"},        /* BOOL 参数 */
            {"v24@0:8^{IjkMediaPlayer=}16", "^"},      /* 结构体指针 */
        };
        BOOL ok = YES;
        NSMutableString *detail = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(canary) / sizeof(canary[0]); i++) {
            char got[96];
            int n = bsp_enc_shapes(canary[i].enc, got, sizeof(got));
            BOOL good = (n >= 0) && (strcmp(got, canary[i].want) == 0);
            if (!good) {
                ok = NO;
                [detail appendFormat:@"\n      %s -> 得到\"%s\" 期望\"%s\"",
                    canary[i].enc, n < 0 ? "(解析失败)" : got, canary[i].want];
            }
        }
        if (ok) {
            PLog(@"hook", @"✓ encoding 解析器自检通过（6 条真机样本）");
        } else {
            PLog(@"hook", @"★★★ encoding 解析器自检**失败** —— 所有带形状校验的 hook "
                          @"都会被误杀、整个包会空转。请把这份日志发回。%@", detail);
        }
    }

    if (!gLivePlayers) {
        gLivePlayers = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory |
                                NSPointerFunctionsObjectPointerPersonality];
    }
    if (!gTaskHostHist) gTaskHostHist = [NSMutableDictionary dictionary];

    // 先验证 hook 机制本身可用，再装真实 hook。
    // 顺序很重要：自检失败时，日志里能明确看到「是机制坏了」而不是「没装上」。
    ProbeHookSelfTest();
    // ---- A. 播放器生命周期：拿到实例，之后由心跳轮询它自己报数 ----
    // shapes 全部取自真机 classes.txt 的 method_getTypeEncoding。
    if (!ProbeGroupEnabled(@"player")) {
        PLogSync(@"hook", @"· [播放器] 分组 player=off，跳过（改 biliprobe/hooks.txt 可打开）");
    } else {
        struct { const char *cls; const char *sel; const char *shapes; const char *label; } t[] = {
            {"IJKFFMoviePlayerControllerFFPlay", "play",                          "",  "开始播放"},
            {"IJKFFMoviePlayerControllerFFPlay", "prepareToPlay",                 "",  "准备播放"},
            {"IJKFFMoviePlayerControllerFFPlay", "initUsingItemWithOptions:",     "@", "用 Item 构建"},
            {"IJKFFMoviePlayerControllerFFPlay", "initUsingItemWithOptions:withGLView:", "@@", "用 Item 构建(带视图)"},
            {"IJKFFMoviePlayerControllerFFPlay", "initWithContentURL:withOptions:",      "@@", "用 URL 构建"},
            {"IJKFFMoviePlayerControllerFFPlay", "initWithContentURLString:withOptions:","@@", "用 URL 字符串构建"},
            {"IJKFFMoviePlayerControllerFFPlay", "initWithMoreContent:withOptions:withGLView:",       "@@@", "多段构建"},
            {"IJKFFMoviePlayerControllerFFPlay", "initWithMoreContentString:withOptions:withGLView:","@@@", "多段构建(字符串)"},
            {"IJKFFMoviePlayerControllerFFPlay", "resetWithContentURLString:withOptions:", "@@", "重置 URL"},
            {"IJKFFMoviePlayerController",       "play",                          "",  "开始播放"},
            {"IJKFFMoviePlayerController",       "prepareToPlay",                 "",  "准备播放"},
            {"IJKFFMoviePlayerController",       "initUsingItemWithOptions:",     "@", "用 Item 构建"},
            {"IJKFFMoviePlayerController",       "initUsingItemWithOptions:withGLView:", "@@", "用 Item 构建(带视图)"},
            {"IJKFFMoviePlayerControllerAVPlayer", "play",                        "",  "开始播放(AVPlayer)"},
            {"IJKFFMoviePlayerControllerAVPlayer", "prepareToPlay",               "",  "准备播放(AVPlayer)"},
            {"IJKFFMoviePlayerControllerAVPlayer", "initUsingItem",               "",  "用 Item 构建(AVPlayer)"},
            {"IJKMediaPlayerWrapper", "start",                                    "",  "包装器启动"},
            {"IJKMediaPlayerWrapper", "prepareWithItem:",                         "@", "包装器准备"},
            {"IJKMediaPlayerItem", "start",                                       "",  "内核 Item 启动"},
            {"IJKMediaPlayerItem", "applyTo:",                                    "^", "Item 灌进 C++ 内核"},
        };
        for (NSUInteger i = 0; i < sizeof(t) / sizeof(t[0]); i++) {
            [self probe_hookPlayerLifecycle:[NSString stringWithUTF8String:t[i].cls]
                                   selector:[NSString stringWithUTF8String:t[i].sel]
                                     shapes:[NSString stringWithUTF8String:t[i].shapes]
                                      label:[NSString stringWithUTF8String:t[i].label]];
        }
    }

    // ---- B. 播放器视图控制器出现 = 用户确实进了视频页 ----
    if (ProbeGroupEnabled(@"player")) {
        for (NSString *cn in @[@"BBPlayerViewController", @"BBPgcPlayerViewController"]) {
            if (!NSClassFromString(cn)) continue;
            [self probe_hookPlayerLifecycle:cn selector:@"viewDidAppear:" shapes:@"B" label:@"进入视频页"];
        }
    }

    // ---- C. 全网观测：NSURLSessionTask.resume ----
    //
    // 为什么改用这个而不是继续挂各种 dataTaskWith* 工厂：
    //   上一版只挂了 NSURLSession 的两个工厂方法，跑完整场只记录到 2 个 NSURLRequest。
    //   App 里图片/接口那么多请求不可能只有 2 个 —— 说明大量请求根本没经过
    //   NSURLRequest 的 ObjC 初始化（CoreFoundation 内部直接造 __NSCFURLRequest），
    //   或者走的是 dataTaskWithURL: 这类我没挂的工厂。
    //   resume 是所有任务最终都必须走的一步，挂它才是真正全覆盖。
    //
    // ⚠ 用**直连**方式挂，不用转发。
    //
    // 为什么（真机日志换来的教训，务必保留）：
    //   上一版用转发方式挂 NSURLSessionTask::resume —— 在类上加 forwardInvocation:，
    //   把实现换成 _objc_msgForward。安装全部成功，但日志停在
    //      12:06:12.746 [session] 媒体请求 host=i2.hdslb.com
    //   之后进程就死了：那正是第一次 task resume。
    //   根因是 NSURLSessionTask 是**系统 class cluster**，实例的真类是
    //   __NSCFURLSessionTask（CoreFoundation 支撑）。这类具体类可能自带
    //   forwardInvocation: / methodSignatureForSelector:，把我们的转发器遮住，
    //   转发链拿不到方法签名 —— 消息无人认领，直接抛异常崩掉。
    //   转发那套在普通 NSObject 子类上很成熟（Aspects 就用它），但系统类上不安全。
    //
    // 直连方式没有这个问题：resume 的签名是 v16@0:8（零参数），
    // 我们自己写的 C 函数 void f(id, SEL) 与它严格对应，装前还会用
    // expectShapes 校验一次形状。既没有 NSInvocation 开销，也完全绕开转发链。
    if (!ProbeGroupEnabled(@"net")) {
        PLogSync(@"hook", @"· [全网] 分组 net=off，跳过 NSURLSessionTask.resume "
                          @"（想看 App 到底请求了谁，就在 biliprobe/hooks.txt 写 net=on）");
    } else {
        PLogSync(@"hook", @"… [全网] 正在安装 NSURLSessionTask :: resume（直连方式）");
        BOOL ok = [BSPDynamicHook hookClass:@"NSURLSessionTask" selector:@"resume"
                               expectShapes:@"" directImp:(IMP)ProbeTaskResume
                                   storeOld:(IMP *)&gOrigTaskResume];
        PLogSync(@"hook", @"%@ [全网] NSURLSessionTask :: resume（直连，覆盖所有任务）",
                 ok ? @"✓" : @"✗");

        // 刻意不再挂 NSURLSession 的 dataTaskWithURL: 系列 ——
        // resume 是**所有**任务（不论由哪个工厂造出来）的必经之路，已经全覆盖；
        // 多挂系统类的工厂方法只是徒增风险（它们同样属于 class cluster）。

        // 关键自检：resume 到底实现在哪一层。
        // 若具体类自己实现了 resume，挂在 NSURLSessionTask 上的 hook 就永远不会响
        // —— 那正是上一版「挂了却零命中」的翻版，必须提前说清楚而不是等真机才发现。
        {
            Method base = class_getInstanceMethod([NSURLSessionTask class], @selector(resume));
            IMP baseImp = base ? method_getImplementation(base) : NULL;
            NSMutableString *s = [NSMutableString string];
            for (NSString *cn in @[@"__NSCFURLSessionTask", @"__NSCFURLSessionDataTask",
                                   @"__NSCFURLSessionDownloadTask", @"__NSCFURLSessionUploadTask"]) {
                Class c = NSClassFromString(cn);
                if (!c) continue;
                Method m = class_getInstanceMethod(c, @selector(resume));
                BOOL overrides = (m && method_getImplementation(m) != baseImp);
                [s appendFormat:@"      %@：%@\n", cn, overrides ? @"自己实现了 resume（会绕过我的 hook）"
                                                                : @"继承 NSURLSessionTask 的 resume"];
            }
            PLogSync(@"hook", @"· [全网] resume 实现层自检：%@\n%@",
                     baseImp ? @"NSURLSessionTask 上有 resume" : @"!! NSURLSessionTask 上没有 resume，hook 未安装",
                     s.length ? s : @"      （未找到已知的具体类）");
        }
    }

    // 关于 NSURLProtocol：上一版挂的是基类 canInitWithRequest:，而基类并不实现它
    // （抽象方法），那条 hook 直接安装失败、计数永远为 0。
    // 这一版**刻意不再逐个具体子类去挂**：系统协议类（_NSURLHTTPProtocol、
    // WKCustomProtocol 等）是所有网络请求的必经之路，往它们身上装转发器会给
    // 全 App 的 URL 加载加一层开销，风险与收益不成比例。
    // 「App 到底请求了什么」已经由 resume 全覆盖回答，静态的协议实现者清单
    // 也已经在 resloader-delegates.txt 里，这里不再重复。

    PLog(@"hook", @"阶段 0 安装完成。心跳里会轮询播放器自己报的 isPlaying / 视频TCP速率 —— "
                  @"这两个值出现非零，就说明「确实在播」这件事不再需要靠推断。");
}

@end

//------------------------------------------------------------------------------
#pragma mark - 入口
//------------------------------------------------------------------------------
__attribute__((constructor))
static void BiliProbeInit(void) {
    @autoreleasepool {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = dirs.firstObject ?: NSTemporaryDirectory();
        gLogDir = [docs stringByAppendingPathComponent:kProbeDirName];
        NSError *dirErr = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:gLogDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&dirErr];
        gLogQueue = dispatch_queue_create("com.biliprobe.log", DISPATCH_QUEUE_SERIAL);

        // 第一行必须同步落盘。它的存在本身就是「dylib 成功加载并执行了构造函数」
        // 的证据 —— 上一轮真机连目录都没建出来，我们却无法区分是「没注入」
        // 还是「注入后立刻崩」，就是因为没有任何同步痕迹。
        PLogSync(@"boot", @"================ BiliProbe 已加载 ================");
        PLogSync(@"boot", @"日志目录=%@ 建目录错误=%@", gLogDir,
                 dirErr ? dirErr.localizedDescription : @"(无)");
        PLogSync(@"boot", @"目录可写=%@",
                 [[NSFileManager defaultManager] isWritableFileAtPath:gLogDir] ? @"是" : @"否");

        // 在 UI 线程装 hook：AVAssetResourceLoader 的使用都在主线程，
        // 主线程安装可避免与 App 初始化竞争
        if ([NSThread isMainThread]) {
            [BiliProbe bootstrap];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [BiliProbe bootstrap];
            });
        }
    }
}
