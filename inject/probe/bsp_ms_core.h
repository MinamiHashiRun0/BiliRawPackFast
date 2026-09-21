/* bsp_ms_core.h — 多 CDN 分段调度核心（纯 C，无依赖，可在 Linux/macOS 单测）
 *
 * 算法来自 stormdl `crates/storm-segment/src/multi_source.rs`：
 *     score = (speed + 1.0) * error_penalty * load_factor
 *     error_penalty = 1 / (1 + errors * 0.5)
 *     load_factor   = 1 / (1 + active * 0.1)
 *     speed         = 最近 N 次「单次请求」测速的滑动均值
 * 再加每主机令牌桶做确定性限速（真实 CDN 会按连接/账号限速，不能假设无限带宽）。
 *
 * 时基：所有 now 参数都是「秒」，单调递增即可，原点任意（调用方用
 * mach_absolute_time / clock_gettime(CLOCK_MONOTONIC) 换算）。
 */
#ifndef BSP_MS_CORE_H
#define BSP_MS_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BSP_MS_MAX_HOSTS    64
#define BSP_MS_SPEED_WINDOW 10

typedef struct {
    int    index;   /* 主机下标 */
    int64_t start;  /* 起始字节，含 */
    int64_t end;    /* 结束字节，含 */
} BSPChunk;

typedef struct BSPMSPlanner BSPMSPlanner;

/* ------------------------------------------------------------------ */
/* 生命周期                                                            */
/* ------------------------------------------------------------------ */

/* host_cap_Bps / host_burst_B 为每主机令牌桶速率与容量；<=0 表示不限速。
 * per_conn_cap_Bps 只影响初始评分上限，<=0 表示不管。 */
BSPMSPlanner *bsp_ms_create(int nhosts, double host_cap_Bps, double host_burst_B);

void bsp_ms_destroy(BSPMSPlanner *p);

int  bsp_ms_host_count(const BSPMSPlanner *p);

/* 写入主机名（用于日志）；name 为 NULL 或空串时写入 "h<i>" */
void bsp_ms_set_host_name(BSPMSPlanner *p, int idx, const char *name);
const char *bsp_ms_host_name(const BSPMSPlanner *p, int idx);

/* healthy=0 的主机不会被 pick 选中 */
void bsp_ms_set_healthy(BSPMSPlanner *p, int idx, int healthy);
int  bsp_ms_is_healthy(const BSPMSPlanner *p, int idx);

/* 自适应调整某主机的令牌桶速率（AIMD 用）。
 * cap<=0 表示该主机不限速。burst 小于 cap 时会一起抬到 cap。 */
void bsp_ms_set_cap(BSPMSPlanner *p, int idx, double cap_Bps);
double bsp_ms_cap(const BSPMSPlanner *p, int idx);

/* ------------------------------------------------------------------ */
/* 时间 / 令牌桶                                                       */
/* ------------------------------------------------------------------ */

/* 把所有令牌桶按 now 补充到当前时刻。必须单调不减；回退会被忽略。 */
void bsp_ms_tick(BSPMSPlanner *p, double now);

/* now 时刻某主机可用令牌数（会先按需 tick，不改变状态） */
double bsp_ms_tokens(const BSPMSPlanner *p, int idx, double now);

/* 距离 idx 攒够 need_bytes 令牌还需要多少秒（0 表示马上够；不限速返回 0） */
double bsp_ms_wait_for(const BSPMSPlanner *p, int idx, int64_t need_bytes, double now);

/* ------------------------------------------------------------------ */
/* 评分与选择                                                          */
/* ------------------------------------------------------------------ */

double bsp_ms_score(const BSPMSPlanner *p, int idx);
double bsp_ms_mean_speed(const BSPMSPlanner *p, int idx);
int    bsp_ms_active(const BSPMSPlanner *p, int idx);
int    bsp_ms_errors(const BSPMSPlanner *p, int idx);

/* 选一个主机来处理 need_bytes：
 *   1) 健康 && 令牌 >= need_bytes 的主机里，选 score 最大的
 *   2) 否则健康主机里选令牌最多的（并列取 score 大的）
 *   3) 全都不健康返回 -1
 * 纯查询，不改变任何状态。 */
int bsp_ms_pick(const BSPMSPlanner *p, int64_t need_bytes, double now);

/* 在 1)/2) 都失败时，返回「最近能凑够 need_bytes 的主机」及其等待秒数。
 * 用于调用方 sleep。返回 -1 表示没有健康主机。 */
int bsp_ms_next_ready(const BSPMSPlanner *p, int64_t need_bytes, double now, double *out_wait);

/* 每主机在途分片数上限。
 *
 * 为什么需要：真机日志里出现大量「网络连接已中断」—— 调度器学会哪台快之后会把
 * 十几个分片同时压到同一台 CDN 上，而对端会掐掉过量并发连接。这是**并发数**上限，
 * 不是带宽上限（带宽上限那套 AIMD 已经证明会自锁成瓶颈，见 BSPProxyServer.m）。
 * 设为 0 表示不限。 */
void bsp_ms_set_max_inflight(BSPMSPlanner *p, int n);
int  bsp_ms_max_inflight(const BSPMSPlanner *p);

/* 与 bsp_ms_pick 相同的选择逻辑，但**优先**返回在途数未达上限的健康主机；
 * 若所有健康主机都已到上限，则退化为普通 pick（宁可超一点，也不能卡住不派发）。 */
int bsp_ms_pick_capped(const BSPMSPlanner *p, int64_t need_bytes, double now);

/* 派发一个分片：tok -= bytes，active += 1 */
void bsp_ms_begin(BSPMSPlanner *p, int idx, int64_t bytes, double now);

/* 分片结束：active -= 1，更新滑动测速与错误计数。
 * bytes<=0 或 seconds<=0 时只更新错误/负载，不污染速度样本。 */
void bsp_ms_finish(BSPMSPlanner *p, int idx, int64_t bytes, double seconds, int error);

/* ------------------------------------------------------------------ */
/* 静态规划（单测 / 预演用；真实代理走 pick+begin/finish 动态循环）      */
/* ------------------------------------------------------------------ */

/* 把 [start,end]（含端点）切成 <=chunk 字节的分片并逐片 pick+begin。
 * 写回 out[0..]，返回分片数；out_cap 不够返回 -1（此时不改状态）。
 * 全部主机不健康返回 -1。now 用于令牌补充。 */
int bsp_ms_plan(BSPMSPlanner *p, int64_t start, int64_t end, int64_t chunk,
                double now, BSPChunk *out, int out_cap);

#ifdef __cplusplus
}
#endif
#endif /* BSP_MS_CORE_H */
