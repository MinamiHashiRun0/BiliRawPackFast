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

/* 供 BSPProxyServer 构建全局调度器主机池。
 * 单 host 模式（默认，hosts.txt 为空）返回空数组——不预填候选池，
 * 每个请求只用它自己的原始 host，多分片打同一海外 CDN 拿多连接绕单连接限速。
 * 多 host 模式（hosts.txt 非空）返回 override 列表，按旧逻辑散到指定 host。 */
+ (NSArray<NSString *> *)effectiveHostsForPlanner;

/* 是否处于多 host 模式（hosts.txt 给了 override）。
 * 单 host = NO 时调度器不挑 host，全部走原始 URL。 */
+ (BOOL)multiHostMode;

@end

NS_ASSUME_NONNULL_END
