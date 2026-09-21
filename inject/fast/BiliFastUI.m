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
#import "BSPCdnPool.h"
#import "BiliFastUI.h"

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

    /* 没有 navigationItem：面板不再是 modal，也没有 UINavigationController。
     * 标题与「完成/刷新」由覆盖窗口自带的顶栏负责（见文件末尾 FOpenPanel）。
     * 旧版把复位「已弹出」标志写在 -done 里，而 FormSheet 还能下滑关闭 ——
     * 滑掉一次面板就永久打不开了，这也是换掉 modal 方案的原因之一。 */
    if (!self.rows) [self reloadRows];
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
    if (s == 1) {
        if ([BSPCdnPool multiHostMode]) {
            return [NSString stringWithFormat:@"CDN 节点（已选 %lu / %lu）",
                    (unsigned long)[self selectedCount], (unsigned long)self.rows.count];
        }
        /* 单 host 模式：节点是动态的（每个视频的原始 host），不是可选候选池 */
        return @"当前 CDN（单 host 多连接模式）";
    }
    return @"指标与说明";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    if (s == 0) return 2;                        /* 总开关 + 悬浮球 */
    if (s == 1) return (NSInteger)self.rows.count;
    /* 单 host 模式不需要「全部启用」（只有一个动态节点）：指标 + 说明 = 2 行
     * 多 host 模式保留「全部启用」：指标 + 全部启用 + 说明 = 3 行 */
    return [BSPCdnPool multiHostMode] ? 3 : 2;
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
        /* 单 host 模式：不可勾选，无 checkmark、不可点。多 host 模式才显示勾选态 */
        c.accessoryType = [BSPCdnPool multiHostMode]
                            ? (on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone)
                            : UITableViewCellAccessoryNone;
        c.selectionStyle = [BSPCdnPool multiHostMode]
                             ? UITableViewCellSelectionStyleDefault
                             : UITableViewCellSelectionStyleNone;
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
    if ([BSPCdnPool multiHostMode] && ip.row == 1) {
        /* 多 host 模式才有「全部启用」行（恢复自动调度） */
        c.textLabel.text = @"全部启用（恢复自动调度）";
        c.textLabel.textColor = [UIColor systemBlueColor];
        c.detailTextLabel.text = @"把所有节点都放回候选池，由实测速度自动分配";
        return c;
    }
    {
        /* 说明行：单 host 模式 row 1，多 host 模式 row 2 */
        c.textLabel.text = @"调参";
        c.detailTextLabel.numberOfLines = 4;
        if ([BSPCdnPool multiHostMode]) {
            c.detailTextLabel.text = [NSString stringWithFormat:
                @"分片 %ld KiB，并发窗口 %ld（多 host 模式）\n"
                @"本页的开关与勾选立即生效；改 hosts.txt / mode.txt 需重启 App",
                (long)[[BSPProxyServer shared] chunkKiB], (long)[[BSPProxyServer shared] windowSize]];
        } else {
            c.detailTextLabel.text = [NSString stringWithFormat:
                @"单 host 多连接：分片 %ld KiB × 并发窗口 %ld 条连接，"
                @"打同一海外 CDN 绕 per-connection 限速\n"
                @"想改回「散到多 host」：在 Documents/BiliFast/hosts.txt 写入.host 列表后重启 App",
                (long)[[BSPProxyServer shared] chunkKiB], (long)[[BSPProxyServer shared] windowSize]];
        }
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
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
        /* 单 host 模式：节点是当前视频的原始 host，不可勾选启停
         * （关掉唯一的 host = 没有候选，毫无意义）。多 host 模式才允许勾选。 */
        if ([BSPCdnPool multiHostMode]) {
            NSMutableDictionary *d = self.rows[(NSUInteger)ip.row];
            BOOL on = ![d[@"enabled"] boolValue];
            d[@"enabled"] = @(on);
            [[BSPProxyServer shared] setHost:d[@"host"] enabled:on];
            [tv reloadSections:[NSIndexSet indexSetWithIndex:1]
              withRowAnimation:UITableViewRowAnimationNone];
        }
        return;
    }
    if (ip.section == 2 && ip.row == 1 && [BSPCdnPool multiHostMode]) {
        /* 多 host 模式 row 1 = 「全部启用」；单 host 模式 row 1 = 说明行，无动作 */
        [[BSPProxyServer shared] enableAllHosts];
        [self reloadRows];
    }
}

