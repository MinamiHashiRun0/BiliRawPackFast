/* BSPProxyServer.m */
#import "BSPProxyServer.h"
#import "BSPCdnPool.h"
#import "bsp_ms_core.h"

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

/* ------------------------------------------------------------------ */
/* 调参                                                                */
/* ------------------------------------------------------------------ */
/* 分片大小 512 KiB、窗口 16。
 *
 * 为什么从 256 KiB/12 调大：真机日志显示换成直连 CDN 之后，每个分片的实测
 * 速率常常只有 0.1~0.5 MiB/s（海外到国内的单条连接就这水平）。256 KiB 在这种
 * 速率下要跑 0.5~2.5 秒，而每条 TCP+TLS 建连本身的往返就要几百毫秒 ——
 * 固定开销占比过高。加大分片能摊薄建连成本，加宽窗口能同时压更多链路。
 * （这是基于实测数值的调整，不是拍脑袋；下一版日志里的「单请求峰值」可以直接
 *   验证调大之后有没有真的变快。） */
static const int64_t  kChunkBytes        = 512 * 1024;   /* 单个上游分片 */
/* 并发窗口：从保守值起步，再按「丢包/失败就减半、吞吐变好就加」自适应。
 *
 * 真机两次对照说明了为什么不能写死：
 *   · 蜂窝网络（管子粗）：窗口 24 时聚合吞吐上得去，14 台 CDN 能同时出力
 *   · 家用 WiFi（管子细）：窗口 24 会把路由器压垮 —— 日志里多个**不同** CDN
 *     同时报「网络连接已中断」，而且失败的只是 150~250 KiB 的小分片；
 *     随后重试、4 秒超时、fail-open 回源（6 次），播放器就一直卡缓冲。
 *     聚合只有 0.05 MiB/s，反而低于单台的 0.11 MiB/s。
 * 这和 TCP 的拥塞控制是同一个问题，所以用同一套办法：AIMD。
 * 默认 6 是「不冒进」的起点：好网络几轮就涨上去，差网络涨不上去也不会崩。 */
static const NSInteger kWindowStart      = 4;             /* 回退：8 在海外真机触发整机卡死。先 4 保证不卡，再视 A/B 上调 */
static const NSInteger kWindowMin        = 2;
static const NSInteger kWindowMax        = 8;             /* 回退：20 上限砍半，防连接风暴挤占主线程调度 */
static const NSInteger kAdaptEveryChunks = 6;             /* 每完成几片评估一次 */
static const NSInteger kBlacklistErrors  = 2;             /* 连续错误到几次拉黑 */
static const NSInteger kMaxInflightPerHost = 3;           /* 回退：4→3，单 host 多连接下别一次压太多 */
static const NSInteger kChunkRetries     = 1;             /* 回退：2→1，重试越多越容易在卡顿时雪崩 */
/* 首片超时：这个值直接等于「最坏情况卡多久」——超时后回源，播放器要重新发起请求。
 * 真机 4.0 秒时出现过 6 次回源，累积卡顿接近一分钟；回到 1.5 秒：卡死时尽快回源放行，
 * 宁可更频繁回源（=退回直连）也不要让播放器干等冻住 UI。 */
static const double   kFirstChunkTimeout = 1.5;
static const NSUInteger kMaxHeaderBytes  = 32 * 1024;
static const int      kRecvTimeoutSec    = 15;

/* 每主机令牌桶上限：0 = 不限速。
 *
 * 为什么默认关掉（记录一轮失败设计，避免以后又加回来）：
 *   最初想用「每主机令牌桶 + AIMD 自适应」来建模 CDN 的账户级限速。
 *   但 AIMD 在这里有个死结：我们对一台 CDN 并发 3 个分片时，单个分片的实测
 *   速率天然只有该 CDN 总能力的 1/3，AIMD 会据此判定「这台很慢」并下调上限
 *   —— 于是上限本身变成了瓶颈，越调越慢。而想上调又必须先把速率用满，
 *   用不满就发现不了余量。
 *   真正负责「别把鸡蛋放一个篮子」的是评分里的 load_factor = 1/(1+active*0.1)：
 *   窗口 12 个分片会被它自然摊到各主机上（单测 [5a] 已固定这一行为）。
 *   所以这里保持不限速，让调度完全由「实测速度 + 在途数」驱动。
 *   令牌桶机制本身保留在 bsp_ms_core 里并被单测覆盖，将来若要启用再说。 */
static const double   kPerHostCapBps     = 0.0;

static double bsp_now(void) { return [NSDate timeIntervalSinceReferenceDate]; }

/* 日志出口。默认 NSLog，但 NSLog 在侧载 App 里**不会**进 Documents 下的 trace.log
 * —— 代理侧的每一次分片抓取、每一个失败节点都因此看不见，而「代理到底跑了多少、
 * 多快」恰恰是判断这一版有没有用的唯一依据。 */
static void (^gProxyLog)(NSString *msg) = nil;

void BSPProxySetLogSink(void (^sink)(NSString *msg)) { gProxyLog = [sink copy]; }

static void PLogProxy(NSString *fmt, ...)
{
    va_list ap;
    NSString *msg;
    va_start(ap, fmt);
    msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (gProxyLog) gProxyLog(msg);
    else NSLog(@"[BSPProxy] %@", msg);
}

static NSString *gLogDirName = @"biliprobe";   /* 探针与正式模块各自的日志目录名 */

static NSSet *kDropReqHeaders(void)
{
    static NSSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"host", @"range", @"connection", @"content-length",
                                  @"accept-encoding", @"if-range", @"if-modified-since",
                                  @"if-none-match", @"proxy-connection", @"keep-alive",
                                  @"te", @"transfer-encoding", @"upgrade"]];
    });
    return s;
}

/* ------------------------------------------------------------------ */
/* 主机统计                                                            */
/* ------------------------------------------------------------------ */
@interface BSPProxyHostStat : NSObject
@property (nonatomic, copy)   NSString *host;
@property (nonatomic, assign) int64_t bytes;
@property (nonatomic, assign) NSUInteger ok;
@property (nonatomic, assign) NSUInteger fail;
@property (nonatomic, assign) double seconds;
/* 只统计「热连接」样本的字节/耗时。给用户看的均速、以及评分用的基准，
 * 都应当排除冷连接（含 DNS+TCP+TLS）那一次，否则快的机器会被算成慢的。 */
@property (nonatomic, assign) int64_t warmBytes;
@property (nonatomic, assign) double  warmSeconds;
@property (nonatomic, assign) NSUInteger warmOk;
@property (nonatomic, assign) NSInteger consecutiveErrors;
@end
@implementation BSPProxyHostStat
@end

/* ------------------------------------------------------------------ */
/* 连接上下文                                                          */
/* ------------------------------------------------------------------ */
@interface BSPConnContext : NSObject
@property (nonatomic, assign) int fd;
@property (nonatomic, strong) dispatch_queue_t q;
@property (nonatomic, strong) NSMutableData *inBuf;
@property (nonatomic, assign) BOOL closed;
@property (nonatomic, assign) BOOL servedOne;

@property (nonatomic, copy)   NSString *url;
@property (nonatomic, copy)   NSDictionary<NSString *, NSString *> *clientHeaders;
@property (nonatomic, assign) int64_t reqStart;      /* 客户端要的范围，含 */
@property (nonatomic, assign) int64_t reqEnd;        /* 含；INT64_MAX=到文件尾 */
@property (nonatomic, assign) int64_t total;         /* 文件总长，-1 未知 */

@property (nonatomic, assign) int64_t nextFetch;
@property (nonatomic, assign) int64_t nextWrite;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *pending;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *chunkEnd;
@property (nonatomic, assign) NSInteger outstanding;
@property (nonatomic, assign) BOOL headerSent;
@property (nonatomic, assign) BOOL bodyDone;
@property (nonatomic, assign) BOOL failed;
@property (nonatomic, assign) BOOL firstChunkArrived;
@property (nonatomic, assign) BOOL schedulePending;
@property (nonatomic, assign) BOOL headOnly;
@property (nonatomic, assign) int originHostIdx;      /* URL 自己的 host 在池中的下标 */
@property (nonatomic, assign) int64_t bytesToClient;
@property (nonatomic, assign) NSTimeInterval tRequest;   /* 客户端请求到达的时刻 */
@property (nonatomic, assign) NSTimeInterval tFirst;
@property (nonatomic, assign) NSTimeInterval tLast;
@end

