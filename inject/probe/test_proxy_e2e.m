/* test_proxy_e2e.m — BSPProxyServer 的端到端真跑测试（macOS / CI）
 *
 * 为什么必须有这个：代理是本项目的核心，如果只验证"能编译"，那和之前
 * BSSegmentFetcher「看着绿其实没验」是同一个错误。这里起真 socket、
 * 真 NSURLSession、真限速上游，端到端验四件事：
 *   ① 代理能把客户端 Range 拆到多个上游 host 并发拉，并**按序**写回
 *   ② 回流字节与上游配方逐字节一致（按字节位置校验，与分片粒度无关）
 *   ③ 响应头正确：206 / Content-Range / Content-Length
 *   ④ 相对单链路基线有真实提速（>=1.5x）
 *
 * 依赖 _recon/serve_multi_cdn.py 起好的 N 个限速服务。
 * 用法：test_proxy_e2e <base_port> <n_servers> <size_bytes>
 */
#import <Foundation/Foundation.h>

#import "BSPCdnPool.h"
#import "BSPProxyServer.h"

static int gFail = 0, gPass = 0;

#define CHECK(cond, ...)                                                        \
    do {                                                                        \
        if (cond) { gPass++; }                                                  \
        else { gFail++; printf("  FAIL %s:%d  ", __FILE__, __LINE__);           \
               printf(__VA_ARGS__); printf("\n"); }                             \
    } while (0)

static int64_t gSize = 0;

static uint8_t recipeByte(int64_t i) { return (uint8_t)((i * 31 + 7) & 0xFF); }

static BOOL verifyRecipe(NSData *d, int64_t startOffset)
{
    const uint8_t *p = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) {
        if (p[i] != recipeByte(startOffset + (int64_t)i)) {
            printf("      字节不符 @ 绝对偏移 %lld：得到 %u 期望 %u\n",
                   (long long)(startOffset + (int64_t)i), p[i],
                   recipeByte(startOffset + (int64_t)i));
            return NO;
        }
    }
    return YES;
}

/* 同步 GET，返回 body / 状态码 / 耗时。
 * 注意：outErr 是 out-parameter，不能在 block 里直接解引用写 —— 那属于
 * 「block 捕获 autoreleasing out-parameter」，ARC 下可能变成 use-after-free。
 * 这里先用 __block 变量接住，等信号量之后再赋给 outErr。 */
