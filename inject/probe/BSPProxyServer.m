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
static const NSInteger kWindow           = 16;            /* 每连接的并发窗口 */
static const NSInteger kBlacklistErrors  = 2;             /* 连续错误到几次拉黑 */
static const NSInteger kMaxInflightPerHost = 3;           /* 每主机在途分片上限（防连接风暴） */
static const NSInteger kChunkRetries     = 1;             /* 单个分片最多换几台重试 */
static const double   kFirstChunkTimeout = 2.5;           /* 首片超过这么久就 fail-open 回源 */
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
@property (nonatomic, assign) NSUInteger completedRequests;
@property (nonatomic, assign) double peakMiBps;
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
    }
    return self;
}

- (void)dealloc { if (_planner) bsp_ms_destroy(_planner); }

#pragma mark - 模式开关

+ (NSString *)logDir
{
    NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = d.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"biliprobe"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
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
        cfg.HTTPMaximumConnectionsPerHost = 8;
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

/* 全局主机池与调度器：所有 URL 共享，跨请求积累测速与黑名单 */
- (void)buildPlanner
{
    NSMutableArray<NSString *> *all = [[BSPCdnPool effectiveHostsForPlanner] mutableCopy];
    if (!all) all = [NSMutableArray array];

    _hosts = all;
    [_hostIndex removeAllObjects];
    for (NSUInteger i = 0; i < all.count; i++) _hostIndex[all[i]] = @(i);

    if (_planner) { bsp_ms_destroy(_planner); _planner = NULL; }
    _planner = bsp_ms_create((int)all.count, kPerHostCapBps, kPerHostCapBps);
    /* 每主机在途上限：防止调度器学会哪台快之后把十几个分片同时压过去，
     * 对端会把过量并发连接直接掐断（真机日志里的「网络连接已中断」）。 */
    bsp_ms_set_max_inflight(_planner, (int)kMaxInflightPerHost);
    for (NSUInteger i = 0; i < all.count; i++)
        bsp_ms_set_host_name(_planner, (int)i, all[i].UTF8String);
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
        int idx = bsp_ms_host_count(_planner);
        if (idx < BSP_MS_MAX_HOSTS) {
            bsp_ms_set_host_name(_planner, idx, host.UTF8String);
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
    if (originalURL.length == 0 || !_running) return nil;

    [_lock lock];
    token = _urlToToken[originalURL];
    if (!token) {
        token = [NSString stringWithFormat:@"%lu", (unsigned long)(++_tokenSeq)];
        _urlToToken[originalURL] = token;
        _tokenToURL[token] = originalURL;
        _rewrittenCount++;
    }
    [_lock unlock];

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

/// URL 的紧凑写法：host + 末段路径。日志里塞完整签名 URL 会把有用信息淹掉。
- (NSString *)shortURL:(NSString *)url
{
    NSURL *u = [NSURL URLWithString:url ?: @""];
    NSString *last = u.lastPathComponent ?: @"?";
    return [NSString stringWithFormat:@"%@/…/%@", u.host ?: @"?", last];
}

/// 一行式吞吐摘要，供心跳与结论段使用。
///
/// 这里刻意给出一个**不需要人来主观判断**的量化指标：并发收益倍数。
///   分子 = 单个客户端请求里，播放器实际体验到的峰值均速
///          （代理服务完这一条 Range 的 字节/墙钟时间）
///   分母 = 本次会话里最快的那台 CDN，单独服务请求时的均速
/// 两者都是**同一次会话、同一条网络、同一批 CDN** 上测出来的，
/// 所以比值 > 1 就说明「把一条连接拆到多台 CDN 并发」确实比单台快；
/// 比值 ≈ 1 说明并发没带来收益（比如瓶颈根本不在单台 CDN 的带宽上）。
/// 注意它比较的是「经代理」对「单台 CDN」，不是「经代理」对「播放器直连」——
/// 后者需要关掉改写再跑一遍才能测，属于对照组的事。
- (NSString *)throughputLine
{
    NSString *s;
    [_lock lock];
    {
        double mib = (double)_servedBytes / 1048576.0;
        double agg = _servedSeconds > 0.05 ? mib / _servedSeconds : 0.0;
        double bestHost = 0.0;
        NSString *bestHostName = nil;
        double gain = 0.0;
        for (NSString *k in _hostStats) {
            BSPProxyHostStat *st = _hostStats[k];
            if (st.bytes <= 0 || st.seconds <= 0.01) continue;
            {
                double sp = (double)st.bytes / st.seconds / 1048576.0;
                if (sp > bestHost) { bestHost = sp; bestHostName = st.host; }
            }
        }
        if (bestHost > 0.001 && _peakMiBps > 0.001) gain = _peakMiBps / bestHost;

        s = [NSString stringWithFormat:
             @"代理：请求=%lu 完成=%lu 上游分片=%lu 失败=%lu 302回源=%lu | "
             @"送达 %.2f MiB 累计均速 %.2f MiB/s 单请求峰值 %.2f MiB/s | "
             @"最快单主机 %@ %.2f MiB/s → 并发收益 %.2fx | 重写URL=%lu",
             (unsigned long)_totalRequests, (unsigned long)_completedRequests,
             (unsigned long)_totalChunks, (unsigned long)_failedChunks,
             (unsigned long)_redirects,
             mib, agg, _peakMiBps,
             bestHostName ?: @"(尚未测到)", bestHost,
             gain,
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
    window = (ctx.total < 0 && ctx.reqEnd == INT64_MAX) ? 2 : kWindow;

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
        /* 第一片固定交给 URL 自己的 host。
         *
         * 为什么：真机日志里出现过连续三次「首片 4 秒未到 -> fail-open 回源」——
         * 因为冷启动时调度器对所有候选主机都没有测速数据，只能按顺序试，
         * 撞上几台不响应/掐连接的节点就把关键路径堵死了。
         * 而 URL 自己的 host 是签名签发方，实测也是最快的那台（2.28 MiB/s）。
         * 让关键路径从一台**已知可用**的机器起步，之后再由测速数据决定去向。 */
        if (s == ctx.reqStart && ctx.originHostIdx >= 0 && bsp_ms_is_healthy(_planner, ctx.originHostIdx))
            hostIdx = ctx.originHostIdx;
        else
            hostIdx = bsp_ms_pick_capped(_planner, need, now);
        if (hostIdx >= 0) wait = bsp_ms_wait_for(_planner, hostIdx, need, now);
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
    NSString *upURL = [BSPCdnPool url:ctx.url withHost:host];
    NSMutableURLRequest *r;
    NSTimeInterval t0 = bsp_now();
    BSPConnContext *wc = ctx;
    int64_t len = e - s + 1;

    if (!upURL) { [self chunkFailed:ctx start:s end:e host:host reason:@"URL 拼接失败" retry:retry]; return; }
    if (!_session) { [self chunkFailed:ctx start:s end:e host:host reason:@"session 未就绪" retry:retry]; return; }

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
                [self noteHost:host bytes:0 seconds:dt ok:NO];
                [self chunkFailed:wc start:s end:e host:host reason:why retry:retry];
                return;
            }

            [self noteHost:host bytes:(int64_t)data.length seconds:dt ok:YES];

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
            if (idx >= 0 && st.consecutiveErrors >= kBlacklistErrors && bsp_ms_is_healthy(_planner, idx)) {
                bsp_ms_set_healthy(_planner, idx, 0);
                blacklisted = YES;
            }
        }
        _failedChunks++;
        if (retry > 0) {
            nextHost = bsp_ms_pick(_planner, need, bsp_now());
            if (nextHost >= 0) bsp_ms_begin(_planner, nextHost, need, bsp_now());
        }
    }
    [_lock unlock];

    PLogProxy(@"分片失败 %lld-%lld @ %@ (%@) 重试余 %ld",
              (long long)s, (long long)e, host, reason, (long)retry);
    if (blacklisted) PLogProxy(@"拉黑 %@（连续 %ld 次失败）", host, (long)kBlacklistErrors);

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

- (void)noteHost:(NSString *)host bytes:(int64_t)bytes seconds:(double)dt ok:(BOOL)ok
{
    [_lock lock];
    {
        BSPProxyHostStat *s = [self statFor:host];
        if (ok) { s.bytes += bytes; s.seconds += dt; s.ok++; s.consecutiveErrors = 0; }
        else    { s.fail++; s.consecutiveErrors++; }
    }
    [_lock unlock];
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
        if (mbps > _peakMiBps) _peakMiBps = mbps;
        [_lock unlock];
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
