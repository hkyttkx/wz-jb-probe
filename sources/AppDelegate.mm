//
//  AppDelegate.mm
//  直接用高层级 HUD 窗口承载 ImGui，并注册到 SpringBoard 覆盖到其它 App 之上
//
#import "AppDelegate.h"
#import "HUDWindow.h"
#import "ImGuiViewController.h"
#import <os/log.h>
#import <AVFoundation/AVFoundation.h>

@interface AppDelegate ()
@property (nonatomic, strong) HUDWindow *hudWindow;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) AVAudioPlayer *keepAlive;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    // 注意：ImGui 是全局单例上下文，只能有一份渲染视图，
    // 所以直接把这个高层级窗口作为唯一窗口。
    self.hudWindow = [[HUDWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.hudWindow.windowLevel = 10000010.0;          // 高于游戏窗口
    self.hudWindow.backgroundColor = [UIColor clearColor];
    self.hudWindow.rootViewController = [[ImGuiViewController alloc] init];
    self.hudWindow.hidden = NO;
    [self.hudWindow makeKeyAndVisible];

    // 注册到 SpringBoard 的窗口托管服务
    BOOL ok = HUDRegisterWindow(self.hudWindow);
    os_log(OS_LOG_DEFAULT, "[WZ] HUD register = %d", ok);

    self.window = self.hudWindow;

    // 静音音频保活：让进程在后台不被挂起，HUD 才能一直贴在游戏上
    [self startKeepAlive];
    return YES;
}

- (void)startKeepAlive {
    // 0.1 秒静音 wav（内联构造）
    NSData *wav = [self silentWav];
    if (!wav) return;
    NSError *err = nil;
    self.keepAlive = [[AVAudioPlayer alloc] initWithData:wav error:&err];
    self.keepAlive.numberOfLoops = -1;
    self.keepAlive.volume = 0.0;
    [self.keepAlive prepareToPlay];
    [self.keepAlive play];
    os_log(OS_LOG_DEFAULT, "[WZ] keepalive audio = %@", err ? err : @"ok");
}

- (NSData *)silentWav {
    // 44 字节 WAV 头 + 少量静音采样
    uint32_t sampleRate = 8000, dataLen = 800;
    NSMutableData *d = [NSMutableData data];
    const char *riff = "RIFF"; [d appendBytes:riff length:4];
    uint32_t chunk = 36 + dataLen; [d appendBytes:&chunk length:4];
    const char *wave = "WAVEfmt "; [d appendBytes:wave length:8];
    uint32_t sub1 = 16; [d appendBytes:&sub1 length:4];
    uint16_t fmt = 1, ch = 1, bits = 8; [d appendBytes:&fmt length:2];
    [d appendBytes:&ch length:2]; [d appendBytes:&sampleRate length:4];
    uint32_t byteRate = sampleRate; [d appendBytes:&byteRate length:4];
    uint16_t align = 1; [d appendBytes:&align length:2]; [d appendBytes:&bits length:2];
    const char *data = "data"; [d appendBytes:data length:4];
    [d appendBytes:&dataLen length:4];
    uint8_t zeros[800] = {0}; [d appendBytes:zeros length:dataLen];
    return d;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    os_log(OS_LOG_DEFAULT, "[WZ] 进入后台，申请后台任务延长存活");
    if (self.bgTask == UIBackgroundTaskInvalid || self.bgTask == 0) {
        self.bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
            [application endBackgroundTask:self.bgTask];
            self.bgTask = UIBackgroundTaskInvalid;
        }];
    }
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    if (self.bgTask && self.bgTask != UIBackgroundTaskInvalid) {
        [application endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

@end
