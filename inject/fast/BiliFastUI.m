//==============================================================================
// BiliFastUI —— 应用内设置面板
//
// 为什么要有它：之前只能靠编辑 Documents/BiliFast/mode.txt 与 hosts.txt 来开关
// 和选节点，这对日常使用完全不合适。正式模块应该有能点开、能勾选、改完立刻
// 生效的界面。
//
// 交互（尽量不干扰 App 本身）：
//   * 悬浮小球（可拖动、半透明、记住位置）→ 点一下打开面板
//   * 三指双击屏幕任意位置 → 同样打开面板（小球被隐藏时的入口）
//
// 三个容易踩的坑，这里都处理了：
//   1. iOS 13+ 手工创建的 UIWindow 若不设 windowScene，**根本不会显示**。
//      启动时场景往往还没就绪，所以这里轮询等场景出现再建窗口。
//   2. 手势/按钮回调不用分类（category）承载 —— 那会引入「先 @selector 后声明」
//      的顺序问题；改用一个 target 对象，干净且不会有警告。
//   3. 小球窗口**只有小球那么大**，三指手势挂在 App 自己的 key window 上，
//      面板从 App 最顶层 VC 弹出。详见下面「入口」一节的说明 ——
//      这三条都是被真机故障逼出来的。
//==============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdatomic.h>

#import "BSPProxyServer.h"
#import "BiliFastUI.h"

static _Atomic(BOOL) gInstalled;

//------------------------------------------------------------------------------
#pragma mark - 设置面板
//------------------------------------------------------------------------------
@interface BiliFastPanel : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy)   void (^onToggle)(BOOL on);
@property (nonatomic, copy)   void (^onToggleBall)(BOOL show);
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *rows;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL ballShown;
@end

@implementation BiliFastPanel

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"BiliFast 设置";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(reloadRows)];
    if (!self.rows) [self reloadRows];
}

- (void)done
{
    [self dismissViewControllerAnimated:YES completion:^{
        /* 通知外面复位「已弹出」标志，否则第二次就打不开了 */
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BiliFastPanelClosed"
                                                            object:nil];
    }];
}

- (void)reloadRows
{
    NSArray<NSDictionary *> *snap = [[BSPProxyServer shared] hostSnapshot];
    self.rows = [NSMutableArray array];
    for (NSDictionary *d in snap) [self.rows addObject:[d mutableCopy]];
    [self.table reloadData];
}

