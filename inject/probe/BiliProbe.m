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

/// 原 IMP 查表（按「类名 + 选择子名」）。
/// 不能用共享选择子做键：多个 delegate 类会撞车，各自的原实现会互相覆盖。
static void        ProbeRegSet(NSString *cls, NSString *sel, IMP imp);
static IMP         ProbeFetchOriginal(Class cls, SEL sel);

/// 统一转发：查回原实现并调用它，把真实返回值带回。
/// 探针「零行为改动」就靠这个函数 —— 调用方拿到的就是 App 原本会拿到的结果。
static BOOL        ProbeForwardToOriginal(id self, SEL cmd, id a1, id a2);

/// 被挂的 delegate 方法实现（路由器）
static id          ProbeRecycledCall(id self, SEL _cmd, id a1, id a2);

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
/// 注意 _cmd 始终是「真实选择子」—— 只有走真实的 delegate 入口才会到这里，
/// 若从回收站选择子进入则是原实现本身，不经过本函数，因此不会重复计数/递归。
static id ProbeRecycledCall(id self, SEL _cmd, id a1, id a2) {
    if ([_cmd isEqual:NSSelectorFromString(@"resourceLoader:shouldWaitForLoadingOfRequestedResource:")]) {
        return (id)(long long)ProbeShouldWaitForLoading(self, _cmd, a1, a2);
    }
    if ([_cmd isEqual:NSSelectorFromString(@"resourceLoader:shouldWaitForRenewalOfRequestedResource:")]) {
        return (id)(long long)ProbeShouldWaitForRenewal(self, _cmd, a1, a2);
    }
    if ([_cmd isEqual:NSSelectorFromString(@"resourceLoader:shouldWaitForResponseToAuthenticationChallenge:")]) {
        return (id)(long long)ProbeAuthChallenge(self, _cmd, a1, a2);
    }
    if ([_cmd isEqual:NSSelectorFromString(@"resourceLoader:didCancelLoadingRequest:")]) {
        (void)ProbeDidCancelLoading(self, _cmd, a1, a2);
        return (id)0;
    }
    // 未登记的方法：直接转发，绝不影响行为
    return (id)(long long)ProbeForwardToOriginal(self, _cmd, a1, a2);
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
    PLog(@"resloader", @"setDelegate:queue: → delegate=%@ queue=%s",
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
    PLog(@"resloader", @"shouldWaitForRenewal URL=%.300@", request.request.URL.absoluteString ?: @"(nil)");
    return ProbeForwardToOriginal(self, _cmd, loader, request);
}

static BOOL ProbeAuthChallenge(id self, SEL _cmd,
                               AVAssetResourceLoader *loader,
                               NSURLAuthenticationChallenge *challenge) {
    PLog(@"pinning", @"⚠️ 资源加载器收到认证挑战 method=%@ host=%@ realm=%@  ← 有值=存在 TLS 校验链路",
         challenge.protectionSpace.authenticationMethod ?: @"(nil)",
         challenge.protectionSpace.host ?: @"(nil)",
         challenge.protectionSpace.realm ?: @"(nil)");
    return ProbeForwardToOriginal(self, _cmd, loader, challenge);
}

static void ProbeDidCancelLoading(id self, SEL _cmd,
                                  AVAssetResourceLoader *loader,
                                  AVAssetResourceLoadingRequest *request) {
    PLog(@"resloader", @"didCancelLoading URL=%.200@", request.request.URL.absoluteString ?: @"(nil)");
    (void)ProbeForwardToOriginal(self, _cmd, loader, request);
}

//=== 2. AVURLAsset ============================================================
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

//=== 4. 环境 / 反调试自检 =====================================================
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

        // ② AVURLAsset 刻意不挂 —— 理由见上方注释（initializer 交换会打断资源创建）

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
            }
        });

        PLog(@"boot", @"探针安装完毕，等待播放器触发…");
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
