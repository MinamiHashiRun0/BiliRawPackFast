/* BSPCdnPool.m */
#import "BSPCdnPool.h"

static NSMutableOrderedSet<NSString *> *gSeen = nil;
static NSLock *gSeenLock = nil;
static NSArray<NSString *> *gOverrideHosts = nil;
static BOOL gMediaCheckDisabled = NO;

@interface BSPCdnPool ()
+ (void)noteHost:(NSString *)host;   /* 内部：记录见过的媒体 host */
@end

@implementation BSPCdnPool

+ (void)initialize
{
    if (self == [BSPCdnPool class]) {
        gSeen = [NSMutableOrderedSet orderedSet];
        gSeenLock = [[NSLock alloc] init];
    }
}

+ (NSArray<NSString *> *)mainlandMirrors
{
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{        a = @[
            @"upos-sz-mirrorali.bilivideo.com",
            @"upos-sz-mirroralib.bilivideo.com",
            @"upos-sz-mirrorcos.bilivideo.com",
            @"upos-sz-mirrorcosb.bilivideo.com",
            @"upos-sz-mirrorhw.bilivideo.com",
            @"upos-sz-mirrorhwb.bilivideo.com",
            @"upos-sz-mirror08c.bilivideo.com",
            @"upos-sz-mirror08h.bilivideo.com",
            @"upos-sz-mirror08ct.bilivideo.com",
            @"upos-sz-mirroraliov.bilivideo.com",
            @"upos-sz-mirrorcosov.bilivideo.com",
            @"upos-sz-mirrorhwov.bilivideo.com",
            @"upos-sz-mirrorbov.bilivideo.com",
            @"upos-sz-mirrorakam.akamaized.net",
            @"upos-hz-mirrorakam.akamaized.net",
            @"upos-tf-all-hw.bilivideo.com",
            @"upos-tf-all-tx.bilivideo.com",
            @"upos-tf-all-ali.bilivideo.com",
            @"cn-hk-eq-bcache-01.bilivideo.com",
            @"cn-hk-eq-bcache-02.bilivideo.com",
            /* 注意：这里**没有** .bilivideo.cn 域名。
             * 真机实测 upos-sz-mirrorali.bilivideo.cn 直接返回 403 ——
             * 签名不跨 .cn/.com 域，放进来只会白白浪费一次重试。 */
        ];
    });
    return a;
}

+ (NSArray<NSString *> *)overseaHosts
{
    static NSArray *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            @"upos-sz-mirroraliov.bilivideo.com",
            @"upos-sz-mirrorcosov.bilivideo.com",
            @"upos-sz-mirrorhwov.bilivideo.com",
            @"upos-hz-mirrorakam.akamaized.net",
            @"upos-sz-mirrorakam.akamaized.net",
            @"cn-hk-eq-bcache-01.bilivideo.com",
        ];
    });
    return a;
}

+ (void)setOverrideHosts:(NSArray<NSString *> *)hosts  { gOverrideHosts = hosts.copy; }
+ (void)setMediaCheckDisabled:(BOOL)disabled          { gMediaCheckDisabled = disabled; }

