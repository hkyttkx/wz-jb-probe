//
//  ProbeViewController.mm
//  验证 libjailbreak（运行时加载设备上那份）是否可用
//
#import "ProbeViewController.h"
#import "jb.h"
#import <mach/mach.h>
#import <unistd.h>

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
    _logView.text = @"加载中…";
    _logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_logView];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = [self runProbe];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_logView.text = result;
        });
    });
}

- (NSString *)runProbe {
    NSMutableString *L = [NSMutableString string];
    [L appendString:@"=== libjailbreak 探测 ===\n\n"];

    // ① 运行时加载设备上的 libjailbreak
    int lr = jb_load();
    [L appendFormat:@"① jb_load() = %d  %@\n", lr, (lr == 0) ? @"OK" : @"FAIL"];
    [L appendFormat:@"%@\n", [NSString stringWithUTF8String:jb_status()]];
    if (lr != 0) {
        [L appendString:@"\n加载失败 —— 无法继续。\n"];
        return L;
    }

    // ② 初始化 primitives
    int r = jb_init_primitives();
    [L appendFormat:@"② init_primitives() = %d  %@\n", r, (r == 0) ? @"OK" : @"FAIL"];
    if (r != 0) {
        [L appendString:@"\n初始化失败。\n"];
        return L;
    }

    // ③ proc_self
    uint64_t selfProc = jb_proc_self();
    [L appendFormat:@"③ proc_self() = 0x%llx  %@\n", selfProc, selfProc ? @"OK" : @"FAIL"];
    if (!selfProc) return L;

    // ④ 内核读
    uint64_t kf = 0;
    jb_kreadbuf(selfProc, &kf, sizeof(kf));
    [L appendFormat:@"④ kreadbuf(proc_self) = 0x%llx  %@\n", kf, kf ? @"OK" : @"FAIL"];

    // ⑤ 跨进程读（本进程已知变量）
    uint64_t canary = 0xDEADBEEFCAFEBABEULL;
    uint64_t back = 0;
    int vr = jb_proc_vreadbuf(selfProc, (const void *)&canary, &back, sizeof(back));
    [L appendFormat:@"⑤ proc_vreadbuf(自己) = %d\n", vr];
    [L appendFormat:@"   原值 0x%llx\n", canary];
    [L appendFormat:@"   读回 0x%llx  %@\n", back, (back == canary) ? @"OK 跨进程读可用" : @"不匹配"];

    // ⑥ 读别的进程
    uint64_t ld = jb_proc_find(1);
    if (ld) {
        uint64_t v = 0;
        jb_kreadbuf(ld, &v, sizeof(v));
        [L appendFormat:@"⑥ proc_find(1)=0x%llx 首字段=0x%llx OK\n", ld, v];
        jb_proc_rele(ld);
    } else {
        [L appendString:@"⑥ proc_find(1) FAIL\n"];
    }

    [L appendString:@"\n=== 结论 ===\n"];
    [L appendString:(r == 0) ? @"libjailbreak 可用，跨进程读写具备。\n" : @"不可用。\n"];
    return L;
}

@end
