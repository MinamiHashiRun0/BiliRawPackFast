//
//  BSSidxIndex.m
//

#import "BSSidxIndex.h"

// ---- ISO BMFF box 类型（大端 4CC）----
static const uint32_t kBoxFTYP = 0x66747970;   // 'ftyp'
static const uint32_t kBoxMOOV = 0x6D6F6F76;   // 'moov'
static const uint32_t kBoxMOOF = 0x6D6F6F66;   // 'moof'
static const uint32_t kBoxSIDX = 0x73696478;   // 'sidx'
static const uint32_t kBoxSSIX = 0x73736978;   // 'ssix'
static const uint32_t kBoxSTYP = 0x73747970;   // 'styp'

static inline uint32_t RD32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
static inline uint64_t RD64(const uint8_t *p) {
    return ((uint64_t)RD32(p) << 32) | (uint64_t)RD32(p + 4);
}

@implementation BSSidxIndex {
    NSData *_backing;                 // 持有数据，entries 的指针指向它
    BSSidxEntry *_entries;
    NSUInteger _count;
    uint32_t _timescale;
    uint64_t _earliest;
    uint64_t _coveredBytes;
    NSUInteger _boxOffset;
}

+ (NSUInteger)recommendedHeaderBytes {
    // 实测 B站 m4s 的 sidx 落在 936 / 837 字节附近，box 本体 4.5KB 左右。
    // 64KiB 足够覆盖绝大多数情况，又不会为预取浪费太多流量。
    return 64 * 1024;
}

- (void)dealloc {
    if (_entries) free(_entries);
}

+ (nullable instancetype)parseData:(NSData *)data {
    if (data.length < 32) return nil;

    // 不复制：entries 里存的是偏移量，真正读取时再回 _backing 取，
    // 所以这里必须持有同一块内存，不能让它被释放。
    const uint8_t *base = (const uint8_t *)data.bytes;
    const NSUInteger total = data.length;

    // ---- 顶层 box 遍历，找 sidx ----
    NSUInteger off = 0;
    NSUInteger sidxOffset = NSNotFound;
    uint64_t sidxSize = 0;

    while (off + 8 <= total) {
        uint64_t size = RD32(base + off);
        uint32_t type = RD32(base + off + 4);
        NSUInteger headerLen = 8;

        if (size == 1) {
            if (off + 16 > total) break;
            size = RD64(base + off + 8);
            headerLen = 16;
        } else if (size == 0) {
            size = total - off;                 // 延伸到文件末尾
        }
        if (size < headerLen || off + size > total) {
            // 最后一个 box 可能被截断（只预取了头部）—— 这不算错误，
            // 但如果截断的正是 sidx，就拿不到段表，按失败处理。
            if (type == kBoxSIDX) return nil;
            break;
        }

        if (type == kBoxSIDX) {
            sidxOffset = off;
            sidxSize = size;
            break;
        }

        // 已知「不含 sidx」的 box，遇到就可以停止；未知 box 则继续扫
        if (type == kBoxFTYP || type == kBoxMOOV || type == kBoxMOOF ||
            type == kBoxSSIX || type == kBoxSTYP) {
            off += (NSUInteger)size;
            continue;
        }
        off += (NSUInteger)size;
    }

    if (sidxOffset == NSNotFound) return nil;

    // ---- 解析 sidx ----
    const uint8_t *p = base + sidxOffset;
    const uint64_t boxSize = sidxSize;

    // FullBox: 4(size) + 4(type) + 1(version) + 3(flags)
    if (boxSize < 12 + 20) return nil;
    uint8_t version = p[8];
    if (version != 0 && version != 1) return nil;   // 未知版本不猜

    const uint8_t *q = p + 12;                       // 跳过 version+flags
    uint32_t referenceID = RD32(q);                  // 保留：同 referenceID 的段属于同一轨
    (void)referenceID;
    uint32_t timescale = RD32(q + 4);
    if (timescale == 0) return nil;                  // 时基为 0 无法换算，视为异常

    uint64_t earliest, firstOffset;
    const uint8_t *r;
    if (version == 0) {
        earliest    = RD32(q + 8);
        firstOffset = RD32(q + 12);
        r = q + 16;
    } else {
        earliest    = RD64(q + 8);
        firstOffset = RD64(q + 16);
        r = q + 24;
    }

    // reserved(2) + reference_count(2)
    if ((NSUInteger)(r - p) + 4 > boxSize) return nil;
    uint16_t refCount = (uint16_t)((r[2] << 8) | r[3]);
    r += 4;
    if (refCount == 0) return nil;

    // 每条 reference 占 12 字节：4(reference_type+size) + 4(duration) + 4(SAP)
    uint64_t need = sidxOffset + (uint64_t)(r - p) + (uint64_t)refCount * 12ULL;
    if (need > total) return nil;                    // 段表被截断

    BSSidxEntry *entries = (BSSidxEntry *)calloc(refCount, sizeof(BSSidxEntry));
    if (!entries) return nil;

    uint64_t offset = firstOffset;
    uint64_t t = 0;
    uint64_t sum = 0;
    uint16_t kept = 0;

    for (uint16_t i = 0; i < refCount; i++) {
        const uint8_t *e = r + (NSUInteger)i * 12;
        uint32_t word = RD32(e);
        uint32_t duration = RD32(e + 4);
        // 高位是 reference_type：0 = 直接媒体段，1 = 指向另一个 sidx。
        // 真实 B站文件里全是 0（直接段），低位 31 bit 才是大小。
        // 只有直接媒体段才有「本文件内的字节范围」，层级引用不能当段用。
        uint32_t type = (word >> 31) & 0x1;
        uint32_t size = word & 0x7FFFFFFFu;

        if (type != 0 || size == 0) continue;        // 跳过层级引用与空段

        entries[kept].offset    = offset;
        entries[kept].size      = size;
        entries[kept].startTime = earliest + t;
        entries[kept].duration  = duration;
        kept++;

        offset += size;
        t += duration;
        sum += size;
    }

    if (kept == 0) {
        free(entries);
        return nil;
    }

    BSSidxIndex *idx = [[BSSidxIndex alloc] init];
    idx->_backing = data;
    idx->_entries = entries;
    idx->_count = kept;
    idx->_timescale = timescale;
    idx->_earliest = earliest;
    idx->_coveredBytes = sum;
    idx->_boxOffset = sidxOffset;
    return idx;
}

