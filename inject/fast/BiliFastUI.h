/* BiliFastUI.h —— 应用内设置面板的对外入口 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 安装悬浮球 + 设置面板。
 *   isEnabled    读当前「并发加速」开关状态
 *   setEnabled   写该状态（应当立即生效，不需要重启） */
void BiliFastInstallUI(BOOL (^isEnabled)(void), void (^setEnabled)(BOOL));

/* 打开设置面板（也可由用户三指双击触发） */
void BiliFastShowSettings(void);

/* 显示/隐藏悬浮小球。隐藏后入口只剩三指双击。 */
void BiliFastSetBallVisible(BOOL visible);

NS_ASSUME_NONNULL_END