@implementation BSPConnContext
@end

/* ------------------------------------------------------------------ */
/* 服务器                                                              */
/* ------------------------------------------------------------------ */
@interface BSPProxyServer ()
@property (nonatomic, assign) int listenFD;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *tokenToURL;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *urlToToken;
@property (nonatomic, strong) NSMutableDictionary<NSString *, BSPProxyHostStat *> *hostStats;
@property (nonatomic, strong) NSLock *lock;          /* 一把锁保护 token/计数/stats/hosts/planner。
                                                          * 规则：持有期间绝不调用任何会加锁的方法。 */
@property (nonatomic, assign) NSUInteger tokenSeq;
@property (nonatomic, assign) NSUInteger totalRequests;
@property (nonatomic, assign) NSUInteger totalChunks;
@property (nonatomic, assign) NSUInteger failedChunks;
@property (nonatomic, assign) NSUInteger rewrittenCount;
@property (nonatomic, assign) NSUInteger redirects;
@property (nonatomic, assign) int64_t servedBytes;       /* 累计发给客户端 */
@property (nonatomic, assign) double servedSeconds;      /* 累计传输耗时 */
@property (nonatomic, assign) NSTimeInterval firstRequestAt; /* 第一个请求到达 */
@property (nonatomic, assign) NSTimeInterval lastCompleteAt; /* 最后一个请求送完 */
@property (nonatomic, assign) NSUInteger completedRequests;
@property (nonatomic, assign) double peakMiBps;
@property (nonatomic, assign) BOOL anyHostMeasured;   /* 是否已有真实测速样本 */
@property (nonatomic, strong) NSMutableSet<NSString *> *warmHosts;  /* 已建立过连接的 host */
/* 自适应并发窗口（AIMD）。见文件顶部 kWindowStart 的注释。 */
@property (nonatomic, assign) NSInteger window;
@property (nonatomic, assign) int64_t adaptBytes;
@property (nonatomic, assign) double  adaptStart;
@property (nonatomic, assign) NSInteger adaptFails;
@property (nonatomic, assign) NSInteger adaptChunks;
@property (nonatomic, assign) double  adaptLastMiBps;
/* 现场 A/B 实测 */
@property (nonatomic, assign) BOOL benchScheduled;
@property (nonatomic, copy)   NSString *benchURL;
@property (nonatomic, copy)   NSString *benchLine;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, assign) BSPMSPlanner *planner;  /* 全局共享，跨请求学习 */
@property (nonatomic, strong) NSMutableArray<NSString *> *hosts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *hostIndex;
@end

@implementation BSPProxyServer

+ (instancetype)shared
{
    static BSPProxyServer *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[BSPProxyServer alloc] init]; });
    return s;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _listenFD  = -1;
        _tokenToURL = [NSMutableDictionary dictionary];
        _urlToToken = [NSMutableDictionary dictionary];
        _hostStats  = [NSMutableDictionary dictionary];
        _lock       = [[NSLock alloc] init];
        _hosts      = [NSMutableArray array];
        _hostIndex  = [NSMutableDictionary dictionary];
        _rewriteActive = YES;   /* 缺省开；设置面板可运行期关掉 */
        _window     = kWindowStart;
        _adaptStart = 0.0;
    }
    return self;
}

- (void)dealloc { if (_planner) bsp_ms_destroy(_planner); }

#pragma mark - 模式开关

+ (void)setLogDirName:(NSString *)name
{
    /* 只允许单层目录名，避免被拼出 ".." 之类跑出沙盒 */
    if (!name.length || [name rangeOfString:@"/"].location != NSNotFound) return;
    gLogDirName = [name copy];
}

+ (NSString *)logDir
{
    NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = d.firstObject ?: NSTemporaryDirectory();
    NSString *p = [base stringByAppendingPathComponent:gLogDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:p
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    return p;
}

+ (BOOL)rewriteEnabled
{
    static BOOL cached = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *p = [[self logDir] stringByAppendingPathComponent:@"mode.txt"];
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        cached = !(s.length && [s.lowercaseString hasPrefix:@"direct"]);
    });
    return cached;
}

#pragma mark - 生命周期

- (BOOL)start
{
    struct sockaddr_in addr;
    int fd, on = 1;
    socklen_t len;

    if (_running) return YES;

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(0);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return NO; }

    len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &len) != 0) { close(fd); return NO; }
    _port = ntohs(addr.sin_port);
    if (listen(fd, 64) != 0) { close(fd); return NO; }
    _listenFD = fd;

    {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        /* 单 host 模式下，绕 per-connection 限速靠的是"同一 host 多条连接"。
         * 但 8e61995 版曾设 24，海外真机上一打视频就整机卡死（日志断在 A/B
         * 开始那行，主线程冻死不闪退）——24 路并发建连 + completionHandler 风暴
         * 把调度挤垮。回退到 6：仍比旧版多 host 的 8 略聚焦，但不再风暴；
         * 先保证能播，提速效果靠 A/B 数据再调。 */
        cfg.HTTPMaximumConnectionsPerHost = 6;
        cfg.timeoutIntervalForRequest     = 20.0;
        cfg.timeoutIntervalForResource    = 180.0;
        cfg.requestCachePolicy            = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.URLCache                      = nil;
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }

    [self buildPlanner];
    _running = YES;
    [NSThread detachNewThreadSelector:@selector(acceptLoop) toTarget:self withObject:nil];
    return YES;
}

- (void)stop
{
    if (!_running) return;
    _running = NO;
    if (_listenFD >= 0) { shutdown(_listenFD, SHUT_RDWR); close(_listenFD); _listenFD = -1; }
    [_session invalidateAndCancel];
    _session = nil;
}

- (BOOL)isRunning { return _running; }

- (void)acceptLoop
{
    @autoreleasepool {
        while (_running) {
            struct sockaddr_in cli;
            socklen_t clen = sizeof(cli);
            int cfd = accept(_listenFD, (struct sockaddr *)&cli, &clen);
            if (cfd < 0) {
                if (!_running) break;
                if (errno == EINTR || errno == ECONNABORTED) continue;
                if (errno == EBADF || errno == EINVAL) break;
                usleep(20000);
                continue;
            }
            {
                int one = 1;
                struct timeval tv;
                setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
                tv.tv_sec = kRecvTimeoutSec; tv.tv_usec = 0;
                setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            }
            {
                BSPConnContext *ctx = [[BSPConnContext alloc] init];
                ctx.fd = cfd;
                ctx.q  = dispatch_queue_create("bsp.proxy.conn", DISPATCH_QUEUE_SERIAL);
                ctx.inBuf = [NSMutableData data];
                dispatch_async(ctx.q, ^{ [self serveConnection:ctx]; });
            }
        }
    }
}

/* 全局主机池与调度器：所有 URL 共享，跨请求积累测速与黑名单
 *
 * 两种模式（由 BSPCdnPool.multiHostMode 决定，启动时 hosts.txt 是否非空）：
 *   · 多 host：候选池 = hosts.txt，分片散到指定 host（旧行为，给国内/高级用户）
 *   · 单 host：候选池空，每个请求只用它自己的原始 host；planner 延迟到第一次
 *     ensureHost: 时建立（n=BSP_MS_MAX_HOSTS 的空槽），运行时按需 accumulate。
 *     分片不再换 host，而是多连接打同一海外 CDN 绕 per-connection 限速。 */
- (void)buildPlanner
{
    NSMutableArray<NSString *> *all = [[BSPCdnPool effectiveHostsForPlanner] mutableCopy];

    if (_planner) { bsp_ms_destroy(_planner); _planner = NULL; }
    _hosts = all ?: [NSMutableArray array];
    [_hostIndex removeAllObjects];

    if (all.count > 0) {
        /* 多 host 模式：planner 只开 all.count 个槽——pick 遍历的全是真实 host，
         * 不会选到无名的空健康槽导致 _hosts[idx] 越界。运行时 ensureHost: 遇到
         * override 池之外的原始 host 时，因 idx>=n 会被 set_host_name 忽略，
         * 这是预期行为（override 模式就是强制只用指定 host）。 */
        _planner = bsp_ms_create((int)all.count, kPerHostCapBps, kPerHostCapBps);
        bsp_ms_set_max_inflight(_planner, (int)kMaxInflightPerHost);
        for (NSUInteger i = 0; i < all.count; i++) {
            _hostIndex[all[i]] = @(i);
            bsp_ms_set_host_name(_planner, (int)i, all[i].UTF8String);
        }
    }
    /* 单 host 模式：_planner 留空，ensureHost: 首次命中时 lazy 建（开
     * BSP_MS_MAX_HOSTS 槽）。单 host 模式不调 pick，空槽不影响调度。 */
}

