/* bsp_ms_core.c — 见 bsp_ms_core.h */
#include "bsp_ms_core.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct {
    char    name[160];
    int     healthy;
    int     active;
    int     errors;
    double  speed_sum;              /* 窗口内速度样本和 */
    double  speed_buf[BSP_MS_SPEED_WINDOW];
    int     speed_len;
    int     speed_pos;
    double  tokens;
    double  cap;                    /* 字节/秒 */
    double  burst;                  /* 字节 */
    double  refilled_at;
    double  last_speed;             /* 最近一次样本，便于日志 */
} BSPHost;

struct BSPMSPlanner {
    int     n;
    double  cap;
    double  burst;
    BSPHost h[BSP_MS_MAX_HOSTS];
};

static double bsp_now_or_zero(double now) { return now; }

BSPMSPlanner *bsp_ms_create(int nhosts, double host_cap_Bps, double host_burst_B)
{
    BSPMSPlanner *p;
    int i;

    if (nhosts < 1) return NULL;
    if (nhosts > BSP_MS_MAX_HOSTS) nhosts = BSP_MS_MAX_HOSTS;

    p = (BSPMSPlanner *)calloc(1, sizeof(*p));
    if (!p) return NULL;

    p->n     = nhosts;
    p->cap   = host_cap_Bps > 0 ? host_cap_Bps : 0.0;
    p->burst = host_burst_B > 0 ? host_burst_B : 0.0;
    if (p->cap > 0 && p->burst < p->cap) p->burst = p->cap; /* 至少 1 秒的桶 */

    for (i = 0; i < nhosts; i++) {
        BSPHost *h = &p->h[i];
        snprintf(h->name, sizeof(h->name), "h%d", i);
        h->healthy    = 1;
        h->active     = 0;
        h->errors     = 0;
        h->cap        = p->cap;
        h->burst      = p->burst;
        h->tokens     = p->burst;   /* 开局满桶 */
        h->refilled_at = 0.0;
    }
    return p;
}

void bsp_ms_destroy(BSPMSPlanner *p) { free(p); }

int bsp_ms_host_count(const BSPMSPlanner *p) { return p ? p->n : 0; }

void bsp_ms_set_host_name(BSPMSPlanner *p, int idx, const char *name)
{
    if (!p || idx < 0 || idx >= p->n) return;
    if (!name || !*name) { snprintf(p->h[idx].name, sizeof(p->h[idx].name), "h%d", idx); return; }
    snprintf(p->h[idx].name, sizeof(p->h[idx].name), "%s", name);
}

const char *bsp_ms_host_name(const BSPMSPlanner *p, int idx)
{
    if (!p || idx < 0 || idx >= p->n) return "?";
    return p->h[idx].name;
}

void bsp_ms_set_healthy(BSPMSPlanner *p, int idx, int healthy)
{
    if (!p || idx < 0 || idx >= p->n) return;
    p->h[idx].healthy = healthy ? 1 : 0;
}

int bsp_ms_is_healthy(const BSPMSPlanner *p, int idx)
{
    if (!p || idx < 0 || idx >= p->n) return 0;
    return p->h[idx].healthy;
}

void bsp_ms_set_cap(BSPMSPlanner *p, int idx, double cap_Bps)
{
    BSPHost *h;
    double newcap;
    if (!p || idx < 0 || idx >= p->n) return;
    h = &p->h[idx];
    newcap = cap_Bps > 0 ? cap_Bps : 0.0;

    if (newcap <= 0) { h->cap = 0; h->burst = 0; return; }

    /* 涨速时把桶底也抬起来，避免长期欠账；桶里已有令牌不超过新桶深 */
    if (newcap > h->cap) {
        if (h->tokens < 0) h->tokens = 0;
        h->burst = newcap;
        if (h->tokens > h->burst) h->tokens = h->burst;
    } else {
        if (h->burst > newcap) h->burst = newcap;
        if (h->tokens > h->burst) h->tokens = h->burst;
    }
    h->cap = newcap;
}

double bsp_ms_cap(const BSPMSPlanner *p, int idx)
{
    if (!p || idx < 0 || idx >= p->n) return 0.0;
    return p->h[idx].cap;
}

/* ------------------------------------------------------------------ */

void bsp_ms_tick(BSPMSPlanner *p, double now)
{
    int i;
    if (!p) return;
    for (i = 0; i < p->n; i++) {
        BSPHost *h = &p->h[i];
        double dt;
        if (h->cap <= 0) { h->refilled_at = now; continue; }
        dt = now - h->refilled_at;
        if (dt <= 0) continue;                 /* 时间回退：忽略 */
        h->tokens += dt * h->cap;
        if (h->tokens > h->burst) h->tokens = h->burst;
        h->refilled_at = now;
    }
}

/* 只读补桶：不改 p，只在副本上算 */
static double bsp_tokens_at(const BSPMSPlanner *p, int idx, double now)
{
    const BSPHost *h;
    double dt;
    if (!p || idx < 0 || idx >= p->n) return 0.0;
    h = &p->h[idx];
    if (h->cap <= 0) return 1.0e18;            /* 不限速 */
    dt = now - h->refilled_at;
    if (dt <= 0) return h->tokens;
    {
        double t = h->tokens + dt * h->cap;
        return t > h->burst ? h->burst : t;
    }
}

double bsp_ms_tokens(const BSPMSPlanner *p, int idx, double now)
{
    return bsp_tokens_at(p, idx, now);
}

