//
//  HUDWindow.mm
//
#import "HUDWindow.h"
#import <objc/message.h>
#import <os/log.h>

// 全局：是否让点击穿透到下层（游戏）
static BOOL gHUDPassthrough = NO;

void HUDSetPassthrough(BOOL v) { gHUDPassthrough = v; }
BOOL HUDGetPassthrough(void) { return gHUDPassthrough; }

@implementation HUDWindow

// 冒充系统窗口
+ (BOOL)_isSystemWindow { return YES; }
// 不归 WindowServer 常规托管，才能悬浮在别的 App 之上
- (BOOL)_isWindowServerHostingManaged { return NO; }
// 触摸穿透开关
- (BOOL)_ignoresHitTest { return gHUDPassthrough; }
// 安全窗口（不被录屏/截屏捕获）
- (BOOL)_isSecure { return YES; }

@end

// 注册/注销窗口到 SpringBoard
BOOL HUDRegisterWindow(HUDWindow *win) {
    if (!win) return NO;
    Class cls = objc_getClass("SBSAccessibilityWindowHostingController");
    if (!cls) {
        os_log(OS_LOG_DEFAULT, "[HUD] SBSAccessibilityWindowHostingController 不存在");
        return NO;
    }
    id ctrl = ((id (*)(id, SEL))objc_msgSend)([cls alloc], sel_registerName("init"));
    SEL sel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if (!ctrl || ![ctrl respondsToSelector:sel]) {
        os_log(OS_LOG_DEFAULT, "[HUD] 注册选择器不可用");
        return NO;
    }
    unsigned int ctx = 0;
    SEL ctxSel = NSSelectorFromString(@"_contextId");
    if ([win respondsToSelector:ctxSel]) {
        ctx = ((unsigned int (*)(id, SEL))objc_msgSend)(win, ctxSel);
    }
    ((void (*)(id, SEL, unsigned int, double))objc_msgSend)(ctrl, sel, ctx, win.windowLevel);
    os_log(OS_LOG_DEFAULT, "[HUD] 已注册 window ctx=%u level=%.0f", ctx, win.windowLevel);
    return YES;
}
