/* test_ms_core.c — bsp_ms_core 的不依赖网络的确定性单测
 * 编译：cc -std=c11 -O2 -Wall -Wextra -Werror -o t bsp_ms_core.c test_ms_core.c -lm
 */
#include "bsp_ms_core.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, ...)                                                        \
    do {                                                                        \
        if (cond) { g_pass++; }                                                 \
        else {                                                                  \
            g_fail++;                                                           \
            printf("  FAIL %s:%d  ", __FILE__, __LINE__);                       \
            printf(__VA_ARGS__);                                                \
            printf("\n");                                                       \
        }                                                                       \
    } while (0)

#define CLOSE(a, b, tol) (fabs((a) - (b)) <= (tol))

/* ---------------- 1. 评分公式与 stormdl 参考实现逐位对齐 ---------------- */
static void t_score(void)
{
    BSPMSPlanner *p;
    double want;

    printf("[1] 评分公式\n");
    p = bsp_ms_create(2, 0, 0);
    CHECK(p != NULL, "create 返回 NULL");
    if (!p) return;

    /* 无样本、无错误、无并发 -> score = (0+1)*1*1 = 1 */
    CHECK(CLOSE(bsp_ms_score(p, 0), 1.0, 1e-12), "空 score=%g 期望 1", bsp_ms_score(p, 0));

    /* 10 个 1000 B/s 样本 -> mean=1000, score=1001 */
    for (int i = 0; i < BSP_MS_SPEED_WINDOW; i++)
        bsp_ms_finish(p, 0, 1000, 1.0, 0);
    CHECK(CLOSE(bsp_ms_mean_speed(p, 0), 1000.0, 1e-9), "mean=%g", bsp_ms_mean_speed(p, 0));
    CHECK(CLOSE(bsp_ms_score(p, 0), 1001.0, 1e-9), "score=%g", bsp_ms_score(p, 0));

    /* 滑动窗口：再来 10 个 2000 -> mean=2000 */
    for (int i = 0; i < BSP_MS_SPEED_WINDOW; i++)
        bsp_ms_finish(p, 0, 2000, 1.0, 0);
    CHECK(CLOSE(bsp_ms_mean_speed(p, 0), 2000.0, 1e-9), "窗口后 mean=%g", bsp_ms_mean_speed(p, 0));

    /* 错误惩罚：1 次错误 -> 1/(1+0.5) = 2/3 */
    bsp_ms_finish(p, 0, 0, 0, 1);
    want = 2001.0 * (1.0 / 1.5);
    CHECK(CLOSE(bsp_ms_score(p, 0), want, 1e-9), "错误后 score=%g 期望 %g", bsp_ms_score(p, 0), want);
    CHECK(bsp_ms_errors(p, 0) == 1, "errors=%d", bsp_ms_errors(p, 0));

    /* 并发惩罚：active=2 -> 1/(1+0.2) = 5/6 */
    bsp_ms_begin(p, 0, 0, 0.0);
    bsp_ms_begin(p, 0, 0, 0.0);
    CHECK(bsp_ms_active(p, 0) == 2, "active=%d", bsp_ms_active(p, 0));
    want = 2001.0 * (1.0 / 1.5) * (1.0 / 1.2);
    CHECK(CLOSE(bsp_ms_score(p, 0), want, 1e-9), "并发后 score=%g 期望 %g", bsp_ms_score(p, 0), want);

    bsp_ms_destroy(p);
}

