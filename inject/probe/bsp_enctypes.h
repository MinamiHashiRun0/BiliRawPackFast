/* bsp_enctypes.h — ObjC method type encoding 的形状解析（纯 C，可单测）
 *
 * 为什么单独抽出来：上一版把这段逻辑内联在 BSPDynamicHook.m 里，从没被测试过，
 * 结果它有 bug，导致**所有**带 expectShapes 校验的 hook 全部安装失败 ——
 * 整个包空转，日志却只显示一片 ✗，看不出原因。
 * 抽出来之后可以在 Linux CI 上拿真机导出的 encoding 逐条断言。
 *
 * encoding 的真实结构是「类型 + 数字」交替：
 *     v24@0:8@16
 *      ^  ^ ^ ^ ^ ^
 *      |  | | | | +-- 第 2 个参数的类型 @，它起始于字节偏移 16
 *      |  | | | +---- 第 1 个参数（_cmd）的类型 :
 *      |  | | +------ _cmd 的偏移 8
 *      |  | +-------- 第 0 个参数（self）的类型 @
 *      |  +---------- self 的偏移 0
 *      +------------- 返回值类型 v；24 是整个栈帧大小
 *
 * 所以数字**不是类型字符**，必须跳过。上一版就是没跳数字，还把第一个类型
 * （返回值）当成了 self，于是 `v24@0:8@16` 被解析成 "60:8@" 之类，
 * 与期望的 "@" 永不相等 -> 全部拒绝安装。
 */
#ifndef BSP_ENCTYPES_H
#define BSP_ENCTYPES_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 形状约定：取参数类型的**首字符**，并做两处归一化
 *   @?          -> '?'   （block，与普通对象区分开，便于校验）
 *   @"Foo"      -> '@'   （带类名的对象）
 *   ^{...}      -> '^'   （指针，后面的聚合体不再展开）
 * 其它原样返回，例如 i/q/d/B/@/#/:/* 等。
 */

/* 解析 enc，把「除 self 与 _cmd 之外」的每个参数的类型首字符写入 out。
 * 返回参数个数；解析失败（encoding 畸形或 out 太小）返回 -1。
 * out 会被写成以 '\0' 结尾的 C 字符串（最多 cap-1 个形状）。 */
int bsp_enc_shapes(const char *enc, char *out, size_t cap);

/* 只要返回值类型的首字符；解析失败返回 '?' */
char bsp_enc_return_type(const char *enc);

/* 这个 encoding 里有几个参数（含 self/_cmd）。解析失败返回 -1。 */
int bsp_enc_arg_count(const char *enc);

#ifdef __cplusplus
}
#endif
#endif /* BSP_ENCTYPES_H */