/* URL 的 host 规格（带端口时保留端口，否则主机池与 URL 对不上） */
- (NSString *)hostSpecOf:(NSString *)urlString
{
    NSURL *u = [NSURL URLWithString:urlString];
    NSNumber *p = nil;
    NSString *h = nil;
    if (u) {
        h = u.host;
        p = u.port;
    }
    if (h.length == 0) h = [BSPCdnPool hostOf:urlString];
    if (h.length == 0) return nil;
    return p ? [NSString stringWithFormat:@"%@:%@", h, p] : h;
}

/* 把某个 URL 自己的 host 也加入池（池满则忽略） */
- (int)ensureHost:(NSString *)host{
    NSNumber *n;
    if (host.length == 0) return -1;
    [_lock lock];
    n = _hostIndex[host];
    if (!n) {
        /* 用 _hosts.count 当下标（而非 bsp_ms_host_count）：
         * 单 host 模式 planner 延迟建立，多 host 模式 planner 开了 BSP_MS_MAX_HOSTS
         * 槽但只预填了候选池前几个——两种情况下"下一个空槽"都是 _hosts.count。 */
        int idx = (int)_hosts.count;
        if (idx < BSP_MS_MAX_HOSTS) {
            if (!_planner) {
                _planner = bsp_ms_create(BSP_MS_MAX_HOSTS, kPerHostCapBps, kPerHostCapBps);
                if (_planner) bsp_ms_set_max_inflight(_planner, (int)kMaxInflightPerHost);
            }
            if (_planner) bsp_ms_set_host_name(_planner, idx, host.UTF8String);
            [_hosts addObject:host];
            _hostIndex[host] = @(idx);
            n = @(idx);
        }
    }
    [_lock unlock];
    return n ? n.intValue : -1;
}

#pragma mark - 本地 URL 编解码

- (NSString *)localURLFor:(NSString *)originalURL
{
    NSString *token;
    BOOL firstTime = NO;
    if (originalURL.length == 0 || !_running) return nil;

    [_lock lock];
    token = _urlToToken[originalURL];
    if (!token) {
        token = [NSString stringWithFormat:@"%lu", (unsigned long)(++_tokenSeq)];
        _urlToToken[originalURL] = token;
        _tokenToURL[token] = originalURL;
        _rewrittenCount++;
        firstTime = YES;
    }
    [_lock unlock];

    /* 拿到第一个真实媒体 URL 之后，安排一次 A/B 实测（只跑一次）。
     * 放在这里是因为：只有真实签名 URL 才能同时被多台 CDN 接受，
     * 用它做对照才反映真实可用带宽。 */
    if (firstTime) [self scheduleBenchmarkWithURL:originalURL];

    return [NSString stringWithFormat:@"http://127.0.0.1:%u/bsp/%@", (unsigned)_port, token];
}

- (NSString *)originalURLForLocal:(NSString *)localURL
{
    NSRange r = [localURL rangeOfString:@"/bsp/"];
    NSString *token, *u;
    if (r.location == NSNotFound) return nil;
    token = [localURL substringFromIndex:NSMaxRange(r)];
    [_lock lock];
    u = _tokenToURL[token];
    [_lock unlock];
    return u;
}

- (NSUInteger)rewrittenURLCount { return _rewrittenCount; }
- (NSUInteger)totalRequests    { return _totalRequests; }

- (NSInteger)chunkKiB { return (NSInteger)(kChunkBytes / 1024); }
- (NSInteger)windowSize { return _window; }

#pragma mark - 设置面板接口

- (NSArray<NSDictionary *> *)hostSnapshot
{
    NSMutableArray *out = [NSMutableArray array];
    [_lock lock];
    for (NSUInteger i = 0; i < _hosts.count; i++) {
        NSString *h = _hosts[i];
        BSPProxyHostStat *st = _hostStats[h];
        /* 均速优先用热连接样本（排除 DNS/TCP/TLS 那一次），
         * 这样面板上显示的「均速」和调度器实际依据的速度是一致的。 */
        double speed = 0.0;
        if (st && st.warmSeconds > 0.05)      speed = (double)st.warmBytes / st.warmSeconds / 1048576.0;
        else if (st && st.seconds > 0.05)     speed = (double)st.bytes / st.seconds / 1048576.0;
        BOOL enabled = _planner ? bsp_ms_is_healthy(_planner, (int)i) : YES;
        [out addObject:@{
            @"host":    h,
            @"enabled": @(enabled),
            @"bytes":   @(st ? st.bytes : 0),
            @"ok":      @(st ? st.ok : 0),
            @"fail":    @(st ? st.fail : 0),
            @"speed":   @(speed),
        }];
    }
    [_lock unlock];
    return out;
}

- (void)setHost:(NSString *)host enabled:(BOOL)enabled
{
    if (!host.length) return;
    [_lock lock];
    {
        NSNumber *n = _hostIndex[host];
        if (n && _planner) bsp_ms_set_healthy(_planner, n.intValue, enabled ? 1 : 0);
    }
    [_lock unlock];
}

- (void)enableAllHosts
{
    [_lock lock];
    if (_planner) {
        for (int i = 0; i < bsp_ms_host_count(_planner); i++) bsp_ms_set_healthy(_planner, i, 1);
    }
    [_lock unlock];
}

/// URL 的紧凑写法：host + 末段路径。日志里塞完整签名 URL 会把有用信息淹掉。
- (NSString *)shortURL:(NSString *)url
{
    NSURL *u = [NSURL URLWithString:url ?: @""];
    NSString *last = u.lastPathComponent ?: @"?";
    return [NSString stringWithFormat:@"%@/…/%@", u.host ?: @"?", last];
}

/// 一行式吞吐摘要，供心跳与结论段使用。
///
/// 「并发收益」语义随模式变：
///   · 多 host 模式：分子 = 墙钟聚合吞吐，分母 = 单主机最好均速（≥3 片热连接样本），
///     比值代表「散到多台并发」相对「单台能给的」倍率。
///   · 单 host 模式：分子分母同一台 host，比值恒≈1 无意义 —— 这里的并发是
///     「同一海外 CDN 多连接」，收益只能由 A/B 实测（多连接 vs 单连接）回答。
///     所以单 host 模式标注「待 A/B」，不算 gain，避免打出误导性的 0.45x。
- (NSString *)throughputLine
{
    NSString *s;
    [_lock lock];
    {
        double mib = (double)_servedBytes / 1048576.0;
        double wall = (_lastCompleteAt > _firstRequestAt) ? (_lastCompleteAt - _firstRequestAt) : 0.0;
        double aggWall = wall > 0.5 ? mib / wall : 0.0;
        double perReqAvg = _servedSeconds > 0.05 ? mib / _servedSeconds : 0.0;
        double bestHost = 0.0;
        NSString *bestHostName = nil;
        double gain = 0.0;
        BOOL multi = [BSPCdnPool multiHostMode];
        for (NSString *k in _hostStats) {
            BSPProxyHostStat *st = _hostStats[k];
            double sp;
            /* 用热连接样本，且至少 3 片 —— 样本太少或混着握手时间的数字没有意义 */
            if (st.warmOk < 3 || st.warmSeconds <= 0.05) continue;
            sp = (double)st.warmBytes / st.warmSeconds / 1048576.0;
            if (sp > bestHost) { bestHost = sp; bestHostName = st.host; }
        }
        if (multi && bestHost > 0.001 && aggWall > 0.001) gain = aggWall / bestHost;

        s = [NSString stringWithFormat:
             @"代理：请求=%lu 完成=%lu 上游分片=%lu 失败=%lu 302回源=%lu | "
             @"送达 %.2f MiB  墙钟聚合 %.2f MiB/s  单请求均 %.2f MiB/s | "
             @"%@ | 重写URL=%lu",
             (unsigned long)_totalRequests, (unsigned long)_completedRequests,
             (unsigned long)_totalChunks, (unsigned long)_failedChunks,
             (unsigned long)_redirects,
             mib, aggWall, perReqAvg,
             multi
                ? [NSString stringWithFormat:@"最快单主机 %@ %.2f MiB/s（≥3 片样本）→ 并发收益 %.2fx",
                   bestHostName ?: @"(样本不足)", bestHost, gain]
                : [NSString stringWithFormat:@"单 host 多连接模式（%@）实测均速 %.2f MiB/s，收益看 A/B",
                   bestHostName ?: @"(待测)", bestHost],
             (unsigned long)_rewrittenCount];
    }
    [_lock unlock];
    return s;
}

