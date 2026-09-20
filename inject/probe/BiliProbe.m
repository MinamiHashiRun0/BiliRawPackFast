//==============================================================================
// BiliProbe —— 哔哩哔哩 iOS 官方客户端（tv.danmaku.bilianime 9.12.0）注入探针
//
// 阶段 1 目标（观测为主，主动承认一处行为改动）：
//   ① 证明 dylib 注入 + 重签 在真机能加载（整个方案的前提）
//   ② 抓视频数据流真实链路：AVAssetResourceLoader 的 delegate 是谁、URL 长什么样
//   ③ 抓 CDN 选择点：_requestCDNNode / addCDNAddress 等落在哪个类、什么签名
//   ④ 运行时类侦察，等于在设备上做一次定向 class-dump，供离线定 hook 点
//   ⑤ 自检反调试/越狱痕迹，判断注入会不会被 App 自身保护干掉
//
// 行为改动声明（必须诚实标注，否则"官方 App 流不流畅"的对照结论不可信）：
//   * 探针会在视频 delegate 上挂 4 个观测方法，并让
//     `shouldWaitForLoadingOfRequestedResource` 恒返回 NO。
//     若 App 原本走「delegate 接管」分支，这会使其退回 AVFoundation 默认加载路径。
//     因此：本次真机对照实验的结论只能用于判断「注入是否可行 + 链路长什么样」，
//     **不能**用来比较官方 App 与原版官方 App 的流畅度。
//   * 不做任何其他行为改动。
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
/// 交换实例方法实现。类/方法缺失时返回 NO 并记录，绝不崩。
static BOOL ProbeSwizzle(Class cls, SEL original, SEL replacement) {
    if (!cls) {
        PLog(@"hook", @"✗ class 为 nil，跳过 %@", NSStringFromSelector(original));
        return NO;
    }
    Method m1 = class_getInstanceMethod(cls, original);
    Method m2 = class_getInstanceMethod(cls, replacement);
    if (!m1 || !m2) {
        PLog(@"hook", @"✗ %@ 上 %@ / %@ 缺失，跳过",
             NSStringFromClass(cls), NSStringFromSelector(original), NSStringFromSelector(replacement));
        return NO;
    }
    method_exchangeImplementations(m1, m2);
    PLog(@"hook", @"✓ 已挂 %@ :: %@", NSStringFromClass(cls), NSStringFromSelector(original));
    return YES;
}

/// 只在该类「自己」实现了该方法时挂载，避免误伤继承自父类的实现。
/// 返回 YES 表示确实挂了。
static BOOL ProbeSwizzleOwnMethod(Class cls, SEL original, SEL replacement) {
    if (!cls) return NO;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    BOOL owns = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(ms[i]) == original) { owns = YES; break; }
    }
    if (ms) free(ms);

    if (!owns) {
        PLog(@"hook", @"· %@ 未自行实现 %@（继承而来），不挂",
             NSStringFromClass(cls), NSStringFromSelector(original));
        return NO;
    }
    return ProbeSwizzle(cls, original, replacement);
}

static BOOL ProbeAddMethodIfAbsent(Class cls, SEL sel, IMP imp, const char *types) {
    if (!cls || !sel || !imp) return NO;
    if (class_getInstanceMethod(cls, sel)) return NO;   // 已存在就不动，避免踩到别人的实现
    return class_addMethod(cls, sel, imp, types);
}

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
@end

@implementation BiliProbe

//=== 1. AVAssetResourceLoader 的 delegate 是指谁 ==============================
// 视频字节从这里流经 App 自己的 delegate（B站靠它塞 PCDN/MCDN）。
// 观测 delegate 身份 + 在 delegate 类上挂观测点 ≠ 改写行为。

/// AVAssetResourceLoader 原始 setDelegate:queue: 的 IMP（bootstrap 时抓取）
static IMP gOrigSetRLDelegate = NULL;

static void ProbeSetResourceLoaderDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    PLog(@"resloader", @"setDelegate:queue: → delegate=%@ queue=%s",
         delegate ? NSStringFromClass([delegate class]) : @"(nil)",
         queue ? "有" : "NULL");

    if (delegate) {
        [BiliProbe probe_installDelegateHooksOnClass:[delegate class]];
    }

    // 直接调原始 IMP，而不是调 probe_setDelegate:queue: ——
    // 这里 self 是 id，编译器看不到后面分类里声明的选择子，会报
    // "no known instance method for selector"。
    // 用抓下来的 IMP 同时还保证了逻辑上不可能递归：它就是原实现本身。
    if (gOrigSetRLDelegate) {
        ((void (*)(id, SEL, id, dispatch_queue_t))gOrigSetRLDelegate)(self, _cmd, delegate, queue);
    } else {
        PLog(@"resloader", @"⚠️ 未抓到原始 IMP，本次不转发（delegate 可能未生效）");
    }
}

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
    // 注意：这里返回 NO 会让 AVFoundation 不走「delegate 接管」分支。
    // 探针只负责观测/不接管，返回 NO 即可（原始实现已被换成 probe_ 选择子，
    // 调回去只会无限递归，绝不能再调 _cmd）。
    return NO;
}