/* hostSpec 允许带端口（"127.0.0.1:18081"），测试用；生产里都是纯域名 */
static void bsp_split_host(NSString *spec, NSString **outHost, NSNumber **outPort)
{
    NSRange colon = [spec rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound && colon.location > 0 &&
        [spec rangeOfString:@"]"].location == NSNotFound) {
        NSString *portStr = [spec substringFromIndex:NSMaxRange(colon)];
        if (portStr.length && [portStr rangeOfCharacterFromSet:
                [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
            *outHost = [spec substringToIndex:colon.location];
            *outPort = @(portStr.integerValue);
            return;
        }
    }
    *outHost = spec;
    *outPort = nil;
}

+ (NSString *)hostOf:(NSString *)urlString
{
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return nil;
    NSURL *u = [NSURL URLWithString:urlString];
    NSString *h = u.host;
    if (h.length == 0) {                      /* 兼容 //host/path 形式 */
        NSRange r = [urlString rangeOfString:@"://"];
        if (r.location != NSNotFound) {
            NSString *rest = [urlString substringFromIndex:NSMaxRange(r)];
            NSRange slash = [rest rangeOfString:@"/"];
            h = slash.location == NSNotFound ? rest : [rest substringToIndex:slash.location];
            NSRange at = [h rangeOfString:@"@"];
            if (at.location != NSNotFound) h = [h substringFromIndex:NSMaxRange(at)];
        }
    }
    return h.length ? h.lowercaseString : nil;
}

+ (BOOL)isPcdnHost:(NSString *)host
{
    if (host.length == 0) return NO;
    return [host rangeOfString:@".mcdn.bilivideo."].location != NSNotFound ||
           [host rangeOfString:@".pcdn.bilivideo."].location != NSNotFound ||
           [host hasPrefix:@"p2p-"] ||
           [host rangeOfString:@"szbdyd.com"].location != NSNotFound;
}

+ (BOOL)isMediaURL:(NSString *)urlString
{
    NSString *host;
    if (![urlString isKindOfClass:[NSString class]] || urlString.length < 12) return NO;
    if (gMediaCheckDisabled) return YES;

    /* 只处理 http/https，避免把 file:// 或本地回环再套一层 */
    if (![urlString hasPrefix:@"http://"] && ![urlString hasPrefix:@"https://"]) return NO;
    if ([urlString rangeOfString:@"127.0.0.1"].location != NSNotFound) return NO;
    if ([urlString rangeOfString:@"localhost"].location != NSNotFound) return NO;

    host = [self hostOf:urlString];
    if (host.length == 0) return NO;

    /* 视频 CDN 家族 */
    BOOL hostLooksCdn =
        [host hasPrefix:@"upos-"] ||
        [host hasSuffix:@".bilivideo.com"] ||
        [host hasSuffix:@".bilivideo.cn"] ||
        [host hasSuffix:@".akamaized.net"] ||
        [host hasPrefix:@"cn-"] ||
        [host hasSuffix:@".szbdyd.com"] ||
        [host rangeOfString:@"bilivideo"].location != NSNotFound;

    if (!hostLooksCdn) return NO;

    /* 排除图片/静态资源域名：这些走重定向没意义还可能坏事 */
    if ([host hasPrefix:@"i0."] || [host hasPrefix:@"i1."] || [host hasPrefix:@"i2."] ||
        [host hasPrefix:@"s1."] || [host hasPrefix:@"api."] || [host hasPrefix:@"app."] ||
        [host hasPrefix:@"grpc."] || [host hasPrefix:@"broadcast."]) {
        return NO;
    }

    /* 真正判定：DASH 媒体路径特征 */
    if ([urlString rangeOfString:@"/upgcxcode/"].location != NSNotFound) return YES;
    if ([urlString rangeOfString:@".m4s"].location != NSNotFound) return YES;
    if ([urlString rangeOfString:@"hdnts="].location != NSNotFound) return YES;
    if ([urlString rangeOfString:@"upsig="].location != NSNotFound) return YES;

    /* 兜底：upos-* 域名的任意路径都算（B 站 upos 只服务媒体） */
    if ([host hasPrefix:@"upos-"]) return YES;

    return NO;
}

+ (NSString *)url:(NSString *)urlString withHost:(NSString *)newHost
{
    NSURLComponents *c;
    NSURL *u;
    NSString *pureHost = newHost;
    NSNumber *port = nil;
    if (urlString.length == 0 || newHost.length == 0) return nil;

    bsp_split_host(newHost, &pureHost, &port);

    u = [NSURL URLWithString:urlString];
    if (u) {
        c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
        if (c) {
            c.host = pureHost;
            if (port) c.port = port;
            return c.URL.absoluteString;
        }
    }

    /* NSURLComponents 对某些畸形查询串会失败，退回手写拼接 */
    {
        NSRange r = [urlString rangeOfString:@"://"];
        NSString *scheme, *rest, *tail;
        NSRange slash;
        if (r.location == NSNotFound) return nil;
        scheme = [urlString substringToIndex:r.location];
        rest   = [urlString substringFromIndex:NSMaxRange(r)];
        slash  = [rest rangeOfString:@"/"];
        if (slash.location == NSNotFound) {
            tail = @"";
        } else {
            tail = [rest substringFromIndex:slash.location];
        }
        return [NSString stringWithFormat:@"%@://%@%@", scheme, newHost, tail];
    }
}

+ (NSArray<NSString *> *)candidateHostsFor:(NSString *)urlString
{
    NSString *orig = [self hostOf:urlString];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    if (gOverrideHosts.count) {
        for (NSString *h in gOverrideHosts) if (![seen containsObject:h]) { [seen addObject:h]; [out addObject:h]; }
        if (orig.length && ![seen containsObject:orig]) [out insertObject:orig atIndex:0];
        return out;
    }

    if (orig.length) { [seen addObject:orig]; }

    /* 顺序：先同族镜像（同区域不同厂商，签名互通概率最高），再海外，再通用 */
    for (NSString *h in [self mainlandMirrors]) {
        if (![seen containsObject:h]) { [seen addObject:h]; [out addObject:h]; }
    }
    for (NSString *h in [self overseaHosts]) {
        if (![seen containsObject:h]) { [seen addObject:h]; [out addObject:h]; }
    }
    if (orig.length) { [out insertObject:orig atIndex:0]; }
    return out;
}

+ (BOOL)multiHostMode { return gOverrideHosts.count > 0; }

+ (NSArray<NSString *> *)effectiveHostsForPlanner
{
    /* 单 host 模式（默认）：不预填候选池。海外用户从马来西亚直连国内 sz 镜像
     * 多数超时/中断（真机日志 36 次「网络连接已中断」），把分片散过去只会拖慢
     * 关键路径、触发 fail-open。改为每请求只用它自己的原始 host（通常是海外 CDN），
     * 多分片并发 = 多条连接打同一海外 CDN = 绕过 per-connection 限速。
     *
     * 想用旧「散到多 host」行为：在 Documents/BiliFast/hosts.txt 里写 host 列表，
     * 即进入多 host 模式，本方法返回该 override。 */
    return gOverrideHosts ?: @[];
}

+ (NSArray<NSString *> *)seenMediaHosts
{
    NSArray *r;
    [gSeenLock lock];
    r = gSeen.array;
    [gSeenLock unlock];
    return r;
}

/* 记录一次见到的媒体 host（内部使用，供日志） */
+ (void)noteHost:(NSString *)host
{
    if (host.length == 0) return;
    [gSeenLock lock];
    if (gSeen.count < 200 && ![gSeen containsObject:host]) [gSeen addObject:host];
    [gSeenLock unlock];
}

@end