@end

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
static UIView           *gPanelBox;      /* 非空 = 面板正开着（整屏遮罩） */
static UIView           *gPanelCard;     /* 居中的卡片，面板实体 */
static BiliFastPanel    *gPanel;         /* 每次打开新建，不复用 */
static CGPoint           gBallCenter;
static BOOL              gBallWanted = YES;
static BOOL (^gIsEnabled)(void);
static void (^gSetEnabled)(BOOL);
static NSHashTable      *gGestureWindows;

static void FLogLine(NSString *s);
static void FOpenPanel(void);
static void FClosePanel(void);
static void FLayoutCard(void);

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
@interface BiliFastBallTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation BiliFastBallTarget
- (void)tapped { FOpenPanel(); }
- (void)threeFingerDoubleTap { FOpenPanel(); }
- (void)closeTapped { FClosePanel(); }
- (void)backdropTapped { FClosePanel(); }

/* 遮罩上的「点空白关闭」不能把卡片上的触摸也算进去 ——
 * 手势挂在外层遮罩上时，落在卡片（它的子视图）里的触摸一样会喂给这个手势，
 * 那样点表格任何地方都会把面板关掉。这里显式排除卡片区域。 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t
{
    if (!gPanelBox) return NO;
    if (!gPanelCard) return YES;
    return ![gPanelCard pointInside:[t locationInView:gPanelBox] withEvent:nil];
}
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
    FLayoutCard();                          /* 转屏后整卡跟着重排 */
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

/// 卡片的位置与大小：居中、让开安全区、且不贴屏幕边缘
static CGRect FCardFrame(CGRect full, UIEdgeInsets sa)
{
    /* 左右各留 32，再往里 16 才是按钮 —— 于是「完成」离屏幕右边缘 48pt。
     * 系统下拉控制中心是从右上角边缘起手的，留够距离才不会打架。
     * 上边让开刘海/状态栏，下边让开 home 指示条。
     * 高度封顶 600：大屏上别铺成一整页，那样又回到「太大」了。 */
    CGFloat w     = MIN(full.size.width - 64.0, 560.0);
    CGFloat top   = sa.top + 24.0;
    CGFloat bot   = full.size.height - sa.bottom - 24.0;
    CGFloat avail = MAX(bot - top, 200.0);
    CGFloat h     = MIN(avail, 600.0);
    return CGRectMake(round((full.size.width - w) / 2.0),
                      round(top + (avail - h) / 2.0), w, h);
}

