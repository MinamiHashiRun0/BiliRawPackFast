//==============================================================================
// BiliFast —— 哔哩哔哩官方 iOS 客户端「多 CDN 并发加速」正式模块
//
// 与探针（BiliProbe）的区别：**只保留真正起作用的那条链路**。
//   不做类枚举、不做缓存盘点、不写 classes.txt/encodings.txt、
//   不轮询播放器状态、不挂系统网络类。日志只有一份精简的 session 报告。
//
// 工作原理（每一环都在真机上验证过）：
//   播放器的网络层在打开每一段媒体前，会构造一个 IJKMediaUrlOpenData，
//   其 .url 字段就是它即将去取的地址。我们把上游的 CDN URL 换成回环代理地址，
//   播放器于是连到 127.0.0.1；代理再把这段 Range 切片、并发地从多台 CDN 取回，
//   按序写回。真机日志确认过：
//       ◆ IJKMediaUrlOpenData 字段全貌： .url = http://127.0.0.1:xxxxx/bsp/1
//
// 安全性（这几条是前 13 轮真机换来的，不要动）：
//   * 只监听 127.0.0.1，不对外开端口
//   * fail-open：首片 2.5 秒没到、或所有节点都失败，直接 302 跳回原始 CDN URL
//     —— 最坏情况是「没加速」，不是「不能播」
//   * 第一片固定走 URL 自己的 host（签名签发方，实测最快也最可靠），
//     不让关键路径从一台可能已经死掉的候选节点起步
//   * 每主机在途分片数上限 3：对端会掐掉过量并发连接
//   * 连续失败 2 次的节点拉黑
//
// 开关（Documents/BiliFast/ 下，改完重启 App 生效）：
//   mode.txt     写 direct → 完全不改写，退回原样播放
//   hosts.txt    每行一台 CDN（写了即进入「多 host 模式」，分片散到指定 host；
//                留空 = 默认「单 host 模式」：多连接打同一海外 CDN 绕限速）
//
// 自证：每次会话结束会在日志与 report.txt 里给出收益判断。
//   单 host 模式靠「A/B 实测」——同一段字节、同一海外 CDN，单连接 vs 4 连接并发，
//   比值 >1 才说明多连接真的绕过了 per-connection 限速；≤1 则本网络下无收益，
//   建议关掉或卸载。多 host 模式才用旧的「并发收益倍数」间接指标。
//==============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdatomic.h>
#include <string.h>

#import "BSPDynamicHook.h"
#import "BSPCdnPool.h"
#import "BSPProxyServer.h"
#import "BiliFastUI.h"

#ifndef FAST_BUILD_SHA
#define FAST_BUILD_SHA "local"
#endif
#ifndef FAST_BUILD_TIME
#define FAST_BUILD_TIME "local"
#endif

static NSString *const kDirName   = @"BiliFast";
static NSString *const kLogName   = @"BiliFast.log";
static NSString *const kReportName = @"report.txt";
static const unsigned long long kMaxLogBytes = 2ULL * 1024 * 1024;

static NSString        *gLogDir;

/* 日志写盘队列：**专用串行队列**，所有 FLog 调用把格式化好的行丢进来就返回，
 * 绝不在调用线程做 open/seek/write/close。
 *
 * 为什么必须异步（这是 8e61995/1299eba 两版海外真机整机卡死的根因）：
 *   旧版 FLogv 在调用线程同步 stat+open+seek+write+close。代理一真干活
 *   （单 host 模式打同一海外 CDN）后，每片 [proxy] 完成 都触发一次，
 *   N 个 wc.q 并发线程同时同步写同一文件 → open/NSFileHandle 竞争 + IO 饱和
 *   → 队列堆积 → 饿死主线程事件投递 → UI 冻死（小球拖不动、不闪退）。
 *   多 host 旧版没卡只是因为散到国内节点快速失败回源、代理基本空转、日志极少。
 * 异步后：调用线程只做一次 NSString 拼接 + dispatch_async，零 IO、无锁竞争。 */
static dispatch_queue_t gLogQueue;          /* 唯一的日志串行队列：缓冲与写盘都在这上面 */
static NSMutableArray<NSData *> *gLogBuf;   /* 仅由 gLogQueue 访问，无需额外加锁 */