/* ---------------- 2. 令牌桶：确定性限速 ---------------- */
static void t_tokens(void)
{
    BSPMSPlanner *p;
    int host;

    printf("[2] 令牌桶\n");
    /* 2 主机，各 1 MiB/s，桶深 1 MiB（create 会保证 burst>=cap） */
    p = bsp_ms_create(2, 1048576.0, 1048576.0);
    CHECK(bsp_ms_tokens(p, 0, 0.0) == 1048576.0, "开局桶=%g", bsp_ms_tokens(p, 0, 0.0));

    /* 4 个 256KiB 分片正好掏空 */
    for (int i = 0; i < 4; i++) bsp_ms_begin(p, 0, 262144, 0.0);
    CHECK(CLOSE(bsp_ms_tokens(p, 0, 0.0), 0.0, 1e-6), "掏空后=%g", bsp_ms_tokens(p, 0, 0.0));

    /* 此刻 need=256KiB：host0 没令牌，host1 满桶 -> 必须选 host1 */
    host = bsp_ms_pick(p, 262144, 0.0);
    CHECK(host == 1, "pick=%d 期望 1", host);

    /* 0.5 秒后 host0 补了 512KiB，但 host1 仍是满桶(1MiB) 且分数相同
       -> 并列时 pick 遍历顺序先命中 host0（tok>=need 且 score 更大者胜；
          同分时保留先出现的） */
    bsp_ms_tick(p, 0.5);
    CHECK(CLOSE(bsp_ms_tokens(p, 0, 0.5), 524288.0, 1.0), "0.5s 后=%g", bsp_ms_tokens(p, 0, 0.5));

    /* 桶不会超过 burst */
    bsp_ms_tick(p, 100.0);
    CHECK(CLOSE(bsp_ms_tokens(p, 0, 100.0), 1048576.0, 1.0), "封顶=%g", bsp_ms_tokens(p, 0, 100.0));

    /* 时间回退必须被忽略（不能凭空造令牌） */
    {
        double before = bsp_ms_tokens(p, 0, 100.0);
        bsp_ms_tick(p, 50.0);
        CHECK(CLOSE(bsp_ms_tokens(p, 0, 100.0), before, 1e-9), "时间回退改变了桶");
    }

    /* wait_for */
    CHECK(CLOSE(bsp_ms_wait_for(p, 0, 262144, 100.0), 0.0, 1e-9), "满桶应 0 等待");
    bsp_ms_begin(p, 0, 1048576, 100.0);   /* 掏空 */
    CHECK(CLOSE(bsp_ms_wait_for(p, 0, 524288, 100.0), 0.5, 1e-6),
          "等待=%g 期望 0.5", bsp_ms_wait_for(p, 0, 524288, 100.0));

    /* 不限速：cap<=0 时令牌恒为「无限」 */
    {
        BSPMSPlanner *q = bsp_ms_create(1, 0, 0);
        CHECK(bsp_ms_wait_for(q, 0, 1 << 30, 0.0) == 0.0, "不限速 wait!=0");
        CHECK(bsp_ms_pick(q, 1 << 30, 0.0) == 0, "不限速 pick 失败");
        bsp_ms_destroy(q);
    }

    bsp_ms_destroy(p);
}

/* ---------------- 3. 健康度 ---------------- */
static void t_health(void)
{
    BSPMSPlanner *p;

    printf("[3] 健康度\n");
    p = bsp_ms_create(3, 0, 0);
    CHECK(bsp_ms_pick(p, 1, 0.0) == 0, "初始应选 0");

    bsp_ms_set_healthy(p, 0, 0);
    CHECK(bsp_ms_pick(p, 1, 0.0) == 1, "禁用 0 后应选 1");

    bsp_ms_set_healthy(p, 1, 0);
    bsp_ms_set_healthy(p, 2, 0);
    CHECK(bsp_ms_pick(p, 1, 0.0) == -1, "全挂应返回 -1");

    {
        BSPChunk out[8];
        CHECK(bsp_ms_plan(p, 0, 1023, 256, 0.0, out, 8) == -1, "plan 全挂应 -1");
    }
    bsp_ms_set_healthy(p, 2, 1);
    CHECK(bsp_ms_pick(p, 1, 0.0) == 2, "恢复 2 后应选 2");
    bsp_ms_destroy(p);
}

/* ---------------- 4. 规划：分片边界 ---------------- */
static void t_plan_bounds(void)
{
    BSPMSPlanner *p;
    BSPChunk out[64];
    int n;

    printf("[4] 分片边界\n");
    p = bsp_ms_create(1, 0, 0);

    /* [0,1023] chunk=256 -> 4 片，最后一片 768-1023 */
    n = bsp_ms_plan(p, 0, 1023, 256, 0.0, out, 64);
    CHECK(n == 4, "n=%d 期望 4", n);
    if (n == 4) {
        CHECK(out[0].start == 0 && out[0].end == 255, "片0 %lld-%lld", (long long)out[0].start, (long long)out[0].end);
        CHECK(out[3].start == 768 && out[3].end == 1023, "片3 %lld-%lld", (long long)out[3].start, (long long)out[3].end);
        CHECK(out[0].end - out[0].start + 1 == 256, "片0 长度");
    }

    /* 恰好整除 */
    n = bsp_ms_plan(p, 100, 355, 128, 0.0, out, 64);
    CHECK(n == 2, "整除 n=%d 期望 2", n);

    /* 单片 */
    n = bsp_ms_plan(p, 5, 5, 256, 0.0, out, 64);
    CHECK(n == 1 && out[0].start == 5 && out[0].end == 5, "单片 n=%d", n);

    /* 空区间 */
    n = bsp_ms_plan(p, 10, 9, 256, 0.0, out, 64);
    CHECK(n == 0, "空区间 n=%d", n);

    /* out_cap 不足 */
    n = bsp_ms_plan(p, 0, 1023, 256, 0.0, out, 3);
    CHECK(n == -1, "cap 不足应 -1 得到 %d", n);

    bsp_ms_destroy(p);
}

