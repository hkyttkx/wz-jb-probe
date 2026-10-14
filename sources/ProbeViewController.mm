//
//  ProbeViewController.mm
//  以 root 子进程方式运行探测（libjailbreak 要求 uid=0）
//
#import "ProbeViewController.h"
#import <spawn.h>
#import <mach-o/dyld.h>
#import <sys/wait.h>
#import <unistd.h>
#import <string.h>
#import <limits.h>

extern char **environ;
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

@implementation ProbeViewController {
    UITextView *_logView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _logView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _logView.backgroundColor = [UIColor blackColor];
    _logView.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.editable = NO;
    _logView.text = @"启动 root 子进程…";
    _logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_logView];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *text = [self runPrivilegedProbe];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_logView.text = text;
        });
    });
}

- (NSString *)runPrivilegedProbe {
    NSMutableString *L = [NSMutableString string];
    [L appendString:@"=== libjailbreak 探测（root 子进程）===\n\n"];

    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *outPath = [doc stringByAppendingPathComponent:@"probe.txt"];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

    char exe[PATH_MAX];
    uint32_t sz = sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) != 0) {
        [L appendString:@"取自身可执行路径失败\n"];
        return L;
    }
    [L appendFormat:@"自身路径: %s\n", exe];

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // persona 提权：以 uid=0 启动子进程
    posix_spawnattr_set_persona_np(&attr, 99, 1);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    const char *argv[] = { exe, "--probe", outPath.UTF8String, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, NULL, &attr, (char *const *)argv, environ);
    posix_spawnattr_destroy(&attr);

    [L appendFormat:@"posix_spawn(uid=0) = %d  pid=%d\n", rc, (int)pid];
    if (rc != 0) {
        [L appendFormat:@"errno = %d  (%s)\n", rc, strerror(rc)];
        [L appendString:@"\n提权失败 —— participant persona-mgmt entitlement 可能没生效。\n"];
        return L;
    }

    int st = 0;
    waitpid(pid, &st, 0);
    [L appendFormat:@"子进程退出 status=%d\n\n", st];

    NSString *res = [NSString stringWithContentsOfFile:outPath
                                              encoding:NSUTF8StringEncoding error:nil];
    if (res.length) {
        [L appendString:res];
    } else {
        [L appendString:@"未读到结果文件（子进程未写成）\n"];
    }
    return L;
}

@end