static void FLogFlush(NSMutableArray<NSData *> *batch)
{
    if (!batch.count || !gLogDir) return;
    NSString *path = [gLogDir stringByAppendingPathComponent:kLogName];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
    if (attr && [attr[NSFileSize] unsignedLongLongValue] > kMaxLogBytes) {
        [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        for (NSData *d in batch) [fh writeData:d];
    } @catch (__unused NSException *e) {
    } @finally {
        [fh closeFile];
    }
}

static void FLogv(NSString *tag, NSString *fmt, va_list ap)
{
    @autoreleasepool {
        NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm:ss";
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                          [df stringFromDate:[NSDate date]], tag, body];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!d) return;

        /* 队列还没建（理论上不会：BiliFastInit 第一件事就是建它）——
         * 退化成直接落盘一次，绝不 dispatch_async(NULL)（那是硬崩）。 */
        if (!gLogQueue) {
            if (gLogDir) {
                NSString *p = [gLogDir stringByAppendingPathComponent:kLogName];
                [line writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:NULL];
            }
            return;
        }

        /* 调用线程零阻塞：所有实际工作（入缓冲/刷盘）都丢到 gLogQueue 这一个
         * 串行队列上。串行队列天然互斥，gLogBuf 无需再加锁，也没有嵌套 block。 */
        dispatch_async(gLogQueue, ^{
            if (!gLogBuf) gLogBuf = [NSMutableArray arrayWithCapacity:64];
            [gLogBuf addObject:d];
            /* 攒够 32 行批量刷一次，摊薄 open/close 开销；
             * 不足则由 1 秒定时器兜底刷（保证启动日志尽快可见）。 */
            if (gLogBuf.count >= 32) {
                NSMutableArray *snap = gLogBuf;
                gLogBuf = nil;
                FLogFlush(snap);
            }
        });
    }
}

static void FLog(NSString *tag, NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    FLogv(tag, fmt, ap);
    va_end(ap);
}

