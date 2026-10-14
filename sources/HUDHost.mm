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

// 私有符号全部用 dlsym 动态取（都在 dyld shared cache 里，无需链接私有框架）
#import <dlfcn.h>

typedef void (*fn_v)(void);
typedef void (*fn_i)(int);
typedef void *(*fn_hid)(void (*)(void *, void *, IOHIDService, IOHIDEvent));
typedef void (*fn_id)(id);

static fn_v  p_GSInitialize      = NULL;
static fn_v  p_UIAppInitialize   = NULL;
static fn_id p_UIAppInstantiate  = NULL;
static fn_i  p_GSEventInitialize = NULL;
static fn_i  p_GSEventPushMode   = NULL;
static fn_v  p_BKSDisplayStart   = NULL;
static fn_hid p_BKSHIDRegister   = NULL;

static void HUDHostResolve(void) {
    dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
           RTLD_NOW | RTLD_GLOBAL);
    dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
           RTLD_NOW | RTLD_GLOBAL);
    p_GSInitialize     = (fn_v)dlsym(RTLD_DEFAULT, "GSInitialize");
    p_UIAppInitialize  = (fn_v)dlsym(RTLD_DEFAULT, "UIApplicationInitialize");
    p_UIAppInstantiate = (fn_id)dlsym(RTLD_DEFAULT, "UIApplicationInstantiateSingleton");
    p_GSEventInitialize= (fn_i)dlsym(RTLD_DEFAULT, "GSEventInitialize");
    p_GSEventPushMode  = (fn_i)dlsym(RTLD_DEFAULT, "GSEventPushRunLoopMode");
    p_BKSDisplayStart  = (fn_v)dlsym(RTLD_DEFAULT, "BKSDisplayServicesStart");
    p_BKSHIDRegister   = (fn_hid)dlsym(RTLD_DEFAULT, "BKSHIDEventRegisterEventCallback");
    os_log(OS_LOG_DEFAULT, "[HUDHost] syms ok=%d (GS=%p UIAI=%p UIAIS=%p BKS=%p HID=%p)",
           (p_GSInitialize && p_UIAppInitialize && p_UIAppInstantiate),
           p_GSInitialize, p_UIAppInitialize, p_UIAppInstantiate,
           p_BKSDisplayStart, p_BKSHIDRegister);
}

extern "C" int HUDHostRun(void);

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
extern "C" int HUDHostRun(void) {
    @autoreleasepool {
        [UIScreen initialize];
        CFRunLoopGetCurrent();

        HUDHostResolve();
        if (p_GSInitialize)     p_GSInitialize();
        if (p_BKSDisplayStart)  p_BKSDisplayStart();
        if (p_UIAppInitialize)  p_UIAppInitialize();
        if (p_UIAppInstantiate) p_UIAppInstantiate([HUDHostApplication class]);

        static HUDHostDelegate *delegate = nil;
        delegate = [[HUDHostDelegate alloc] init];
        [[UIApplication sharedApplication] setDelegate:delegate];

        [[UIApplication sharedApplication] _accessibilityInit];
        [[UIApplication sharedApplication] __completeAndRunAsPlugin];

        [NSRunLoop currentRunLoop];
        if (p_BKSHIDRegister) p_BKSHIDRegister(HUDHIDCallback);   // ★ 接管全局触摸

        if (p_GSEventInitialize) p_GSEventInitialize(0);
        if (p_GSEventPushMode)
            ((void (*)(CFStringRef))p_GSEventPushMode)(kCFRunLoopDefaultMode);

        os_log(OS_LOG_DEFAULT, "[HUDHost] 进入 CFRunLoop");
        CFRunLoopRun();
    }
    return 0;
}