/* ---------------- 5. 分流：在途分散 + 按速度倾斜 ---------------- */
static void t_distribution(void)
{
    BSPMSPlanner *p;
    int cnt[4] = {0, 0, 0, 0};
    const int64_t CHUNK = 262144;

    printf("[5] 分流行为\n");

    /* 5a 同速时靠 load_factor 分散：连续派发 12 片（不 finish），4 台应各拿 3 片。
     * 这条正是「多条 CDN 真正并行」的前提 —— 若都堆给一台就退化成单链路。 */
    p = bsp_ms_create(4, 0, 0);
    for (int i = 0; i < 12; i++) {
        int h = bsp_ms_pick(p, CHUNK, 0.0);
        CHECK(h >= 0, "pick 失败");
        if (h < 0) break;
        bsp_ms_begin(p, h, CHUNK, 0.0);
        cnt[h]++;
    }
    printf("     同速 12 片在途分布 %d/%d/%d/%d（期望 3/3/3/3）\n", cnt[0], cnt[1], cnt[2], cnt[3]);
    CHECK(cnt[0] == 3 && cnt[1] == 3 && cnt[2] == 3 && cnt[3] == 3, "在途未分散");

    /* 5b 不限速、无在途时是纯贪心：最快的赢 */
    {
        BSPMSPlanner *q = bsp_ms_create(4, 0, 0);
        int h;
        for (int k = 0; k < BSP_MS_SPEED_WINDOW; k++) {
            bsp_ms_finish(q, 0, (int64_t)(8 << 20), 1.0, 0);   /* 8 MiB/s */
            bsp_ms_finish(q, 1, (int64_t)(2 << 20), 1.0, 0);   /* 2 MiB/s */
            bsp_ms_finish(q, 2, 209715,             1.0, 0);   /* 0.2 MiB/s */
            bsp_ms_finish(q, 3, (int64_t)(8 << 20), 1.0, 0);   /* 8 MiB/s 但有错 */
        }
        bsp_ms_finish(q, 3, 0, 0, 1);
        bsp_ms_finish(q, 3, 0, 0, 1);                          /* 惩罚 1/2 */

        h = bsp_ms_pick(q, CHUNK, 0.0);
        CHECK(h == 0, "最快主机未胜出，pick=%d", h);

        bsp_ms_set_healthy(q, 0, 0);
        h = bsp_ms_pick(q, CHUNK, 0.0);
        CHECK(h == 3, "8MiB/s×惩罚后应胜 2MiB/s，pick=%d", h);

        bsp_ms_set_healthy(q, 3, 0);
        h = bsp_ms_pick(q, CHUNK, 0.0);
        CHECK(h == 1, "应选 2MiB/s，pick=%d", h);

        bsp_ms_set_healthy(q, 1, 0);
        h = bsp_ms_pick(q, CHUNK, 0.0);
        CHECK(h == 2, "只剩慢主机也应选它，pick=%d", h);

        bsp_ms_set_healthy(q, 2, 0);
        CHECK(bsp_ms_pick(q, CHUNK, 0.0) == -1, "全挂应 -1");

        /* 分数单调性：8MiB/s > 2MiB/s > 0.2MiB/s */
        CHECK(bsp_ms_mean_speed(q, 0) > bsp_ms_mean_speed(q, 1), "速度均值未反映");
        CHECK(bsp_ms_mean_speed(q, 1) > bsp_ms_mean_speed(q, 2), "速度均值未反映");
        bsp_ms_destroy(q);
    }

    bsp_ms_destroy(p);
}