#pragma mark - 统计

- (BSPProxyHostStat *)statFor:(NSString *)host
{
    BSPProxyHostStat *s;
    if (host.length == 0) host = @"?";
    s = _hostStats[host];
    if (!s) { s = [[BSPProxyHostStat alloc] init]; s.host = host; _hostStats[host] = s; }
    return s;
}

- (NSString *)statsReport
{
    NSMutableString *out = [NSMutableString string];
    NSArray<BSPProxyHostStat *> *all;
    int64_t sum = 0;

    [_lock lock];
    all = _hostStats.allValues;
    [out appendFormat:@"代理请求=%lu 上游分片=%lu 失败分片=%lu 重写URL=%lu 302回源=%lu\n",
         (unsigned long)_totalRequests, (unsigned long)_totalChunks,
         (unsigned long)_failedChunks, (unsigned long)_rewrittenCount,
         (unsigned long)_redirects];
    [_lock unlock];

    all = [all sortedArrayUsingComparator:^NSComparisonResult(BSPProxyHostStat *a, BSPProxyHostStat *b) {
        if (a.bytes > b.bytes) return NSOrderedAscending;
        if (a.bytes < b.bytes) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (BSPProxyHostStat *s in all) sum += s.bytes;

    [out appendString:@"各 CDN 实际承担：\n"];
    for (BSPProxyHostStat *s in all) {
        double pct, speed;
        if (s.bytes == 0 && s.ok == 0 && s.fail == 0) continue;
        pct   = sum > 0 ? (double)s.bytes * 100.0 / (double)sum : 0.0;
        speed = s.seconds > 0.01 ? (double)s.bytes / s.seconds : 0.0;
        [out appendFormat:@"   %-44@ %8.2f MiB %5.1f%%  成功%lu 失败%lu  实测均速 %.2f MiB/s\n",
             s.host, (double)s.bytes / 1048576.0, pct,
             (unsigned long)s.ok, (unsigned long)s.fail, speed / 1048576.0];
    }
    if (sum > 0) [out appendFormat:@"   合计 %.2f MiB\n", (double)sum / 1048576.0];
    if (all.count == 0) [out appendString:@"   （还没有任何上游拉取）\n"];
    return out;
}

#pragma mark - 连接处理

- (void)closeConn:(BSPConnContext *)ctx
{
    if (ctx.closed) return;
    ctx.closed = YES;
    if (ctx.fd >= 0) { shutdown(ctx.fd, SHUT_RDWR); close(ctx.fd); ctx.fd = -1; }
}

static BOOL bsp_write_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    int spins = 0;
    while (off < len) {
        ssize_t n = send(fd, p + off, len - off, 0);
        if (n > 0) { off += (size_t)n; spins = 0; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (++spins > 4000) return NO;
            usleep(500);
            continue;
        }
        return NO;
    }
    return YES;
}

/* 一条连接只服务一个请求，响应完即关。
 * 这样读请求（阻塞 recv）与分片回调不会争同一条串行队列 -> 不会死锁。
 * FFmpeg 的 http 协议对 Connection: close 处理正常，会为下一个 Range 重开连接。 */
- (void)serveConnection:(BSPConnContext *)ctx
{
    @autoreleasepool {
        NSDictionary *req = [self readRequest:ctx];
        if (!req) { [self closeConn:ctx]; return; }
        [self handleRequest:req ctx:ctx];
    }
}

- (NSDictionary *)readRequest:(BSPConnContext *)ctx
{
    NSMutableData *buf = ctx.inBuf;
    NSRange hdrEnd = NSMakeRange(NSNotFound, 0);
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + kRecvTimeoutSec;

    for (;;) {
        if (buf.length > kMaxHeaderBytes) return nil;
        {
            const uint8_t *bytes = buf.bytes;
            NSUInteger n = buf.length;
            for (NSUInteger i = 0; i + 3 < n; i++) {
                if (bytes[i] == '\r' && bytes[i+1] == '\n' && bytes[i+2] == '\r' && bytes[i+3] == '\n') {
                    hdrEnd = NSMakeRange(i, 4);
                    break;
                }
            }
        }
        if (hdrEnd.location != NSNotFound) break;
        if ([NSDate timeIntervalSinceReferenceDate] > deadline) return nil;

        {
            uint8_t tmp[8192];
            ssize_t n = recv(ctx.fd, tmp, sizeof(tmp), 0);
            if (n > 0) { [buf appendBytes:tmp length:(NSUInteger)n]; continue; }
            if (n == 0) return nil;
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return nil;
            return nil;
        }
    }

    {
        NSData *hdrData = [buf subdataWithRange:NSMakeRange(0, hdrEnd.location)];
        NSString *hdr = [[NSString alloc] initWithData:hdrData encoding:NSISOLatin1StringEncoding];
        NSArray<NSString *> *lines;
        NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
        NSArray<NSString *> *parts;
        NSString *method, *target;
        NSInteger contentLength;

        if (!hdr) return nil;
        lines = [hdr componentsSeparatedByString:@"\r\n"];
        if (lines.count == 0) return nil;
        parts = [lines[0] componentsSeparatedByString:@" "];
        if (parts.count < 2) return nil;
        method = parts[0];
        target = parts[1];

        for (NSUInteger i = 1; i < lines.count; i++) {
            NSRange colon = [lines[i] rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            {
                NSString *k = [[lines[i] substringToIndex:colon.location]
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSString *v = [[lines[i] substringFromIndex:NSMaxRange(colon)]
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (k.length) headers[k.lowercaseString] = v;
            }
        }

        contentLength = [headers[@"content-length"] integerValue];
        while (contentLength > 0 &&
               (NSInteger)buf.length < (NSInteger)(NSMaxRange(hdrEnd) + (NSUInteger)contentLength)) {
            uint8_t tmp[8192];
            ssize_t n = recv(ctx.fd, tmp, sizeof(tmp), 0);
            if (n <= 0) break;
            [buf appendBytes:tmp length:(NSUInteger)n];
        }

        return @{ @"method": method, @"target": target, @"headers": headers };
    }
}

#pragma mark - 请求分派

- (void)handleRequest:(NSDictionary *)req ctx:(BSPConnContext *)ctx
{
    NSString *target = req[@"target"];
    NSString *path = target;
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) path = [target substringToIndex:q.location];

    if ([path isEqualToString:@"/bsp/status"]) {
        [self respondText:[self statsReport] ctx:ctx];
        return;
    }
    if (![path hasPrefix:@"/bsp/"]) {
        [self respondStatus:404 body:@"not found" ctx:ctx];
        return;
    }

    {
        NSString *token = [path substringFromIndex:5];
        NSString *orig;
        [_lock lock];
        orig = _tokenToURL[token];
        _totalRequests++;
        [_lock unlock];

        if (orig.length == 0) { [self respondStatus:404 body:@"unknown token" ctx:ctx]; return; }
        {
            NSString *m = [req[@"method"] uppercaseString];
            if ([m isEqualToString:@"HEAD"])      ctx.headOnly = YES;
            else if (![m isEqualToString:@"GET"]) { [self respondStatus:405 body:@"method not allowed" ctx:ctx]; return; }
        }

        [self beginRequest:orig headers:req[@"headers"] ctx:ctx];
    }
}

- (void)beginRequest:(NSString *)orig
             headers:(NSDictionary<NSString *, NSString *> *)headers
                 ctx:(BSPConnContext *)ctx
{
    int origIdx;

    ctx.url = orig;
    ctx.clientHeaders = headers;
    ctx.pending     = [NSMutableDictionary dictionary];
    ctx.chunkEnd    = [NSMutableDictionary dictionary];
    ctx.outstanding = 0;
    ctx.headerSent  = NO;
    ctx.bodyDone    = NO;
    ctx.failed      = NO;
    ctx.firstChunkArrived = NO;
    ctx.schedulePending   = NO;
    ctx.bytesToClient = 0;
    ctx.tFirst = ctx.tLast = 0;
    /* 请求到达时刻：吞吐与「并发收益」都以它为起点。
     *
     * 为什么不用「首片写出时刻」当起点（上一版就是这么写的，结果是错的）：
     *   一个请求常常只切出一个分片（512 KiB），首片到达即全部到达，
     *   tFirst 与 tLast 在同一条语句里被赋成同一个值 -> 耗时恒为 0
     *   -> 所有速率都印成 0.00 MiB/s、并发收益 0.00x。
     *   真机日志里「0.35 MiB / 0.00s = 0.00 MiB/s」就是这个 bug。
     * 从请求到达算起，测到的才是**播放器真实等待的时间**，也正是我们要比较的量。 */
    ctx.tRequest = bsp_now();
    [_lock lock];
    if (_firstRequestAt <= 0.0) _firstRequestAt = ctx.tRequest;
    [_lock unlock];

    {
        NSString *r = headers[@"range"];
        int64_t s = 0, e = INT64_MAX;
        if (r.length && [r hasPrefix:@"bytes="]) {
            NSString *spec = [r substringFromIndex:6];
            NSRange dash = [spec rangeOfString:@"-"];
            NSRange comma = [spec rangeOfString:@","];
            if (comma.location != NSNotFound) spec = [spec substringToIndex:comma.location];
            dash = [spec rangeOfString:@"-"];
            if (dash.location != NSNotFound) {
                NSString *a = [spec substringToIndex:dash.location];
                NSString *b = [spec substringFromIndex:NSMaxRange(dash)];
                if (a.length) s = [a longLongValue];
                if (b.length) e = [b longLongValue];
                if (e < s) e = s;
            }
        }
        ctx.reqStart = s;
        ctx.reqEnd   = e;
    }

    ctx.nextFetch = ctx.reqStart;
    ctx.nextWrite = ctx.reqStart;
    ctx.total     = -1;

    origIdx = [self ensureHost:[self hostSpecOf:orig]];
    ctx.originHostIdx = origIdx;

    /* 首片 fail-open 定时器 */
    {
        BSPConnContext *wc = ctx;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFirstChunkTimeout * NSEC_PER_SEC)),
                       ctx.q, ^{
            if (wc.closed || wc.firstChunkArrived || wc.failed || wc.headerSent) return;
            PLogProxy(@"首片 %.1fs 未到，fail-open 302 回源: %@",
                      kFirstChunkTimeout, [self shortURL:wc.url]);
            [self sendFailOpenRedirect:wc];
        });
    }

    [self scheduleMore:ctx];
}

