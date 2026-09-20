/* BSPDynamicHook.m */
#import "BSPDynamicHook.h"

#import <pthread.h>
#import <string.h>

/* _objc_msgForward：arm64/x86_64 上同名，声明为 C 函数再转 IMP */
extern void _objc_msgForward(void);

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
static pthread_once_t gOnce = PTHREAD_ONCE_INIT;

/* 类自带的 forwardInvocation: IMP（若有），用于未命中时链式回退 */
static NSMutableDictionary<NSString *, NSValue *> *gInheritedForward = nil;

static void bsp_depth_key_init(void) { pthread_key_create(&gDepthKey, NULL); }

static void bsp_init(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gEntries  = [NSMutableDictionary dictionary];
        gOrder    = [NSMutableArray array];
        gLock     = [[NSLock alloc] init];
        gInheritedForward = [NSMutableDictionary dictionary];
        pthread_once(&gDepthKey, bsp_depth_key_init);
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

/* 返回参数（不含 self/_cmd）的类型首字符数组。
 * 同时把每个参数在 encoding 里的起始偏移写入 offs（可为 NULL）。 */
static NSInteger bsp_arg_shapes(const char *enc, char *shapes, NSUInteger shapesCap)
{
    NSUInteger n = 0;
    const char *p = enc;
    int argIndex = 0;

    if (!p) return -1;
    if (shapesCap == 0) return -1;

    while (*p) {
        const char *typeStart;
        /* 跳过限定符，typeStart 指向「真正的类型字符」 */
        while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' ||
               *p == 'R' || *p == 'V') p++;
        if (!*p) break;
        typeStart = p;

        switch (*p) {
        case '{': case '(': case '[': {
            char open = *p;
            char close = (open == '{') ? '}' : (open == '(' ? ')' : ']');
            int depth = 0;
            while (*p) {
                if (*p == open) depth++;
                else if (*p == close) { depth--; if (depth == 0) { p++; break; } }
                p++;
            }
            break;
        }
        case '^':
            while (*p == '^') p++;
            if (*p == '{' || *p == '(' || *p == '[') {
                char open = *p;
                char close = (open == '{') ? '}' : (open == '(' ? ')' : ']');
                int depth = 0;
                while (*p) {
                    if (*p == open) depth++;
                    else if (*p == close) { depth--; if (depth == 0) { p++; break; } }
                    p++;
                }
            } else if (*p) {
                p++;
            }
            break;
        case 'b':
            p++;
            while (*p == '0' || *p == '1') p++;
            break;
        default:
            p++;
            break;
        }

        if (argIndex >= 2) {              /* 0=self 1=_cmd */
            if (n + 1 >= shapesCap) return -1;
            shapes[n++] = *typeStart;
        }
        argIndex++;
    }
    shapes[n] = '\0';
    return (NSInteger)n;
}

/* 取「限定符之后」的真实类型字符 */
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
        NSLog(@"[BSPDynamicHook] handler 异常 %s::%s -> %@",
              class_getName(e.cls), sel_getName(e.sel), ex);
    }

    if (!skip) {
        if ([inv respondsToSelector:@selector(invokeUsingIMP:)]) {
            [inv invokeUsingIMP:e.original];
        } else {
            /* 兜底：临时把原 IMP 装回目标类，invokeWithTarget，再换回转发器。
             * 必须用 class_replaceMethod（而不是 method_setImplementation）：
             * class_getInstanceMethod 可能返回父类的方法，直接改会污染父类。 */
            const char *t = e.types.UTF8String;
            class_replaceMethod(e.cls, e.sel, e.original, t);
            @try { [inv invokeWithTarget:self]; }
            @finally { class_replaceMethod(e.cls, e.sel, (IMP)_objc_msgForward, t); }
        }
        if (e.after) {
            @try { e.after(inv); }
            @catch (NSException *ex) {
                NSLog(@"[BSPDynamicHook] after 异常 %s::%s -> %@",
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
    char actual[64];
    NSString *key;

    if (!cls || !selectorName) return NO;
    m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    enc = method_getTypeEncoding(m);
    if (!enc) return NO;

    if (shapes) {
        NSInteger n = bsp_arg_shapes(enc, actual, sizeof(actual));
        if (n < 0 || ![shapes isEqualToString:@(actual)]) {
            NSLog(@"[BSPDynamicHook] ✗ %@::%@ encoding=%@ 参数形状=%@ 与期望 %@ 不符，拒绝安装",
                  className, selectorName, @(enc), n < 0 ? @"(解析失败)" : @(actual), shapes);
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
            NSLog(@"[BSPDynamicHook] ✗ %@ 自带 forwardInvocation:，拒绝 hook %@", className, selectorName);
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
        NSLog(@"[BSPDynamicHook] ✗ %@ 无法添加 forwardInvocation:，拒绝 hook %@", className, selectorName);
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
        class_replaceMethod(cls, sel, (IMP)_objc_msgForward, enc);
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
            __unsafe_unretained id obj = nil;
            @try { [inv getArgument:&obj atIndex:i]; } @catch (__unused NSException *ex) { obj = nil; }
            if (c == '#') [s appendFormat:@"class(%@)", obj ? NSStringFromClass((Class)obj) : @"nil"];
            else         [s appendFormat:@"sel(%@)", obj ? NSStringFromSelector((SEL)obj) : @"nil"];
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