- (BOOL)segmentAtIndex:(NSUInteger)index entry:(BSSidxEntry *)outEntry {
    if (index >= _count || !outEntry) return NO;
    *outEntry = _entries[index];
    return YES;
}

- (NSUInteger)segmentIndexForOffset:(uint64_t)offset {
    if (_count == 0) return NSNotFound;
    NSUInteger lo = 0, hi = _count - 1;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        const BSSidxEntry *e = &_entries[mid];
        if (offset < e->offset) {
            hi = mid;
        } else if (offset >= e->offset + e->size) {
            lo = mid + 1;
        } else {
            return mid;
        }
    }
    const BSSidxEntry *e = &_entries[lo];
    if (offset >= e->offset && offset < e->offset + e->size) return lo;
    return NSNotFound;
}

- (BOOL)isSelfConsistent {
    uint64_t sum = 0;
    for (NSUInteger i = 0; i < _count; i++) sum += _entries[i].size;
    return sum == _coveredBytes;
}

- (NSString *)describe {
    if (_count == 0) return @"SIDX: 空";
    const BSSidxEntry *f = &_entries[0];
    const BSSidxEntry *l = &_entries[_count - 1];
    double totalSec = (_timescale > 0)
        ? (double)((l->startTime + l->duration) - _earliest) / (double)_timescale : 0;
    return [NSString stringWithFormat:
            @"SIDX@%lu timescale=%u 段数=%lu 覆盖=%llu 字节 时长=%.3fs 首段(off=%llu,size=%u) 末段(off=%llu,size=%u)",
            (unsigned long)_boxOffset, _timescale, (unsigned long)_count,
            _coveredBytes, totalSec, f->offset, f->size, l->offset, l->size];
}

// ---- 只读属性 ----
- (uint32_t)timescale { return _timescale; }
- (uint64_t)earliestPresentationTime { return _earliest; }
- (NSUInteger)count { return _count; }
- (uint64_t)coveredBytes { return _coveredBytes; }
- (NSUInteger)boxOffset { return _boxOffset; }

@end
