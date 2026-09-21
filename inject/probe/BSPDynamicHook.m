/* BSPDynamicHook.m */
#import "BSPDynamicHook.h"
#import "bsp_enctypes.h"

#import <dlfcn.h>
#import <pthread.h>
#import <string.h>

/* _objc_msgForward 用 dlsym 在运行时取，不做链接期依赖。
 * 为什么：如果这个符号在目标系统上不存在/不导出，链接期引用会让 **dyld 在加载
 * dylib 的瞬间就杀掉进程** —— 症状是「App 打不开」，而且连构造函数的第一行
 * （创建日志目录）都跑不到，真机上只剩「什么都没有」，完全无法诊断。
 * 改成 dlsym 之后，取不到就拒绝安装所有 hook 并大声记日志，dylib 本身照样加载。 */
static IMP bsp_msg_forward(void)
{
    static IMP imp = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h;
        h = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY);
        if (h) imp = (IMP)dlsym(h, "_objc_msgForward");
        if (!imp) imp = (IMP)dlsym(RTLD_DEFAULT, "_objc_msgForward");
        if (!imp) imp = (IMP)dlsym(RTLD_DEFAULT, "objc_msgForward");
    });
    return imp;
}

/* 日志出口。默认 NSLog，但 NSLog 在侧载 App 里**不会**进我们的 trace.log ——
 * 上一版所有 hook 拒绝安装的原因都走了 NSLog，于是真机日志里只剩一片 ✗，
 * 完全看不出为什么。现在由探针注入一个写文件的 block。 */
static void (^gLogBlock)(NSString *msg) = nil;

void BSPDynamicHookSetLogSink(void (^sink)(NSString *msg))
{
    gLogBlock = [sink copy];
}

static void BSPHookLog(NSString *fmt, ...)
{
    va_list ap;
    NSString *msg;
    va_start(ap, fmt);
    msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (gLogBlock) gLogBlock(msg);
    else NSLog(@"[BSPDynamicHook] %@", msg);
}

/* 转发入口一律走 bsp_msg_forward()（dlsym 运行时取），不要在这里声明外部符号 ——
 * 声明了就会产生链接期依赖，符号缺失时 dyld 会在加载 dylib 的瞬间杀掉进程，
 * 连日志目录都建不出来。 */

/* NSInvocation 的私有但稳定的入口：直接以指定 IMP 调用，不重新派发。
 * 全 iOS 版本存在；下面仍会做 respondsToSelector 兜底。 */
@interface NSInvocation (BSPPrivate)
- (void)invokeUsingIMP:(IMP)imp;
@end

#pragma mark - 注册表

@interface BSPHookEntry : NSObject
@property (nonatomic, assign) Class cls;
@property (nonatomic, assign) SEL sel;
@property (nonatomic, assign) IMP original;
@property (nonatomic, copy)   NSString *types;
@property (nonatomic, copy)   BSPHookHandler handler;
@property (nonatomic, copy)   BSPHookAfter   after;
@property (nonatomic, assign) NSUInteger calls;
@property (nonatomic, copy)   NSString *key;
@end

@implementation BSPHookEntry
@end

static NSMutableDictionary<NSString *, BSPHookEntry *> *gEntries = nil;   /* key = "Cls|sel" */
static NSMutableArray<NSString *> *gOrder = nil;
static NSLock *gLock = nil;
static pthread_key_t gDepthKey;

/* 类自带的 forwardInvocation: IMP（若有），用于未命中时链式回退 */
static NSMutableDictionary<NSString *, NSValue *> *gInheritedForward = nil;

static void bsp_init(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gEntries  = [NSMutableDictionary dictionary];
        gOrder    = [NSMutableArray array];
        gLock     = [[NSLock alloc] init];
        gInheritedForward = [NSMutableDictionary dictionary];
        pthread_key_create(&gDepthKey, NULL);
    });
}

