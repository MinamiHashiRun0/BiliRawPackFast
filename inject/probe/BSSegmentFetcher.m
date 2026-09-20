//
//  BSSegmentFetcher.m
//
//  状态机与 _recon/segment_fetcher_ref.py 同构（那份已在本地对限速 Range 服务器
//  验证过：40 段按序交付逐字节正确、并发 8 实测 8.02× 提速、坏 host 降级、
//  全失效时显式报错）。移植时保持同一语义，只把 HTTP 层换成 NSURLSession。
//
//  并发模型：
//    * 所有共享状态只在 _queue（串行）上访问 → 不需要锁
//    * NSURLSession 的回调回到 _queue 上再改状态
//    * 交付（onData）也在 _queue 上按段号递增串行发出
//    * 因此上层（AVAssetResourceLoader delegate）可以安全地直接把数据喂给
//      AVAssetResourceLoadingRequest.dataRequest，不会出现重入
//

#import "BSSegmentFetcher.h"

/// 每个在飞请求的上下文
@interface BSSegmentTask : NSObject
@property (nonatomic, assign) NSUInteger index;         // 段号
@property (nonatomic, assign) NSUInteger attempt;       // 第几次尝试（0 起）
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, assign) NSUInteger expectedSize;
@end

@implementation BSSegmentTask
@end


@implementation BSSegmentFetcher {
    // 段表访问器（避免持有整张表，交给调用方/SIDX 持有）
    BSSegmentRange (^_segmentAt)(NSUInteger index);

    NSUInteger _total;
    NSUInteger _nextSend;        // 下一个要发起的段号
    NSUInteger _nextDeliver;     // 下一个要交付的段号
    NSUInteger _inFlight;        // 当前在飞请求数

    NSMutableDictionary<NSNumber *, NSData *> *_ready;   // 段号 -> 已完成字节（乱序）

    NSURLSession *_session;
    BOOL _started;
    BOOL _cancelled;
    BOOL _finished;

    // 诊断计数
    NSUInteger _delivered;
    NSUInteger _retries;
    NSUInteger _hostSwitches;
    NSUInteger _consecutiveTotalFailure;
}

- (instancetype)initWithBaseURL:(NSURL *)baseURL
                        segment:(BSSegmentRange (^)(NSUInteger))segment
                   segmentCount:(NSUInteger)count
                          queue:(dispatch_queue_t)queue {
    if (!baseURL || !segment || count == 0 || !queue) return nil;
    self = [super init];
    if (!self) return nil;

    _baseURL = baseURL;
    _segmentAt = [segment copy];
    _total = count;
    _queue = queue;
    _maxConcurrent = 8;
    _maxRetryPerSegment = 2;
    _requestTimeout = 15.0;
    _hosts = @[];
    _ready = [NSMutableDictionary dictionary];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = _requestTimeout;
    cfg.timeoutIntervalForResource = 60.0;
    cfg.HTTPMaximumConnectionsPerHost = 8;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    // 注意：不加 Accept-Encoding —— m4s 是已压缩媒体，再压一层只会浪费 CPU，
    // 且会让 Range 语义变得难以对齐（Content-Length 与段长不再一致）。
    cfg.HTTPShouldSetCookies = NO;
    _session = [NSURLSession sessionWithConfiguration:cfg
                                             delegate:nil
                                        delegateQueue:nil];
    return self;
}

- (instancetype)initWithBaseURL:(NSURL *)baseURL
                      sidxIndex:(BSSidxIndex *)index
                          queue:(dispatch_queue_t)queue {
    if (!index) return nil;
    return [self initWithBaseURL:baseURL
                         segment:^BSSegmentRange(NSUInteger i) {
                             BSSidxEntry e = (BSSidxEntry){0, 0, 0, 0};
                             BSSegmentRange r = (BSSegmentRange){0, 0};
                             if ([index segmentAtIndex:i entry:&e]) {
                                 r.offset = e.offset;
                                 r.size = e.size;
                             }
                             return r;
                         }
                    segmentCount:index.count
                           queue:queue];
}

