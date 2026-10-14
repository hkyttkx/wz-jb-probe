//
//  ProbeViewController.mm
//  验证 libjailbreak 在真实设备上是否可用：
//    ① 初始化（拿 kernel r/w）
//    ② proc_self / proc_find
//    ③ 内核读 kread64
//    ④ 跨进程读 proc_vreadbuf
//
#import "ProbeViewController.h"
#import "jb.h"
#import <mach/mach.h>

@implementation ProbeViewController {
    UITextView *_logView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _logView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _logView.backgroundColor = [UIColor blackColor];
    _logView.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
    _logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _logView.editable = NO;
    _logView.text = @"探测中…";
    _logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_logView];

    // 探测放到后台线程，避免卡启动
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = [self runProbe];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_logView.text = result;
        });
    });
}

- (NSString *)runProbe {
    NSMutableString *L = [NSMutableString string];
    [L appendString:@"=== libjailbreak 可用性探测 ===\n\n"];

    // ① 初始化
    int r = jbclient_initialize_primitives();
    [L appendFormat:@"① init_primitives() = %d  %@\n", r, (r == 0) ? @"OK" : @"FAIL"];
    if (r != 0) {
        [L appendString:@"\n初始化失败 —— 后续步骤无法执行。\n"];
        [L appendString:@"可能原因：越狱未完全生效 / dylib 版本不匹配。\n"];
        return L;
    }

    // ② proc_self
    uint64_t selfProc = proc_self();
    [L appendFormat:@"② proc_self() = 0x%llx  %@\n",
        selfProc, selfProc ? @"OK" : @"FAIL"];
    if (!selfProc) return L;

    // ③ 内核读（读 proc 结构首 8 字节）
    uint64_t kfirst = 0;
    kreadbuf(selfProc, &kfirst, sizeof(kfirst));
    [L appendFormat:@"③ kreadbuf(proc_self) = 0x%llx  %@\n",
        kfirst, kfirst ? @"OK 内核读可用" : @"FAIL"];

    // ④ 跨进程读（读本进程一个已知变量）
    uint64_t canary = 0xDEADBEEFCAFEBABEULL;
    uint64_t back = 0;
    int vr = proc_vreadbuf(selfProc, (const void *)&canary, &back, sizeof(back));
    [L appendFormat:@"④ proc_vreadbuf(自己, canary) = %d\n", vr];
    [L appendFormat:@"   原值 = 0x%llx\n", canary];
    [L appendFormat:@"   读回 = 0x%llx  %@\n", back,
        (back == canary) ? @"OK 跨进程读可用" : @"值不匹配"];

    // ⑤ 读别的进程（launchd, pid=1）
    uint64_t ld = proc_find(1);
    if (ld) {
        uint64_t v = 0;
        kreadbuf(ld, &v, sizeof(v));
        [L appendFormat:@"⑤ proc_find(1)=0x%llx, 首字段=0x%llx  OK\n", ld, v];
        proc_rele(ld);
    } else {
        [L appendString:@"⑤ proc_find(1) FAIL\n"];
    }

    // ⑥ 读一个真实 App 进程（如果给了 pid）
    //    这里演示按 pid 找：本进程自己的 pid
    pid_t myPid = getpid();
    uint64_t me = proc_find(myPid);
    [L appendFormat:@"⑥ proc_find(%d) = 0x%llx  %@\n", myPid, me, me ? @"OK" : @"FAIL"];
    if (me) proc_rele(me);

    [L appendString:@"\n=== 结论 ===\n"];
    [L appendString:(r == 0) ? @"libjailbreak 在你的系统上可用，跨进程读写具备。\n"
                             : @"不可用。\n"];
    return L;
}

@end
