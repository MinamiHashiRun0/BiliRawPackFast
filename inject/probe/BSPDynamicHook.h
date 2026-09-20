/* BSPDynamicHook.h — 基于运行时 type encoding + NSInvocation 的安全 hook
 *
 * 为什么需要它：
 *   class_replaceMethod / MSHookMessageEx 的 type encoding 只是「元数据」，
 *   写错了不会报错，只会让调用方按错误布局压栈 -> 直接崩。之前就崩过。
 *
 * 做法：
 *   1. 从运行时读真实 encoding：method_getTypeEncoding(class_getInstanceMethod(...))
 *   2. 把 IMP 换成 _objc_msgForward，让消息进入 forwardInvocation:
 *   3. 在 forwardInvocation: 里用 NSInvocation 拿到「按真实签名解析好的参数」，
 *      可以读、可以改（setArgument:atIndex:），再 invokeUsingIMP: 原始实现
 *   => 不猜签名、不改行为（除非 handler 主动改参数），任意参数个数都安全。
 *
 * 限制：
 *   - 目标类自己实现了 forwardInvocation: 时拒绝 hook（避免踩掉它的转发逻辑）
 *   - 只 hook ObjC 方法；C 函数不适用
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/* handler 在原始实现之前被调用。
 *   inv          : 已按真实签名填充好的调用
 *   skipOriginal : 置 YES 表示不再调用原实现（谨慎使用）
 */
typedef void (^BSPHookHandler)(NSInvocation *inv, BOOL *skipOriginal);

/* 在原始实现返回之后调用，可读改返回值（setReturnValue:） */
typedef void (^BSPHookAfter)(NSInvocation *inv);

@interface BSPDynamicHook : NSObject

/* 安装一个 hook。返回 YES 表示成功；NO 表示类/方法不存在或类自带 forwardInvocation: */
+ (BOOL)hookClass:(NSString *)className
         selector:(NSString *)selectorName
          handler:(BSPHookHandler)handler;

/* 便捷版：用真实 encoding 校验参数形状后再安装。
 * shapes 里每项是一个字符，对应「除 self/_cmd 外」每个参数的类型首字符，
 * 例如 willOpenUrl: 期望 @shapes = @"@"；updateUrl:resolved: 期望 @"@B"。
 * 不符则不安装并返回 NO —— 这是防「逆向结论与真机不符」的最后一道闸。 */
+ (BOOL)hookClass:(NSString *)className
         selector:(NSString *)selectorName
     expectShapes:(nullable NSString *)shapes
          handler:(BSPHookHandler)handler;

/* 也允许挂 after：原实现跑完后可改返回值（例如 callMeteredNetworkUrl: 这类
 * 「输入 URL、返回 URL」的方法，改参数没用，必须改返回值）。 */
+ (BOOL)hookClass:(NSString *)className
         selector:(NSString *)selectorName
     expectShapes:(nullable NSString *)shapes
           before:(nullable BSPHookHandler)before
            after:(nullable BSPHookAfter)after;

/* 只读一次真实 type encoding（不做任何修改），用于离线核对 */
+ (nullable NSString *)typeEncodingOfClass:(NSString *)className selector:(NSString *)selectorName;

/* 把 inv 的参数渲染成一行人类可读文本（对象给内容，标量给数值） */
+ (NSString *)describeInvocation:(NSInvocation *)inv maxObjectLength:(NSUInteger)maxLen;

/* 已安装的 hook 列表（"Class::sel  enc"） */
+ (NSArray<NSString *> *)installedHooks;
+ (NSUInteger)callCountForClass:(NSString *)className selector:(NSString *)selectorName;

@end

NS_ASSUME_NONNULL_END
