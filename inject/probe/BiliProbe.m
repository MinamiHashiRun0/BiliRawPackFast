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
    // 用 lowercaseString 一次，避免多次大小写不敏感比较
    static NSArray<NSString *> *needles = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[@"bilivideo", @"mcdn", @"akamai", @"hdslb", @"upos"];
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

static NSURLSessionDataTask *ProbeDataTaskWithRequestCompletion(id self, SEL _cmd,
                                                               NSURLRequest *request,
                                                               void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    if (gOrigDataTaskCR == NULL && gOrigDataTaskC) {
        gOrigDataTaskCR = (NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)))gOrigDataTaskC;
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
    // 注：renewal / authChallenge / cancel 三个计数仍在采集（心跳里用得上），
    // 但结论行不再逐个列出 —— 上一版把它们留成了未使用变量，被 -Werror 拦下。

    PLog(@"verdict", @"=========== 结论 [%@] ===========", phase);
    PLog(@"verdict", @"计数：委托类=%d setDelegate=%d shouldWait=%d | NSURLSession=%d "
                     @"NSURLRequest=%d | 下载器init=%d 段级下载=%d | AVURLAsset=%d 加载器类=%d "
                     @"| 预加载=%d",
         hookClasses, setDel, waits, sessMedia, reqBuilt, dlInit, dlTask, assetInit, loaderCls,
         preloads);

    if (dlTask > 0) {
        PLog(@"verdict", @"OK 已抓到视频段级下载（%d 次）→ 阶段 2/3 落点确定："
                         @"BBRMediaDownloader（改 host + 段级并发）", dlTask);
    } else if (preloads > 0) {
        PLog(@"verdict", @"★ 预加载在跑（%d 次）但没有段级下载 → 视频是**提前预下载**好的，"
                         @"播放走本地缓存。阶段 2 的落点应上移到预加载/下载层，"
                         @"而不是播放期的网络层", preloads);
    } else if (assetInit > 0) {
        PLog(@"verdict", @"AVURLAsset 已创建 %d 次但下载器与预加载都没动 → "
                         @"播放走本地缓存（可能是更早的预下载，或磁盘缓存命中）", assetInit);
    } else if (hookClasses > 0 && waits > 0) {
        PLog(@"verdict", @"OK 视频数据经 AVAssetResourceLoaderDelegate（shouldWait=%d）", waits);
    } else {
        PLog(@"verdict", @"未命中 连 AVURLAsset 都没创建 → 播放器不是 AVPlayer 系，"
                         @"或取日志时视频尚未开始");
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

        // ②c 视频字节的实际下载器（依据 classes.txt 的真实方法表）
        Class dlCls = NSClassFromString(@"BBRMediaDownloader");
        if (dlCls) {            gOrigDLInitURL = ProbeReplaceMethod(dlCls, @selector(initWithURL:cacheWorker:),
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

        // ③ 重型枚举延后 2 秒：此时主程序初始化基本完成，类注册更全，
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
                              @"下载器=%d 段级下载=%d | 预加载=%d",
                     beats, beats * 15,
                     ProbeRead(&gCntDelegateClassHooked), ProbeRead(&gCntSetDelegate),
                     ProbeRead(&gCntShouldWait),
                     ProbeRead(&gCntSessionMediaReq), ProbeRead(&gCntRequestConstructed),
                     ProbeRead(&gCntMediaDownloaderInit), ProbeRead(&gCntMediaDownloadTask),
                     ProbeRead(&gCntPreloadCall));

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
        [[NSFileManager defaultManager] createDirectoryAtPath:gLogDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        gLogQueue = dispatch_queue_create("com.biliprobe.log", DISPATCH_QUEUE_SERIAL);

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