double bsp_ms_wait_for(const BSPMSPlanner *p, int idx, int64_t need_bytes, double now)
{
    const BSPHost *h;
    double have, deficit;
    if (!p || idx < 0 || idx >= p->n) return 0.0;
    h = &p->h[idx];
    if (h->cap <= 0) return 0.0;
    have = bsp_tokens_at(p, idx, now);
    deficit = (double)need_bytes - have;
    if (deficit <= 0) return 0.0;
    return deficit / h->cap;
}

double bsp_ms_mean_speed(const BSPMSPlanner *p, int idx)
{
    if (!p || idx < 0 || idx >= p->n) return 0.0;
    if (p->h[idx].speed_len <= 0) return 0.0;
    return p->h[idx].speed_sum / (double)p->h[idx].speed_len;
}

int bsp_ms_active(const BSPMSPlanner *p, int idx)
{
    if (!p || idx < 0 || idx >= p->n) return 0;
    return p->h[idx].active;
}

int bsp_ms_errors(const BSPMSPlanner *p, int idx)
{
    if (!p || idx < 0 || idx >= p->n) return 0;
    return p->h[idx].errors;
}

double bsp_ms_score(const BSPMSPlanner *p, int idx)
{
    double speed, err_pen, load_fac, s;
    if (!p || idx < 0 || idx >= p->n) return 0.0;
    speed    = bsp_ms_mean_speed(p, idx);
    err_pen  = 1.0 / (1.0 + (double)p->h[idx].errors * 0.5);
    load_fac = 1.0 / (1.0 + (double)p->h[idx].active * 0.1);
    s = (speed + 1.0) * err_pen * load_fac;
    return s;
}

int bsp_ms_pick(const BSPMSPlanner *p, int64_t need_bytes, double now)
{
    int i, best_scored = -1, best_token = -1;
    double best_score = -1.0, best_tok = -1.0, best_token_score = -1.0;

    if (!p) return -1;

    for (i = 0; i < p->n; i++) {
        double tok, sc;
        if (!p->h[i].healthy) continue;
        tok = bsp_tokens_at(p, i, now);
        sc  = bsp_ms_score(p, i);

        if (tok >= (double)need_bytes) {
            if (sc > best_score) { best_score = sc; best_scored = i; }
        }
        if (tok > best_tok || (tok == best_tok && sc > best_token_score)) {
            best_tok = tok; best_token = i; best_token_score = sc;
        }
    }
    if (best_scored >= 0) return best_scored;
    return best_token;
}

int bsp_ms_next_ready(const BSPMSPlanner *p, int64_t need_bytes, double now, double *out_wait)
{
    int i, best = -1;
    double best_wait = -1.0;
    if (!p) return -1;

    for (i = 0; i < p->n; i++) {
        double w;
        if (!p->h[i].healthy) continue;
        w = bsp_ms_wait_for(p, i, need_bytes, now);
        if (w <= 0.0) { if (out_wait) *out_wait = 0.0; return i; }
        if (best < 0 || w < best_wait) { best = i; best_wait = w; }
    }
    if (best >= 0 && out_wait) *out_wait = best_wait;
    return best;
}

void bsp_ms_begin(BSPMSPlanner *p, int idx, int64_t bytes, double now)
{
    if (!p || idx < 0 || idx >= p->n) return;
    bsp_ms_tick(p, now);
    p->h[idx].tokens -= (double)bytes;
    if (p->h[idx].cap > 0 && p->h[idx].tokens < -p->h[idx].burst)
        p->h[idx].tokens = -p->h[idx].burst;   /* 欠账封顶，别无限负 */
    p->h[idx].active += 1;
}

void bsp_ms_finish(BSPMSPlanner *p, int idx, int64_t bytes, double seconds, int error)
{
    BSPHost *h;
    double sp;
    if (!p || idx < 0 || idx >= p->n) return;
    h = &p->h[idx];

    if (h->active > 0) h->active -= 1;

    if (error) {
        h->errors += 1;
        return;
    }
    if (bytes <= 0 || seconds <= 0.0) return;

    sp = (double)bytes / seconds;
    if (!(sp >= 0.0) || sp > 1.0e12) return;   /* NaN/离谱值丢弃 */

    if (h->speed_len == BSP_MS_SPEED_WINDOW) h->speed_sum -= h->speed_buf[h->speed_pos];
    else                                     h->speed_len += 1;
    h->speed_buf[h->speed_pos] = sp;
    h->speed_sum += sp;
    h->speed_pos = (h->speed_pos + 1) % BSP_MS_SPEED_WINDOW;
    h->last_speed = sp;
}

int bsp_ms_plan(BSPMSPlanner *p, int64_t start, int64_t end, int64_t chunk,
                double now, BSPChunk *out, int out_cap)
{
    int n = 0;
    int64_t off;

    if (!p || !out || out_cap <= 0) return -1;
    if (chunk <= 0) chunk = 1;
    if (end < start) return 0;

    {   /* 先确认至少有一个健康主机，避免写一半状态 */
        int i, any = 0;
        for (i = 0; i < p->n; i++) if (p->h[i].healthy) { any = 1; break; }
        if (!any) return -1;
    }

    for (off = start; off <= end; off += chunk) {
        int64_t e = off + chunk - 1;
        int host;
        if (e > end) e = end;
        if (n >= out_cap) return -1;

        host = bsp_ms_pick(p, e - off + 1, now);
        if (host < 0) return -1;

        bsp_ms_begin(p, host, e - off + 1, now);
        out[n].index = host;
        out[n].start = off;
        out[n].end   = e;
        n++;
    }
    return n;
}