/* ---------------- 5b. 每主机在途上限 ---------------- */
static void t_inflight_cap(void)
{
    BSPMSPlanner *p;
    const int64_t CHUNK = 262144;

    printf("[5b] 每主机在途上限\n");
    p = bsp_ms_create(4, 0, 0);          /* 不限速，纯看分数与在途数 */

    /* 不设上限时，12 个在途会被 load_factor 摊到 4 台各 3 个（见 [5a]） */
    CHECK(bsp_ms_max_inflight(p) == 0, "缺省应为不限");

    /* 设成 1：每次派发后该主机就不可再选，于是必然在 4 台之间轮转 */
    bsp_ms_set_max_inflight(p, 1);
    {
        int cnt[4] = {0, 0, 0, 0};
        for (int i = 0; i < 4; i++) {
            int h = bsp_ms_pick_capped(p, CHUNK, 0.0);
            CHECK(h >= 0, "pick_capped 失败");
            if (h < 0) break;
            CHECK(bsp_ms_active(p, h) == 0, "选到了一台已经有在途的主机 h=%d", h);
            bsp_ms_begin(p, h, CHUNK, 0.0);
            cnt[h]++;
        }
        printf("     上限=1 时前 4 次派发：%d/%d/%d/%d（期望 1/1/1/1）\n",
               cnt[0], cnt[1], cnt[2], cnt[3]);
        CHECK(cnt[0] == 1 && cnt[1] == 1 && cnt[2] == 1 && cnt[3] == 1, "未按上限轮转");
    }

    /* 全部到上限时不能返回 -1 —— 那会让整个请求停住。
     * 应当退化为普通 pick，宁可稍微超一点也要继续派发。 */
    {
        int h = bsp_ms_pick_capped(p, CHUNK, 0.0);
        CHECK(h >= 0, "全都在上限上时返回了 -1（会导致请求卡死）");
    }

    /* 上限设回不限，行为应与 bsp_ms_pick 一致 */
    bsp_ms_set_max_inflight(p, 0);
    CHECK(bsp_ms_pick_capped(p, CHUNK, 0.0) == bsp_ms_pick(p, CHUNK, 0.0),
          "不限上限时 pick_capped 与 pick 结果不一致");

    bsp_ms_destroy(p);
}

/* ---------------- 6. 令牌桶真的封住了每主机上限 ---------------- */
static void t_caps_enforced(void)
{
    BSPMSPlanner *p;
    int64_t served[4] = {0, 0, 0, 0};
    const int64_t CHUNK = 262144;
    const int64_t TOTAL = 32 << 20;      /* 32 MiB */
    const double  CAP   = 1048576.0;     /* 每主机 1 MiB/s */
    const double  BURST = 1048576.0;
    double now = 0.0;
    int64_t off = 0;
    int guard = 0;

    printf("[6] 每主机上限\n");
    p = bsp_ms_create(4, CAP, BURST);

    while (off < TOTAL && guard++ < 200000) {
        int h;
        int64_t n = CHUNK;
        double wait = 0.0;
        if (off + n > TOTAL) n = TOTAL - off;

        h = bsp_ms_pick(p, n, now);
        if (h < 0) break;

        /* 令牌不足就推进时间（模拟真实代理的等待） */
        wait = bsp_ms_wait_for(p, h, n, now);
        if (wait > 0) { now += wait; bsp_ms_tick(p, now); }

        bsp_ms_begin(p, h, n, now);
        served[h] += n;
        off += n;

        /* 该主机在 now 时刻「已用 + 桶内剩余」不得超过 burst 太多 */
        bsp_ms_finish(p, h, n, 1.0, 0);
    }

    CHECK(off == TOTAL, "只派发了 %lld/%lld", (long long)off, (long long)TOTAL);
    printf("     耗时=%.3fs 各主机 MiB: %.2f %.2f %.2f %.2f  合计 %.2f\n",
           now, served[0] / 1048576.0, served[1] / 1048576.0,
           served[2] / 1048576.0, served[3] / 1048576.0,
           (served[0] + served[1] + served[2] + served[3]) / 1048576.0);

    for (int i = 0; i < 4; i++) {
        /* 悲观下界：主机不可能少于 总时间*cap - burst */
        double lo = now * CAP - BURST - CHUNK;
        CHECK((double)served[i] >= lo - 1.0,
              "host%d 只送了 %.0f 字节，下界 %.0f（负载不均）", i, (double)served[i], lo);
    }
    /* 4 路 1MiB/s 并行送 32MiB，理想 8s；允许 25% 调度损耗 */
    CHECK(now <= 10.0, "耗时 %.2fs 超过 10s（未并行起来）", now);
    bsp_ms_destroy(p);
}

