/*
 * BSSidxCore.h —— SIDX 解析核心（纯 C，不依赖 Foundation）
 *
 * 为什么单独抽成纯 C：
 *   iOS dylib 只能靠 macOS runner 编译，单次反馈约 1 分钟且要排队；
 *   而 SIDX 解析是纯字节逻辑，与 Foundation 无关。
 *   抽成纯 C 之后，Linux runner 上用一行 clang 就能编译并跑真实夹具，
 *   把「解析器是否真的能解析规范字节」这件事在 CI 上真正验证掉，
 *   而不是只验证"能编译"。
 *
 *   这样分工：
 *     - 纯 C 核心  → Linux + clang + 夹具：验证语义正确性（真跑）
 *     - ObjC 外壳  → macOS + Theos：验证编译、类型、与 iOS 运行时集成
 *
 * 段数上限：B站单轨 sidx 实测 377 段量级，取 8192 留足余量。
 * 超出即判失败，绝不静默截断。
 */
#ifndef BSSIDX_CORE_H
#define BSSIDX_CORE_H

#include <stdint.h>
#include <stddef.h>

#define BSSIDX_MAX_SEGMENTS 8192

typedef struct {
    uint64_t offset;      /* 段在文件中的字节偏移 */
    uint32_t size;        /* 段字节数 */
    uint64_t start_time;  /* 起始时间（timescale 单位） */
    uint32_t duration;    /* 时长（timescale 单位） */
} BSSidxCoreEntry;

typedef struct {
    int      version;             /* 0 或 1 */
    uint32_t timescale;
    uint64_t earliest;            /* earliest_presentation_time */
    uint64_t covered_bytes;       /* 各直接段字节数之和 */
    size_t   box_offset;          /* sidx box 起始偏移 */
    size_t   count;               /* 解析出的段数 */
    BSSidxCoreEntry entries[BSSIDX_MAX_SEGMENTS];
} BSSidxCoreResult;

/* 解析结果码 */
typedef enum {
    BSSIDX_OK = 0,
    BSSIDX_ERR_TOO_SHORT      = -1,  /* 数据长度不足 */
    BSSIDX_ERR_NO_SIDX        = -2,  /* 没找到 sidx box */
    BSSIDX_ERR_BAD_VERSION    = -3,  /* version 非 0/1，不猜 */
    BSSIDX_ERR_BAD_TIMESCALE  = -4,  /* timescale == 0 */
    BSSIDX_ERR_TRUNCATED      = -5,  /* 段表数据不足 */
    BSSIDX_ERR_NO_SEGMENT     = -6,  /* 没有可用的直接媒体段 */
    BSSIDX_ERR_TOO_MANY       = -7,  /* 段数超过上限 */
    BSSIDX_ERR_BAD_STRUCTURE  = -8,  /* box 结构异常 */
} BSSidxCoreStatus;

/*
 * 解析 data[0..len) 中的第一个 sidx box。
 * 成功返回 BSSIDX_OK 并填充 out；失败返回负的错误码，out 内容不可用。
 *
 * 语义要点：
 *   - 顶层遍历 box 序列，跳过 ftyp/moov/moof 等，遇到 sidx 即解析
 *   - 支持 size==1（64 位长度）与 size==0（延伸到末尾）
 *   - reference_type：bit31 == 1 表示层级引用（指向另一个 sidx），
 *     这种条目**不是**本文件内的字节范围，必须跳过而不是当段用
 *   - size == 0 的条目同样跳过
 *   - 全部条目都被跳过（无直接段）视为失败，不返回空表
 */
int bssidx_core_parse(const uint8_t *data, size_t len, BSSidxCoreResult *out);

/* 二分查找覆盖给定偏移的段号；找不到返回 -1 */
long bssidx_core_segment_for_offset(const BSSidxCoreResult *r, uint64_t offset);

#endif /* BSSIDX_CORE_H */
