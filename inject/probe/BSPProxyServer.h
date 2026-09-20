/* BSPProxyServer.h — 回环 HTTP 代理：把播放器的单连接请求拆成多 CDN 并发分片
 *
 * 为什么用「本地代理」而不是只换 host：
 *   实测单 CDN 天花板 3.09 MiB/s，纯换 host（pick-best）只有 2.38 MiB/s，
 *   等分也只有 2.07 —— 真正有效的是「多 CDN 并发」。而 IJK 是自研 FFmpeg 内核，
 *   字节完全不经过 NSURL* 体系，唯一能同时看到 URL 和字节的地方就是
 *   「把 URL 换成 127.0.0.1 上的代理地址」，让播放器自己连过来。
 *
 * 代理行为：
 *   1. 收到 GET，解析出原始 CDN URL 与 Range
 *   2. 把 Range 切成 CHUNK 大小的分片，用 BSPMSPlanner 按「实测速度 + 在途数」
 *      评分派发到多个 CDN host
 *   3. 并发用 NSURLSession 拉取，按序写回给客户端（顺序保证，内存窗口受控）
 *   4. 3 次失败即拉黑该 host；首片超时或全挂则 302 回原始 URL（fail-open，不砸播放）
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BSPProxyServer : NSObject

+ (instancetype)shared;

/* 启动/停止回环监听；start 返回 NO 表示端口没起来 */
- (BOOL)start;
- (void)stop;
- (BOOL)isRunning;
- (uint16_t)port;

/* 原始 CDN URL -> 本地代理 URL（幂等：同一 URL 复用同一 token） */
- (nullable NSString *)localURLFor:(NSString *)originalURL;
/* 反解（仅调试用） */
- (nullable NSString *)originalURLForLocal:(NSString *)localURL;

/* 本次会话的统计报告（多行文本，写进 trace.log 的 [perf] 段） */
- (NSString *)statsReport;

/* 是否把 URL 重写打开（读 Documents/biliprobe/mode.txt，缺省 proxy） */
+ (BOOL)rewriteEnabled;
/* 运行期统计计数，供 verdict 判断 */
- (NSUInteger)totalRequests;
- (NSUInteger)rewrittenURLCount;

@end

NS_ASSUME_NONNULL_END