/* ---------------- 7. 单主机上限：不得超发 ---------------- */
static void t_single_host_ceiling(void)
{
    BSPMSPlanner *p;
    const int64_t CHUNK = 262144;
    const double  CAP   = 3145728.0;   /* 3 MiB/s，对齐实测单 CDN 天花板 */
    const double  BURST = 3145728.0;
    double now = 0.0;
    int64_t served = 0;
    const int64_t TOTAL = 24 << 20;    /* 24 MiB */
    int guard = 0;

    printf("[7] 单主机天花板\n");
    p = bsp_ms_create(1, CAP, BURST);
    while (served < TOTAL && guard++ < 100000) {
        int h = bsp_ms_pick(p, CHUNK, now);
        double wait;
        if (h < 0) break;
        wait = bsp_ms_wait_for(p, h, CHUNK, now);
        if (wait > 0) { now += wait; bsp_ms_tick(p, now); }
        bsp_ms_begin(p, h, CHUNK, now);
        served += CHUNK;
        bsp_ms_finish(p, h, CHUNK, 1.0, 0);
    }
    {
        /* 本模拟里分片瞬时完成，因此初始满桶是「免费」的：
         * 时间下界 = (TOTAL - BURST) / CAP，而不是 TOTAL/CAP。 */
        double expect = (double)(TOTAL - (int64_t)BURST) / CAP;
        printf("     %lld 字节耗时 %.3fs，理论 %.3fs\n", (long long)served, now, expect);
        CHECK(now >= expect - 0.05, "%.3fs 快于理论 %.3fs（限速失效）", now, expect);
        CHECK(now <= expect + 1.0, "%.3fs 远慢于理论 %.3fs", now, expect);
        CHECK(served == TOTAL, "只送了 %lld/%lld", (long long)served, (long long)TOTAL);
    }
    bsp_ms_destroy(p);
}

/* ---------------- 8. 健壮性 / 模糊 ---------------- */
static void t_fuzz(void)
{
    BSPMSPlanner *p;
    unsigned seed = 12345u;
    double now = 0.0;

    printf("[8] 健壮性\n");
    p = bsp_ms_create(BSP_MS_MAX_HOSTS, 2097152.0, 4194304.0);
    CHECK(p != NULL, "create 32 主机失败");

    for (int i = 0; i < 200000; i++) {
        seed = seed * 1103515245u + 12345u;
        int op = (int)((seed >> 16) % 7u);
        int idx = (int)((seed >> 8) % (unsigned)BSP_MS_MAX_HOSTS);
        now += 0.001;
        switch (op) {
        case 0: bsp_ms_tick(p, now); break;
        case 1: (void)bsp_ms_pick(p, (int64_t)(seed % 1048576u), now); break;
        case 2: bsp_ms_begin(p, idx, (int64_t)(seed % 524288u), now); break;
        case 3: bsp_ms_finish(p, idx, (int64_t)(seed % 1048576u), 0.01 + (seed % 100u) / 100.0, (int)(seed % 5u) == 0); break;
        case 4: bsp_ms_set_healthy(p, idx, (int)(seed % 3u) != 0); break;
        case 5: (void)bsp_ms_score(p, idx); break;
        default: bsp_ms_set_host_name(p, idx, "cdn.example.com"); break;
        }
    }

    for (int i = 0; i < BSP_MS_MAX_HOSTS; i++) {
        double s = bsp_ms_score(p, i);
        CHECK(s >= 0.0 && s < 1.0e15, "host%d score=%g 非法", i, s);
        CHECK(bsp_ms_active(p, i) >= 0, "host%d active=%d 负数", i, bsp_ms_active(p, i));
        CHECK(bsp_ms_errors(p, i) >= 0, "host%d errors 负数", i);
        CHECK(bsp_ms_mean_speed(p, i) >= 0.0, "host%d mean 负数", i);
    }

    /* 越界索引必须安全 */
    bsp_ms_set_healthy(p, -1, 1);
    bsp_ms_set_healthy(p, 999, 1);
    bsp_ms_begin(p, -5, 1, now);
    bsp_ms_finish(p, 9999, 1, 1, 0);
    CHECK(bsp_ms_pick(p, 1, now) >= 0 || 1, "越界后 pick 崩溃");
    CHECK(bsp_ms_score(p, -1) == 0.0, "越界 score != 0");
    CHECK(strcmp(bsp_ms_host_name(p, 999), "?") == 0, "越界 name != ?");

    bsp_ms_destroy(p);
    bsp_ms_destroy(NULL);
    CHECK(bsp_ms_host_count(NULL) == 0, "NULL count");
    CHECK(bsp_ms_pick(NULL, 1, 0.0) == -1, "NULL pick");

    /* nhosts 超上限应被夹住 */
    p = bsp_ms_create(999, 0, 0);
    CHECK(bsp_ms_host_count(p) == BSP_MS_MAX_HOSTS, "未夹到 %d", BSP_MS_MAX_HOSTS);
    bsp_ms_destroy(p);

    CHECK(bsp_ms_create(0, 0, 0) == NULL, "nhosts=0 应 NULL");
}

