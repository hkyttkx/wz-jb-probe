//
//  HUDMainApplicationDelegate.mm
//  基于 TrollSpeed 原版，替换界面为我们的 ImGuiViewController
//
#import <objc/runtime.h>
#import <os/log.h>

#import "HUDMainApplicationDelegate.h"
#import "HUDMainWindow.h"
#import "ImGuiViewController.h"
#import "SBSAccessibilityWindowHostingController.h"
#import "UIWindow+Private.h"

@implementation HUDMainApplicationDelegate {
    UIViewController *_root;
}

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {

    os_log(OS_LOG_DEFAULT, "[HUDDelegate] didFinishLaunching");

    _root = [[ImGuiViewController alloc] init];

    HUDMainWindow *win = [[HUDMainWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [win setRootViewController:_root];
    [win setWindowLevel:10000010.0];
    [win setBackgroundColor:[UIColor clearColor]];
    [win setHidden:NO];
    [win makeKeyAndVisible];
    self.window = win;

    // 注册到 SpringBoard（用 NSInvocation，避免 ARC 下的 performSelector 警告）
    id hc = [[objc_getClass("SBSAccessibilityWindowHostingController") alloc] init];
    if (hc) {
        unsigned int ctx = [win _contextId];
        double lvl = [win windowLevel];
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:hc];
        [inv setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
        [inv setArgument:&ctx atIndex:2];
        [inv setArgument:&lvl atIndex:3];
        [inv invoke];
        os_log(OS_LOG_DEFAULT, "[HUDDelegate] 注册窗口 ctx=%u level=%.0f", ctx, lvl);
    }
    return YES;
}

@end