#pragma mark - 失败处理

- (void)failRequest:(BSPConnContext *)ctx reason:(NSString *)reason
{
    if (ctx.failed || ctx.closed) return;
    ctx.failed = YES;
    if (!ctx.headerSent) {
        [self respondStatus:502 body:[NSString stringWithFormat:@"proxy: %@", reason] ctx:ctx];
    } else {
        [self closeConn:ctx];
    }
}

- (void)sendFailOpenRedirect:(BSPConnContext *)ctx
{
    if (ctx.headerSent || ctx.failed || ctx.closed) return;
    ctx.failed = YES;
    [_lock lock]; _redirects++; _failedChunks++; [_lock unlock];
    {
        NSString *resp = [NSString stringWithFormat:
            @"HTTP/1.1 302 Found\r\nLocation: %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            ctx.url];
        bsp_write_all(ctx.fd, resp.UTF8String, strlen(resp.UTF8String));
    }
    [self closeConn:ctx];
}

#pragma mark - 分片调度

- (void)scheduleMore:(BSPConnContext *)ctx
{
    NSInteger window;
    if (!ctx.url || ctx.closed || ctx.failed || ctx.bodyDone) return;
    ctx.schedulePending = NO;

    /* 只有「客户端没给结束位置、我们也不知道文件总长」时才收窗口。
     *
     * 客户端给了 bytes=N-M 时我们清楚边界，怎么预取都不会越界 —— 那种情况必须
     * 放开窗口。之前不看 reqEnd 一律收成 2，把绝大多数请求的并发都掐掉了。
     * 真正需要收敛的只有 bytes=N-（开放式）：512 KiB × 16 = 8 MiB 可能冲过文件末尾，
     * 上游对越界 Range 返回 416，于是分片失败、整个请求 502。
     * 第一片的 Content-Range 就能学到总长，之后自动放开。 */
    window = (ctx.total < 0 && ctx.reqEnd == INT64_MAX) ? 2 : _window;

    while (ctx.outstanding < window) {
        int64_t s = ctx.nextFetch;
        int64_t e, need;
        double now = bsp_now();
        int hostIdx = -1;
        double wait = 0.0;
        NSString *hostName = nil;

        if (ctx.total >= 0 && s > ctx.total - 1) break;
        if (ctx.reqEnd != INT64_MAX && s > ctx.reqEnd) break;

        e = s + kChunkBytes - 1;
        if (ctx.reqEnd != INT64_MAX && e > ctx.reqEnd) e = ctx.reqEnd;
        if (ctx.total  >= 0 && e > ctx.total - 1)      e = ctx.total - 1;
        need = e - s + 1;

        [_lock lock];
        bsp_ms_tick(_planner, now);
        if ([BSPCdnPool multiHostMode]) {
            /* 多 host 模式（hosts.txt 显式开启）：按测速 + 在途评分挑选，旧行为。
             * 第一片固定交给 URL 自己的 host —— 但只在冷启动时；冷启动调度器对
             * 所有候选主机都没有测速数据，撞上不响应的节点会堵死关键路径，而 URL
             * 自己的 host 是签名签发方，已知可用，用它起步最稳。一旦有了测速数据
             * 就让评分说话。 */
            if (s == ctx.reqStart && !_anyHostMeasured
                && ctx.originHostIdx >= 0 && bsp_ms_is_healthy(_planner, ctx.originHostIdx))
                hostIdx = ctx.originHostIdx;
            else
                hostIdx = bsp_ms_pick_capped(_planner, need, now);
            if (hostIdx >= 0) wait = bsp_ms_wait_for(_planner, hostIdx, need, now);
        } else {
            /* 单 host 模式（默认，海外）：不挑 host，全部走原始 host。多分片并发 =
             * 多条连接打同一海外 CDN，靠 HTTPMaximumConnectionsPerHost 叠带宽绕
             * per-connection 限速。不检查 healthy——唯一节点被拉黑等于无候选，
             * 不如继续试，让首片 fail-open 定时器兜底回源（= 直连原始 URL）。 */
            hostIdx = ctx.originHostIdx;
            wait = 0.0;
        }
        if (hostIdx >= 0 && wait <= 0.0) {
        ctx.nextFetch = e + 1;
        ctx.outstanding++;
        ctx.chunkEnd[@(s)] = @(e);
        bsp_ms_begin(_planner, hostIdx, need, now);
        _totalChunks++;
        hostName = _hosts[(NSUInteger)hostIdx];
    }
    [_lock unlock];

        if (hostIdx < 0) { [self failRequest:ctx reason:@"所有 CDN 节点均不可用"]; return; }
        if (wait > 0.0) {
            if (!ctx.schedulePending) {
                BSPConnContext *wc = ctx;
                ctx.schedulePending = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                               ctx.q, ^{ [self scheduleMore:wc]; });
            }
            return;
        }
        [self fetchChunk:ctx start:s end:e host:hostName retry:kChunkRetries];
    }

    if (ctx.outstanding == 0 &&
        ((ctx.total >= 0 && ctx.nextFetch > ctx.total - 1) ||
         (ctx.reqEnd != INT64_MAX && ctx.nextFetch > ctx.reqEnd))) {
        [self finishBody:ctx];
    }
}

