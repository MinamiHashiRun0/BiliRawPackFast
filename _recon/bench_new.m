/* A/B 基准的默认测量范围。真正能测多远还要看探测片学到的文件总长 ——
 * 文件比它小就按文件来。 */
static const int64_t kBenchBudgetDefault = 2 * 1024 * 1024;

/// 按当前模式挑出「取数真正走的那台 host」。三种模式都不要求历史成功记录。
- (NSString *)benchHostForMode
{
    NSString *h = nil;

    if ([BSPCdnPool mode] == BSPCdnModeSingle) {
        /* 单 CDN 模式：就是钉住的那台 */
        h = [BSPCdnPool pinnedHost];
    } else if ([BSPCdnPool multiHostMode]) {
        /* 多 CDN 模式：取有成功记录、实测最快的那个候选项 */
        NSMutableArray<NSDictionary *> *sorted = [[[self hostSnapshot]
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(NSDictionary *d, id bindings) {
                    return [d[@"enabled"] boolValue] && [d[@"ok"] longLongValue] > 0;
                }]] mutableCopy];
        [sorted sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"speed"] compare:a[@"speed"]];
        }];
        if (sorted.count) h = sorted.firstObject[@"host"];
    }

    /* Follow 模式（以及上面没挑出来时）：用 benchURL 自己的 host，
     * 也就是改写前的真实媒体地址。 */
    if (!h.length) h = [BSPCdnPool hostOf:_benchURL];
    return h;
}

- (void)benchJobsWithBudget:(int64_t)budget host:(NSString *)host
{
    const int64_t chunk = kChunkBytes;
    NSMutableArray<NSArray *> *serialJobs = [NSMutableArray array];
    NSMutableArray<NSArray *> *parJobs    = [NSMutableArray array];
    NSInteger n = (NSInteger)(budget / chunk);
    NSInteger i;

    if (n > 4) n = 4;          /* 每腿最多 4 片：与旧版可比，也不至于太吃带宽 */
    if (n < 2) {
        PLogProxy(@"A/B 实测跳过：可用范围不足（%lld B）", (long long)budget);
        return;
    }

    for (i = 0; i < n; i++) {
        int64_t s = (int64_t)i * chunk;
        int64_t e = s + chunk - 1;
        /* 两条腿取**完全相同**的范围，只有串行/并发之分 —— 收益比值才只反映
         * 并发本身。旧版给并发腿挑了不同 host，单 host 模式下虽然退化成同一台，
         * 但语义上是两回事，容易看错。 */
        [serialJobs addObject:@[host, @(s), @(e)]];
        [parJobs    addObject:@[host, @(s), @(e)]];
    }

    PLogProxy(@"A/B 实测开始：单连接 vs %ld 连接并发，各 %.2f MiB（host %@）",
              (long)n, (double)(n * chunk) / 1048576.0, host);

    {
        NSTimeInterval a0 = bsp_now();
        [self benchSerial:serialJobs i:0 bytes:0 ok:0 t0:a0
                   finish:^(double secsA, int64_t bytesA, NSInteger okA) {
            double mbpsA = secsA > 0.05 ? (double)bytesA / secsA / 1048576.0 : 0.0;
            NSTimeInterval b0 = bsp_now();
            [self benchParallel:parJobs t0:b0
                         finish:^(double secsB, int64_t bytesB, NSInteger okB) {
                double mbpsB = secsB > 0.05 ? (double)bytesB / secsB / 1048576.0 : 0.0;
                double gain  = mbpsA > 0.001 ? mbpsB / mbpsA : 0.0;
                /* 只有两腿都拿满才是干净样本。真机出过「成功2/4」——
                 * 那是因为测到文件末尾之外拿了 416，不是网络问题。 */
                BOOL clean = (okA == n && okB == n);

                NSString *line = [NSString stringWithFormat:
                    @"A/B 实测：单连接 %.2f MiB/s（%.2fs, 成功%ld/%ld）"
                    @"  vs  %ld 连接并发 %.2f MiB/s（%.2fs, 成功%ld/%ld）"
                    @"  → 并发收益 %.2fx%@%@",
                    mbpsA, secsA, (long)okA, (long)n,
                    (long)n, mbpsB, secsB, (long)okB, (long)n,
                    gain,
                    (gain >= 1.05 ? @"（并发更快）"
                     : (gain > 0.01 ? @"（**并发更慢**）" : @"（样本不足）")),
                    clean ? @"" : @"  ⚠ 有分片失败，本次数值不可信"];

                [_lock lock];
                _benchLine = line;
                [_lock unlock];
                PLogProxy(@"%@", line);

                if (clean && gain > 0.01 && gain < 1.05) {
                    PLogProxy(@"★ 你这条网络下并发是负收益。建议在设置面板里关掉"
                              @"「并发加速」，或把 BiliFast/mode.txt 写成 direct。");
                }
            }];
        }];
    }
}

- (void)runBenchmark
{
    NSString *h;

    if (!_benchURL.length) return;

    h = [self benchHostForMode];
    if (!h.length) {
        PLogProxy(@"A/B 实测跳过：拿不到媒体 host");
        return;
    }

    [_lock lock];
    _benchTotal = 0;
    [_lock unlock];

    /* 先探一片：既确认这条路真能取到数，也顺便问出文件总长。
     * 之后所有任务都夹在 [0, 总长) 之内 —— 旧版固定测 0~2 MiB，抽到小文件时
     * 后两片越过末尾拿 416，被算成失败，量出来的收益完全不可信。 */
    [self benchFetchURL:_benchURL host:h start:0 end:kChunkBytes - 1
                   done:^(int64_t b, BOOL ok) {
        int64_t total, budget;

        [_lock lock];
        total = _benchTotal;
        [_lock unlock];

        budget = kBenchBudgetDefault;
        if (total > 0 && total < budget) budget = total;

        if (!ok) {
            PLogProxy(@"A/B 实测跳过：探测片就没取到（host %@）", h);
            return;
        }
        if (budget < kChunkBytes * 2) {
            PLogProxy(@"A/B 实测跳过：媒体文件太小（总长 %lld B），切不出两片可比",
                      (long long)total);
            return;
        }
        [self benchJobsWithBudget:budget host:h];
    }];
}
