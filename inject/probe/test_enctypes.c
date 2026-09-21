/* test_enctypes.c — bsp_enctypes 的单测
 *
 * 夹具 bsp_enctypes_fixtures.inc 由 _recon/gen_enc_fixtures.py 从**真机
 * classes.txt** 逐字节抽出，不手写，避免抄错。
 *
 * 编译：cc -std=c11 -Wall -Wextra -Werror -o t bsp_enctypes.c test_enctypes.c
 */
#include "bsp_enctypes.h"

#include <stdio.h>
#include <string.h>

static int gFail = 0, gPass = 0;

#define CHECK(cond, ...)                                                        \
    do {                                                                        \
        if (cond) { gPass++; }                                                  \
        else {                                                                  \
            gFail++;                                                            \
            printf("  FAIL %s:%d  ", __FILE__, __LINE__);                       \
            printf(__VA_ARGS__);                                                \
            printf("\n");                                                       \
        }                                                                       \
    } while (0)

typedef struct { const char *cls; const char *sel; const char *enc; const char *want; } Fixture;

static const Fixture kFixtures[] = {
#include "bsp_enctypes_fixtures.inc"
};

/* ------------------------------------------------------------------ */
/* 1. 真机夹具：每一条都必须解析出期望形状                              */
/* ------------------------------------------------------------------ */
static void t_device_fixtures(void)
{
    size_t n = sizeof(kFixtures) / sizeof(kFixtures[0]);
    printf("[1] 真机 encoding 夹具 %lu 条\n", (unsigned long)n);

    for (size_t i = 0; i < n; i++) {
        char shapes[64];
        int got = bsp_enc_shapes(kFixtures[i].enc, shapes, sizeof(shapes));
        if (got < 0) {
            CHECK(0, "%s::%s  enc=%s  解析失败", kFixtures[i].cls, kFixtures[i].sel, kFixtures[i].enc);
            continue;
        }
        if (strcmp(shapes, kFixtures[i].want) != 0) {
            CHECK(0, "%s::%s  enc=%s  形状=%s 期望=%s",
                  kFixtures[i].cls, kFixtures[i].sel, kFixtures[i].enc,
                  shapes, kFixtures[i].want);
        } else {
            gPass++;
        }
    }
}

/* ------------------------------------------------------------------ */
/* 2. 回归固件：上一版正是栽在这里                                       */
/* ------------------------------------------------------------------ */
static void t_regression_numbers(void)
{
    char s[64];

    printf("[2] 回归：数字是大小/偏移，不是类型\n");

    /* 上一版没跳数字、还把返回值当成 self，v24@0:8@16 被解析成 "60:8@"
     * 之类，于是所有 expectShapes 校验全部失败 -> 所有 hook 拒绝安装。 */
    CHECK(bsp_enc_shapes("v24@0:8@16", s, sizeof(s)) == 1, "零参+1 参数个数不对");
    CHECK(strcmp(s, "@") == 0, "v24@0:8@16 -> %s 期望 @", s);

    CHECK(strcmp((bsp_enc_shapes("v16@0:8", s, sizeof(s)), s), "") == 0,
          "v16@0:8 -> %s 期望空", s);
    CHECK(bsp_enc_shapes("v16@0:8", s, sizeof(s)) == 0, "零参方法参数个数应为 0");

    CHECK(strcmp((bsp_enc_shapes("B28@0:8@16B24", s, sizeof(s)), s), "@B") == 0,
          "B28@0:8@16B24 -> %s 期望 @B", s);
    CHECK(strcmp((bsp_enc_shapes("@32@0:8@16@24", s, sizeof(s)), s), "@@") == 0,
          "@32@0:8@16@24 -> %s 期望 @@", s);
    CHECK(strcmp((bsp_enc_shapes("@40@0:8@16@24@32", s, sizeof(s)), s), "@@@") == 0,
          "三参 -> %s 期望 @@@", s);
    CHECK(strcmp((bsp_enc_shapes("@48@0:8i16i20@24q32i40i44", s, sizeof(s)), s), "ii@qii") == 0,
          "六参混合 -> %s 期望 ii@qii", s);
    CHECK(strcmp((bsp_enc_shapes("@64@0:8q16q24q32q40@48@56", s, sizeof(s)), s), "qqqq@@") == 0,
          "四 q 两 @ -> %s 期望 qqqq@@", s);
    CHECK(strcmp((bsp_enc_shapes("v20@0:8B16", s, sizeof(s)), s), "B") == 0,
          "v20@0:8B16 -> %s 期望 B", s);
    CHECK(strcmp((bsp_enc_shapes("@32@0:8@16q24", s, sizeof(s)), s), "@q") == 0,
          "@32@0:8@16q24 -> %s 期望 @q", s);

    /* 大偏移（多位数）也要能跳干净 */
    CHECK(strcmp((bsp_enc_shapes("v100@0:8@16@24@32@40@48@56@64@72@80@88@96", s, sizeof(s)), s),
                 "@@@@@@@@@@@") == 0,
          "十二参 -> %s", s);

    /* 返回值本身是对象，不能被当成参数 */
    CHECK(bsp_enc_shapes("@16@0:8", s, sizeof(s)) == 0, "@16@0:8 应无参数");
}