- (void)fetchChunk:(BSPConnContext *)ctx
             start:(int64_t)s
               end:(int64_t)e
              host:(NSString *)host
             retry:(NSInteger)retry
{
    /* 单 host 模式：不换 host，直接用原始 URL——多分片打同一海外 CDN 才能叠连接
     * 绕 per-connection 限速。多 host 模式仍换到调度器选中的 host（旧行为）。 */
    NSString *upURL = [BSPCdnPool multiHostMode] ? [BSPCdnPool url:ctx.url withHost:host] : ctx.url;
    NSMutableURLRequest *r;
    NSTimeInterval t0 = bsp_now();
    BOOL hostWarm;
    BSPConnContext *wc = ctx;
    int64_t len = e - s + 1;

    if (!upURL) { [self chunkFailed:ctx start:s end:e host:host reason:@"URL 拼接失败" retry:retry]; return; }
    if (!_session) { [self chunkFailed:ctx start:s end:e host:host reason:@"session 未就绪" retry:retry]; return; }

    /* 这台 host 是不是第一次用？
     *
     * 为什么要区分：`dt` 是从建任务到收完的**整段**时间，头一次访问还要算上
     * DNS + TCP + TLS，海外到国内这段往往就是几百毫秒。512 KiB 的分片若耗掉
     * 0.8 秒握手，算出来的速度只有 0.6 MiB/s，而同一台机器热连接时能到 3 MiB/s。
     * 结果就是「测速最快的那台」和「实际拿到最多分片的那台」对不上 ——
     * 用户真机上看到 28.5% 那台并不是测速最高的那台，根因就在这里：
     * 头一次用完就被打上"慢"的标签，后面很难翻身。 */
    hostWarm = [self isHostWarm:host];
    if (!hostWarm) [self markHostWarm:host];

    r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:upURL]];
    r.HTTPMethod = @"GET";
    r.timeoutInterval = 20.0;
    r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    for (NSString *k in ctx.clientHeaders) {
        if ([kDropReqHeaders() containsObject:k]) continue;
        [r setValue:ctx.clientHeaders[k] forHTTPHeaderField:k];
    }
    [r setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", (long long)s, (long long)e]
        forHTTPHeaderField:@"Range"];
    [r setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    /* 标记：这是代理自己发出的上游分片请求。
     * 探针的 NSURLSession 观测点看到这个标记会直接跳过日志 ——
     * 否则一次播放会产生上千行 [session]，把真正有用的信息淹掉。 */
    [r setValue:@"1" forHTTPHeaderField:@"X-BSP-Upstream"];

    [[_session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSTimeInterval dt = bsp_now() - t0;
        dispatch_async(wc.q, ^{
            NSHTTPURLResponse *hr = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
            NSInteger code = hr ? hr.statusCode : 0;

            /* 416 = 我们请求的范围越过了文件末尾。这不是错误，而是「已经到头了」。
             * 416 的响应头里带 Content-Range: bytes *\/总长，正好可以补上我们还不知道
             * 的总长；把这个分片直接丢掉即可（在途槽位归还，写指针靠前一片自然收尾）。
             * 不做这一步的话，开放式 Range 的请求会因为越界预取而整体 502。 */
            if (code == 416 && hr) {
                NSString *cr = hr.allHeaderFields[@"Content-Range"];
                if ([cr isKindOfClass:[NSString class]]) {
                    NSRange slash = [cr rangeOfString:@"/"];
                    if (slash.location != NSNotFound) {
                        int64_t t = [[cr substringFromIndex:NSMaxRange(slash)] longLongValue];
                        if (t > 0) {
                            if (wc.total < 0) wc.total = t;
                            PLogProxy(@"分片 %lld 越界（416），学到总长 %lld，丢弃该分片",
                                      (long long)s, (long long)t);
                            if (wc.outstanding > 0) wc.outstanding--;
                            [self flushWrites:wc];
                            [self scheduleMore:wc];
                            return;
                        }
                    }
                }
            }

            if (err || !data.length || code >= 400 || (code != 200 && code != 206)) {
                NSString *why = err ? err.localizedDescription
                                    : [NSString stringWithFormat:@"HTTP %ld", (long)code];
                [self noteHost:host bytes:0 seconds:dt ok:NO warm:NO];
                [self chunkFailed:wc start:s end:e host:host reason:why retry:retry];
                return;
            }

            [self noteHost:host bytes:(int64_t)data.length seconds:dt ok:YES warm:hostWarm];
            [self markHostWarm:host];   /* 这一台的连接已建立，之后的分片就是热连接 */

            if (wc.total < 0 && hr) {
                NSString *cr = hr.allHeaderFields[@"Content-Range"];
                if ([cr isKindOfClass:[NSString class]]) {
                    NSRange slash = [cr rangeOfString:@"/"];
                    if (slash.location != NSNotFound) {
                        NSString *tot = [cr substringFromIndex:NSMaxRange(slash)];
                        if (![tot isEqualToString:@"*"]) {
                            int64_t t = [tot longLongValue];
                            if (t > 0) wc.total = t;
                        }
                    }
                } else if (code == 200) {
                    NSString *cl = hr.allHeaderFields[@"Content-Length"];
                    if ([cl isKindOfClass:[NSString class]]) {
                        int64_t t = [cl longLongValue];
                        if (t > 0) wc.total = t;
                    }
                }
            }

            if (wc.outstanding > 0) wc.outstanding--;
            if (!wc.pending[@(s)]) wc.pending[@(s)] = data;
            [self flushWrites:wc];
            [self scheduleMore:wc];
        });
    }] resume];
    (void)len;
}

- (void)chunkFailed:(BSPConnContext *)ctx start:(int64_t)s end:(int64_t)e
               host:(NSString *)host reason:(NSString *)reason retry:(NSInteger)retry
{
    int idx, nextHost = -1;
    BOOL blacklisted = NO;
    int64_t need = e - s + 1;

    [_lock lock];
    {
        NSNumber *n = _hostIndex[host];
        idx = n ? n.intValue : -1;

        if (idx >= 0) bsp_ms_finish(_planner, idx, 0, 0, 1);

        {
            BSPProxyHostStat *st = [self statFor:host];
            st.fail++;
            st.consecutiveErrors++;
            if (idx >= 0 && st.consecutiveErrors >= kBlacklistErrors
                && [BSPCdnPool multiHostMode]   /* 单 host 模式不拉黑唯一节点，否则自杀 */
                && bsp_ms_is_healthy(_planner, idx)) {
                bsp_ms_set_healthy(_planner, idx, 0);
                blacklisted = YES;
            }
        }
        _failedChunks++;
        if (retry > 0) {
            /* 单 host 模式重试同一原始 host（没别的可选）；多 host 模式挑别的 */
            nextHost = [BSPCdnPool multiHostMode] ? bsp_ms_pick(_planner, need, bsp_now()) : idx;
            if (nextHost >= 0) bsp_ms_begin(_planner, nextHost, need, bsp_now());
        }
    }
    [_lock unlock];

    PLogProxy(@"分片失败 %lld-%lld @ %@ (%@) 重试余 %ld",
              (long long)s, (long long)e, host, reason, (long)retry);
    if (blacklisted) PLogProxy(@"拉黑 %@（连续 %ld 次失败）", host, (long)kBlacklistErrors);
    [self noteAdaptSample:0 failed:YES];

    /* 重试复用同一个在途槽位，不改 outstanding */
    if (retry > 0 && nextHost >= 0 && !ctx.closed && !ctx.failed) {
        [self fetchChunk:ctx start:s end:e host:_hosts[(NSUInteger)nextHost] retry:retry - 1];
        return;
    }

    if (ctx.outstanding > 0) ctx.outstanding--;
    if (!ctx.headerSent) {
        [self failRequest:ctx reason:[NSString stringWithFormat:@"分片失败(%@)", reason]];
    } else {
        ctx.failed = YES;
        [self closeConn:ctx];
    }
}

