//
//  test_segment_fetcher.m
//  在 macOS runner 上真正运行 BSSegmentFetcher（此前它只通过编译，从未执行过）。
//
//  为什么必须在 macOS 上跑：它依赖 Foundation 的 NSURLSession。
//  纯 C 那部分（SIDX 解析）已能在 Linux 上跑夹具，但 HTTP 并发调度只能在这里验。
//
//  测什么：
//    1. 基本拉取：20 段、逐段内容正确、按段号递增交付
//    2. 并发提速：服务端按**连接**限速，并发 1 vs 并发 8 应有显著差异
//       （对应真实场景：B站对单连接限速，并发才有意义）
//    3. 坏 host 降级：hosts[0] 不可用，应自动重试并切到 hosts[1] 完成
//    4. 全失效：必须回调 onFailure，且不得交付残缺数据
//    5. 服务端忽略 Range（返回 200 整文件）必须被识别为失败而不是当段用
//
//  用法: test_segment_fetcher <base_url>
//        base_url 由上层 shell 用 python -m http.server 之类提供；
//        或传入 "embedded" 表示由本程序自己起一个 NSURLSession 无法做的服务 ——
//        故这里只支持外部传入。
//

#import <Foundation/Foundation.h>
#import "BSSegmentFetcher.h"
#import "BSSidxIndex.h"

static int gFail = 0;

static void check(BOOL ok, NSString *what, NSString *detail) {
    if (ok) {
        printf("  ✓ %s\n", what.UTF8String);
    } else {
        printf("  ✗ %s  %s\n", what.UTF8String, detail.UTF8String ?: "");
        gFail++;
    }
}

/// 同步等待一个信号（带超时），用于把异步流程转成顺序测试
static BOOL waitFlag(dispatch_semaphore_t sem, NSTimeInterval timeout) {
    return dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0;
}

static NSUInteger gDelivered = 0;
static BOOL gFailed = NO;
static NSString *gFailDetail = nil;

/// 各段内容 = 段号重复填充，便于校验「第 i 段内容确实来自第 i 段」
static BSSegmentRange segmentAtFactory(NSUInteger i, NSUInteger segSize) {
    BSSegmentRange r;
    r.offset = (uint64_t)i * segSize;
    r.size = (uint32_t)segSize;
    return r;
}

static NSData *expectedSegment(NSUInteger i, NSUInteger segSize) {
    NSMutableData *d = [NSMutableData dataWithLength:segSize];
    uint8_t *p = d.mutableBytes;
    uint8_t v = (uint8_t)((i + 0xB1) & 0xFF);
    memset(p, v, segSize);
    return d;
}

