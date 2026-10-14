//
//  HUDWindow.h
//  覆盖在所有 App（含全屏游戏）之上的窗口
//
#import <UIKit/UIKit.h>

@interface HUDWindow : UIWindow
@end

// 注册到 SpringBoard 的窗口托管服务
@interface SBSAccessibilityWindowHostingController : NSObject
- (void)registerWindowWithContextID:(unsigned int)contextID atLevel:(double)level;
@end

@interface UIWindow (HUDPrivate)
- (unsigned int)_contextId;
@end

#ifdef __cplusplus
extern "C" {
#endif

// 触摸穿透控制（YES = 点到下层，游戏可操作）
void HUDSetPassthrough(BOOL v);
BOOL HUDGetPassthrough(void);

// 注册/取消注册到 SpringBoard
BOOL HUDRegisterWindow(HUDWindow *win);

// 覆盖模式开关：YES=悬浮在所有 App 之上；NO=普通 App 窗口
void HUDSetOverlayMode(HUDWindow *win, BOOL overlay);

#ifdef __cplusplus
}
#endif