static BOOL ProbeShouldWaitForRenewal(id self, SEL _cmd,
                                      AVAssetResourceLoader *loader,
                                      AVAssetResourceRenewalRequest *request) {
    PLog(@"resloader", @"shouldWaitForRenewal URL=%.300@", request.request.URL.absoluteString ?: @"(nil)");
    return NO;   // 同上：不接管续期，也不回调 _cmd
}

static BOOL ProbeAuthChallenge(id self, SEL _cmd,
                               AVAssetResourceLoader *loader,
                               NSURLAuthenticationChallenge *challenge) {
    PLog(@"pinning", @"⚠️ 资源加载器收到认证挑战 method=%@ host=%@ realm=%@  ← 有值=存在 TLS 校验链路",
         challenge.protectionSpace.authenticationMethod ?: @"(nil)",
         challenge.protectionSpace.host ?: @"(nil)",
         challenge.protectionSpace.realm ?: @"(nil)");
    return NO;
}

static void ProbeDidCancelLoading(id self, SEL _cmd,
                                  AVAssetResourceLoader *loader,
                                  AVAssetResourceLoadingRequest *request) {
    PLog(@"resloader", @"didCancelLoading URL=%.200@", request.request.URL.absoluteString ?: @"(nil)");
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

//=== 5. 给 delegate 类挂观测点 ================================================
+ (void)probe_installDelegateHooksOnClass:(Class)cls {
    if (!cls) return;
    static NSMutableSet *done = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ done = [NSMutableSet set]; });
    NSString *key = NSStringFromClass(cls);
    if ([done containsObject:key]) return;
    [done addObject:key];

    PLog(@"resloader", @"为 delegate %@ 安装观测点", key);

    // 顺序很重要：必须先把 probe_ 实现加进「这个类自己」，再交换。
    // 否则 class_getInstanceMethod 可能返回父类实现，
    // method_exchangeImplementations 会把父类实现与 probe_ 对调，
    // 污染所有兄弟类 —— 这是 swizzle 的经典事故。
    ProbeAddMethodIfAbsent(cls, @selector(probe_shouldWaitForLoadingOfRequestedResource:),
                           (IMP)ProbeShouldWaitForLoading, "B@:@@");
    ProbeSwizzleOwnMethod(cls,
                          @selector(resourceLoader:shouldWaitForLoadingOfRequestedResource:),
                          @selector(probe_shouldWaitForLoadingOfRequestedResource:));

    ProbeAddMethodIfAbsent(cls, @selector(probe_shouldWaitForRenewalOfRequestedResource:),
                           (IMP)ProbeShouldWaitForRenewal, "B@:@@");
    ProbeSwizzleOwnMethod(cls,
                          @selector(resourceLoader:shouldWaitForRenewalOfRequestedResource:),
                          @selector(probe_shouldWaitForRenewalOfRequestedResource:));

    ProbeAddMethodIfAbsent(cls, @selector(probe_shouldWaitForResponseToAuthenticationChallenge:),
                           (IMP)ProbeAuthChallenge, "B@:@@");
    ProbeSwizzleOwnMethod(cls,
                          @selector(resourceLoader:shouldWaitForResponseToAuthenticationChallenge:),
                          @selector(probe_shouldWaitForResponseToAuthenticationChallenge:));

    ProbeAddMethodIfAbsent(cls, @selector(probe_didCancelLoadingRequest:),
                           (IMP)ProbeDidCancelLoading, "v@:@@");
    ProbeSwizzleOwnMethod(cls,
                          @selector(resourceLoader:didCancelLoadingRequest:),
                          @selector(probe_didCancelLoadingRequest:));

    unsigned int mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < mc; i++) {
        [names addObject:NSStringFromSelector(method_getName(ms[i]))];
    }
    if (ms) free(ms);
    PLog(@"resloader", @"%@ 共 %u 个方法：%@", key, mc, [names componentsJoinedByString:@", "]);
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