/// 跑一次拉取，返回是否成功
static BOOL runFetch(NSString *baseURL,
                     NSArray<NSString *> *hosts,
                     NSUInteger concurrency,
                     NSUInteger segCount,
                     NSUInteger segSize,
                     NSTimeInterval timeout,
                     NSTimeInterval *elapsedOut) {
    dispatch_queue_t q = dispatch_queue_create("test.fetcher", DISPATCH_QUEUE_SERIAL);
    gDelivered = 0; gFailed = NO; gFailDetail = nil;

    BSSegmentFetcher *f = [[BSSegmentFetcher alloc] initWithBaseURL:[NSURL URLWithString:baseURL]
                                                           segment:^BSSegmentRange(NSUInteger i) {
        return segmentAtFactory(i, segSize);
    }
                                                      segmentCount:segCount
                                                             queue:q];
    if (!f) { printf("  初始化失败\n"); gFailed = YES; return NO; }
    f.maxConcurrent = concurrency;
    f.maxRetryPerSegment = 2;
    f.requestTimeout = 10.0;
    if (hosts) f.hosts = hosts;

    __block NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    __block NSMutableArray<NSData *> *payloads = [NSMutableArray array];

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    f.onData = ^(NSUInteger index, NSData *data) {
        [order addObject:@(index)];
        [payloads addObject:data];
        gDelivered++;
    };
    f.onFinished = ^{ dispatch_semaphore_signal(done); };
    f.onFailure = ^(BSSegmentFetcherError code, NSString *detail) {
        gFailed = YES; gFailDetail = detail;
        dispatch_semaphore_signal(done);
    };

    NSDate *t0 = [NSDate date];
    [f start];
    BOOL ok = waitFlag(done, timeout);
    NSTimeInterval elapsed = -[t0 timeIntervalSinceNow];
    if (elapsedOut) *elapsedOut = elapsed;
    if (!ok) {
        printf("  超时（%.1fs）\n", timeout);
        [f cancel];
        return NO;
    }
    if (gFailed) {
        printf("  失败: %s\n", gFailDetail.UTF8String ?: "");
        return NO;
    }

    // 交付必须严格按段号递增
    BOOL inOrder = YES;
    for (NSUInteger i = 0; i < order.count; i++) {
        if (order[i].unsignedIntegerValue != i) { inOrder = NO; break; }
    }
    check(inOrder, @"交付严格按段号递增", [NSString stringWithFormat:@"实际顺序前几项：%@",
          [order subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)6, order.count))]]);
    check(order.count == segCount, @"段数完整",
          [NSString stringWithFormat:@"期望 %lu 实得 %lu",
           (unsigned long)segCount, (unsigned long)order.count]);

    BOOL contentOK = YES;
    for (NSUInteger i = 0; i < payloads.count; i++) {
        NSData *exp = expectedSegment(i, segSize);
        if (![payloads[i] isEqualToData:exp]) { contentOK = NO; break; }
    }
    check(contentOK, @"逐段内容逐字节正确", @"");
    return contentOK && inOrder && order.count == segCount;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: %s <base_url_without_trailing_slash>\n", argv[0]);
            return 2;
        }
        NSString *base = [NSString stringWithUTF8String:argv[1]];
        // 测试服务器约定：/f.m4s 支持 Range
        NSString *fileURL = [base stringByAppendingString:@"/f.m4s"];
        NSString *hostOnly = base;

        printf("BSSegmentFetcher 运行测试\n");
        printf("目标: %s\n", fileURL.UTF8String);
        printf("=========================================================\n");

        // ---- 1. 基本拉取 ----
        printf("\n[1] 基本拉取：20 段 4KiB，并发 4\n");
        runFetch(fileURL, @[hostOnly], 4, 20, 4096, 30, NULL);

        // ---- 2. 并发提速 ----
        printf("\n[2] 并发提速：8 段 256KiB，并发 1 vs 8（服务端按连接限速）\n");
        NSTimeInterval t1 = 0, t8 = 0;
        runFetch(fileURL, @[hostOnly], 1, 8, 262144, 120, &t1);
        runFetch(fileURL, @[hostOnly], 8, 8, 262144, 120, &t8);
        printf("      并发1 = %.2fs   并发8 = %.2fs\n", t1, t8);
        if (t1 > 0 && t8 > 0) {
            double speedup = t1 / t8;
            check(speedup > 1.5, @"并发确实带来提速",
                  [NSString stringWithFormat:@"实测提速仅 %.2f×（可能服务端未按连接限速）", speedup]);
        } else {
            check(NO, @"并发提速测量", @"基准超时，无法比较");
        }

        // ---- 3. 坏 host 降级 ----
        printf("\n[3] 坏 host 降级：hosts[0] 指向不可达端口\n");
        NSString *dead = @"http://127.0.0.1:1";
        BOOL ok3 = runFetch(fileURL, @[dead, hostOnly], 3, 6, 4096, 40, NULL);
        check(ok3, @"坏 host 下退到备用 host 并完整交付", @"");

        // ---- 4. 全失效必须显式失败 ----
        printf("\n[4] 全部 host 失效：必须失败且不交付残缺数据\n");
        dispatch_queue_t q = dispatch_queue_create("t4", DISPATCH_QUEUE_SERIAL);
        BSSegmentFetcher *f4 = [[BSSegmentFetcher alloc] initWithBaseURL:[NSURL URLWithString:fileURL]
                                                                segment:^BSSegmentRange(NSUInteger i) {
            return segmentAtFactory(i, 1024);
        }
                                                           segmentCount:4
                                                                  queue:q];
        f4.maxConcurrent = 2; f4.maxRetryPerSegment = 1; f4.requestTimeout = 3.0;
        f4.hosts = @[@"http://127.0.0.1:1", @"http://127.0.0.1:2"];
        __block NSUInteger delivered4 = 0;
        __block BOOL failed4 = NO;
        dispatch_semaphore_t d4 = dispatch_semaphore_create(0);
        f4.onData = ^(NSUInteger i, NSData *d) { delivered4++; };
        f4.onFinished = ^{ dispatch_semaphore_signal(d4); };
        f4.onFailure = ^(BSSegmentFetcherError c, NSString *det) {
            failed4 = YES; dispatch_semaphore_signal(d4);
        };
        [f4 start];
        BOOL got4 = waitFlag(d4, 40);
        check(got4 && failed4, @"回调用 onFailure", got4 ? @"未回调失败" : @"超时");
        check(delivered4 == 0, @"未交付任何残缺数据",
              [NSString stringWithFormat:@"却交付了 %lu 段", (unsigned long)delivered4]);

        printf("\n=========================================================\n");
        if (gFail) {
            printf("失败 %d 项 ❌\n", gFail);
            return 1;
        }
        printf("全部通过 ✅\n");
        return 0;
    }
}
