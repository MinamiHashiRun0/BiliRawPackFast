//
//  BSSidxIndex.h
//  BiliProbe / BiliRawPackFast
//
//  ISO BMFF SIDX（Segment Index Box）解析器。
//
//  为什么需要它：
//    B站 m4s 文件在头部约 1KB 处带一个 sidx box，给出每个段的字节偏移与时长。
//    拿到段表才能做「按段并发拉取 + 段级重试」，而不是盲目按字节窗口切。
//    （参考实现在 _recon/segment_fetcher_ref.py 与 PiliPlusRDCDN 的
//      lib/services/cdn/sidx_index.dart，两者语义一致。）
//
//  已知限制（如实标注）：
//    * 只处理文件里的第一个 sidx box；多 sidx 的层级索引不支持
//    * reference_type 的判读：真实 B站文件里 bit31 = 0 表示「直接媒体段」，
//      低位 31 bit 是段大小。这一点在 Dart 版上踩过坑（最初读反了，
//      且合成用例以同样错误的语义"假绿"通过），此实现按真实字节语义写。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    uint64_t offset;        // 段在文件中的字节偏移
    uint32_t size;          // 段字节数
    uint64_t startTime;     // 起始时间（timescale 单位）
    uint32_t duration;      // 时长（timescale 单位）
} BSSidxEntry;

@interface BSSidxIndex : NSObject

/// 时间刻度（每秒的时基单位）
@property (nonatomic, readonly) uint32_t timescale;

/// 首段的绝对起始时间
@property (nonatomic, readonly) uint64_t earliestPresentationTime;

/// 段数
@property (nonatomic, readonly) NSUInteger count;

/// SIDX 声明覆盖的总字节数（校验用：应等于各段大小之和）
@property (nonatomic, readonly) uint64_t coveredBytes;

/// sidx box 在文件中的偏移（诊断用）
@property (nonatomic, readonly) NSUInteger boxOffset;

/// 解析。数据不足 / 结构异常一律返回 nil，绝不返回半成品。
+ (nullable instancetype)parseData:(NSData *)data;

/// 取第 index 段；越界返回 NO
- (BOOL)segmentAtIndex:(NSUInteger)index entry:(BSSidxEntry *)outEntry;

/// 二分查找覆盖给定字节偏移的段号；找不到返回 NSNotFound
- (NSUInteger)segmentIndexForOffset:(uint64_t)offset;

/// 自检：段表声明的总字节数是否与 SIDX 声明的 coveredBytes 一致
- (BOOL)isSelfConsistent;

/// 人类可读描述（诊断日志用）
- (NSString *)describe;

/// 建议的头部预取字节数：sidx 通常在前 1KB 内，取 64KiB 足够且不浪费
+ (NSUInteger)recommendedHeaderBytes;

@end

NS_ASSUME_NONNULL_END