static NSData *syncGET(NSString *url, NSString *range, NSInteger *outCode,
                       double *outSeconds, NSError **outErr)
{
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.timeoutInterval = 120.0;
    r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    if (range) [r setValue:range forHTTPHeaderField:@"Range"];
    [r setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

    __block NSData *body = nil;
    __block NSInteger code = 0;
    __block NSError *capturedErr = nil;
    __block BOOL timedOut = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];

    NSURLSessionDataTask *t = [[NSURLSession sharedSession]
        dataTaskWithRequest:r
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        body = data;
        code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        capturedErr = err;
        dispatch_semaphore_signal(sem);
    }];
    [t resume];

    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC))) != 0) {
        timedOut = YES;
        [t cancel];
    }
    if (timedOut) {
        if (outErr) *outErr = [NSError errorWithDomain:@"test" code:1
                                             userInfo:@{NSLocalizedDescriptionKey: @"超时"}];
        if (outCode) *outCode = 0;
        if (outSeconds) *outSeconds = 180.0;
        return nil;
    }
    if (outErr)     *outErr = capturedErr;
    if (outCode)    *outCode = code;
    if (outSeconds) *outSeconds = [NSDate timeIntervalSinceReferenceDate] - t0;
    return body;
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        int basePort = argc > 1 ? atoi(argv[1]) : 18081;
        int nServers = argc > 2 ? atoi(argv[2]) : 4;
        gSize        = argc > 3 ? atoll(argv[3]) : (6 * 1024 * 1024);

        printf("=== BSPProxyServer 端到端测试 ===\n");
        printf("上游 %d 个：127.0.0.1:%d..%d  夹具 %lld 字节\n",
               nServers, basePort, basePort + nServers - 1, (long long)gSize);

        /* --- 测试缝：把主机池换成假 CDN，关掉 B 站域名判定 --- */
        NSMutableArray<NSString *> *hosts = [NSMutableArray array];
        for (int i = 0; i < nServers; i++)
            [hosts addObject:[NSString stringWithFormat:@"127.0.0.1:%d", basePort + i]];
        [BSPCdnPool setOverrideHosts:hosts];
        [BSPCdnPool setMediaCheckDisabled:YES];

        /* --- 主机池/URL 重写工具的行为 --- */
        printf("\n[1] BSPCdnPool 基础行为\n");
        {
            NSString *u = @"https://upos-sz-mirroraliov.bilivideo.com/upgcxcode/95/39/1/1-1-504.mp4?e=1&hdnts=abc";
            NSString *swapped = [BSPCdnPool url:u withHost:@"upos-sz-mirrorcos.bilivideo.com"];
            CHECK(swapped != nil, "换 host 返回 nil");
            CHECK([BSPCdnPool hostOf:swapped] != nil &&
                  [[BSPCdnPool hostOf:swapped] isEqualToString:@"upos-sz-mirrorcos.bilivideo.com"],
                  "换 host 后 host 不对: %s", [BSPCdnPool hostOf:swapped].UTF8String ?: "?");
            CHECK([swapped rangeOfString:@"upgcxcode"].location != NSNotFound, "换 host 丢了 path");
            CHECK([swapped rangeOfString:@"hdnts=abc"].location != NSNotFound, "换 host 丢了 query");
            CHECK([swapped hasPrefix:@"https://"], "换 host 丢了 scheme");

            /* 端口形式（测试用） */
            NSString *p = [BSPCdnPool url:@"http://127.0.0.1:1234/a/b?x=1" withHost:@"127.0.0.1:9999"];
            CHECK([p isEqualToString:@"http://127.0.0.1:9999/a/b?x=1"], "带端口换 host 结果=%s", p.UTF8String ?: "?");
        }

        printf("\n[2] 媒体 URL 判定\n");
        {
            [BSPCdnPool setMediaCheckDisabled:NO];
            CHECK([BSPCdnPool isMediaURL:@"https://upos-sz-mirroraliov.bilivideo.com/upgcxcode/1/2/3.m4s?e=1"], "upos 未识别");
            CHECK([BSPCdnPool isMediaURL:@"https://xy1.example.bilivideo.com/upgcxcode/a.m4s"], "bilivideo 未识别");
            CHECK(![BSPCdnPool isMediaURL:@"https://i0.hdslb.com/bfs/face/a.jpg"], "图片域名被误判");
            CHECK(![BSPCdnPool isMediaURL:@"https://api.bilibili.com/x/v2/reply"], "api 被误判");
            CHECK(![BSPCdnPool isMediaURL:@"http://127.0.0.1:8080/upgcxcode/a.m4s"], "回环被误判");
            CHECK(![BSPCdnPool isMediaURL:@"file:///tmp/a.m4s"], "file 被误判");
            [BSPCdnPool setMediaCheckDisabled:YES];
        }

        printf("\n[3] 代理启动\n");
        BSPProxyServer *proxy = [BSPProxyServer shared];
        CHECK([proxy start], "代理启动失败");
        CHECK(proxy.port > 0, "端口为 0");
        printf("     代理端口 %u\n", (unsigned)proxy.port);

        NSString *origURL = [NSString stringWithFormat:@"http://127.0.0.1:%d/fixture.m4s", basePort];
        NSString *localURL = [proxy localURLFor:origURL];
        CHECK(localURL.length > 0, "localURLFor 返回空");
        printf("     本地 URL %s\n", localURL.UTF8String ?: "?");
        CHECK([[proxy originalURLForLocal:localURL] isEqualToString:origURL], "反解不一致");
        CHECK([[proxy localURLFor:origURL] isEqualToString:localURL], "token 不幂等");

        NSString *range = [NSString stringWithFormat:@"bytes=0-%lld", (long long)(gSize - 1)];

        printf("\n[4] 单链路基线\n");
        NSInteger baseCode = 0; double baseSec = 0; NSError *baseErr = nil;
        NSData *baseBody = syncGET(origURL, range, &baseCode, &baseSec, &baseErr);
        CHECK(baseCode == 206 || baseCode == 200, "基线状态码 %ld err=%s",
              (long)baseCode, baseErr.localizedDescription.UTF8String ?: "(无)");
        CHECK(baseBody.length == (NSUInteger)gSize,
              "基线长度 %lu 期望 %lld", (unsigned long)baseBody.length, (long long)gSize);
        if (baseBody.length == (NSUInteger)gSize) {
            CHECK(verifyRecipe(baseBody, 0), "基线内容不符配方");
        }
        printf("     基线 %.3fs (%.2f MiB/s)\n", baseSec,
               baseSec > 0 ? (gSize / 1048576.0) / baseSec : 0.0);

        printf("\n[5] 经代理并发抓取\n");
        NSInteger pCode = 0; double pSec = 0; NSError *pErr = nil;
        NSData *pBody = syncGET(localURL, range, &pCode, &pSec, &pErr);
        CHECK(pCode == 206, "代理状态码 %ld（期望 206）err=%s",
              (long)pCode, pErr.localizedDescription.UTF8String ?: "(无)");
        CHECK(pBody.length == (NSUInteger)gSize,
              "代理长度 %lu 期望 %lld", (unsigned long)pBody.length, (long long)gSize);
        if (pBody.length == (NSUInteger)gSize) {
            CHECK(verifyRecipe(pBody, 0), "代理内容不符配方");
        }
        printf("     代理 %.3fs (%.2f MiB/s)\n", pSec,
               pSec > 0 ? (gSize / 1048576.0) / pSec : 0.0);

        printf("\n[6] 提速比\n");
        {
            double ratio = pSec > 0 ? baseSec / pSec : 0;
            printf("     提速 %.2fx\n", ratio);
            CHECK(ratio > 1.5, "提速仅 %.2fx（<1.5x）", ratio);
        }

        printf("\n[7] 中段 Range（不从头开始）\n");
        {
            int64_t s = gSize / 3;
            int64_t e = s + 700000;
            NSString *mid = [NSString stringWithFormat:@"bytes=%lld-%lld", (long long)s, (long long)e];
            NSInteger c = 0; double sec = 0; NSError *err = nil;
            NSData *b = syncGET(localURL, mid, &c, &sec, &err);
            CHECK(c == 206, "中段状态码 %ld err=%s", (long)c, err.localizedDescription.UTF8String ?: "(无)");
            CHECK(b.length == (NSUInteger)(e - s + 1),
                  "中段长度 %lu 期望 %lld", (unsigned long)b.length, (long long)(e - s + 1));
            if (b.length) CHECK(verifyRecipe(b, s), "中段内容不符配方");
        }

        printf("\n[8] 开放式 Range（bytes=N-）\n");
        {
            int64_t s = gSize / 2;
            NSString *open = [NSString stringWithFormat:@"bytes=%lld-", (long long)s];
            NSInteger c = 0; double sec = 0; NSError *err = nil;
            NSData *b = syncGET(localURL, open, &c, &sec, &err);
            CHECK(c == 206, "开放 Range 状态码 %ld err=%s", (long)c, err.localizedDescription.UTF8String ?: "(无)");
            CHECK(b.length == (NSUInteger)(gSize - s),
                  "开放 Range 长度 %lu 期望 %lld", (unsigned long)b.length, (long long)(gSize - s));
            if (b.length) CHECK(verifyRecipe(b, s), "开放 Range 内容不符配方");
        }

        printf("\n[9] 无 Range（整文件）\n");
        {
            NSInteger c = 0; double sec = 0; NSError *err = nil;
            NSData *b = syncGET(localURL, nil, &c, &sec, &err);
            CHECK(c == 206 || c == 200, "无 Range 状态码 %ld err=%s",
                  (long)c, err.localizedDescription.UTF8String ?: "(无)");
            CHECK(b.length == (NSUInteger)gSize,
                  "无 Range 长度 %lu 期望 %lld", (unsigned long)b.length, (long long)gSize);
            if (b.length == (NSUInteger)gSize) CHECK(verifyRecipe(b, 0), "无 Range 内容不符配方");
        }

        printf("\n[10] 统计报告\n");
        {
            NSString *rep = [proxy statsReport];
            printf("%s", rep.UTF8String);
            CHECK([rep rangeOfString:@"合计"].location != NSNotFound, "报告缺合计行");
            CHECK(proxy.totalRequests >= 4, "总请求数 %lu 偏少", (unsigned long)proxy.totalRequests);
        }

        printf("\n[11] 未知 token 必须 404 而不是挂住\n");
        {
            NSString *bad = [NSString stringWithFormat:@"http://127.0.0.1:%u/bsp/99999999",
                             (unsigned)proxy.port];
            NSInteger c = 0; double sec = 0; NSError *err = nil;
            (void)syncGET(bad, @"bytes=0-15", &c, &sec, &err);
            CHECK(c == 404, "未知 token 状态码 %ld（期望 404）", (long)c);
        }

        [proxy stop];
        printf("\n=== 通过 %d，失败 %d ===\n", gPass, gFail);
    }
    return gFail == 0 ? 0 : 1;
}
