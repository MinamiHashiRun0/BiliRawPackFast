/*
 * test_sidx_core.c —— 用真实夹具跑 BSSidxCore 的验证程序
 *
 * 在 Linux runner 上用 clang 编译执行，不需要 macOS / Xcode / Theos。
 * 夹具来自 _recon/sidx_fixtures/，由 _recon/gen_sidx_fixtures.py 生成，
 * 并经独立的 Python 解析器复核过。
 *
 * 用法: test_sidx_core <fixtures_dir> <cases.json 不可用，故按约定名与期望值内置>
 *   这里不解析 JSON（避免引入依赖）：期望值以最小形式内联在下表，
 *   真正的期望明细留在 cases.json 供人工核对。
 */
#include "BSSidxCore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *file;
    int expect_ok;
    size_t expect_count;      /* expect_ok 时有意义；0 表示不断言段数 */
    const char *note;
} Case;

static const Case kCases[] = {
    { "v0_all_direct.bin",           1, 10, "10 个直接媒体段" },
    { "v1_64bit_offsets.bin",        1,  6, "64 位 earliest/first_offset" },
    { "mixed_hier_and_empty.bin",    1,  2, "2 直接 + 2 层级 + 1 空段，应只剩 2" },
    { "hier_only.bin",               0,  0, "全是层级引用" },
    { "unknown_version.bin",         0,  0, "version=2 不应猜" },
    { "timescale_zero.bin",          0,  0, "时基为 0" },
    { "truncated_table.bin",         0,  0, "段表数据不足" },
    { "no_sidx.bin",                 0,  0, "只有 ftyp+moov" },
    { "zero_refs.bin",               0,  0, "reference_count=0" },
};

static unsigned char *read_file(const char *path, size_t *outLen) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long n = ftell(f);
    if (n < 0) { fclose(f); return NULL; }
    rewind(f);
    unsigned char *buf = (unsigned char *)malloc((size_t)n ? (size_t)n : 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    *outLen = got;
    return buf;
}

/* 各错误码的短名，便于失败时定位 */
static const char *status_name(int s) {
    switch (s) {
        case BSSIDX_OK:                  return "OK";
        case BSSIDX_ERR_TOO_SHORT:       return "TOO_SHORT";
        case BSSIDX_ERR_NO_SIDX:         return "NO_SIDX";
        case BSSIDX_ERR_BAD_VERSION:     return "BAD_VERSION";
        case BSSIDX_ERR_BAD_TIMESCALE:   return "BAD_TIMESCALE";
        case BSSIDX_ERR_TRUNCATED:       return "TRUNCATED";
        case BSSIDX_ERR_NO_SEGMENT:      return "NO_SEGMENT";
        case BSSIDX_ERR_TOO_MANY:        return "TOO_MANY";
        case BSSIDX_ERR_BAD_STRUCTURE:   return "BAD_STRUCTURE";
        default:                          return "?";
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "用法: %s <fixtures_dir>\n", argv[0]);
        return 2;
    }
    const char *dir = argv[1];
    int fails = 0;
    size_t n = sizeof(kCases) / sizeof(kCases[0]);

    printf("SIDX 核心验证（夹具目录 %s）\n", dir);
    printf("=========================================================\n");

    for (size_t i = 0; i < n; i++) {
        const Case *c = &kCases[i];
        char path[1024];
        snprintf(path, sizeof(path), "%s/%s", dir, c->file);

        size_t len = 0;
        unsigned char *buf = read_file(path, &len);
        if (!buf) {
            printf("  ✗ %-26s 读取失败: %s\n", c->file, path);
            fails++;
            continue;
        }

        BSSidxCoreResult res;
        int st = bssidx_core_parse(buf, len, &res);

        if (c->expect_ok) {
            if (st != BSSIDX_OK) {
                printf("  ✗ %-26s 期望成功，实际 %s\n", c->file, status_name(st));
                fails++;
            } else if (c->expect_count && res.count != c->expect_count) {
                printf("  ✗ %-26s 段数期望 %zu，实际 %zu\n",
                       c->file, c->expect_count, res.count);
                fails++;
            } else {
                /* 自检：各段字节和应等于 covered_bytes；段应连续无空洞 */
                uint64_t sum = 0;
                int contiguous = 1;
                for (size_t k = 0; k < res.count; k++) {
                    sum += res.entries[k].size;
                    if (k > 0) {
                        uint64_t prev_end =
                            res.entries[k-1].offset + res.entries[k-1].size;
                        if (res.entries[k].offset != prev_end) contiguous = 0;
                    }
                }
                if (sum != res.covered_bytes) {
                    printf("  ✗ %-26s covered_bytes 不自洽: %llu vs %llu\n",
                           c->file, (unsigned long long)sum,
                           (unsigned long long)res.covered_bytes);
                    fails++;
                } else if (!contiguous) {
                    printf("  ✗ %-26s 段不连续（存在空洞）\n", c->file);
                    fails++;
                } else {
                    /* 二分查找抽查：随机若干偏移应命中正确的段 */
                    int bsearch_ok = 1;
                    for (size_t k = 0; k < res.count; k += (res.count / 4) + 1) {
                        uint64_t probe = res.entries[k].offset + res.entries[k].size / 2;
                        long got = bssidx_core_segment_for_offset(&res, probe);
                        if (got != (long)k) { bsearch_ok = 0; break; }
                    }
                    if (!bsearch_ok) {
                        printf("  ✗ %-26s 二分查找命中错误段\n", c->file);
                        fails++;
                    } else {
                        printf("  ✓ %-26s 段数=%-3zu timescale=%-6u covered=%llu  %s\n",
                               c->file, res.count, res.timescale,
                               (unsigned long long)res.covered_bytes, c->note);
                    }
                }
            }
        } else {
            if (st == BSSIDX_OK) {
                printf("  ✗ %-26s 期望失败，却解析成功（段数 %zu）  %s\n",
                       c->file, res.count, c->note);
                fails++;
            } else {
                printf("  ✓ %-26s 正确拒绝: %-14s %s\n",
                       c->file, status_name(st), c->note);
            }
        }
        free(buf);
    }

    printf("=========================================================\n");
    if (fails) {
        printf("失败 %d / %zu ❌\n", fails, n);
        return 1;
    }
    printf("全部 %zu 个夹具通过 ✅\n", n);
    return 0;
}