static inline NSString *bsp_key(Class cls, SEL sel)
{
    return [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
}

/* 沿继承链找注册项 */
static BSPHookEntry *bsp_lookup(id target, SEL sel)
{
    Class c = object_getClass(target);
    BSPHookEntry *e = nil;
    if (!c) return nil;
    [gLock lock];
    while (c) {
        e = gEntries[bsp_key(c, sel)];
        if (e) break;
        c = class_getSuperclass(c);
    }
    [gLock unlock];
    return e;
}

#pragma mark - type encoding 解析

/* 解析逻辑已抽到 bsp_enctypes.c 并配了单测（真机 encoding 夹具 55 条）。
 * 之所以必须抽出来测：上一版这段内联代码从没被执行验证过，它有 bug，
 * 导致**所有**带 expectShapes 的 hook 全部拒绝安装、整个包空转。 */

/* 取「限定符之后」的真实类型字符（用于参数渲染，输入来自 NSMethodSignature，
 * 不含大小/偏移数字） */
static char bsp_first_type_char(const char *enc)
{
    const char *p = enc ? enc : "";
    while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' ||
           *p == 'R' || *p == 'V') p++;
    return *p ? *p : '?';
}

#pragma mark - forwardInvocation 实现

static void bsp_forward(id self, SEL _cmd, NSInvocation *inv)
{
    BSPHookEntry *e = bsp_lookup(self, inv.selector);

    if (!e) {
        /* 没注册：回退到类原本的 forwardInvocation:（通常是 NSObject 的崩溃实现） */
        NSString *k = [NSString stringWithFormat:@"%s", class_getName(object_getClass(self))];
        NSValue *v;
        [gLock lock];
        v = gInheritedForward[k];
        [gLock unlock];
        if (v) {
            IMP imp = (IMP)[v pointerValue];
            if (imp) { ((void (*)(id, SEL, NSInvocation *))imp)(self, _cmd, inv); return; }
        }
        [self doesNotRecognizeSelector:inv.selector];
        return;
    }

    /* 重入保护：handler 内部如果又触发同一 selector，直接走原实现 */
    e.calls++;

    int depth = (int)(intptr_t)pthread_getspecific(gDepthKey);
    if (depth > 0) {
        [inv invokeUsingIMP:e.original];
        return;
    }
    pthread_setspecific(gDepthKey, (void *)(intptr_t)(depth + 1));

    BOOL skip = NO;
    @try {
        if (e.handler) e.handler(inv, &skip);
    } @catch (NSException *ex) {
        BSPHookLog(@"handler 异常 %s::%s -> %@",
                   class_getName(e.cls), sel_getName(e.sel), ex);
    }

    if (!skip) {
        IMP fwd = bsp_msg_forward();
        if (e.original == fwd) {
            /* 绝不该发生：原实现就是转发入口，再调一次就是无限递归 -> 爆栈。
             * 出现说明安装期没拦住（见 hookClass 里的同一道检查）。 */
            BSPHookLog(@"!! %s::%s 的 original 竟是转发入口，拒绝调用以免递归",
                       class_getName(e.cls), sel_getName(e.sel));
            [self doesNotRecognizeSelector:inv.selector];
            pthread_setspecific(gDepthKey, (void *)(intptr_t)depth);
            return;
        }
        if ([inv respondsToSelector:@selector(invokeUsingIMP:)]) {
            [inv invokeUsingIMP:e.original];
        } else {
            /* 兜底：临时把原 IMP 装回目标类，invokeWithTarget，再换回转发器。
             * 必须用 class_replaceMethod（而不是 method_setImplementation）：
             * class_getInstanceMethod 可能返回父类的方法，直接改会污染父类。 */
            const char *t = e.types.UTF8String;
            class_replaceMethod(e.cls, e.sel, e.original, t);
            @try { [inv invokeWithTarget:self]; }
            @finally { class_replaceMethod(e.cls, e.sel, fwd, t); }
        }
        if (e.after) {
            @try { e.after(inv); }
            @catch (NSException *ex) {
                BSPHookLog(@"after 异常 %s::%s -> %@",
                           class_getName(e.cls), sel_getName(e.sel), ex);
            }
        }
    }

    pthread_setspecific(gDepthKey, (void *)(intptr_t)depth);
}

