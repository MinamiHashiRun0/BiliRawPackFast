# -*- coding: utf-8 -*-
"""把 BiliFastUI.m 的「入口」一节整体替换成覆盖窗口方案。

原方案用 presentViewController 从 B 站自己的 VC 层级弹面板 —— 真机结果是
一块黑屏且打不开。新方案把面板做成我们自己覆盖窗口里的子视图，没有
present/dismiss 状态机，也就没有那一类失败模式。
"""
import io
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'inject', 'fast', 'BiliFastUI.m')

MARK = u'#pragma mark - 入口（小球 / 三指手势 / 面板）'

TAIL = r'''
//------------------------------------------------------------------------------
#pragma mark - 覆盖窗口（小球 / 面板）
//------------------------------------------------------------------------------
// 设计要点（都是被真机故障逼出来的）：
//
// 1. **不再用 presentViewController 弹面板。**
//    上一版从「App 最顶层 VC」present，弹出来是一块黑屏且打不开。原因是
//    present 依赖 B 站自己的 VC 层级：顶层是谁、是不是正在 present 别的东西、
//    是不是全屏播放器 VC —— 这些都不归我们管，任何一环不对就是黑屏或静默
//    失败；而从不属于该窗口层级的 view 上 present 还会直接抛
//    「whose view is not in the window hierarchy」。
//    现在面板是**我们自己覆盖窗口里的一个子视图**：没有 present、没有
//    dismiss、没有 modal 状态机，也就没有这一类失败模式。
//    （旧版还有个隐藏坑：FormSheet 可以下滑关闭，而复位「已弹出」标志只写在
//     「完成」按钮里 —— 滑掉一次之后面板就再也打不开了。子视图方案连这个
//     问题一起消掉。）
//
// 2. 窗口平时只有 46x46（本就不挡别的位置，不需要 hitTest 作弊），打开面板时
//    把同一个窗口临时撑满屏幕，关闭时缩回去。反过来：**全屏透明窗口会吞掉
//    所有触摸**，所以窗口绝不能常驻全屏。
//
// 3. 三指双击挂在 App 自己的 key window 上：窗口是命中测试的根，App 里任何
//    位置的触摸都会经过它的手势识别器。key window 会随切页面/切场景变化，
//    因此监听 UIWindowDidBecomeKey 动态补挂（集合去重）。
//
// 4. 每一步都打日志、全部包 @try/@catch。这个模块最不该做的事就是把用户的
//    App 搞崩；宁可面板打不开，也要让下一次日志直接指出卡在哪一步。

static UIWindow         *gWin;
static UIViewController *gRootVC;
static UIButton         *gBall;
static UIView           *gPanelBox;      /* 非空 = 面板正开着 */
static BiliFastPanel    *gPanel;         /* 每次打开新建，不复用 */
static CGPoint           gBallCenter;
static BOOL              gBallWanted = YES;
static BOOL (^gIsEnabled)(void);
static void (^gSetEnabled)(BOOL);
static NSHashTable      *gGestureWindows;

static void FLogLine(NSString *s);
static void FOpenPanel(void);
static void FClosePanel(void);

static NSString *FBallFrameKey(void) { return @"BiliFastBallFrame"; }

static void FSaveBallCenter(CGPoint c)
{
    [[NSUserDefaults standardUserDefaults] setObject:@[@(c.x), @(c.y)] forKey:FBallFrameKey()];
}
static CGPoint FLoadBallCenter(void)
{
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:FBallFrameKey()];
    if (a.count == 2) return CGPointMake([a[0] doubleValue], [a[1] doubleValue]);
    return CGPointZero;
}

//------------------------------------------------------------------------------
#pragma mark - 回调目标
//------------------------------------------------------------------------------
@interface BiliFastBallTarget : NSObject
@end

@implementation BiliFastBallTarget
- (void)tapped { FOpenPanel(); }
- (void)threeFingerDoubleTap { FOpenPanel(); }
- (void)closeTapped { FClosePanel(); }
- (void)refreshTapped
{
    [gPanel reloadRows];
    FLogLine([NSString stringWithFormat:@"面板已刷新（CDN %ld 行）", (long)gPanel.rows.count]);
}

- (void)panned:(UIPanGestureRecognizer *)g
{
    UIWindow *win = gWin;
    if (!win || gPanelBox) return;          /* 面板开着时小球是隐藏的 */
    CGPoint p = [g translationInView:win];
    CGPoint c = CGPointMake(win.center.x + p.x, win.center.y + p.y);
    [g setTranslation:CGPointZero inView:win];
    {
        /* 夹在屏幕内。用场景自己的坐标空间，比 UIScreen.mainScreen 准 */
        CGSize sz = win.windowScene ? win.windowScene.coordinateSpace.bounds.size
                                    : [UIScreen mainScreen].bounds.size;
        c.x = MIN(MAX(c.x, 26), sz.width  - 26);
        c.y = MIN(MAX(c.y, 48), sz.height - 48);
    }
    win.center = c;
    gBallCenter = c;
    if (g.state == UIGestureRecognizerStateEnded) FSaveBallCenter(c);
}
@end

static BiliFastBallTarget *gTarget;

/// 覆盖窗口自己的根 VC：只做一件事 —— 转屏时把面板重新铺满
@interface BiliFastOverlayVC : UIViewController
@end

@implementation BiliFastOverlayVC
- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (!gPanelBox) return;                 /* 只挂着小球时不用管 */
    UIWindowScene *scene = gWin.windowScene;
    if (scene) {
        CGRect sc = scene.coordinateSpace.bounds;
        if (!CGRectIsEmpty(sc) && !CGRectEqualToRect(gWin.frame, sc)) gWin.frame = sc;
    }
    gPanelBox.frame = self.view.bounds;
}
@end

//------------------------------------------------------------------------------
#pragma mark - 组装
//------------------------------------------------------------------------------
static UIWindowScene *FActiveWindowScene(void)
{
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState != UISceneActivationStateUnattached) {
            return (UIWindowScene *)s;
        }
    }
    return nil;
}

static CGRect FFullScreenBounds(void)
{
    UIWindowScene *scene = gWin.windowScene ?: FActiveWindowScene();
    if (scene) {
        CGRect r = scene.coordinateSpace.bounds;
        if (!CGRectIsEmpty(r)) return r;
    }
    return [UIScreen mainScreen].bounds;
}

/// 给一个 App 窗口挂三指双击（同一个窗口只挂一次）
static void FAttachGesture(UIWindow *w)
{
    if (!w || !gTarget) return;
    if (!gGestureWindows) gGestureWindows = [NSHashTable weakObjectsHashTable];
    @synchronized (gGestureWindows) {
        if ([gGestureWindows containsObject:w]) return;
        [gGestureWindows addObject:w];
    }
    @try {
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:gTarget
                                                    action:@selector(threeFingerDoubleTap)];
        tap.numberOfTouchesRequired = 3;
        tap.numberOfTapsRequired = 2;
        tap.cancelsTouchesInView = NO;   /* 不干扰 App 自己的手势 */
        tap.delaysTouchesEnded = NO;
        [w addGestureRecognizer:tap];
    } @catch (__unused NSException *e) {}
}

static void FObserveKeyWindows(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIWindowDidBecomeKeyNotification object:nil
                        queue:[NSOperationQueue mainQueue]
                   usingBlock:^(NSNotification *n) {
            if ([n.object isKindOfClass:[UIWindow class]]) {
                UIWindow *w = (UIWindow *)n.object;
                if (w != gWin) FAttachGesture(w);
            }
        }];
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) FAttachGesture(w);
        }
    });
}

static void FLogLine(NSString *s)
{
    /* 走 BiliFast.m 里的文件日志（通过一条通知解耦，避免这里直接依赖它） */
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BiliFastLog"
                                                        object:nil userInfo:@{@"msg": s ?: @""}];
}

static void FBuildOverlay(void)
{
    if (gWin) return;

    UIWindowScene *scene = FActiveWindowScene();
    if (!scene) return;   /* 场景没就绪，外面会重试 */

    gTarget = [[BiliFastBallTarget alloc] init];

    /* 小球：46x46，本就不挡别的位置 */
    {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, 0, 46, 46);
        b.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.62];
        b.layer.cornerRadius = 23;
        b.layer.borderWidth = 1.5;
        b.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85].CGColor;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [b setTitle:@"加速" forState:UIControlStateNormal];
        [b addTarget:gTarget action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gTarget
                                                                       action:@selector(panned:)]];
        gBall = b;
    }

    gRootVC = [[BiliFastOverlayVC alloc] init];
    gRootVC.view.backgroundColor = [UIColor clearColor];
    [gRootVC.view addSubview:gBall];

    gWin = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 46, 46)];
    gWin.windowScene = scene;                     /* iOS 13+ 不设它窗口根本不显示 */
    gWin.windowLevel = UIWindowLevelAlert + 1;
    gWin.backgroundColor = [UIColor clearColor];
    gWin.rootViewController = gRootVC;

    gBallCenter = FLoadBallCenter();
    if (CGPointEqualToPoint(gBallCenter, CGPointZero)) {
        CGRect sb = FFullScreenBounds();
        gBallCenter = CGPointMake(sb.size.width - 44, sb.size.height * 0.62);
    }
    gWin.center = gBallCenter;

    gBallWanted = [[NSUserDefaults standardUserDefaults] objectForKey:@"BiliFastBallVisible"]
                    ? [[NSUserDefaults standardUserDefaults] boolForKey:@"BiliFastBallVisible"]
                    : YES;
    gWin.hidden = !gBallWanted;

    FObserveKeyWindows();
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w != gWin) FAttachGesture(w);
        }
    }
}

//------------------------------------------------------------------------------
#pragma mark - 开关面板
//------------------------------------------------------------------------------
static void FOpenPanel(void)
{
    if (gPanelBox) return;                       /* 已经开着 */
    if (!gWin || !gRootVC || !gBall) {
        FLogLine(@"面板打不开：覆盖窗口还没建好");
        return;
    }

    CGRect full = FFullScreenBounds();
    if (CGRectIsEmpty(full)) {
        FLogLine(@"面板打不开：拿不到屏幕尺寸");
        return;
    }

    @try {
        gBallCenter = gWin.center;               /* 记住小球位置，关面板时放回去 */
        gWin.hidden = NO;
        gWin.frame = full;
        gRootVC.view.frame = CGRectMake(0, 0, full.size.width, full.size.height);
        gBall.hidden = YES;                      /* 面板期间藏起小球，位置已记住 */

        gPanel = [[BiliFastPanel alloc] init];
        gPanel.onToggle     = ^(BOOL on)   { if (gSetEnabled) gSetEnabled(on); };
        gPanel.onToggleBall = ^(BOOL show) { BiliFastSetBallVisible(show); };
        gPanel.enabled   = gIsEnabled ? gIsEnabled() : YES;
        gPanel.ballShown = gBallWanted;

        const CGFloat barH = 52.0;
        gPanelBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, full.size.width, full.size.height)];
        gPanelBox.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        gPanelBox.backgroundColor = [UIColor systemBackgroundColor];

        /* 顶栏自己做：不用 UINavigationController，也就没有 present 那一套 */
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, full.size.width, barH)];
        bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        bar.backgroundColor = [UIColor secondarySystemBackgroundColor];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, full.size.width - 180, barH)];
        title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        title.text = @"BiliFast 设置";
        title.font = [UIFont boldSystemFontOfSize:17];
        [bar addSubview:title];

        UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
        done.frame = CGRectMake(full.size.width - 74, 0, 60, barH);
        done.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [done setTitle:@"完成" forState:UIControlStateNormal];
        done.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [done addTarget:gTarget action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:done];

        UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
        refresh.frame = CGRectMake(full.size.width - 136, 0, 60, barH);
        refresh.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [refresh setTitle:@"刷新" forState:UIControlStateNormal];
        [refresh addTarget:gTarget action:@selector(refreshTapped) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:refresh];

        [gPanelBox addSubview:bar];

        /* 真正的配置页：访问 .view 会触发 viewDidLoad（里面会 reloadRows） */
        [gRootVC addChildViewController:gPanel];
        gPanel.view.frame = CGRectMake(0, barH, full.size.width, full.size.height - barH);
        gPanel.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [gPanelBox addSubview:gPanel.view];
        [gPanel didMoveToParentViewController:gRootVC];
        [gPanel reloadRows];                     /* 确保表格有数据 */

        [gRootVC.view addSubview:gPanelBox];

        FLogLine([NSString stringWithFormat:
            @"面板已打开：CDN %ld 行，屏幕 %.0fx%.0f，%@外观",
            (long)gPanel.rows.count, full.size.width, full.size.height,
            gPanel.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? @"深色" : @"浅色"]);
    } @catch (NSException *ex) {
        [gPanelBox removeFromSuperview];
        gPanelBox = nil;
        gPanel = nil;
        gBall.hidden = !gBallWanted;
        FLogLine([NSString stringWithFormat:@"面板打开失败：%@ — %@", ex.name, ex.reason]);
    }
}

static void FClosePanel(void)
{
    if (!gPanelBox) return;
    UIView *box = gPanelBox;
    BiliFastPanel *p = gPanel;
    gPanelBox = nil;
    gPanel = nil;
    @try {
        [p willMoveToParentViewController:nil];
        [p.view removeFromSuperview];
        [p removeFromParentViewController];
        [box removeFromSuperview];
    } @catch (__unused NSException *e) {}

    /* 窗口缩回小球大小，位置还原 */
    CGRect small = CGRectMake(0, 0, 46, 46);
    gRootVC.view.frame = small;
    gWin.frame = small;
    gWin.center = gBallCenter;
    gBall.hidden = !gBallWanted;
    FLogLine(@"面板已关闭");
}

//------------------------------------------------------------------------------
#pragma mark - 对外入口
//------------------------------------------------------------------------------
void BiliFastShowSettings(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{ FOpenPanel(); });
}

void BiliFastSetBallVisible(BOOL visible)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        gBallWanted = visible;
        gBall.hidden = (!visible || gPanelBox != nil);
        if (!gPanelBox) gWin.hidden = !visible;   /* 面板开着时窗口必须留着 */
        [[NSUserDefaults standardUserDefaults] setBool:visible forKey:@"BiliFastBallVisible"];
    });
}

static int gBuildTries = 0;
static void FTryBuild(void)
{
    if (gWin) return;
    if (FActiveWindowScene() || ++gBuildTries > 24) {
        @try { FBuildOverlay(); }
        @catch (NSException *ex) {
            FLogLine([NSString stringWithFormat:@"界面初始化失败：%@", ex.reason ?: @"?"]);
        }
        if (gWin || gBuildTries > 24) return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FTryBuild(); });
}

void BiliFastInstallUI(BOOL (^isEnabled)(void), void (^setEnabled)(BOOL))
{
    BOOL expected = NO;
    static _Atomic(BOOL) installed;
    if (!atomic_compare_exchange_strong(&installed, &expected, YES)) return;

    gIsEnabled  = [isEnabled copy];
    gSetEnabled = [setEnabled copy];

    dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { FTryBuild(); } });
}
'''

src = io.open(P, encoding='utf-8').read()
i = src.index(MARK)
head = src[:i].rstrip()
sep = '//' + '-' * 78
if head.endswith(sep):
    head = head[:-len(sep)].rstrip()

io.open(P, 'w', encoding='utf-8', newline='\n').write(head + '\n' + TAIL)
print('OK: %s  %d -> %d bytes' % (P, len(src), len(head + TAIL)))
