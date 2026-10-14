//
//  HUDHost.h/.mm 合体 — root 子进程用的自建 UIApplication 宿主
//  作用：脱离"前台 App"限制，接管系统 HID 事件，让 HUD 在后台也能触摸
//
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

typedef struct __IOHIDEvent *IOHIDEvent;
typedef struct __IOHIDService *IOHIDService;

extern "C" {
void GSInitialize(void);
void UIApplicationInitialize(void);
void BKSDisplayServicesStart(void);
void GSEventInitialize(Boolean registerPurple);
void GSEventPushRunLoopMode(CFStringRef mode);
void UIApplicationInstantiateSingleton(id aclass);
void *BKSHIDEventRegisterEventCallback(void (*cb)(void *, void *, IOHIDService, IOHIDEvent));
}

@interface UIApplication (HUDHostPrivate)
- (void)_accessibilityInit;
- (void)__completeAndRunAsPlugin;
- (void)_enqueueHIDEvent:(IOHIDEvent)event;
@end

// 系统 HID 事件 → UIApplication
static void HUDHIDCallback(void *target, void *refcon, IOHIDService service, IOHIDEvent event) {
    static UIApplication *app = [UIApplication sharedApplication];
    if (event && app) [app _enqueueHIDEvent:event];
}

@interface HUDHostApplication : UIApplication
@end
@implementation HUDHostApplication
@end

@interface HUDHostDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation HUDHostDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 复用同一个 ImGui 视图控制器
    Class vcCls = NSClassFromString(@"ImGuiViewController");
    UIViewController *vc = vcCls ? [[vcCls alloc] init] : [[UIViewController alloc] init];

    Class winCls = NSClassFromString(@"HUDWindow");
    UIWindow *win = winCls ? [[winCls alloc] initWithFrame:[UIScreen mainScreen].bounds]
                           : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    win.windowLevel = 10000010.0;
    win.backgroundColor = [UIColor clearColor];
    win.rootViewController = vc;
    win.hidden = NO;
    [win makeKeyAndVisible];
    self.window = win;

    // 注册到 SpringBoard 窗口托管
    SEL reg = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    Class hc = objc_getClass("SBSAccessibilityWindowHostingController");
    if (hc && [win respondsToSelector:NSSelectorFromString(@"_contextId")]) {
        id ctrl = [[hc alloc] init];
        unsigned ctx = ((unsigned int (*)(id, SEL))objc_msgSend)(win, NSSelectorFromString(@"_contextId"));
        if ([ctrl respondsToSelector:reg]) {
            ((void (*)(id, SEL, unsigned, double))objc_msgSend)(ctrl, reg, ctx, win.windowLevel);
            os_log(OS_LOG_DEFAULT, "[HUDHost] window registered ctx=%u", ctx);
        }
    }
    os_log(OS_LOG_DEFAULT, "[HUDHost] 宿主启动完成");
    return YES;
}

@end

// 由 main.mm 在 --hud 模式下调用；此函数不返回
int HUDHostRun(void) {
    @autoreleasepool {
        [UIScreen initialize];
        CFRunLoopGetCurrent();
        GSInitialize();
        BKSDisplayServicesStart();
        UIApplicationInitialize();
        UIApplicationInstantiateSingleton([HUDHostApplication class]);

        static HUDHostDelegate *delegate = nil;
        delegate = [[HUDHostDelegate alloc] init];
        [[UIApplication sharedApplication] setDelegate:delegate];

        [[UIApplication sharedApplication] _accessibilityInit];
        [[UIApplication sharedApplication] __completeAndRunAsPlugin];

        [NSRunLoop currentRunLoop];
        BKSHIDEventRegisterEventCallback(HUDHIDCallback);   // ★ 接管全局触摸

        GSEventInitialize(0);
        GSEventPushRunLoopMode(kCFRunLoopDefaultMode);

        os_log(OS_LOG_DEFAULT, "[HUDHost] 进入 CFRunLoop");
        CFRunLoopRun();
    }
    return 0;
}
    }
    return 0;
}