#pragma mark - 参数渲染

static void bsp_append_obj(NSMutableString *s, id obj, NSUInteger maxLen)
{
    if (!obj) { [s appendString:@"nil"]; return; }
    if (obj == (id)[NSNull null]) { [s appendString:@"NSNull"]; return; }

    if ([obj isKindOfClass:[NSString class]]) {
        NSString *t = (NSString *)obj;
        [s appendFormat:@"\"%@\"", t.length > maxLen ? [t substringToIndex:maxLen] : t];
        if (t.length > maxLen) [s appendFormat:@"…(%lu字)", (unsigned long)t.length];
        return;
    }
    if ([obj isKindOfClass:[NSURL class]]) {
        NSString *t = [(NSURL *)obj absoluteString];
        [s appendFormat:@"URL(%@)", t.length > maxLen ? [t substringToIndex:maxLen] : t];
        if (t.length > maxLen) [s appendFormat:@"…(%lu字)", (unsigned long)t.length];
        return;
    }
    if ([obj isKindOfClass:[NSData class]]) {
        NSData *d = obj;
        [s appendFormat:@"NSData(%luB)", (unsigned long)d.length];
        return;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *a = obj;
        [s appendFormat:@"%@(%lu)[", NSStringFromClass([obj class]), (unsigned long)a.count];
        for (NSUInteger i = 0; i < a.count && i < 4; i++) {
            if (i) [s appendString:@", "];
            bsp_append_obj(s, a[i], 160);
        }
        if (a.count > 4) [s appendString:@", …"];
        [s appendString:@"]"];
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = obj;
        [s appendFormat:@"%@(%lu){", NSStringFromClass([obj class]), (unsigned long)d.count];
        NSUInteger i = 0;
        for (id k in d) {
            if (i >= 4) { [s appendString:@", …"]; break; }
            if (i) [s appendString:@", "];
            bsp_append_obj(s, k, 60);
            [s appendString:@"="];
            bsp_append_obj(s, d[k], 120);
            i++;
        }
        [s appendString:@"}"];
        return;
    }
    if ([obj isKindOfClass:[NSSet class]]) {
        [s appendFormat:@"%@(%lu)", NSStringFromClass([obj class]), (unsigned long)[obj count]];
        return;
    }
    [s appendFormat:@"<%@ %p>", NSStringFromClass([obj class]), obj];
}

@implementation BSPDynamicHook

+ (NSString *)typeEncodingOfClass:(NSString *)className selector:(NSString *)selectorName
{
    Class cls = NSClassFromString(className);
    Method m;
    if (!cls || !selectorName) return nil;
    m = class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
    if (!m) return nil;
    {
        const char *t = method_getTypeEncoding(m);
        return t ? @(t) : nil;
    }
}

+ (BOOL)hookClass:(NSString *)className selector:(NSString *)selectorName handler:(BSPHookHandler)handler
{
    return [self hookClass:className selector:selectorName expectShapes:nil
                    before:handler after:nil];
}

+ (BOOL)hookClass:(NSString *)className
         selector:(NSString *)selectorName
     expectShapes:(NSString *)shapes
          handler:(BSPHookHandler)handler
{
    return [self hookClass:className selector:selectorName expectShapes:shapes
                    before:handler after:nil];
}

