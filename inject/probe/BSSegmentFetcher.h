//
//  BSSegmentFetcher.h
//  BiliProbe / BiliRawPackFast
//
//  按 SIDX 段表并发拉取，并严格按段号递增向上层交付字节。
//
//  为什么需要它：
//    官方客户端自己实现了 AVAssetResourceLoaderDelegate 来取视频字节
//    （BBRResourceLoaderManager 等），并且内置了 B站自己的 PCDN/MCDN。
//    海外场景下 PCDN 会连到国内边缘节点，是主要劣化来源。
//    本类替代该职责：绕开 PCDN，直连优选 CDN 节点，用我们可控的并发度拉取。
//
//  设计要点（与 _recon/segment_fetcher_ref.py 的状态机同构，已在本地验证）：
//    * 单串行状态队列：所有共享状态只在 queue 上访问，不用锁
//    * 固定并发上限：在飞请求数不超过 maxConcurrent
//    * 乱序到达进槽位；交付严格按段号递增（AVPlayer 只接受顺序流）
//    * 段级失败重试；重试用尽则切换 host
//    * 全部 host 失效时回调 onFailure，绝不静默交付残缺数据
//
//  线程约定：delegate 队列必须与 queue 一致或串行化，本类内部会回到 queue。
//

#import <Foundation/Foundation.h>
#import "BSSidxIndex.h"

NS_ASSUME_NONNULL_BEGIN

/// 段描述（来自 SIDX）
typedef struct {
    uint64_t offset;
    uint32_t size;
} BSSegmentRange;

/// 失败原因，用于上层决定是否降级到直连
typedef NS_ENUM(NSInteger, BSSegmentFetcherError) {
    BSSegmentFetcherErrorAllSegmentsFailed = 1,
    BSSegmentFetcherErrorCancelled          = 2,
    BSSegmentFetcherErrorBadSegmentTable    = 3,
};

@interface BSSegmentFetcher : NSObject

/// 串行状态队列。必须由调用方持有并保证其生命周期覆盖整个拉取过程。
@property (nonatomic, readonly) dispatch_queue_t queue;

/// 并发上限，默认 8
@property (nonatomic, assign) NSUInteger maxConcurrent;

/// 单段最多重试次数（不含首次），默认 2
@property (nonatomic, assign) NSUInteger maxRetryPerSegment;

/// 单个请求超时，默认 15 秒
@property (nonatomic, assign) NSTimeInterval requestTimeout;

/// 在这些 host 之间轮换。hosts[0] 为默认；重试时按序后退。
/// 字符串形式为 scheme+host（如 @"https://upos-sz-mirror08c.bilivideo.com"），
/// 路径与查询串沿用 baseURL 的其余部分 —— 因为 B站 m4s 的 upsig/hdnts 签名
/// 与路径和查询串绑定，只换 authority 最安全。
@property (nonatomic, copy) NSArray<NSString *> *hosts;

/// baseURL：完整可用的 m4s 地址（含签名参数）。host 会被 hosts 里的值替换。
@property (nonatomic, copy) NSURL *baseURL;

/// 依次交付的段字节。回调在 queue 上串行调用，按段号递增。
@property (nonatomic, copy) void (^onData)(NSUInteger index, NSData *data);

/// 全部段交付完成
@property (nonatomic, copy) void (^onFinished)(void);

/// 失败（不可继续）。此时不保证已交付完整数据。
@property (nonatomic, copy) void (^onFailure)(BSSegmentFetcherError code, NSString *detail);

/// 进度（已交付段数 / 总段数），用于诊断面板
@property (nonatomic, copy) void (^onProgress)(NSUInteger delivered, NSUInteger total);

/// 用 SIDX 段表初始化
- (nullable instancetype)initWithBaseURL:(NSURL *)baseURL
                                 segment:(BSSegmentRange (^)(NSUInteger index))segment
                             segmentCount:(NSUInteger)count
                                   queue:(dispatch_queue_t)queue;

/// 用 BSSidxIndex 便捷初始化
- (nullable instancetype)initWithBaseURL:(NSURL *)baseURL
                                sidxIndex:(BSSidxIndex *)index
                                    queue:(dispatch_queue_t)queue;

- (void)start;
- (void)cancel;

/// 只读诊断计数（线程安全读取，内部会同步到 queue）
@property (nonatomic, readonly) NSUInteger deliveredCount;
@property (nonatomic, readonly) NSUInteger retryCount;
@property (nonatomic, readonly) NSUInteger hostSwitchCount;
@property (nonatomic, readonly) NSUInteger totalCount;

@end

NS_ASSUME_NONNULL_END
