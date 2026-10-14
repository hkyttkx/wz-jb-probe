//
//  HUDWindow.mm
//
#import "HUDWindow.h"
#import <objc/message.h>
#import <os/log.h>

static BOOL gHUDPassthrough = NO;      // 触摸穿透
static BOOL gHUDOverlay     = NO;      // 是否处于覆盖模式

void HUDSetPassthrough(BOOL v) { gHUDPassthrough = v; }
BOOL HUDGetPassthrough(void)   { return gHUDPassthrough; }

@implementation HUDWindow

- (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return gHUDOverlay ? NO : [super _isWindowServerHostingManaged]; }
- (BOOL)_ignoresHitTest { return gHUDPassthrough; }
- (BOOL)_isSecure {
    // 覆盖模式下用安全窗口（不被录屏抓到）；普通模式恢复常规
    return gHUDOverlay ? YES : [super _isSecure];
}

@end

BOOL HUDRegisterWindow(HUDWindow *win) {
    if (!win) return NO;
    Class cls = objc_getClass("SBSAccessibilityWindowHostingController");
    if (!cls) { os_log(OS_LOG_DEFAULT, "[HUD] 无 SBSAccessibilityWindowHostingController"); return NO; }
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
    os_log(OS_LOG_DEFAULT, "[HUD] 已注册 ctx=%u level=%.0f", ctx, win.windowLevel);
    return YES;
}

void HUDSetOverlayMode(HUDWindow *win, BOOL overlay) {
    if (!win) return;
    gHUDOverlay = overlay;
    if (overlay) {
        win.windowLevel = 10000010.0;   // 高于游戏窗口
        HUDRegisterWindow(win);
    } else {
        win.windowLevel = UIWindowLevelNormal;  // 回到普通 App 层级
        HUDSetPassthrough(NO);
    }
    os_log(OS_LOG_DEFAULT, "[HUD] overlay=%d level=%.0f", overlay, win.windowLevel);
}