- (void)noteHost:(NSString *)host bytes:(int64_t)bytes seconds:(double)dt
              ok:(BOOL)ok warm:(BOOL)warm
{
    /* ★ 整段必须在**同一把锁**内完成，绝不能出现第二次 [_lock lock]。
     *
     * 这里曾经是海外两版真机整机卡死的真因：第一段 [_lock lock] 之后漏了
     * [_lock unlock]（commit 7b4f782 加第二段时弄丢的），第二段又 [_lock lock]
     * —— NSLock **不可重入**，同一线程二次加锁立即永久死锁。
     * noteHost 在每片成功/失败时都被调用，于是打开视频一瞬间就锁死；
     * 主线程随后经 hook 回调抢 _lock（localURLFor:）→ 永久阻塞
     * = UI 冻死、小球拖不动、不闪退。与并发参数无关 —— 这正是把
     * HTTPMaximumConnectionsPerHost 从 24 降到 6 完全无效的原因。
     * （605f534 能播，是因为那时 noteHost 只有一段、unlock 配对完整。） */
    [_lock lock];
    {
        BSPProxyHostStat *s = [self statFor:host];
        if (ok) {
            s.bytes += bytes; s.seconds += dt; s.ok++; s.consecutiveErrors = 0;
            if (bytes > 0) _anyHostMeasured = YES;   /* 有真实测速样本了 */
            if (warm && bytes > 0) { s.warmBytes += bytes; s.warmSeconds += dt; s.warmOk++; }
        } else {
            s.fail++; s.consecutiveErrors++;
        }

        /* ★ 关键：成功也必须配对地 finish 一次。
         *
         * 这里曾经漏了整整一个版本：bsp_ms_begin 每次派发都 +1，而 bsp_ms_finish
         * 只在失败路径调用过 —— **在途计数只增不减**。后果很隐蔽：
         *   · load_factor = 1/(1+active) 对所有主机一起衰减到接近 0，
         *     评分之间的比例被压平，分配变得近乎随机
         *     —— 用户真机上就是「拿到最多分片的那台并不是测速最快的那台」
         *   · pick_capped 的「在途≥4 就跳过」会永久排除所有主机，上限形同虚设
         * 冷连接样本（含 DNS+TCP+TLS）不进速度窗口，理由见 fetchChunk 里的注释
         * ——但即使样本不入窗口，也必须把在途数减回去。 */
        {
            int idx = [self hostIndexOfLocked:host];
            if (idx >= 0 && _planner) {
                if (ok && warm && bytes > 0 && dt > 0.005)
                    bsp_ms_finish(_planner, idx, bytes, dt, 0);
                else
                    bsp_ms_finish(_planner, idx, 0, 0, 0);
            }
        }
    }
    [_lock unlock];
}

- (BOOL)isHostWarm:(NSString *)host
{
    BOOL w;
    if (!host.length) return NO;
    [_lock lock];
    w = [_warmHosts containsObject:host];
    [_lock unlock];
    return w;
}

- (void)markHostWarm:(NSString *)host
{
    if (!host.length) return;
    [_lock lock];
    if (!_warmHosts) _warmHosts = [NSMutableSet set];
    [_warmHosts addObject:host];
    [_lock unlock];
}

/// 已持有 _lock 时用，避免 NSLock 不可重入导致死锁
- (int)hostIndexOfLocked:(NSString *)host
{
    NSNumber *n = _hostIndex[host];
    return n ? n.intValue : -1;
}

#pragma mark - 现场 A/B 实测
//
// 见头文件里的说明。核心是「同样字节、同样区间、背靠背」：
//   A：4 个连续 512 KiB 分片，串行从单台 CDN 取（等价于一条连接）
//   B：同样 4 个分片，并发发给 4 台不同 CDN
// 这样得到的两个 MiB/s 才是可比的 —— 与播放码率、播放器缓冲策略无关。

- (void)benchFetchURL:(NSString *)url host:(NSString *)host
                start:(int64_t)s end:(int64_t)e
                 done:(void (^)(int64_t bytes, BOOL ok))done
{
    /* 单 host 模式：A/B 也用原始 URL（不换 host），对照的是「同一海外 CDN
     * 多连接 vs 单连接」，正好回答"多连接能否绕 per-connection 限速"。 */
    NSString *up = [BSPCdnPool multiHostMode] ? [BSPCdnPool url:url withHost:host] : url;
    NSMutableURLRequest *r;
    if (!up || !_session) { if (done) done(0, NO); return; }

    r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:up]];
    r.timeoutInterval = 15.0;
    r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [r setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", (long long)s, (long long)e]
        forHTTPHeaderField:@"Range"];
    [r setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

    [[_session dataTaskWithRequest:r
       completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]]
                           ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        BOOL ok = (!err && d.length > 0 && (code == 200 || code == 206));
        if (done) done(ok ? (int64_t)d.length : 0, ok);
    }] resume];
}

/// 串行跑完一列任务（模拟单连接）
- (void)benchSerial:(NSArray<NSArray *> *)jobs
                  i:(NSInteger)i
              bytes:(int64_t)bytes
                t0:(NSTimeInterval)t0
             finish:(void (^)(double secs, int64_t bytes, NSInteger okCount))finish
{
    if (i >= (NSInteger)jobs.count) {
        finish(bsp_now() - t0, bytes, 0);
        return;
    }
    {
        NSArray *j = jobs[(NSUInteger)i];
        [self benchFetchURL:_benchURL host:j[0]
                      start:[j[1] longLongValue] end:[j[2] longLongValue]
                       done:^(int64_t b, BOOL ok) {
            [self benchSerial:jobs i:i + 1 bytes:bytes + b t0:t0 finish:finish];
        }];
    }
}

/// 并发跑完一列任务（模拟多 CDN）
- (void)benchParallel:(NSArray<NSArray *> *)jobs
                   t0:(NSTimeInterval)t0
               finish:(void (^)(double secs, int64_t bytes, NSInteger okCount))finish
{
    dispatch_group_t g = dispatch_group_create();
    __block int64_t total = 0;
    __block NSInteger okCount = 0;

    for (NSArray *j in jobs) {
        dispatch_group_enter(g);
        [self benchFetchURL:_benchURL host:j[0]
                      start:[j[1] longLongValue] end:[j[2] longLongValue]
                       done:^(int64_t b, BOOL ok) {
            @synchronized (g) {
                total += b;
                if (ok) okCount++;
            }
            dispatch_group_leave(g);
        }];
    }
    dispatch_group_notify(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        double secs = bsp_now() - t0;
        int64_t bytes;
        NSInteger oks;
        @synchronized (g) { bytes = total; oks = okCount; }
        finish(secs, bytes, oks);
    });
}

- (void)runBenchmark
{
    NSArray<NSDictionary *> *snap;
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    NSMutableArray<NSArray *> *serialJobs = [NSMutableArray array];
    NSMutableArray<NSArray *> *parJobs = [NSMutableArray array];
    const int64_t chunk = 512 * 1024;
    int i;

    if (!_benchURL.length) return;

    if ([BSPCdnPool multiHostMode]) {
        /* 多 host 模式：选有热连接成功记录的节点，按实测速度从高到低，取前 4 */
        snap = [self hostSnapshot];
        NSMutableArray<NSDictionary *> *sorted = [[snap filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *d, id bindings) {
                return [d[@"enabled"] boolValue] && [d[@"ok"] longLongValue] > 0;
            }]] mutableCopy];
        [sorted sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"speed"] compare:a[@"speed"]];
        }];
        for (NSDictionary *d in sorted) {
            if (cands.count >= 4) break;
            [cands addObject:d[@"host"]];
        }
        if (cands.count == 0) {
            PLogProxy(@"A/B 实测跳过：还没有任何成功过的节点");
            return;
        }
    } else {
        /* 单 host 模式：A/B = 「同一原始 host 多连接 vs 单连接」。不要求有成功
         * 记录——哪怕之前全失败，也要测出"多连接是否更快"，这才是决定本模块去留
         * 的关键数据。host 直接取 benchURL 自己的（就是改写前的真实媒体地址）。 */
        NSString *orig = [BSPCdnPool hostOf:_benchURL];
        if (orig.length) [cands addObject:orig];
    }
    /* 不够 4 个就重复用同一个 —— 单 host 模式下 4 个全是同一台，正是
     * 「同一 CDN 开 4 条连接」的真实情形，与单连接串行可比。 */
    if (cands.count == 0) {
        PLogProxy(@"A/B 实测跳过：拿不到媒体 host");
        return;
    }
    while (cands.count < 4) [cands addObject:cands[0]];

    for (i = 0; i < 4; i++) {
        int64_t s = (int64_t)i * chunk;
        int64_t e = s + chunk - 1;
        [serialJobs addObject:@[cands[0], @(s), @(e)]];   /* A：全走同一台 */
        [parJobs    addObject:@[cands[(NSUInteger)i], @(s), @(e)]]; /* B：四台各一片 */
    }

    PLogProxy(@"A/B 实测开始：单连接 vs 4 连接并发，各 2 MiB（host %@）",
              [cands componentsJoinedByString:@", "]);

    {
        NSTimeInterval a0 = bsp_now();
        [self benchSerial:serialJobs i:0 bytes:0 t0:a0
                   finish:^(double secsA, int64_t bytesA, NSInteger okA) {
            double mbpsA = secsA > 0.05 ? (double)bytesA / secsA / 1048576.0 : 0.0;
            NSTimeInterval b0 = bsp_now();
            [self benchParallel:parJobs t0:b0
                         finish:^(double secsB, int64_t bytesB, NSInteger okB) {
                double mbpsB = secsB > 0.05 ? (double)bytesB / secsB / 1048576.0 : 0.0;
                double gain = mbpsA > 0.001 ? mbpsB / mbpsA : 0.0;
                NSString *line = [NSString stringWithFormat:
                    @"A/B 实测：单连接 %.2f MiB/s（%.2fs, %lld B, 成功%ld）"
                    @"  vs  4 连接并发 %.2f MiB/s（%.2fs, %lld B, 成功%ld）"
                    @"  → 并发收益 %.2fx%@",
                    mbpsA, secsA, (long long)bytesA, (long)okA,
                    mbpsB, secsB, (long long)bytesB, (long)okB,
                    gain,
                    (gain >= 1.05 ? @"（并发更快）"
                     : (gain > 0.01 ? @"（**并发更慢**）" : @"（样本不足）"))];
                [_lock lock];
                _benchLine = line;
                [_lock unlock];
                PLogProxy(@"%@", line);
                if (gain > 0.01 && gain < 1.05) {
                    PLogProxy(@"★ 你这条网络下并发是负收益。建议在设置面板里关掉"
                              @"「并发加速」，或把 BiliFast/mode.txt 写成 direct。");
                }
            }];
        }];
    }
}