+ (BOOL)hookClass:(NSString *)className
         selector:(NSString *)selectorName
     expectShapes:(NSString *)shapes
           before:(BSPHookHandler)before
            after:(BSPHookAfter)after
{
    bsp_init();

    Class cls = NSClassFromString(className);
    SEL   sel = NSSelectorFromString(selectorName);
    Method m;
    const char *enc;
    char actual[96];
    NSString *key;

    if (!cls) {
        BSPHookLog(@"· 类 %@ 不在运行时", className);
        return NO;
    }
    if (!selectorName) return NO;

    m = class_getInstanceMethod(cls, sel);
    if (!m) {
        BSPHookLog(@"✗ %@ 上找不到方法 %@（类存在，但没实现这个方法）", className, selectorName);
        return NO;
    }

    enc = method_getTypeEncoding(m);
    if (!enc) {
        BSPHookLog(@"✗ %@::%@ 拿不到 type encoding", className, selectorName);
        return NO;
    }

    /* ★ 继承链陷阱（这一条是真会爆栈的）：
     * class_getInstanceMethod 会沿继承链找。如果一个祖先类上已经挂过同一个
     * 选择子，那么这里拿到的「原实现」其实是 _objc_msgForward。把它当成原实现
     * 存下来，将来 invokeUsingIMP: 会重新进入转发 -> 无限递归 -> 爆栈闪退。
     * 例：IJKFFMoviePlayerController 与 FFPlay / AVPlayer 三个类名字高度重合，
     * 若它们是父子关系，先挂父类再挂子类就会踩中。
     * 正确做法是拒绝安装子类的那一份 —— 祖先类的 hook 本来就会覆盖子类实例。 */
    {
        IMP orig = method_getImplementation(m);
        IMP fwd  = bsp_msg_forward();
        if (!fwd) {
            BSPHookLog(@"✗ 运行时拿不到 _objc_msgForward，无法安装任何 hook"
                       @"（dylib 本身仍正常加载；请把这条日志发回）");
            return NO;
        }
        if (orig == fwd) {
            BSPHookLog(@"· %@::%@ 在继承链上已被祖先类挂过，跳过（祖先的 hook 已覆盖本类实例）",
                       className, selectorName);
            return NO;
        }
    }

    if (shapes) {
        int n = bsp_enc_shapes(enc, actual, sizeof(actual));
        if (n < 0) {
            BSPHookLog(@"✗ %@::%@ enc=%@ 解析失败（encoding 畸形或缓冲不够），拒绝安装",
                       className, selectorName, @(enc));
            return NO;
        }
        if (![shapes isEqualToString:@(actual)]) {
            /* 这一行就是上一版缺失的那一行 —— 没有它，真机日志只剩 ✗，
             * 完全看不出是「方法不存在」还是「形状不符」。 */
            BSPHookLog(@"✗ %@::%@ 参数形状不符，拒绝安装\n"
                       @"        enc=%@  实际形状=\"%@\"  期望=\"%@\"",
                       className, selectorName, @(enc), @(actual), shapes);
            return NO;
        }
    }

    [gLock lock];

    key = bsp_key(cls, sel);
    if (gEntries[key]) { [gLock unlock]; return YES; }   /* 已装 */

    /* 类自己实现了 forwardInvocation: -> 拒绝，避免踩掉它的转发逻辑 */
    {
        unsigned int cnt = 0;
        Method *list = class_copyMethodList(cls, &cnt);
        BOOL owns = NO;
        for (unsigned int i = 0; i < cnt; i++) {
            if (method_getName(list[i]) == @selector(forwardInvocation:)) { owns = YES; break; }
        }
        free(list);
        if (owns) {
            [gLock unlock];
            BSPHookLog(@"✗ %@ 自带 forwardInvocation:（会与转发器打架），拒绝 hook %@", className, selectorName);
            return NO;
        }
    }

    /* 记录继承来的 forwardInvocation:（一般是 NSObject 的） */
    {
        Method fw = class_getInstanceMethod(cls, @selector(forwardInvocation:));
        if (fw) {
            NSString *ck = [NSString stringWithFormat:@"%s", class_getName(cls)];
            if (!gInheritedForward[ck])
                gInheritedForward[ck] = [NSValue valueWithPointer:(const void *)method_getImplementation(fw)];
        }
    }

    if (!class_addMethod(cls, @selector(forwardInvocation:), (IMP)bsp_forward, "v@:@")) {
        [gLock unlock];
        BSPHookLog(@"✗ %@ 无法添加 forwardInvocation:，拒绝 hook %@", className, selectorName);
        return NO;
    }

    {
        BSPHookEntry *e = [[BSPHookEntry alloc] init];
        e.cls      = cls;
        e.sel      = sel;
        e.original = method_getImplementation(m);
        e.types    = @(enc);
        e.handler  = before;
        e.after    = after;
        e.key      = key;

        /* 必须用 class_replaceMethod：m 可能是父类的方法，
         * method_setImplementation 会改到父类上去，波及所有子类。 */
        class_replaceMethod(cls, sel, bsp_msg_forward(), enc);
        gEntries[key] = e;
        [gOrder addObject:[NSString stringWithFormat:@"%@::%@  [%@]", className, selectorName, @(enc)]];
    }

    [gLock unlock];
    return YES;
}

