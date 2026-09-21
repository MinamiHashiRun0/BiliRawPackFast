/* bsp_enctypes.c — 见 bsp_enctypes.h */
#include "bsp_enctypes.h"

/* 解析一个「聚合体」：{...} / (...) / [...]，处理嵌套 */
static const char *skip_aggregate(const char *p)
{
    char open = *p;
    char close = (open == '{') ? '}' : (open == '(' ? ')' : ']');
    int depth = 0;
    while (*p) {
        if (*p == open) depth++;
        else if (*p == close) { depth--; if (depth == 0) { p++; break; } }
        p++;
    }
    return p;
}

/* 消耗一个完整类型，返回其首字符（归一化后），并让 p 前进到该类型之后
 * （数字留给调用方统一跳过）。 */
static char consume_type(const char **pp)
{
    const char *p = *pp;
    char shape;

    /* 限定符：r=const n=in N=inout o=out O=bycopy R=byref V=oneway */
    while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' ||
           *p == 'O' || *p == 'R' || *p == 'V') p++;

    if (!*p) { *pp = p; return '?'; }

    switch (*p) {
    case '{': case '(': case '[':
        shape = *p;
        p = skip_aggregate(p);
        break;

    case '^':
        while (*p == '^') p++;
        if (*p == '{' || *p == '(' || *p == '[') p = skip_aggregate(p);
        else if (*p) p++;                    /* ^i / ^v / ^@ ... */
        shape = '^';
        break;

    case '@':
        p++;
        if (*p == '?') { p++; shape = '?'; }          /* block */
        else if (*p == '"') {                          /* @"ClassName" */
            p++;
            while (*p && *p != '"') p++;
            if (*p == '"') p++;
            shape = '@';
        } else {
            shape = '@';
        }
        break;

    case 'b':                                          /* bitfield b1..bN */
        p++;
        while (*p == '0' || *p == '1') p++;
        shape = 'b';
        break;

    default:
        shape = *p;
        p++;
        break;
    }

    *pp = p;
    return shape;
}

int bsp_enc_shapes(const char *enc, char *out, size_t cap)
{
    const char *p = enc;
    int idx = 0;
    size_t n = 0;

    if (!enc || cap == 0) return -1;

    while (*p) {
        const char *before = p;
        char shape = consume_type(&p);

        /* 跳过「大小 / 偏移」数字 —— 它们不是类型 */
        while (*p >= '0' && *p <= '9') p++;

        if (p == before) break;            /* 防御：没有前进就退出，避免死循环 */

        /* 索引 0 = 返回值，1 = self，2 = _cmd，之后才是真正的参数 */
        if (idx >= 3) {
            if (n + 1 >= cap) return -1;
            out[n++] = shape;
        }
        idx++;
    }

    out[n] = '\0';
    return (int)n;
}

char bsp_enc_return_type(const char *enc)
{
    const char *p = enc;
    if (!enc) return '?';
    return consume_type(&p);
}

int bsp_enc_arg_count(const char *enc)
{
    const char *p = enc;
    int idx = 0;
    if (!enc) return -1;
    while (*p) {
        const char *before = p;
        (void)consume_type(&p);
        while (*p >= '0' && *p <= '9') p++;
        if (p == before) break;
        idx++;
    }
    /* idx 含返回值，参数数（含 self/_cmd）= idx - 1 */
    return idx > 0 ? idx - 1 : 0;
}
