//
//  AppDelegate.mm
//
#import "AppDelegate.h"
#import "ImGuiViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ImGuiViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