static void FWriteFile(NSString *name, NSString *content)
{
    if (!gLogDir || !name) return;
    [content writeToFile:[gLogDir stringByAppendingPathComponent:name]
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

//------------------------------------------------------------------------------
#pragma mark - 改写落点
//------------------------------------------------------------------------------
// 这些选择子全部来自真机 classes.txt 的 method_getTypeEncoding，
// 安装前还会用 expectShapes 再校验一次参数形状，不符即拒绝安装（宁可少改，不可改错）。

static _Atomic(int32_t) gRewriteCount = 0;
static _Atomic(int32_t) gSeenCount    = 0;

/// 总开关的**运行期**状态。设置面板可以随时改，改完下一个请求就生效，
/// 不需要重启 App —— 每个 hook 进来先看一眼这个原子量，代价可忽略。
static _Atomic(BOOL) gEnabled;

static inline BOOL FEnabled(void) { return atomic_load_explicit(&gEnabled, memory_order_relaxed); }
static void FSetEnabled(BOOL on)
{
    atomic_store_explicit(&gEnabled, on, memory_order_relaxed);
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"BiliFastEnabled"];
    FLog(@"cfg", @"并发加速 %@", on ? @"已开启" : @"已关闭（URL 不再改写）");
}

/// 遍历包装对象的属性，谁的值是 B 站媒体 URL 就改谁。
/// 真机确认：网络层读的是 IJKMediaUrlOpenData.url / IJKMediaAsset 里的字段，
/// 而不是裸字符串；字段名不必事先知道。
static BOOL FRewriteFields(id obj)
{
    BOOL changed = NO;
    if (!obj) return NO;
    for (Class c = object_getClass(obj); c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int i, n = 0;
        objc_property_t *props = class_copyPropertyList(c, &n);
        for (i = 0; i < n; i++) {
            NSString *key = @(property_getName(props[i]));
            id v = nil;
            @try { v = [obj valueForKey:key]; } @catch (__unused NSException *e) { continue; }

            {
                NSString *s = nil;
                if ([v isKindOfClass:NSString.class]) s = v;
                else if ([v isKindOfClass:NSURL.class]) s = [(NSURL *)v absoluteString];
                if (s && [BSPCdnPool isMediaURL:s]) {
                    NSString *local = [[BSPProxyServer shared] localURLFor:s];
                    id repl = [v isKindOfClass:NSURL.class] ? [NSURL URLWithString:local] : (id)local;
                    if (local && repl) {
                        @try { [obj setValue:repl forKey:key]; changed = YES; }
                        @catch (__unused NSException *e) {}
                    }
                }
            }
            if ([v isKindOfClass:NSArray.class]) {
                NSArray *arr = v;
                NSMutableArray *na = nil;
                for (NSUInteger k = 0; k < arr.count; k++) {
                    id e = arr[k];
                    NSString *s = [e isKindOfClass:NSString.class] ? e :
                                  ([e isKindOfClass:NSURL.class] ? [(NSURL *)e absoluteString] : nil);
                    if (!s || ![BSPCdnPool isMediaURL:s]) { if (na) [na addObject:e]; continue; }
                    if (!na) na = [arr mutableCopy];
                    {
                        NSString *local = [[BSPProxyServer shared] localURLFor:s];
                        id repl = [e isKindOfClass:NSURL.class] ? [NSURL URLWithString:local] : (id)local;
                        if (local && repl) na[k] = repl;
                    }
                }
                if (na) {
                    @try { [obj setValue:na forKey:key]; changed = YES; }
                    @catch (__unused NSException *e) {}
                }
            }
        }
        free(props);
    }
    return changed;
}

/// 返回值保命池：NSInvocation 不 retain 返回值，局部强引用出作用域就释放，
/// 调用方拿到的是野指针。
static NSMutableArray *gKeepAlive = nil;
static void FKeepAlive(id o)
{
    if (!o) return;
    if (!gKeepAlive) gKeepAlive = [NSMutableArray array];
    @synchronized (gKeepAlive) {
        [gKeepAlive addObject:o];
        while (gKeepAlive.count > 256) [gKeepAlive removeObjectAtIndex:0];
    }
}

static NSString *FStringArg(NSInvocation *inv, NSUInteger idx, BOOL isReturn)
{
    __unsafe_unretained id obj = nil;
    @try {
        if (isReturn) {
            const char *rt = inv.methodSignature.methodReturnType;
            if (!rt || strcmp(rt, "@") != 0) return nil;
            [inv getReturnValue:&obj];
        } else {
            [inv getArgument:&obj atIndex:idx];
        }
    } @catch (__unused NSException *e) { return nil; }
    if ([obj isKindOfClass:NSString.class]) return obj;
    if ([obj isKindOfClass:NSURL.class]) return [(NSURL *)obj absoluteString];
    return nil;
}

static void FNoteRewrite(void)
{
    atomic_fetch_add_explicit(&gRewriteCount, 1, memory_order_relaxed);
}

/// 装一个「参数里带 URL」的落点
static void FInstallArgHook(NSString *cls, NSString *sel, NSUInteger argIndex, NSString *shapes)
{
    if (!NSClassFromString(cls)) return;
    BSPHookHandler before = ^(NSInvocation *inv, BOOL *skip) {
        NSString *s;
        id repl;
        (void)skip;
        if (!FEnabled()) return;                 /* 面板上一关，下一个请求就生效 */
        s = FStringArg(inv, argIndex, NO);
        if (s) {
            if ([BSPCdnPool isMediaURL:s]) {
                atomic_fetch_add_explicit(&gSeenCount, 1, memory_order_relaxed);
                repl = [[BSPProxyServer shared] localURLFor:s];
                if (repl) {
                    __unsafe_unretained id keep = repl;
                    [inv setArgument:&keep atIndex:argIndex];
                    FNoteRewrite();
                }
            }
            return;
        }
        /* 参数是包装对象（例如 IJKMediaUrlOpenData）：扫它的字段 */
        {
            __unsafe_unretained id obj = nil;
            @try { [inv getArgument:&obj atIndex:argIndex]; } @catch (__unused NSException *e) { obj = nil; }
            if (obj && FRewriteFields(obj)) FNoteRewrite();
        }
    };
    [BSPDynamicHook hookClass:cls selector:sel expectShapes:shapes before:before after:nil];
}

/// 装一个「读侧」落点：直接改写 getter 的返回值。
/// 有些字段不走 setter 赋值（可能 KVC 或 protobuf 直填），只挂写侧会漏；
/// 读侧是终点，谁来读都得经过它。
static void FInstallGetterHook(NSString *cls, NSString *sel, NSString *shapes)
{
    if (!NSClassFromString(cls)) return;
    BSPHookAfter after = ^(NSInvocation *inv) {
        NSString *s;
        id repl;
        if (!FEnabled()) return;
        s = FStringArg(inv, 0, YES);
        if (!s || ![BSPCdnPool isMediaURL:s]) return;
        repl = [[BSPProxyServer shared] localURLFor:s];
        if (!repl) return;
        FKeepAlive(repl);
        {
            __unsafe_unretained id keep = repl;
            [inv setReturnValue:&keep];
        }
        FNoteRewrite();
    };
    [BSPDynamicHook hookClass:cls selector:sel expectShapes:shapes before:nil after:after];
}

//------------------------------------------------------------------------------
#pragma mark - 会话报告
//------------------------------------------------------------------------------
static NSString *FSessionReport(NSString *phase)
{
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"构建 %s（%s）\n", FAST_BUILD_SHA, FAST_BUILD_TIME];
    [s appendFormat:@"时间 %@\n", [NSDate date]];
    [s appendFormat:@"改写次数 %d，识别到的媒体 URL %d 个\n",
        atomic_load_explicit(&gRewriteCount, memory_order_relaxed),
        atomic_load_explicit(&gSeenCount, memory_order_relaxed)];
    [s appendFormat:@"%@\n", [[BSPProxyServer shared] throughputLine]];
    {
        NSString *b = [[BSPProxyServer shared] benchmarkLine];
        [s appendString:b.length ? [NSString stringWithFormat:@"%@\n", b]
                                 : @"（A/B 实测还没跑，通常启动后 45 秒左右出结果）\n"];
    }
    [s appendString:@"\n各 CDN 实际承担：\n"];
    [s appendString:[[BSPProxyServer shared] statsReport]];
    [s appendFormat:@"\n阶段：%@\n", phase];

    /* 自证：并发到底有没有用。
     * 首选**现场 A/B 实测**（同字节同区间，单连接 vs 4 台并发）——
     * 那是唯一干净的对照。没有 A/B 数据时退回间接指标并明确标注。 */
    {
        NSString *bench = [[BSPProxyServer shared] benchmarkLine];
        if (bench.length) {
            [s appendFormat:@"\n%@\n", bench];
            if ([bench rangeOfString:@"并发更慢"].location != NSNotFound) {
                [s appendString:@"\n✗ **你这条网络下并发是负收益**。\n"
                            @"   建议在设置面板里关掉「并发加速」，"
                            @"或把 BiliFast/mode.txt 写成 direct。\n"];
            } else if ([bench rangeOfString:@"并发更快"].location != NSNotFound) {
                [s appendString:@"\n✓ 并发有效，保持开启即可。\n"];
            }
        } else {
            /* 没有 A/B 数据。单 host 模式 throughputLine 不含「并发收益」字段
             * （同 host 多连接，比值恒≈1 无意义），直接告诉用户待 A/B 即可；
             * 多 host 模式才解析间接指标。 */
            NSString *line = [[BSPProxyServer shared] throughputLine];
            if ([BSPCdnPool multiHostMode]) {
                NSRange r = [line rangeOfString:@"并发收益 "];
                double gain = 0.0;
                if (r.location != NSNotFound) gain = [[line substringFromIndex:NSMaxRange(r)] doubleValue];
                if (gain > 1.05) {
                    [s appendFormat:@"\n（间接指标：并发收益 %.2fx；A/B 实测还没出结果）\n", gain];
                } else if (gain > 0.01) {
                    [s appendFormat:@"\n（间接指标：并发收益 %.2fx；等 A/B 实测出来再下结论）\n", gain];
                } else {
                    [s appendString:@"\n（本次会话还没有足够样本；A/B 实测通常启动后 45 秒出结果）\n"];
                }
            } else {
                [s appendString:@"\n（单 host 多连接模式：多连接打同一海外 CDN。"
                                 @"收益以 A/B 实测为准，通常启动后 45 秒出结果）\n"];
            }
        }
    }
    return s;
}

