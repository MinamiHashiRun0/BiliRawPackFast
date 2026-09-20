//
//  BSSidxIndex.m
//
//  ObjC 外壳：把 NSData 交给已通过夹具验证的纯 C 核心（BSSidxCore），
//  再把结果搬进 ObjC 侧的结构。
//
//  为什么这么分层（重要，别把核心逻辑又抄回这里）：
//    纯 C 核心能在 Linux runner 上用 clang 编译并跑真实夹具，
//    因此「解析语义是否正确」是在 CI 上真跑出来的。
//    ObjC 侧只做类型搬运，不重复实现解析 —— 一旦抄回来，
//    被测代码与出货代码就分叉了，测试立刻变成摆设。
//

#import "BSSidxIndex.h"
#import "BSSidxCore.h"

@implementation BSSidxIndex {
    BSSidxCoreResult _core;      // 由 C 核心填充
}

+ (NSUInteger)recommendedHeaderBytes {
    // 实测 B站 m4s 的 sidx 落在 936 / 837 字节附近，box 本体 4.5KB 左右。
    // 64KiB 足够覆盖绝大多数情况，又不会为预取浪费太多流量。
    return 64 * 1024;
}

+ (nullable instancetype)parseData:(NSData *)data {
    if (data.length < 32) return nil;

    BSSidxCoreResult core;
    int st = bssidx_core_parse((const uint8_t *)data.bytes, (size_t)data.length, &core);
    if (st != BSSIDX_OK) return nil;

    BSSidxIndex *idx = [[BSSidxIndex alloc] init];
    idx->_core = core;
    return idx;
}

- (BOOL)segmentAtIndex:(NSUInteger)index entry:(BSSidxEntry *)outEntry {
    if (index >= _core.count || !outEntry) return NO;
    outEntry->offset    = _core.entries[index].offset;
    outEntry->size      = _core.entries[index].size;
    outEntry->startTime = _core.entries[index].start_time;
    outEntry->duration  = _core.entries[index].duration;
    return YES;
}

- (NSUInteger)segmentIndexForOffset:(uint64_t)offset {
    long i = bssidx_core_segment_for_offset(&_core, offset);
    return (i < 0) ? NSNotFound : (NSUInteger)i;
}

- (BOOL)isSelfConsistent {
    uint64_t sum = 0;
    for (NSUInteger i = 0; i < _core.count; i++) sum += _core.entries[i].size;
    return sum == _core.covered_bytes;
}

- (NSString *)describe {
    if (_core.count == 0) return @"SIDX: 空";
    const BSSidxCoreEntry *f = &_core.entries[0];
    const BSSidxCoreEntry *l = &_core.entries[_core.count - 1];
    double totalSec = (_core.timescale > 0)
        ? (double)((l->start_time + l->duration) - _core.earliest) / (double)_core.timescale
        : 0;
    return [NSString stringWithFormat:
            @"SIDX@%lu v%d timescale=%u 段数=%lu 覆盖=%llu 字节 时长=%.3fs "
            @"首段(off=%llu,size=%u) 末段(off=%llu,size=%u)",
            (unsigned long)_core.box_offset, _core.version, _core.timescale,
            (unsigned long)_core.count, _core.covered_bytes, totalSec,
            f->offset, f->size, l->offset, l->size];
}

// ---- 只读属性 ----
- (uint32_t)timescale { return _core.timescale; }
- (uint64_t)earliestPresentationTime { return _core.earliest; }
- (NSUInteger)count { return _core.count; }
- (uint64_t)coveredBytes { return _core.covered_bytes; }
- (NSUInteger)boxOffset { return _core.box_offset; }

@end