+ (NSArray<NSString *> *)installedHooks
{
    NSArray *r;
    bsp_init();
    [gLock lock];
    r = gOrder.copy;
    [gLock unlock];
    return r;
}

+ (NSUInteger)callCountForClass:(NSString *)className selector:(NSString *)selectorName
{
    Class cls = NSClassFromString(className);
    BSPHookEntry *e;
    NSUInteger n = 0;
    if (!cls) return 0;
    bsp_init();
    [gLock lock];
    e = gEntries[bsp_key(cls, NSSelectorFromString(selectorName))];
    if (e) n = e.calls;
    [gLock unlock];
    return n;
}

+ (NSString *)describeInvocation:(NSInvocation *)inv maxObjectLength:(NSUInteger)maxLen
{
    NSMutableString *s = [NSMutableString string];
    NSMethodSignature *sig = inv.methodSignature;
    NSUInteger n = sig.numberOfArguments;

    [s appendString:NSStringFromSelector(inv.selector)];
    [s appendString:@"("];

    for (NSUInteger i = 2; i < n; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i];
        char c = bsp_first_type_char(t);
        if (i > 2) [s appendString:@", "];

        if (c == '@') {
            __unsafe_unretained id obj = nil;
            @try { [inv getArgument:&obj atIndex:i]; } @catch (__unused NSException *ex) { obj = nil; }
            bsp_append_obj(s, obj, maxLen);
        } else if (c == ':' || c == '#') {
            if (c == '#') {
                __unsafe_unretained id obj = nil;
                @try { [inv getArgument:&obj atIndex:i]; } @catch (__unused NSException *ex) { obj = nil; }
                [s appendFormat:@"class(%@)", obj ? NSStringFromClass((Class)obj) : @"nil"];
            } else {
                SEL sel = NULL;
                @try { [inv getArgument:&sel atIndex:i]; } @catch (__unused NSException *ex) { sel = NULL; }
                [s appendFormat:@"sel(%@)", sel ? NSStringFromSelector(sel) : @"nil"];
            }
        } else if (c == '^' || c == '*') {
            void *p = NULL;
            @try { [inv getArgument:&p atIndex:i]; } @catch (__unused NSException *ex) { p = NULL; }
            [s appendFormat:@"ptr(%p)", p];
        } else if (c == 'c' || c == 'B') {
            signed char v = 0;
            @try { [inv getArgument:&v atIndex:i]; } @catch (__unused NSException *ex) {}
            [s appendFormat:@"%s", v ? "YES" : "NO"];
        } else if (c == 'i' || c == 's' || c == 'l') {
            int32_t v = 0;
            @try { [inv getArgument:&v atIndex:i]; } @catch (__unused NSException *ex) {}
            [s appendFormat:@"%d", v];
        } else if (c == 'q' || c == 'I' || c == 'S' || c == 'L' || c == 'Q') {
            int64_t v = 0;
            @try { [inv getArgument:&v atIndex:i]; } @catch (__unused NSException *ex) {}
            [s appendFormat:@"%lld", (long long)v];
        } else if (c == 'f') {
            float v = 0;
            @try { [inv getArgument:&v atIndex:i]; } @catch (__unused NSException *ex) {}
            [s appendFormat:@"%g", (double)v];
        } else if (c == 'd') {
            double v = 0;
            @try { [inv getArgument:&v atIndex:i]; } @catch (__unused NSException *ex) {}
            [s appendFormat:@"%g", v];
        } else if (c == '{' || c == '(' || c == '[') {
            [s appendString:@"(结构体)"];
        } else {
            [s appendFormat:@"<%c>", c];
        }
    }
    [s appendString:@")"];
    return s;
}

@end