- (NSUInteger)selectedCount
{
    NSUInteger n = 0;
    for (NSDictionary *d in self.rows) if ([d[@"enabled"] boolValue]) n++;
    return n;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s
{
    if (s == 0) return @"并发加速";
    if (s == 1) return [NSString stringWithFormat:@"CDN 节点（已选 %lu / %lu）",
                        (unsigned long)[self selectedCount], (unsigned long)self.rows.count];
    return @"指标与说明";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    if (s == 0) return 2;                        /* 总开关 + 悬浮球 */
    if (s == 1) return (NSInteger)self.rows.count;
    return 3;                                    /* 指标 / 快捷 / 说明 */
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                               reuseIdentifier:nil];
    c.detailTextLabel.numberOfLines = 2;
    c.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];

    if (ip.section == 0) {
        UISwitch *sw = [[UISwitch alloc] init];
        if (ip.row == 0) {
            c.textLabel.text = @"启用并发加速";
            sw.on = self.enabled;
            [sw addTarget:self action:@selector(masterChanged:)
        forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            c.detailTextLabel.numberOfLines = 3;
            c.detailTextLabel.text = self.enabled
                ? @"已开启：视频地址改写到本机代理，由代理并发取数\n改动立即生效"
                : @"已关闭：完全不动 URL，播放器直连 CDN";
        } else {
            c.textLabel.text = @"显示悬浮小球";
            sw.on = self.ballShown;
            [sw addTarget:self action:@selector(ballChanged:)
        forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            c.detailTextLabel.text = @"关掉后：三指双击屏幕任意位置仍可打开本面板";
        }
        return c;
    }

    if (ip.section == 1) {
        NSDictionary *d = self.rows[(NSUInteger)ip.row];
        BOOL on = [d[@"enabled"] boolValue];
        long long ok = [d[@"ok"] longLongValue];
        long long fail = [d[@"fail"] longLongValue];
        double speed = [d[@"speed"] doubleValue];
        c.textLabel.text = d[@"host"];
        c.textLabel.adjustsFontSizeToFitWidth = YES;
        c.textLabel.minimumScaleFactor = 0.65;
        c.detailTextLabel.text = [NSString stringWithFormat:@"均速 %.2f MiB/s   成功 %lld   失败 %lld",
                                  speed, ok, fail];
        c.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        /* 试过但一次都没成的节点标红：一眼看出该关谁 */
        if (fail > 0 && ok == 0) c.detailTextLabel.textColor = [UIColor systemRedColor];
        else if (ok > 0)         c.detailTextLabel.textColor = [UIColor systemGreenColor];
        else                     c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        return c;
    }

    if (ip.row == 0) {
        c.textLabel.text = @"本次会话指标";
        c.detailTextLabel.numberOfLines = 4;
        c.detailTextLabel.text = [[BSPProxyServer shared] throughputLine];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    if (ip.row == 1) {
        c.textLabel.text = @"全部启用（恢复自动调度）";
        c.textLabel.textColor = [UIColor systemBlueColor];
        c.detailTextLabel.text = @"把所有节点都放回候选池，由实测速度自动分配";
        return c;
    }
    c.textLabel.text = @"调参";
    c.detailTextLabel.numberOfLines = 3;
    c.detailTextLabel.text = [NSString stringWithFormat:
        @"分片 %ld KiB，并发窗口 %ld\n"
        @"本页的开关与勾选立即生效；改 hosts.txt / mode.txt 需重启 App",
        (long)[[BSPProxyServer shared] chunkKiB], (long)[[BSPProxyServer shared] windowSize]];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (void)masterChanged:(UISwitch *)sw
{
    self.enabled = sw.on;
    if (self.onToggle) self.onToggle(self.enabled);
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:0]
              withRowAnimation:UITableViewRowAnimationNone];
}

- (void)ballChanged:(UISwitch *)sw
{
    self.ballShown = sw.on;
    if (self.onToggleBall) self.onToggleBall(self.ballShown);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        NSMutableDictionary *d = self.rows[(NSUInteger)ip.row];
        BOOL on = ![d[@"enabled"] boolValue];
        d[@"enabled"] = @(on);
        [[BSPProxyServer shared] setHost:d[@"host"] enabled:on];
        [tv reloadSections:[NSIndexSet indexSetWithIndex:1]
          withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    if (ip.section == 2 && ip.row == 1) {
        [[BSPProxyServer shared] enableAllHosts];
        [self reloadRows];
    }
}

@end


//------------------------------------------------------------------------------
#pragma mark - 入口（小球 / 三指手势 / 面板）
//------------------------------------------------------------------------------
// 设计要点（都是踩过坑之后改的）：
//
// 1. 小球窗口**只有小球那么大**，不再是一个全屏透明窗口。
//    上一版用了全屏窗口 + hitTest 对根视图返回 nil，想做到「不挡 App」。
//    结果三指手势挂在那个窗口上，而 hitTest 返回 nil 意味着触摸被交给下面的
//    App 窗口 —— **手势识别器根本收不到触摸**（它只能收到命中测试落在自己
//    或自己子视图上的触摸）。所以「非主页三指双击无效」是必然的。
//    小球窗口做小之后完全不需要 hitTest 作弊：窗口本身就不挡任何别的位置。
//
// 2. 三指双击挂到**App 自己的 key window** 上。窗口是命中测试的根，
//    App 里任何位置的触摸都会经过它的手势识别器，所以到处都有效。
//    key window 会随 App 切页面/切场景而变化，因此监听 UIWindowDidBecomeKey
//    动态补挂（用一个集合避免重复挂）。
//
// 3. 面板从 **App 最顶层的 VC** 弹出，不从我们自己的窗口根视图弹 ——
//    后者的 view 不在 App 的窗口层级里，present 会直接抛
//    「whose view is not in the window hierarchy」而崩掉。
//    这也是「主页三指双击闪退」的直接原因。
//
// 4. 全部包 @try/@catch 并加重复弹出保护：这个模块最不该做的事就是把用户的
//    App 搞崩。宁可面板打不开，也不能闪退。

static UIWindow      *gBallWindow;
static BiliFastPanel *gPanel;
static UIButton      *gBall;
static BOOL           gBallWanted = YES;
static BOOL           gPanelPresented;
static BOOL (^gIsEnabled)(void);
static void (^gSetEnabled)(BOOL);
static NSHashTable   *gGestureWindows;

static void FLogLine(NSString *s);

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

/// App 最顶层的、可以拿来 present 的 VC
static UIViewController *FTopViewController(void)
{
    UIWindow *key = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (!key) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (!w.hidden && w.windowLevel == UIWindowLevelNormal) { key = w; break; }
            }
            if (key) break;
        }
    }
    if (!key) key = UIApplication.sharedApplication.keyWindow;
    if (!key) return nil;

    UIViewController *vc = key.rootViewController;
    for (int guard = 0; vc && guard < 12; guard++) {
        if (vc.presentedViewController) { vc = vc.presentedViewController; continue; }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *v = [(UINavigationController *)vc visibleViewController];
            if (v && v != vc) { vc = v; continue; }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *v = [(UITabBarController *)vc selectedViewController];
            if (v && v != vc) { vc = v; continue; }
        }
        break;
    }
    return vc;
}

