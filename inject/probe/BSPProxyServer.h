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

/* 一行式吞吐摘要（心跳用）：请求/分片/送达字节/累计均速/单请求峰值/改写数 */
- (NSString *)throughputLine;

/* ------------------------------------------------------------------ */
/* 设置面板要用的运行时接口                                            */
/* ------------------------------------------------------------------ */
/* 每台候选 CDN 的当前状态。字典字段：
 *   host(NSString) enabled(BOOL) bytes(NSNumber) speedMiBps(NSNumber)
 *   ok(NSNumber) fail(NSNumber) isOrigin(BOOL)
 * 顺序与候选池一致（原始 host 排第一）。 */
- (NSArray<NSDictionary *> *)hostSnapshot;

/* 启停某台 CDN。内部就是把调度器上的 healthy 置 0/1 ——
 * 这样运行期切换是安全的：在途请求继续用旧索引，新请求立刻按新选择走。 */
- (void)setHost:(NSString *)host enabled:(BOOL)enabled;

/* 一键把所有候选 CDN 都打开（恢复自动调度） */
- (void)enableAllHosts;

/* 改写总开关。true=改写，false=完全不动 URL（播放器直连）。
 * 与启动时读的 mode.txt 是「与」的关系：mode.txt=direct 时此项无效。 */
@property (nonatomic, assign) BOOL rewriteActive;

/* 并发分片大小 / 并发窗口的当前值（面板显示用） */
- (NSInteger)chunkKiB;
- (NSInteger)windowSize;

/* ------------------------------------------------------------------ */
/* 并发档位（省电 / 均衡 / 极速）                                       */
/* ------------------------------------------------------------------ */
/* 为什么需要它：并发不是越多越好 —— 每多一条 TCP+TLS 连接，就多一份
 * 无线电占空、握手加解密和 CDN 侧压力。真机反馈：把窗口上限放到 24、
 * 连接上限放到 24 之后明显发烫。AIMD 只看吞吐，它不知道电费。
 *
 * 于是拆成三档，默认「均衡」：
 *      省电   连接 4   窗口 2..6     长时间看剧、机器烫的时候用
 *      均衡   连接 8   窗口 4..12    A/B 实测过有收益的范围，默认
 *      极速   连接 16  窗口 6..20    短时间拉进度条/换集时用
 *
 * 窗口档位改完**下一个请求就生效**；连接数上限在 NSURLSession 创建时定死，
 * 需要重启 App —— 面板里对这一点有明确提示，不假装能热改。 */
typedef NS_ENUM(NSInteger, BSPPerfPreset) {
    BSPPerfPresetSaver    = 0,
    BSPPerfPresetBalanced = 1,
    BSPPerfPresetSpeed    = 2,
};

NSInteger BSPPerfPresetGet(void);
void      BSPSetPerfPreset(NSInteger preset);
NSString *BSPPerfPresetName(NSInteger preset);

/* ------------------------------------------------------------------ */
/* 现场 A/B 实测                                                       */
/* ------------------------------------------------------------------ */
/* 拿一个真实媒体 URL，在同一时刻、同一网络下做对照：
 *   A：4 个连续分片**串行**从单台 CDN 取（等价于一条连接）
 *   B：同样 4 个分片**并发**发给 4 台不同 CDN
 * 各 2 MiB，比较 MiB/s。
 *
 * 为什么必须实测：前面几轮我一直在用「单台均速」「墙钟聚合」这类间接指标推断，
 * 而它们都建立在真实播放流量上，受码率、缓冲策略、并发请求数影响，无法回答
 * 「并发到底比单连接快还是慢」这个问题本身。只有同样字节、同样区间、背靠背的
 * A/B 才是干净的对照。
 * 只跑一次（首次改写到媒体 URL 之后约 45 秒），结果写进日志与报告。 */
- (void)scheduleBenchmarkWithURL:(NSString *)url;
- (NSString *)benchmarkLine;      /* 最近一次 A/B 结果；没跑过返回 nil */

/* 把代理侧日志接进宿主的日志文件。
 * 必需：NSLog 在侧载 App 里不进 Documents 下的 trace.log，
 * 于是「代理到底跑了多少、多快」这条唯一能量化效果的线索会整条丢失。 */
void BSPProxySetLogSink(void (^sink)(NSString *msg));

/* 日志目录 {Documents}/<名字>（会确保存在）。
 * 公开出来是因为 hooks.txt / mode.txt 这些开关文件都放在这里。
 * 名字可改：探针用 biliprobe，正式模块 BiliFast 用 BiliFast。 */
+ (NSString *)logDir;
+ (void)setLogDirName:(NSString *)name;

/* 是否把 URL 重写打开（读 Documents/biliprobe/mode.txt，缺省 proxy） */
+ (BOOL)rewriteEnabled;
/* 运行期统计计数，供 verdict 判断 */
- (NSUInteger)totalRequests;
- (NSUInteger)rewrittenURLCount;

@end

NS_ASSUME_NONNULL_END