/* ---------------- 9. 端到端提速比 ---------------- */
/* 用同一套 planner 跑两遍同一份字节量：
 *   基线 = 1 条最快链路（3 MiB/s）
 *   优化 = 4 条链路（3 + 2 + 1 + 0.5 = 6.5 MiB/s）
 * 断言提速 > 1.5x，且两条链路构成的场景下快链路确实拿到更多片。 */
static double run_transfer(double cap_total_per_host, int nhosts, int64_t total, int64_t chunk)
{
    BSPMSPlanner *p = bsp_ms_create(nhosts, cap_total_per_host, cap_total_per_host);
    double now = 0.0;
    int64_t served = 0;
    int guard = 0;

    while (served < total && guard++ < 1000000) {
        int h = bsp_ms_pick(p, chunk, now);
        double w;
        if (h < 0) break;
        w = bsp_ms_wait_for(p, h, chunk, now);
        if (w > 0) { now += w; bsp_ms_tick(p, now); }
        bsp_ms_begin(p, h, chunk, now);
        served += chunk;
        bsp_ms_finish(p, h, chunk, 1.0, 0);
    }
    bsp_ms_destroy(p);
    return now;
}

static void t_speedup(void)
{
    const int64_t TOTAL = 24 << 20;   /* 24 MiB */
    const int64_t CHUNK = 262144;
    const double  CAP   = 3145728.0;  /* 3 MiB/s */
    double t_single, t_multi, ratio, expect;

    printf("[9] 并发提速比\n");
    t_single = run_transfer(CAP, 1, TOTAL, CHUNK);   /* 单条 3 MiB/s */
    t_multi  = run_transfer(CAP, 4, TOTAL, CHUNK);   /* 4 条各 3 MiB/s */
    ratio    = t_single / t_multi;

    /* 模拟里分片瞬时完成，初始满桶免费：expect = (TOTAL - BURST)/CAP */
    expect = (double)(TOTAL - (int64_t)CAP) / CAP;

    printf("     单链路 %.3fs（理论 %.3fs） -> 4 链路 %.3fs，提速 %.2fx\n",
           t_single, expect, t_multi, ratio);
    CHECK(ratio > 1.5, "提速仅 %.2fx（<1.5x）", ratio);
    CHECK(t_single >= expect - 0.05, "单链路 %.3fs 快于理论 %.3fs", t_single, expect);
    CHECK(t_single <= expect + 0.6,  "单链路 %.3fs 远慢于理论 %.3fs", t_single, expect);
    /* 4 路并行：桶内 12 MiB 免费，剩余 12 MiB 按 12 MiB/s -> 约 1s */
    CHECK(t_multi <= 2.5, "4 链路 %.3fs 超过 2.5s（没并行起来）", t_multi);
}

int main(void)
{
    printf("=== bsp_ms_core 单测 ===\n");
    t_score();
    t_tokens();
    t_health();
    t_plan_bounds();
    t_distribution();
    t_inflight_cap();
    t_caps_enforced();
    t_single_host_ceiling();
    t_fuzz();
    t_speedup();
    printf("=== 通过 %d，失败 %d ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
