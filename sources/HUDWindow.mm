//
//  HUDWindow.mm
//
#import "HUDWindow.h"
#import <objc/message.h>
#import <os/log.h>

static BOOL gHUDPassthrough = NO;
static BOOL gHUDOverlay     = NO;

void HUDSetPassthrough(BOOL v) { gHUDPassthrough = v; }
BOOL HUDGetPassthrough(void)   { return gHUDPassthrough; }

@implementation HUDWindow

- (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return gHUDOverlay ? NO : YES; }
- (BOOL)_ignoresHitTest { return gHUDPassthrough; }
- (BOOL)_isSecure { return gHUDOverlay ? YES : NO; }

@end

BOOL HUDRegisterWindow(HUDWindow *win) {
    if (!win) return NO;
    Class cls = objc_getClass("SBSAccessibilityWindowHostingController");
    if (!cls) { os_log(OS_LOG_DEFAULT, "[HUD] 无 hosting controller"); return NO; }
    id ctrl = ((id (*)(id, SEL))objc_msgSend)([cls alloc], sel_registerName("init"));
    SEL sel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if (!ctrl || ![ctrl respondsToSelector:sel]) return NO;
    unsigned int ctx = 0;
    SEL ctxSel = NSSelectorFromString(@"_contextId");
    if ([win respondsToSelector:ctxSel])
        ctx = ((unsigned int (*)(id, SEL))objc_msgSend)(win, ctxSel);
    ((void (*)(id, SEL, unsigned int, double))objc_msgSend)(ctrl, sel, ctx, win.windowLevel);
    os_log(OS_LOG_DEFAULT, "[HUD] 注册 ctx=%u level=%.0f", ctx, win.windowLevel);
    return YES;
}

void HUDSetOverlayMode(HUDWindow *win, BOOL overlay) {
    if (!win) return;
    gHUDOverlay = overlay;
    if (overlay) {
        win.windowLevel = 10000010.0;
        HUDRegisterWindow(win);
    } else {
        win.windowLevel = UIWindowLevelNormal;
        HUDSetPassthrough(NO);
    }
    os_log(OS_LOG_DEFAULT, "[HUD] overlay=%d level=%.0f", overlay, win.windowLevel);
}
