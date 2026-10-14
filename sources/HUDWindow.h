//
//  HUDWindow.h
//  覆盖在所有 App（含全屏游戏）之上的窗口
//
#import <UIKit/UIKit.h>

@interface HUDWindow : UIWindow
@end

// 注册到 SpringBoard 的窗口托管服务（Superman 同款机制）
@interface SBSAccessibilityWindowHostingController : NSObject
- (void)registerWindowWithContextID:(unsigned int)contextID atLevel:(double)level;
@end

@interface UIWindow (HUDPrivate)
- (unsigned int)_contextId;
@end

// 触摸穿透控制（YES = 点到下层游戏）
void HUDSetPassthrough(BOOL v);
BOOL HUDGetPassthrough(void);

// 把窗口注册到 SpringBoard 的窗口托管服务
BOOL HUDRegisterWindow(HUDWindow *win);
