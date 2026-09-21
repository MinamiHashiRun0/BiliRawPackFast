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

/* 让宿主把 hook 器的诊断信息接进自己的日志文件。
 * 必需：NSLog 在侧载 App 里不会进 Documents 下的日志，上一版所有 hook 拒绝
 * 安装的原因都因此丢失，真机日志里只剩一片 ✗。 */
void BSPDynamicHookSetLogSink(void (^sink)(NSString *msg));

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

/* ------------------------------------------------------------------ */
/* 直连 hook：不走转发，直接把实现换成调用方写的 C 函数                  */
/* ------------------------------------------------------------------ */
/*
 * 为什么不一律用转发：
 *   转发路径要在类上添加 forwardInvocation: 并把实现换成 _objc_msgForward，
 *   再靠 NSInvocation 重建调用。这在**普通 NSObject 子类**上是成熟做法
 *   （Aspects 就是这个套路），但在**系统 class cluster / CoreFoundation 支撑
 *   的对象**上有额外风险：具体类（如 __NSCFURLSessionTask）可能自带
 *   forwardInvocation: 或 methodSignatureForSelector:，把我们的转发器遮住，
 *   转发链拿不到签名 —— 结果是消息无人认领，抛异常直接崩。
 *   真机日志已经证实了这一点：挂完 NSURLSessionTask::resume 之后，
 *   第一次网络请求（第一个 task resume）进程就死了。
 *
 * 适用条件（务必遵守）：
 *   shapes 必须与真机 encoding 解析结果**完全一致**，且调用方写的 C 函数
 *   签名要与之一一对应。只要形状对上了，签名就不可能错 —— 这正是之前
 *   缺失的那道闸。参数形状复杂（结构体、变参）时不要用这条路径。
 *
 * 相比转发的收益：零 NSInvocation 开销，且完全绕开 _objc_msgForward /
 * forwardInvocation:，系统类上稳得多。代价是只能观察、不能在调用前改参数
 * （要在调用前改参数仍然用转发版）。
 */
+ (BOOL)hookClass:(NSString *)className
         selector:(NSString *)selectorName
     expectShapes:(nullable NSString *)shapes
        directImp:(IMP)imp
         storeOld:(IMP _Nullable * _Nullable)outOld;

/* 已安装的直连 hook 列表（"Class::sel  [enc] -> 直连"） */
+ (NSArray<NSString *> *)installedDirectHooks;

/* 只读一次真实 type encoding（不做任何修改），用于离线核对 */
+ (nullable NSString *)typeEncodingOfClass:(NSString *)className selector:(NSString *)selectorName;

/* 把 inv 的参数渲染成一行人类可读文本（对象给内容，标量给数值） */
+ (NSString *)describeInvocation:(NSInvocation *)inv maxObjectLength:(NSUInteger)maxLen;

/* 已安装的 hook 列表（"Class::sel  enc"） */
+ (NSArray<NSString *> *)installedHooks;
+ (NSUInteger)callCountForClass:(NSString *)className selector:(NSString *)selectorName;

@end

NS_ASSUME_NONNULL_END