/// 按当前屏幕与安全区重排卡片内容。转屏时由 BiliFastOverlayVC 再调一次。
static void FLayoutCard(void)
{
    if (!gPanelBox || !gPanelCard || !gRootVC) return;

    CGRect full = FFullScreenBounds();
    gPanelBox.frame  = CGRectMake(0, 0, full.size.width, full.size.height);
    gPanelCard.frame = FCardFrame(full, gRootVC.view.safeAreaInsets);

    const CGFloat barH = 52.0, btnW = 60.0, btnH = 44.0, pad = 16.0, gap = 8.0;
    CGFloat cw = gPanelCard.frame.size.width;
    CGFloat ch = gPanelCard.frame.size.height;

    UIView   *bar = [gPanelCard viewWithTag:101];
    UILabel  *tit = (UILabel *)[gPanelCard viewWithTag:102];
    UIButton *dn  = (UIButton *)[gPanelCard viewWithTag:103];
    UIButton *rf  = (UIButton *)[gPanelCard viewWithTag:104];

    bar.frame = CGRectMake(0, 0, cw, barH);
    dn.frame  = CGRectMake(cw - pad - btnW, (barH - btnH) / 2.0, btnW, btnH);
    rf.frame  = CGRectMake(cw - pad - btnW - gap - btnW, (barH - btnH) / 2.0, btnW, btnH);
    tit.frame = CGRectMake(pad, 0, MAX(rf.frame.origin.x - pad - gap, 40.0), barH);

    if (gPanel.view.superview) {
        gPanel.view.frame = CGRectMake(0, barH, cw, MAX(ch - barH, 0));
    }
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

        /* 背景遮罩：整屏压暗，点空白处关闭。
         * 面板本身是一张**居中的卡片**，不铺满屏幕 —— 铺满时右上角的
         * 「完成」正好落在系统下拉控制中心的手势区里，点不着。 */
        gPanelBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, full.size.width, full.size.height)];
        gPanelBox.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.38];
        {
            UITapGestureRecognizer *tap =
                [[UITapGestureRecognizer alloc] initWithTarget:gTarget
                                                        action:@selector(backdropTapped)];
            tap.delegate = gTarget;          /* 点在卡片上时不关，见 shouldReceiveTouch */
            tap.cancelsTouchesInView = NO;
            [gPanelBox addGestureRecognizer:tap];
        }

        gPanelCard = [[UIView alloc] initWithFrame:CGRectZero];
        gPanelCard.backgroundColor = [UIColor systemBackgroundColor];
        gPanelCard.layer.cornerRadius = 14.0;
        gPanelCard.layer.masksToBounds = YES;
        [gPanelBox addSubview:gPanelCard];

        /* 顶栏自己做：不用 UINavigationController，也就没有 present 那一套。
         * 用 tag 取回来，是为了转屏时能整卡重排（见 FLayoutCard）。 */
        UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
        bar.tag = 101;
        bar.backgroundColor = [UIColor secondarySystemBackgroundColor];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
        title.tag = 102;
        title.text = @"BiliFast 设置";
        title.font = [UIFont boldSystemFontOfSize:17];
        [bar addSubview:title];

        UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
        done.tag = 103;
        [done setTitle:@"完成" forState:UIControlStateNormal];
        done.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [done addTarget:gTarget action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:done];

        UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
        refresh.tag = 104;
        [refresh setTitle:@"刷新" forState:UIControlStateNormal];
        [refresh addTarget:gTarget action:@selector(refreshTapped) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:refresh];

        [gPanelCard addSubview:bar];

        /* 真正的配置页：访问 .view 会触发 viewDidLoad（里面会 reloadRows） */
        [gRootVC addChildViewController:gPanel];
        [gPanelCard addSubview:gPanel.view];
        [gPanel didMoveToParentViewController:gRootVC];
        [gPanel reloadRows];                     /* 确保表格有数据 */

        [gRootVC.view addSubview:gPanelBox];
        FLayoutCard();                           /* 尺寸/安全区一次性算好 */

        FLogLine([NSString stringWithFormat:
            @"面板已打开：CDN %ld 行，屏幕 %.0fx%.0f，卡片 %.0fx%.0f，%@外观",
            (long)gPanel.rows.count, full.size.width, full.size.height,
            gPanelCard.frame.size.width, gPanelCard.frame.size.height,
            gPanel.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? @"深色" : @"浅色"]);
    } @catch (NSException *ex) {
        [gPanelBox removeFromSuperview];
        gPanelBox  = nil;
        gPanelCard = nil;
        gPanel = nil;
        gBall.hidden = !gBallWanted;
        FLogLine([NSString stringWithFormat:@"面板打开失败：%@ — %@", ex.name, ex.reason]);
    }
}

static void FClosePanel(void)
{
    if (!gPanelBox) return;
    UIView *box  = gPanelBox;
    UIView *card = gPanelCard;
    BiliFastPanel *p = gPanel;
    gPanelBox  = nil;
    gPanelCard = nil;
    gPanel = nil;
    @try {
        [p willMoveToParentViewController:nil];
        [p.view removeFromSuperview];
        [p removeFromParentViewController];
        [card removeFromSuperview];
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
