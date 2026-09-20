/*
 * BSSidxCore.c —— SIDX 解析核心实现（纯 C）
 *
 * 与 _recon/sidx_fixtures/ 下的夹具配套；夹具生成脚本用独立的 Python 解析器
 * 复核过同一批字节，因此这里跑的是「两份独立实现 + 同一批夹具」的对拍。
 *
 * 规范依据：ISO/IEC 14496-12 Segment Index Box
 *   aligned(8) class SegmentIndexBox extends FullBox('sidx', version, 0) {
 *     unsigned int(32) reference_ID;
 *     unsigned int(32) timescale;
 *     if (version == 0) {
 *       unsigned int(32) earliest_presentation_time;
 *       unsigned int(32) first_offset;
 *     } else {
 *       unsigned int(64) earliest_presentation_time;
 *       unsigned int(64) first_offset;
 *     }
 *     unsigned int(16) reserved = 0;
 *     unsigned int(16) reference_count;
 *     for (i = 1; i <= reference_count; i++) {
 *       bit(1)           reference_type;
 *       unsigned int(31) referenced_size;
 *       unsigned int(32) subsegment_duration;
 *       bit(1)           starts_with_SAP;
 *       bit(3)           SAP_type;
 *       bit(28)          SAP_delta_time;
 *     }
 *   }
 */

#include "BSSidxCore.h"
#include <string.h>

#define BOX_FTYP 0x66747970u
#define BOX_MOOV 0x6D6F6F76u
#define BOX_MOOF 0x6D6F6F66u
#define BOX_SIDX 0x73696478u
#define BOX_SSIX 0x73736978u
#define BOX_STYP 0x73747970u

static uint32_t rd32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}

static uint64_t rd64(const uint8_t *p) {
    return ((uint64_t)rd32(p) << 32) | (uint64_t)rd32(p + 4);
}

int bssidx_core_parse(const uint8_t *data, size_t len, BSSidxCoreResult *out) {
    if (!data || !out) return BSSIDX_ERR_BAD_STRUCTURE;
    if (len < 32) return BSSIDX_ERR_TOO_SHORT;
    memset(out, 0, sizeof(*out));

    /* ---- 顶层 box 遍历，找 sidx ---- */
    size_t off = 0;
    size_t sidx_off = 0;
    uint64_t sidx_size = 0;
    int have_sidx = 0;

    while (off + 8 <= len) {
        uint64_t size = rd32(data + off);
        uint32_t type = rd32(data + off + 4);
        size_t hlen = 8;

        if (size == 1) {
            if (off + 16 > len) break;
            size = rd64(data + off + 8);
            hlen = 16;
        } else if (size == 0) {
            size = (uint64_t)(len - off);
        }

        if (size < hlen || off + size > len) {
            /* box 越界：要么文件异常，要么数据被截断。
               如果截断的正好是我们需要的 sidx，就无法解析。 */
            if (type == BOX_SIDX) return BSSIDX_ERR_TRUNCATED;
            break;
        }

        if (type == BOX_SIDX) {
            sidx_off = off;
            sidx_size = size;
            have_sidx = 1;
            break;
        }

        /* 这几个 box 确定不含 sidx（或其子 box 我们不递归），跳过即可 */
        (void)BOX_FTYP; (void)BOX_MOOV; (void)BOX_MOOF; (void)BOX_SSIX; (void)BOX_STYP;
        off += (size_t)size;
    }

    if (!have_sidx) return BSSIDX_ERR_NO_SIDX;

    /* ---- 解析 sidx ---- */
    const uint8_t *p = data + sidx_off;
    if (sidx_size < 12 + 20) return BSSIDX_ERR_BAD_STRUCTURE;

    int version = (int)p[8];
    if (version != 0 && version != 1) return BSSIDX_ERR_BAD_VERSION;

    const uint8_t *q = p + 12;                 /* 跳过 version+flags */
    uint32_t timescale = rd32(q + 4);
    if (timescale == 0) return BSSIDX_ERR_BAD_TIMESCALE;

    uint64_t earliest, first_offset;
    const uint8_t *r;
    if (version == 0) {
        earliest    = rd32(q + 8);
        first_offset = rd32(q + 12);
        r = q + 16;
    } else {
        earliest    = rd64(q + 8);
        first_offset = rd64(q + 16);
        r = q + 24;
    }

    if ((size_t)(r - p) + 4 > (size_t)sidx_size) return BSSIDX_ERR_BAD_STRUCTURE;
    uint16_t ref_count = (uint16_t)((r[2] << 8) | r[3]);
    r += 4;
    if (ref_count == 0) return BSSIDX_ERR_NO_SEGMENT;
    if (ref_count > BSSIDX_MAX_SEGMENTS) return BSSIDX_ERR_TOO_MANY;

    /* 段表必须完整落在 sidx box 内 */
    uint64_t need = (uint64_t)(r - p) + (uint64_t)ref_count * 12ULL;
    if (need > sidx_size) return BSSIDX_ERR_TRUNCATED;

    uint64_t offset = first_offset;
    uint64_t t = 0;
    uint64_t sum = 0;
    size_t kept = 0;

    for (uint16_t i = 0; i < ref_count; i++) {
        const uint8_t *e = r + (size_t)i * 12;
        uint32_t word = rd32(e);
        uint32_t duration = rd32(e + 4);
        uint32_t ref_type = (word >> 31) & 0x1u;
        uint32_t seg_size = word & 0x7FFFFFFFu;

        /* 层级引用不是本文件内的字节范围；空段无意义。两者都跳过。 */
        if (ref_type != 0 || seg_size == 0) continue;

        out->entries[kept].offset     = offset;
        out->entries[kept].size       = seg_size;
        out->entries[kept].start_time = earliest + t;
        out->entries[kept].duration   = duration;
        kept++;

        offset += seg_size;
        t += duration;
        sum += seg_size;
    }

    if (kept == 0) return BSSIDX_ERR_NO_SEGMENT;

    out->version = version;
    out->timescale = timescale;
    out->earliest = earliest;
    out->covered_bytes = sum;
    out->box_offset = sidx_off;
    out->count = kept;
    return BSSIDX_OK;
}

long bssidx_core_segment_for_offset(const BSSidxCoreResult *r, uint64_t offset) {
    if (!r || r->count == 0) return -1;
    size_t lo = 0, hi = r->count - 1;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        uint64_t s = r->entries[mid].offset;
        uint64_t e = s + r->entries[mid].size;
        if (offset < s) {
            hi = mid;
        } else if (offset >= e) {
            lo = mid + 1;
        } else {
            return (long)mid;
        }
    }
    uint64_t s = r->entries[lo].offset;
    if (offset >= s && offset < s + r->entries[lo].size) return (long)lo;
    return -1;
}