- (void)dealloc {
    [_session invalidateAndCancel];
}

// ------------------------------------------------------------------ 对外
- (void)start {
    dispatch_async(_queue, ^{
        if (self->_started || self->_cancelled) return;
        self->_started = YES;
        [self noteLog:@"start 段数=%lu 并发=%lu host=%lu",
         (unsigned long)self->_total, (unsigned long)self->_maxConcurrent,
         (unsigned long)self->_hosts.count];
        [self pump];
    });
}

- (void)cancel {
    dispatch_async(_queue, ^{
        if (self->_cancelled || self->_finished) return;
        self->_cancelled = YES;
        [self->_session invalidateAndCancel];
        if (self.onFailure) self.onFailure(BSSegmentFetcherErrorCancelled, @"已取消");
    });
}

- (NSUInteger)deliveredCount  { return _delivered; }
- (NSUInteger)retryCount      { return _retries; }
- (NSUInteger)hostSwitchCount { return _hostSwitches; }
- (NSUInteger)totalCount      { return _total; }

// ------------------------------------------------------------------ 调度
/// 在 _queue 上：尽量把在飞请求填满并发上限
- (void)pump {
    while (_inFlight < _maxConcurrent && _nextSend < _total && !_cancelled) {
        NSUInteger idx = _nextSend++;
        [self sendSegment:idx attempt:0];
    }
    [self tryDeliver];
    if (_nextDeliver >= _total && !_finished) {
        _finished = YES;
        [self noteLog:@"finished 交付=%lu 重试=%lu 换host=%lu",
         (unsigned long)_delivered, (unsigned long)_retries, (unsigned long)_hostSwitches];
        if (self.onFinished) self.onFinished();
    }
}

/// 构造某个段在某个 host 下的请求 URL：只替换 authority，路径与查询串原样保留。
/// 原因：B站 m4s 的 upsig/uparams/hdnts 签名同时绑定路径与查询串，
/// 换 host 时若改动其他部分签名会失效。
- (NSURL *)requestURLForSegment:(NSUInteger)idx attempt:(NSUInteger)attempt {
    // 注意：这里刻意不取段范围。URL 只由 baseURL 的路径/查询串 + host 决定，
    // 段信息只影响 Range 头。第一版在这里取了一次段范围却没用，
    // 被 -Wall 判为 unused variable 且构建开了 -Werror → 直接构建失败。
    NSURLComponents *c = [NSURLComponents componentsWithURL:_baseURL resolvingAgainstBaseURL:NO];

    if (_hosts.count > 0) {
        NSString *host = _hosts[MIN(attempt, _hosts.count - 1)];
        NSURLComponents *h = [NSURLComponents componentsWithString:host];
        if (h.host) {
            c.scheme = h.scheme ?: c.scheme;
            c.host = h.host;
            c.port = h.port;
        }
    }
    return c.URL;
}

- (void)sendSegment:(NSUInteger)idx attempt:(NSUInteger)attempt {
    BSSegmentRange r = _segmentAt(idx);
    if (r.size == 0) {
        // 空段：直接当已完成，避免死等
        [self completeSegment:idx data:[NSData data] expected:0];
        return;
    }

    NSURL *url = [self requestURLForSegment:idx attempt:attempt];
    if (!url) {
        [self failSegment:idx reason:@"URL 构造失败"];
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = _requestTimeout;
    [req setValue:[NSString stringWithFormat:@"bytes=%llu-%llu",
                   r.offset, r.offset + r.size - 1] forHTTPHeaderField:@"Range"];
    // m4s 直链通常不强校验 Referer，但缺失时部分节点会 403，补上更稳
    [req setValue:@"https://www.bilibili.com" forHTTPHeaderField:@"Referer"];
    if (![req valueForHTTPHeaderField:@"User-Agent"]) {
        [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
   forHTTPHeaderField:@"User-Agent"];
    }

    BSSegmentTask *st = [[BSSegmentTask alloc] init];
    st.index = idx;
    st.attempt = attempt;
    st.expectedSize = r.size;
    st.buffer = [NSMutableData dataWithCapacity:r.size];

    __weak typeof(self) weakSelf = self;
    st.task = [_session dataTaskWithRequest:req
                         completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        dispatch_async(self2->_queue, ^{
            [self2 handleResponse:st data:data response:resp error:err];
        });
    }];

    _inFlight++;
    if (attempt > 0) _retries++;
    if (attempt > 0 && _hosts.count > 1) {
        _hostSwitches++;
        [self noteLog:@"段 %lu 第 %lu 次尝试，切到 host %@",
         (unsigned long)idx, (unsigned long)attempt, url.host ?: @"?"];
    }
    [st.task resume];
}

