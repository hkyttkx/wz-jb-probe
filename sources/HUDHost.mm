//
//  HUDHost.mm
//  root HUD 宿主进程 —— 采用 TrollSpeed 验证过的事件机制：
//    HID 事件 → AXEventRepresentation → TSEventFetcher → [UIApplication sendEvent:]
//  注意：iOS 15.1+ 不能再用 _enqueueHIDEvent（会拖垮 SpringBoard）。
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <notify.h>

#import "HUDMainApplication.h"
#import "HUDMainApplicationDelegate.h"
#import "TSEventFetcher.h"
#import "AXEventRepresentation.h"
#import "AXEventHandInfoRepresentation.h"
#import "AXEventPathInfoRepresentation.h"
#import "UIApplication+Private.h"
#import "BackboardServices.h"

// 私有符号：由 Vendor/tbd 里的 .tbd 提供
extern "C" {
void GSInitialize(void);
void UIApplicationInitialize(void);
void BKSDisplayServicesStart(void);
void GSEventInitialize(Boolean registerPurple);
void GSEventPushRunLoopMode(CFStringRef mode);
void UIApplicationInstantiateSingleton(id aclass);
void *BKSHIDEventRegisterEventCallback(void (*cb)(void *, void *, IOHIDServiceRef, IOHIDEventRef));
int HUDHostRun(void);
}

// ─────────────────────────────────────────────
//  HID → AXEvent → UITouch（TrollSpeed 的做法）
// ─────────────────────────────────────────────
static void _HUDEventCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    static UIApplication *app = [UIApplication sharedApplication];
    if (!event) return;

    static Class AXRepCls = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework"] load];
        AXRepCls = objc_getClass("AXEventRepresentation");
    });
    if (!AXRepCls) return;

    AXEventRepresentation *rep = [AXRepCls representationWithHIDEvent:event
                                                   hidStreamIdentifier:@"UIApplicationEvents"];
    if (!rep) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [[app windows] firstObject];
        if (!keyWindow) return;
        UIWindow *searchWin = keyWindow;
        UIView *keyView = [searchWin hitTest:[rep location] withEvent:nil];

        UITouchPhase phase = UITouchPhaseEnded;
        if ([rep isTouchDown])      phase = UITouchPhaseBegan;
        else if ([rep isMove])      phase = UITouchPhaseMoved;
        else if ([rep isCancel])    phase = UITouchPhaseCancelled;
        else if ([rep isLift] || [rep isInRange] || [rep isInRangeLift])
                                    phase = UITouchPhaseEnded;

        NSInteger pointerId = [[[[rep handInfo] paths] firstObject] pathIdentity];
        if (pointerId > 0) {
            [TSEventFetcher receiveAXEventID:MIN(MAX(pointerId, 1), 98)
                          atGlobalCoordinate:[rep location]
                              withTouchPhase:phase
                                    inWindow:searchWin
                                      onView:keyView];
        }
    });
}

// ─────────────────────────────────────────────
//  启动 root HUD 宿主
// ─────────────────────────────────────────────
// 让 UI 知道自己是 HUD 宿主进程（默认悬浮+收起）
extern "C" int gHUDHostMode = 0;

extern "C" int HUDHostRun(void) {
    @autoreleasepool {
        gHUDHostMode = 1;
        os_log(OS_LOG_DEFAULT, "[HUDHost] 启动");

        [UIScreen initialize];
        CFRunLoopGetCurrent();

        GSInitialize();
        BKSDisplayServicesStart();
        UIApplicationInitialize();

        UIApplicationInstantiateSingleton(objc_getClass("HUDMainApplication"));

        static id<UIApplicationDelegate> delegate = nil;
        delegate = [[objc_getClass("HUDMainApplicationDelegate") alloc] init];
        [[UIApplication sharedApplication] setDelegate:delegate];
        [[UIApplication sharedApplication] _accessibilityInit];

        [NSRunLoop currentRunLoop];

        // ★ 接管系统 HID
        BKSHIDEventRegisterEventCallback(_HUDEventCallback);

        GSEventInitialize(0);
        GSEventPushRunLoopMode(kCFRunLoopDefaultMode);

        [[UIApplication sharedApplication] __completeAndRunAsPlugin];

        // SpringBoard 重启后自动恢复
        static int sbToken;
        notify_register_dispatch("SBSpringBoardDidLaunchNotification", &sbToken,
                                 dispatch_get_main_queue(), ^(int token) {
            notify_cancel(token);
            os_log(OS_LOG_DEFAULT, "[HUDHost] SpringBoard 重启，退出宿主");
            kill(getpid(), SIGKILL);
        });

        os_log(OS_LOG_DEFAULT, "[HUDHost] 进入 CFRunLoop");
        CFRunLoopRun();
    }
    return 0;
}