static void FFlushReport(NSString *phase)
{
    NSString *r = FSessionReport(phase);
    FWriteFile(kReportName, r);
}

//------------------------------------------------------------------------------
#pragma mark - 入口
//------------------------------------------------------------------------------
__attribute__((constructor))
static void BiliFastInit(void)
{
    @autoreleasepool {
        [BSPProxyServer setLogDirName:kDirName];

        /* 建异步日志队列（见 FLogv 注释：同步写盘是两版卡死的根因）。
         * 一个串行队列包办缓冲与写盘，天然互斥。 */
        if (!gLogQueue) {
            gLogQueue = dispatch_queue_create("bilifast.log", DISPATCH_QUEUE_SERIAL);
        }

        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = dirs.firstObject ?: NSTemporaryDirectory();
        gLogDir = [docs stringByAppendingPathComponent:kDirName];
        [[NSFileManager defaultManager] createDirectoryAtPath:gLogDir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];

        /* 定时刷盘：缓冲区没攒够 32 行时，每 1 秒强制刷一次，
         * 保证 boot/cfg/最后的崩溃前日志都能落盘（异步的代价是掉最后几行，
         * 定时刷把这个代价压到 1 秒内）。 */
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                    dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0));
            dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                                     (uint64_t)(1 * NSEC_PER_SEC), (uint64_t)(200 * NSEC_PER_MSEC));
            dispatch_source_set_event_handler(t, ^{
                /* 取缓冲+刷盘都在 gLogQueue 上做（串行，无需锁，无嵌套 block） */
                dispatch_async(gLogQueue, ^{
                    if (gLogBuf.count) {
                        NSMutableArray *snap = gLogBuf;
                        gLogBuf = nil;
                        FLogFlush(snap);
                    }
                });
            });
            dispatch_resume(t);
        });

        /* hosts.txt：每行一台 CDN，覆盖内置候选池。
         * 内置池是按真机实测筛过的，但不同地区/不同时段能用的节点会变，
         * 留一个不改代码就能调的口子。空文件或不存在则用内置池。 */
        {
            NSString *p = [gLogDir stringByAppendingPathComponent:@"hosts.txt"];
            NSString *txt = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
            NSMutableArray<NSString *> *hosts = [NSMutableArray array];
            for (NSString *raw in [txt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (!l.length || [l hasPrefix:@"#"]) continue;
                [hosts addObject:l];
            }
            if (hosts.count) {
                [BSPCdnPool setOverrideHosts:hosts];
                FLog(@"boot", @"hosts.txt 生效，使用 %lu 台自定义 CDN", (unsigned long)hosts.count);
            }
        }

        FLog(@"boot", @"================ BiliFast 已加载 ================");
        FLog(@"boot", @"构建 %s  编译于 %s", FAST_BUILD_SHA, FAST_BUILD_TIME);
        FLog(@"boot", @"日志目录 %@", gLogDir);

        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                /* 开关初值：mode.txt=direct 是硬关；否则读上次面板里的选择（缺省开） */
                {
                    BOOL hardOff = ![BSPProxyServer rewriteEnabled];
                    BOOL saved = [[NSUserDefaults standardUserDefaults]
                                    objectForKey:@"BiliFastEnabled"]
                                    ? [[NSUserDefaults standardUserDefaults] boolForKey:@"BiliFastEnabled"]
                                    : YES;
                    FSetEnabled(hardOff ? NO : saved);
                    if (hardOff) FLog(@"boot", @"mode.txt=direct —— 本次不做任何改写（面板开关也无效）");
                }

                BSPProxySetLogSink(^(NSString *msg) { FLog(@"proxy", @"%@", msg); });

                if (![[BSPProxyServer shared] start]) {
                    FLog(@"boot", @"✗ 回环代理启动失败 —— 本模块不会改写任何 URL");
                    return;
                }
                FLog(@"boot", @"✓ 代理已启动 127.0.0.1:%u",
                     (unsigned)[BSPProxyServer shared].port);

                /* ---- URL 改写落点 ----
                 * 按「先写侧、后读侧」的顺序装。全部通过 expectShapes 校验，
                 * 形状不符会被拒绝并记一行日志（不会硬挂上去崩掉）。 */
                NSArray *argHooks = @[
                    // (类, 选择子, 参数下标, 期望形状)
                    @[@"IJKMediaAssetStreamSegment", @"initWithUrl:",              @2, @"@"],
                    @[@"IJKMediaPlayerItem",         @"willOpenUrl:",              @2, @"@"],
                    @[@"IJKMediaPlayerItem",         @"updateUrlInfo:",            @2, @"@"],
                    @[@"IJKMediaPlayerItem",         @"updateUrl:resolved:",       @2, @"@B"],
                    @[@"IJKMediaPlayerItem",         @"setUrl:",                   @2, @"@"],
                    @[@"IJKDashStreamItem",          @"setBaseUrl:",               @2, @"@"],
                    @[@"IJKDashStreamItem",          @"setBackupUrl0:",            @2, @"@"],
                    @[@"IJKDashStreamItem",          @"setBackupUrl1:",            @2, @"@"],
                    @[@"IJKDashStreamItem",          @"initWithStreamId:bandwidth:baseUrl:fileSize:streamType:codecType:", @4, @"ii@qii"],
                    @[@"IJKDashStreamBridge",        @"setUrl:",                   @2, @"@"],
                    @[@"IJKDashStreamBridge",        @"setBackupUrls:",            @2, @"@"],
                    @[@"IJKDashStreamBridge",        @"initWithMediaType:codecId:qn:bandwidth:url:backupUrls:", @6, @"qqqq@@"],
                    @[@"BBPlayerPreloadNextItem",    @"setPreloadUrl:",            @2, @"@"],
                ];
                for (NSArray *h in argHooks) {
                    FInstallArgHook(h[0], h[1], [h[2] unsignedIntegerValue], h[3]);
                }

                NSArray *getHooks = @[
                    @[@"IJKDashStreamItem",   @"baseUrl",    @""],
                    @[@"IJKDashStreamItem",   @"backupUrl0", @""],
                    @[@"IJKDashStreamItem",   @"backupUrl1", @""],
                    @[@"IJKMediaPlayerItem",  @"url",        @""],
                    @[@"IJKDashStreamBridge", @"url",        @""],
                ];
                for (NSArray *h in getHooks) {
                    FInstallGetterHook(h[0], h[1], h[2]);
                }

                FLog(@"boot", @"落点安装完毕，共 %lu 条（安装详情见上方逐条日志）",
                     (unsigned long)(argHooks.count + getHooks.count));

                /* ---- 会话报告：定时 + 退到后台时各写一次 ---- */
                {
                    __block int n = 0;
                    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:YES
                                                                   block:^(NSTimer *timer) {
                        @autoreleasepool {
                            n++;
                            FLog(@"stat", @"%@", [[BSPProxyServer shared] throughputLine]);
                            FFlushReport([NSString stringWithFormat:@"运行中（第 %d 分钟）", n]);
                        }
                    }];
                    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
                }
                [[NSNotificationCenter defaultCenter]
                    addObserverForName:UIApplicationDidEnterBackgroundNotification
                                object:nil queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                    FFlushReport(@"App 退到后台");
                }];
                [[NSNotificationCenter defaultCenter]
                    addObserverForName:UIApplicationWillTerminateNotification
                                object:nil queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                    FFlushReport(@"App 即将退出");
                }];

                FFlushReport(@"刚启动，尚无数据");

                /* ---- 设置面板：悬浮小球 + 三指双击 ----
                 * 装完就不需要再碰文本文件了。开关立即生效（hook 里读原子量），
                 * CDN 勾选立即生效（改调度器的 healthy 位）。 */
                [[NSNotificationCenter defaultCenter]
                    addObserverForName:@"BiliFastLog" object:nil
                                queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *n) {
                    NSString *m = n.userInfo[@"msg"];
                    if (m.length) FLog(@"ui", @"%@", m);
                }];
                BiliFastInstallUI(^BOOL { return FEnabled(); },
                                  ^(BOOL on) { FSetEnabled(on); });

                FLog(@"boot", @"就绪。悬浮小球「加速」可打开设置；三指双击屏幕同样打开。");
                FLog(@"boot", @"报告在 Documents/%@/report.txt", kDirName);
            }
        });
    }
}