- (void)scheduleBenchmarkWithURL:(NSString *)url
{
    if (_benchScheduled || !url.length) return;
    _benchScheduled = YES;
    [_lock lock];
    _benchURL = [url copy];
    [_lock unlock];

    /* 等 45 秒再跑：避开起播时最紧张的那一段，也不与首个缓冲竞争带宽 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try { [self runBenchmark]; }
        @catch (NSException *ex) { PLogProxy(@"A/B 实测异常：%@", ex.reason); }
    });
}

- (NSString *)benchmarkLine
{
    NSString *s;
    [_lock lock];
    s = _benchLine;
    [_lock unlock];
    return s;
}

#pragma mark - 自适应并发窗口（AIMD）
//
// 每完成 kAdaptEveryChunks 片评估一次：
//   有失败/超时  -> 窗口减半（最小 kWindowMin）—— 丢包就是拥塞信号，先退
//   吞吐提升 ≥15% -> 窗口 +2（最大 kWindowMax）—— 有余量就多用
//   其它          -> 保持
// 这跟 TCP 拥塞控制的思路一致：细管子（家用 WiFi）上会迅速降到很低，
// 粗管子（蜂窝）上会稳步涨上去。日志会记下每次调整，便于对照。
- (void)noteAdaptSample:(int64_t)bytes failed:(BOOL)failed
{
    BOOL changed = NO;
    NSInteger before = 0, after = 0, fails = 0;
    double speed = 0.0, prev = 0.0;

    [_lock lock];
    {
        double now = bsp_now();
        if (_adaptStart <= 0.0) _adaptStart = now;
        _adaptBytes += bytes;
        _adaptChunks++;
        if (failed) _adaptFails++;

        if (_adaptChunks >= kAdaptEveryChunks) {
            double dt = now - _adaptStart;
            if (dt > 0.5) {
                speed = (double)_adaptBytes / dt / 1048576.0;
                prev  = _adaptLastMiBps;
                before = _window;
                fails = _adaptFails;

                if (_adaptFails > 0) {
                    _window = MAX(_window / 2, kWindowMin);
                } else if (prev <= 0.001 || speed > prev * 1.15) {
                    _window = MIN(_window + 2, kWindowMax);
                }
                after = _window;
                changed = (after != before);
                _adaptLastMiBps = speed;
            }
            _adaptBytes = 0;
            _adaptChunks = 0;
            _adaptFails = 0;
            _adaptStart = now;
        }
    }
    [_lock unlock];

    if (changed) {
        PLogProxy(@"并发窗口 %ld → %ld（本轮 %.2f MiB/s%@）",
                  (long)before, (long)after, speed, fails > 0 ? @"，有失败故退让" : @"");
    }
}

- (int)hostIndexOf:(NSString *)host
{
    NSNumber *n;
    int idx;
    if (host.length == 0) return -1;
    [_lock lock];
    n = _hostIndex[host];
    idx = n ? n.intValue : -1;
    [_lock unlock];
    return idx;
}

#pragma mark - 顺序写回

- (void)flushWrites:(BSPConnContext *)ctx
{
    if (!ctx.url || ctx.closed || ctx.failed) return;

    for (;;) {
        NSNumber *key = @(ctx.nextWrite);
        NSData *d = ctx.pending[key];
        if (!d) break;
        [ctx.pending removeObjectForKey:key];

        if (!ctx.headerSent) {
            ctx.firstChunkArrived = YES;
            ctx.tFirst = ctx.tLast = bsp_now();
            [self sendHeaders:ctx chunkLength:d.length];
            if (ctx.failed) return;
            if (ctx.headOnly) { [self finishBody:ctx]; return; }
        }
        if (!bsp_write_all(ctx.fd, d.bytes, d.length)) { ctx.failed = YES; [self closeConn:ctx]; return; }
        ctx.bytesToClient += (int64_t)d.length;
        ctx.nextWrite     += (int64_t)d.length;
        ctx.tLast = bsp_now();

        if (ctx.total >= 0 && ctx.nextWrite > ctx.total - 1) { [self finishBody:ctx]; return; }
        if (ctx.reqEnd != INT64_MAX && ctx.nextWrite > ctx.reqEnd) { [self finishBody:ctx]; return; }
    }
}

- (void)sendHeaders:(BSPConnContext *)ctx chunkLength:(NSUInteger)len
{
    NSMutableString *h = [NSMutableString string];
    int64_t total = ctx.total;
    int64_t lastByte;

    if (total > 0) {
        lastByte = (ctx.reqEnd != INT64_MAX && ctx.reqEnd < total - 1) ? ctx.reqEnd : total - 1;
    } else {
        lastByte = (ctx.reqEnd != INT64_MAX) ? ctx.reqEnd : (ctx.reqStart + (int64_t)len - 1);
    }

    [h appendString:@"HTTP/1.1 206 Partial Content\r\n"];
    [h appendString:@"Content-Type: video/mp4\r\n"];
    [h appendFormat:@"Content-Range: bytes %lld-%lld/%@\r\n",
        (long long)ctx.reqStart, (long long)lastByte,
        total > 0 ? [NSString stringWithFormat:@"%lld", (long long)total] : @"*"];
    if (total > 0) [h appendFormat:@"Content-Length: %lld\r\n", (long long)(lastByte - ctx.reqStart + 1)];
    [h appendString:@"Accept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n"];
    [h appendString:@"X-BSP-Proxy: 1\r\n\r\n"];

    if (!bsp_write_all(ctx.fd, h.UTF8String, strlen(h.UTF8String))) { ctx.failed = YES; [self closeConn:ctx]; return; }
    ctx.headerSent = YES;
}

- (void)finishBody:(BSPConnContext *)ctx
{
    if (ctx.bodyDone) return;
    ctx.bodyDone = YES;
    {
        double dt = ctx.tLast - ctx.tRequest;      /* 从请求到达到送完：播放器真实等待 */
        double mib = (double)ctx.bytesToClient / 1048576.0;
        double mbps = dt > 0.02 ? mib / dt : 0.0;
        PLogProxy(@"完成 %@  %.2f MiB / %.3fs = %.2f MiB/s",
                  [self shortURL:ctx.url], mib, dt, mbps);
        [_lock lock];
        _servedBytes += ctx.bytesToClient;
        if (dt > 0.02) _servedSeconds += dt;
        _completedRequests++;
        _lastCompleteAt = bsp_now();
        if (mbps > _peakMiBps) _peakMiBps = mbps;
        [_lock unlock];
        [self noteAdaptSample:ctx.bytesToClient failed:NO];
    }
    [self closeConn:ctx];
}

#pragma mark - 简单响应

- (void)respondStatus:(NSInteger)code body:(NSString *)body ctx:(BSPConnContext *)ctx
{
    NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSString *resp = [NSString stringWithFormat:
        @"HTTP/1.1 %ld X\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        (long)code, (unsigned long)d.length];
    bsp_write_all(ctx.fd, resp.UTF8String, strlen(resp.UTF8String));
    bsp_write_all(ctx.fd, d.bytes, d.length);
    ctx.failed = YES;
    [self closeConn:ctx];
}

- (void)respondText:(NSString *)text ctx:(BSPConnContext *)ctx
{
    [self respondStatus:200 body:text ctx:ctx];
}

@end