- (void)handleResponse:(BSSegmentTask *)st
                  data:(NSData *)data
              response:(NSURLResponse *)resp
                 error:(NSError *)err {
    if (_cancelled) return;

    NSInteger status = 0;
    if ([resp isKindOfClass:NSHTTPURLResponse.class]) {
        status = ((NSHTTPURLResponse *)resp).statusCode;
    }

    BOOL ok = (err == nil) && (status == 200 || status == 206) && data.length > 0;
    // 200 表示服务端忽略了 Range，返回了整段文件 —— 那不能当段数据用
    if (ok && status == 200 && data.length != st.expectedSize) {
        ok = NO;
        err = [NSError errorWithDomain:@"BSSegmentFetcher" code:200
                              userInfo:@{NSLocalizedDescriptionKey:
                                             @"服务端忽略 Range（返回 200 且长度不符）"}];
    }
    if (ok && data.length != st.expectedSize) {
        ok = NO;
        err = [NSError errorWithDomain:@"BSSegmentFetcher" code:-1
                              userInfo:@{NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:@"段长不符 期望 %lu 实得 %lu",
                                              (unsigned long)st.expectedSize, (unsigned long)data.length]}];
    }

    _inFlight--;

    if (ok) {
        _consecutiveTotalFailure = 0;
        [self completeSegment:st.index data:data expected:st.expectedSize];
        [self pump];
        return;
    }

    [self noteLog:@"段 %lu 第 %lu 次失败 status=%ld err=%@",
     (unsigned long)st.index, (unsigned long)st.attempt, (long)status,
     err.localizedDescription ?: @"(无)"];

    if (st.attempt < _maxRetryPerSegment) {
        // 重试：attempt+1 会自动让 requestURLForSegment: 后退到下一个 host
        [self sendSegment:st.index attempt:st.attempt + 1];
        return;
    }

    [self failSegment:st.index reason:err.localizedDescription ?: @"重试用尽"];
}

- (void)completeSegment:(NSUInteger)idx data:(NSData *)data expected:(NSUInteger)expected {
    _ready[@(idx)] = data;
    [self tryDeliver];
}

/// 按段号递增交付；缺段即停（等它到）
- (void)tryDeliver {
    while (YES) {
        NSData *d = _ready[@(_nextDeliver)];
        if (!d) break;
        [_ready removeObjectForKey:@(_nextDeliver)];
        NSUInteger idx = _nextDeliver;
        _nextDeliver++;
        _delivered++;

        if (self.onProgress) self.onProgress(_delivered, _total);
        if (self.onData) self.onData(idx, d);
    }
}

/// 某段彻底失败：不再交付残缺数据，直接报错终止
- (void)failSegment:(NSUInteger)idx reason:(NSString *)reason {
    if (_finished) return;
    _finished = YES;
    _consecutiveTotalFailure++;
    _inFlight = 0;
    [_session invalidateAndCancel];
    NSString *detail = [NSString stringWithFormat:@"段 %lu/%lu 失败：%@（已交付 %lu 段）",
                        (unsigned long)idx, (unsigned long)_total, reason,
                        (unsigned long)_delivered];
    [self noteLog:@"%@", detail];
    if (self.onFailure) self.onFailure(BSSegmentFetcherErrorAllSegmentsFailed, detail);
}

- (void)noteLog:(NSString *)fmt, ... {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[BSSegmentFetcher] %@", msg);
}

@end