/// 弹出设置面板。任何一个环节不对就安静地放弃（记一行日志），绝不抛异常出去。
static void FPresentPanel(void)
{
    if (gPanelPresented) return;
    UIViewController *top = FTopViewController();
    if (!top || !top.view.window) {
        FLogLine(@"面板打不开：找不到可用的顶层视图（App 可能还没进入前台）");
        return;
    }
    gPanel.enabled   = gIsEnabled ? gIsEnabled() : YES;
    gPanel.ballShown = gBallWanted;
    [gPanel reloadRows];
    gPanelPresented = YES;
    @try {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:gPanel];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [top presentViewController:nav animated:YES completion:nil];
    } @catch (NSException *ex) {
        gPanelPresented = NO;
        FLogLine([NSString stringWithFormat:@"面板弹出失败：%@ — %@", ex.name, ex.reason]);
    }
}

void BiliFastShowSettings(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{ FPresentPanel(); });
}

void BiliFastSetBallVisible(BOOL visible)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        gBallWanted = visible;
        gBallWindow.hidden = !visible;
        [[NSUserDefaults standardUserDefaults] setBool:visible forKey:@"BiliFastBallVisible"];
    });
}

//------------------------------------------------------------------------------
#pragma mark - 小球与手势的回调目标
//------------------------------------------------------------------------------
@interface BiliFastBallTarget : NSObject
@end

@implementation BiliFastBallTarget
- (void)tapped { FPresentPanel(); }

- (void)threeFingerDoubleTap { FPresentPanel(); }

- (void)panned:(UIPanGestureRecognizer *)g
{
    UIWindow *win = gBallWindow;
    if (!win) return;
    CGPoint p = [g translationInView:win];
    CGPoint c = CGPointMake(win.center.x + p.x, win.center.y + p.y);
    [g setTranslation:CGPointZero inView:win];
    {
        /* 夹在屏幕内（用窗口所在场景的坐标空间，取屏幕尺寸足够） */
        CGSize sz = [UIScreen mainScreen].bounds.size;
        c.x = MIN(MAX(c.x, 26), sz.width - 26);
        c.y = MIN(MAX(c.y, 48), sz.height - 48);
    }
    win.center = c;
    if (g.state == UIGestureRecognizerStateEnded) FSaveBallCenter(c);
}
@end

static BiliFastBallTarget *gTarget;

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

/// 监听 key window 变化，动态补挂
static void FObserveKeyWindows(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIWindowDidBecomeKeyNotification object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            if ([n.object isKindOfClass:[UIWindow class]]) {
                UIWindow *w = (UIWindow *)n.object;
                if (w != gBallWindow) FAttachGesture(w);
            }
        }];
        /* 也覆盖 App 刚起来那一刻已经存在的窗口 */
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

static void FBuildBall(void)
{
    if (gBallWindow) return;

    UIWindowScene *scene = FActiveWindowScene();
    if (!scene) return;   /* 场景没就绪，外面会重试 */

    gTarget = [[BiliFastBallTarget alloc] init];
    gPanel  = [[BiliFastPanel alloc] init];
    gPanel.onToggle = ^(BOOL on) { if (gSetEnabled) gSetEnabled(on); };
    gPanel.onToggleBall = ^(BOOL show) { BiliFastSetBallVisible(show); };

    /* 小球窗口：只有 46x46 —— 本就不挡别的位置，不需要 hitTest 作弊 */
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

    gBallWindow = [[UIWindow alloc] initWithFrame:gBall.bounds];
    gBallWindow.windowScene = scene;              /* iOS 13+ 不设它窗口根本不显示 */
    gBallWindow.windowLevel = UIWindowLevelAlert + 1;
    gBallWindow.backgroundColor = [UIColor clearColor];
    gBallWindow.rootViewController = [[UIViewController alloc] init];
    gBallWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    [gBallWindow.rootViewController.view addSubview:gBall];
    {
        CGPoint saved = FLoadBallCenter();
        if (CGPointEqualToPoint(saved, CGPointZero)) {
            CGSize sz = [UIScreen mainScreen].bounds.size;
            saved = CGPointMake(sz.width - 44, sz.height * 0.62);
        }
        gBallWindow.center = saved;
    }
    gBallWanted = [[NSUserDefaults standardUserDefaults] objectForKey:@"BiliFastBallVisible"]
                    ? [[NSUserDefaults standardUserDefaults] boolForKey:@"BiliFastBallVisible"]
                    : YES;
    gBallWindow.hidden = !gBallWanted;

    FObserveKeyWindows();
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w != gBallWindow) FAttachGesture(w);
        }
    }
}

static int gBuildTries = 0;
static void FTryBuild(void)
{
    if (gBallWindow) return;
    if (FActiveWindowScene() || ++gBuildTries > 24) {
        @try { FBuildBall(); }
        @catch (NSException *ex) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"BiliFastLog"
                object:nil userInfo:@{@"msg": [NSString stringWithFormat:@"界面初始化失败：%@", ex.reason ?: @"?"]}];
        }
        if (gBallWindow || gBuildTries > 24) return;
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

    /* 面板关闭后要复位「已弹出」标志，否则第二次打不开 */
    [[NSNotificationCenter defaultCenter] addObserverForName:@"BiliFastPanelClosed"
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        gPanelPresented = NO;
    }];

    dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { FTryBuild(); } });
}
