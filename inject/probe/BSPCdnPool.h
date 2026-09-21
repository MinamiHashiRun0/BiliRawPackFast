/* BSPCdnPool.h — B 站视频 CDN 主机池与媒体 URL 识别
 *
 * 主机名单来源（交叉验证）：
 *   - BiliFast 模块 MAINLAND_MIRRORS / OVERSEA_VIDEO_HOSTS
 *   - 第三方轻量客户端 PlaybackCDNProbeService 的 host pool
 *   - 用户 HAR 实际抓到的 upos-sz-mirroraliov.bilivideo.com
 * 只做「同 path/同签名、换 host」的重写：B 站 m4s 的 upsig / hdnts / deadline
 * 绑定的是 path + 查询串，不绑定 host（HAR 里 uparams 不含 host），因此换 host
 * 在原理上可行；是否真被接受由代理在运行时用「对冲并发 + 失败即拉黑」自适应判定。
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BSPCdnPool : NSObject

/* 是否是 B 站视频媒体 URL（m4s / dash 分片），可安全做 host 重定向 */
+ (BOOL)isMediaURL:(nullable NSString *)urlString;

/* 取出主 host（小写） */
+ (nullable NSString *)hostOf:(NSString *)urlString;

/* 是否为 .mcdn.bilivideo.* 这类 PCDN 节点 */
+ (BOOL)isPcdnHost:(nullable NSString *)host;

/* 把 url 的 host 换成 newHost，其余（scheme/user/path/query/fragment）原样保留 */
+ (nullable NSString *)url:(NSString *)urlString withHost:(NSString *)newHost;

/* 给 url 生成候选 host 列表（已去掉原 host，已去重，顺序即优先级） */
+ (NSArray<NSString *> *)candidateHostsFor:(NSString *)urlString;

/* 全量大陆镜像 / 海外节点 */
+ (NSArray<NSString *> *)mainlandMirrors;
+ (NSArray<NSString *> *)overseaHosts;

/* 统计：本次进程内已见过的媒体 host（保序） */
+ (NSArray<NSString *> *)seenMediaHosts;

/* 仅供测试：把主机池换成给定列表（传 nil 恢复内置名单）。
 * 生产路径永不调用。 */
+ (void)setOverrideHosts:(nullable NSArray<NSString *> *)hosts;

/* 仅供测试：关掉「必须是 B 站媒体 URL」的判定 */
+ (void)setMediaCheckDisabled:(BOOL)disabled;

/*------------------------------------------------------------------------------
 * CDN 使用模式（面板可选，存 NSUserDefaults，改完下一个请求就生效）
 *
 * 之前只有「跟随原始 URL」一种行为，用户没法指定走哪台 CDN —— 而 B 站分给
 * 不同视频的 CDN 并不一样（真机日志里同一个会话既有 akamaized.net 也有
 * bilivideo.com），海外用户想钉死一台快的都做不到。现在三种：
 *
 *   Follow  跟随原始 URL：不改 host，多分片打原始 CDN 拿多连接。
 *           最安全（签名与 host 本来就匹配），也是之前的默认行为。
 *   Single  单 CDN 多发：把**全部**流量钉到一台选定的 CDN，多连接并发。
 *   Multi   多 CDN 多发：在勾选的一组 CDN 之间分配，每个也可多连接。
 *
 * 风险（面板里也写了）：Single/Multi 都要改写 host。B 站 m4s 的签名绑 path +
 * 查询串、不绑 host（见文件头注释），所以原理上可行；但个别域名会 403
 * （.bilivideo.cn 已实测 403，故不在名单里）。换到不通的 CDN 会表现为失败
 * 分片变多、缓冲反而更慢 —— 那时切回 Follow 即可。
 *------------------------------------------------------------------------------*/
typedef NS_ENUM(NSInteger, BSPCdnMode) {
    BSPCdnModeFollow = 0,
    BSPCdnModeSingle = 1,
    BSPCdnModeMulti  = 2,
};

+ (BSPCdnMode)mode;
+ (void)setMode:(BSPCdnMode)mode;          /* 立即持久化 */

/* 勾选的 CDN（保序）。Single 取第一个，Multi 全用。 */
+ (NSArray<NSString *> *)selectedHosts;
+ (void)setSelectedHosts:(NSArray<NSString *> *)hosts;
+ (void)toggleHost:(NSString *)host;

/* Single 模式钉住的那台；一台都没勾时返回 nil（此时退化为 Follow）。 */
+ (nullable NSString *)pinnedHost;

/* 面板可勾选的完整候选：海外节点在前、内置大陆镜像在后，再补本次见过的。
 * 海外优先，是因为这个模块就是给海外用户用的，国内多数连不上。 */
+ (NSArray<NSString *> *)pickerCandidates;

/* 供 BSPProxyServer 构建全局调度器主机池。
 * 只有 Multi 模式才预填候选池；Follow / Single 返回空数组——调度器不挑 host。 */
+ (NSArray<NSString *> *)effectiveHostsForPlanner;

/* 是否处于多 host 模式（= Multi）。其余两种模式调度器都不挑 host。 */
+ (BOOL)multiHostMode;

@end

NS_ASSUME_NONNULL_END
