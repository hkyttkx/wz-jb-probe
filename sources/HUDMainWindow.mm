//
//  HUDMainWindow.mm  (TrollSpeed 原版基础上调整)
//  注意：TrollSpeed 原本 _ignoresHitTest=YES（纯显示不拦截）。
//        我们需要点悬浮球，改成 NO；因为窗口尺寸只覆盖球/菜单那块，
//        不会挡住游戏的其它区域。
//
#import "HUDMainWindow.h"

@implementation HUDMainWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return NO; }      // 拦截（要能点）
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }

@end
