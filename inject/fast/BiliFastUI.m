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
//   * 透明窗口的 hitTest 只认「小球」与「面板」，其余位置一律放行给 App，
//     所以不会挡住任何正常操作
//
// 两个容易踩的坑，这里都处理了：
//   1. iOS 13+ 手工创建的 UIWindow 若不设 windowScene，**根本不会显示**。
//      启动时场景往往还没就绪，所以这里轮询等场景出现再建窗口。
//   2. 手势/按钮回调不用分类（category）承载 —— 那会引入「先 @selector 后声明」
//      的顺序问题；改用一个 target 对象，干净且不会有警告。
//==============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdatomic.h>

#import "BSPProxyServer.h"
#import "BiliFastUI.h"

static _Atomic(BOOL) gInstalled;

//------------------------------------------------------------------------------
#pragma mark - 悬浮窗：只有小球与面板接管触摸
//------------------------------------------------------------------------------
@interface BiliFastWindow : UIWindow
@end

@implementation BiliFastWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *v = [super hitTest:point withEvent:event];
    /* 根视图（透明底板）本身不接管触摸 —— 否则整块屏幕都被我们吃掉，
     * App 就点不动了。只有小球和面板里的子视图会被返回。 */
    if (v == self.rootViewController.view) return nil;
    return v;
}
@end

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

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

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
#pragma mark - 入口（小球 / 手势 / 面板）
//------------------------------------------------------------------------------
static BiliFastWindow *gWindow;
static BiliFastPanel  *gPanel;
static UIButton       *gBall;
static BOOL            gBallWanted = YES;
static BOOL (^gIsEnabled)(void);
static void (^gSetEnabled)(BOOL);

static void FSaveBallPos(CGPoint c)
{
    [[NSUserDefaults standardUserDefaults] setObject:@[@(c.x), @(c.y)] forKey:@"BiliFastBallPos"];
}
static CGPoint FLoadBallPos(void)
{
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:@"BiliFastBallPos"];
    if (a.count == 2) return CGPointMake([a[0] doubleValue], [a[1] doubleValue]);
    return CGPointZero;
}

static void FPresentPanel(void)
{
    UIViewController *top = gWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]] &&
        [(UINavigationController *)top topViewController] == gPanel) return;

    gPanel.enabled   = gIsEnabled ? gIsEnabled() : YES;
    gPanel.ballShown = gBallWanted;
    [gPanel reloadRows];
    [top presentViewController:[[UINavigationController alloc] initWithRootViewController:gPanel]
                      animated:YES completion:nil];
}

void BiliFastShowSettings(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{ if (gWindow) FPresentPanel(); });
}

void BiliFastSetBallVisible(BOOL visible)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        gBallWanted = visible;
        gBall.hidden = !visible;
        [[NSUserDefaults standardUserDefaults] setBool:visible forKey:@"BiliFastBallVisible"];
    });
}

/// 小球与手势的统一回调目标（不用分类，避免 @selector 顺序问题）
@interface BiliFastBallTarget : NSObject
@end

@implementation BiliFastBallTarget
- (void)tapped { FPresentPanel(); }
- (void)threeFingerDoubleTap { FPresentPanel(); }
- (void)panned:(UIPanGestureRecognizer *)g
{
    UIView *host = g.view.superview ?: gWindow;
    CGPoint p = [g translationInView:host];
    g.view.center = CGPointMake(g.view.center.x + p.x, g.view.center.y + p.y);
    [g setTranslation:CGPointZero inView:host];
    {
        CGSize sz = host.bounds.size;
        g.view.center = CGPointMake(MIN(MAX(g.view.center.x, 26), sz.width - 26),
                                    MIN(MAX(g.view.center.y, 48), sz.height - 48));
    }
    if (g.state == UIGestureRecognizerStateEnded) FSaveBallPos(g.view.center);
}
@end

static BiliFastBallTarget *gTarget;

static void FBuildWindow(void)
{
    if (gWindow) return;

    /* iOS 13+ 必须给手工创建的窗口指定 windowScene，否则它根本不会显示。
     * 启动早期场景常常还没就绪，所以先用轮询等它出现。 */
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState != UISceneActivationStateUnattached) {
            scene = (UIWindowScene *)s;
            break;
        }
    }

    gTarget = [[BiliFastBallTarget alloc] init];
    gPanel  = [[BiliFastPanel alloc] init];
    gPanel.onToggle = ^(BOOL on) { if (gSetEnabled) gSetEnabled(on); };
    gPanel.onToggleBall = ^(BOOL show) { BiliFastSetBallVisible(show); };

    gWindow = [[BiliFastWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    if (scene) gWindow.windowScene = scene;
    gWindow.windowLevel = UIWindowLevelAlert + 1;
    gWindow.backgroundColor = [UIColor clearColor];
    gWindow.rootViewController = [[UIViewController alloc] init];
    gWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    gWindow.hidden = NO;

    /* 悬浮小球 */
    {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, 0, 46, 46);
        b.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.62];
        b.layer.cornerRadius = 23;
        b.layer.borderWidth = 1.5;
        b.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8].CGColor;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [b setTitle:@"加速" forState:UIControlStateNormal];
        [b addTarget:gTarget action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gTarget
                                                                       action:@selector(panned:)]];
        {
            CGPoint saved = FLoadBallPos();
            if (CGPointEqualToPoint(saved, CGPointZero)) {
                CGSize sz = [UIScreen mainScreen].bounds.size;
                saved = CGPointMake(sz.width - 60, sz.height * 0.62);
            }
            b.center = saved;
        }
        [gWindow addSubview:b];
        gBall = b;
    }

    /* 三指双击：小球被隐藏后的入口 */
    {
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:gTarget
                                                    action:@selector(threeFingerDoubleTap)];
        tap.numberOfTouchesRequired = 3;
        tap.numberOfTapsRequired = 2;
        tap.cancelsTouchesInView = NO;
        [gWindow addGestureRecognizer:tap];
    }

    gBallWanted = [[NSUserDefaults standardUserDefaults] objectForKey:@"BiliFastBallVisible"]
                    ? [[NSUserDefaults standardUserDefaults] boolForKey:@"BiliFastBallVisible"]
                    : YES;
    gBall.hidden = !gBallWanted;

    gPanel.enabled   = gIsEnabled ? gIsEnabled() : YES;
    gPanel.ballShown = gBallWanted;
    [gPanel reloadRows];
}

void BiliFastInstallUI(BOOL (^isEnabled)(void), void (^setEnabled)(BOOL))
{
    BOOL expected = NO;
    if (!atomic_compare_exchange_strong(&gInstalled, &expected, YES)) return;

    gIsEnabled  = [isEnabled copy];
    gSetEnabled = [setEnabled copy];

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            /* 场景没就绪就再等一拍 —— 最多等约 10 秒，之后仍建（至少逻辑上是活的） */
            __block int tries = 0;
            __block void (^tryBuild)(void);
            tryBuild = ^{
                BOOL hasScene = NO;
                for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                    if ([s isKindOfClass:[UIWindowScene class]]) { hasScene = YES; break; }
                }
                if (hasScene || ++tries > 20) {
                    FBuildWindow();
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), tryBuild);
            };
            tryBuild();
        }
    });
}