/* ------------------------------------------------------------------ */
/* 3. 复杂类型：指针 / 结构体 / block / 限定符                          */
/* ------------------------------------------------------------------ */
static void t_complex(void)
{
    char s[64];

    printf("[3] 复杂类型\n");

    CHECK(strcmp((bsp_enc_shapes("v24@0:8^{IjkMediaPlayer=}16", s, sizeof(s)), s), "^") == 0,
          "结构体指针 -> %s 期望 ^", s);

    CHECK(strcmp((bsp_enc_shapes("@32@0:8@16@?24", s, sizeof(s)), s), "@?") == 0,
          "block 参数 -> %s 期望 @?", s);

    CHECK(strcmp((bsp_enc_shapes("v32@0:8@16^{DashDataSource=iiiiii[20{ijk=iii}]iii}24", s, sizeof(s)), s),
                 "@^") == 0, "聚合体指针 -> %s 期望 @^", s);

    CHECK(strcmp((bsp_enc_shapes("v48@0:8@16@24@32^v40", s, sizeof(s)), s), "@@@^") == 0,
          "void* -> %s 期望 @@@^", s);

    CHECK(strcmp((bsp_enc_shapes("@24@0:8r*16", s, sizeof(s)), s), "*") == 0,
          "const char* -> %s 期望 *", s);

    CHECK(strcmp((bsp_enc_shapes("@24@0:8@\"NSString\"16", s, sizeof(s)), s), "@") == 0,
          "带类名的对象 -> %s 期望 @", s);

    CHECK(strcmp((bsp_enc_shapes("v20@0:8n@16", s, sizeof(s)), s), "@") == 0,
          "in 限定符 -> %s 期望 @", s);

    CHECK(strcmp((bsp_enc_shapes("v24@0:8O@16", s, sizeof(s)), s), "@") == 0,
          "bycopy 限定符 -> %s 期望 @", s);

    CHECK(strcmp((bsp_enc_shapes("v24@0:8#16", s, sizeof(s)), s), "#") == 0,
          "Class -> %s 期望 #", s);

    CHECK(strcmp((bsp_enc_shapes("v24@0:8:16", s, sizeof(s)), s), ":") == 0,
          "SEL -> %s 期望 :", s);

    /* 返回体是结构体：结构体编码在最前面，不能被当成参数 */
    CHECK(strcmp((bsp_enc_shapes("{DashStreamInfo=ii[20i][20i]ii}16@0:8i16", s, sizeof(s)), s),
                 "i") == 0,
          "结构体返回值 -> %s 期望 i", s);
}

/* ------------------------------------------------------------------ */
/* 4. 返回值 / 参数个数                                                 */
/* ------------------------------------------------------------------ */
static void t_return_and_count(void)
{
    printf("[4] 返回值与参数个数\n");

    CHECK(bsp_enc_return_type("v24@0:8@16") == 'v', "void 返回");
    CHECK(bsp_enc_return_type("@24@0:8@16") == '@', "对象返回");
    CHECK(bsp_enc_return_type("B28@0:8@16B24") == 'B', "BOOL 返回");
    CHECK(bsp_enc_return_type("q16@0:8") == 'q', "long long 返回");
    CHECK(bsp_enc_return_type("d16@0:8") == 'd', "double 返回");
    CHECK(bsp_enc_return_type("f16@0:8") == 'f', "float 返回");
    CHECK(bsp_enc_return_type("{DashStreamInfo=ii[20i][20i]ii}16@0:8") == '{', "结构体返回");
    CHECK(bsp_enc_return_type(NULL) == '?', "NULL 安全");

    CHECK(bsp_enc_arg_count("v24@0:8@16") == 3, "含 self/_cmd 共 3");
    CHECK(bsp_enc_arg_count("@24@0:8@16") == 3, "含 self/_cmd 共 3");
    CHECK(bsp_enc_arg_count("B28@0:8@16B24") == 4, "含 self/_cmd 共 4");
    CHECK(bsp_enc_arg_count("v16@0:8") == 2, "含 self/_cmd 共 2");
    CHECK(bsp_enc_arg_count("@48@0:8i16i20@24q32i40i44") == 8, "六参方法含 self/_cmd 共 8");
    CHECK(bsp_enc_arg_count("{DashStreamInfo=ii[20i][20i]ii}16@0:8") == 2,
          "结构体返回值不应算成参数");
    CHECK(bsp_enc_arg_count(NULL) == -1, "NULL 返回 -1");
}

/* ------------------------------------------------------------------ */
/* 5. 边界与健壮性                                                      */
/* ------------------------------------------------------------------ */
static void t_robustness(void)
{
    char s[64];
    char tiny[1];

    printf("[5] 边界\n");

    CHECK(bsp_enc_shapes(NULL, s, sizeof(s)) == -1, "NULL enc");
    CHECK(bsp_enc_shapes("v16@0:8", NULL, 0) == -1, "NULL out");
    CHECK(bsp_enc_shapes("v24@0:8@16", tiny, sizeof(tiny)) == -1, "缓冲放不下应返回 -1");

    /* 畸形 encoding 不能死循环 */
    CHECK(bsp_enc_shapes("", s, sizeof(s)) == 0, "空串 -> 0 个参数");
    CHECK(bsp_enc_shapes("@@@@", s, sizeof(s)) >= 0, "全是类型字符不应崩");
    CHECK(bsp_enc_shapes("{{{{", s, sizeof(s)) >= 0, "未闭合结构体不应死循环");
    CHECK(bsp_enc_shapes("^^^^", s, sizeof(s)) >= 0, "连续指针不应死循环");
    CHECK(bsp_enc_shapes("12345", s, sizeof(s)) >= 0, "纯数字不应死循环");
    CHECK(bsp_enc_shapes("v99999999999999999999@0:8", s, sizeof(s)) >= 0, "超长数字不应死循环");
}

int main(void)
{
    printf("=== bsp_enctypes 单测 ===\n");
    t_device_fixtures();
    t_regression_numbers();
    t_complex();
    t_return_and_count();
    t_robustness();
    printf("=== 通过 %d，失败 %d ===\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
}
