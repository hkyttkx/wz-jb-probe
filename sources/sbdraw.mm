//
//  sbdraw.mm
//  跨进程绘制：用 DS 的 RemoteCall 在 SpringBoard 里创建/更新 UIKit 对象
//  ——不注入、不改文件，纯"让别人进程帮你画"
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>
#import "RemoteCall.h"

extern "C" {
uint64_t proc_find_by_name(const char *name);
void ds_sync_kernel_info(void);
int  jb_load(void);
int  jb_init_primitives(void);
const char *jb_status(void);
void offsets_init(void);
void init_offsets(void);
int  ds_run(void);
uint64_t jb_kernel_virtbase(void);
extern uint64_t kernel_base;
extern uint64_t kernel_slide;
}

// ── 复用的远程对象句柄 ────────────────────────────────
static RemoteCall *g_sb = nil;
static uint64_t g_window = 0;
static uint64_t g_box    = 0;      // 一个测试矩形
static uint64_t g_label  = 0;      // 一个测试文字
static int      g_boxIndex = 0;

// ── 小工具：取 selector / class（带缓存）────────────────
static uint64_t S(RemoteCall *p, const char *name) {
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *k = [NSString stringWithUTF8String:name];
    NSNumber *v = cache[k];
    if (v) return v.unsignedLongLongValue;
    uint64_t s = remote_sel(p, name);
    if (s) cache[k] = @(s);
    return s;
}
static uint64_t C(RemoteCall *p, const char *name) {
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *k = [NSString stringWithUTF8String:name];
    NSNumber *v = cache[k];
    if (v) return v.unsignedLongLongValue;
    uint64_t c = remote_getClass(p, name);
    if (c) cache[k] = @(c);
    return c;
}

// 发消息（无参 / 单指针参）
static uint64_t M(RemoteCall *p, uint64_t obj, const char *sel,
                  uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    return remote_msg(p, obj, S(p, sel), a0, a1, a2, a3);
}

// 在远程构造 NSString
static uint64_t SBStr(RemoteCall *p, NSString *s) {
    return remote_NSString(p, s.UTF8String);
}

// 用 NSInvocation 调带 CGRect 参数的方法（UIKit 的 setFrame:/setBounds: 等）
static BOOL InvokeRect(RemoteCall *p, uint64_t target, const char *selName, CGRect r) {
    if (!p || !target) return NO;
    @try {
        uint64_t sel = S(p, selName);
        uint64_t sig = M(p, target, "methodSignatureForSelector:", sel, 0, 0, 0);
        if (!sig) return NO;
        uint64_t invCls = C(p, "NSInvocation");
        uint64_t inv = M(p, invCls, "invocationWithMethodSignature:", sig, 0, 0, 0);
        if (!inv) return NO;
        M(p, inv, "setTarget:", target, 0, 0, 0);
        M(p, inv, "setSelector:", sel, 0, 0, 0);
        // 参数写进 RemoteCall 的 scratch 页
        uint64_t scratch = p.trojanMem + 0x1000;
        if (![p remote_write:scratch from:&r size:sizeof(r)]) return NO;
        M(p, inv, "setArgument:atIndex:", scratch, 2, 0, 0);
        M(p, inv, "invoke", 0, 0, 0, 0);
        return YES;
    } @catch (NSException *e) {
        os_log_error(OS_LOG_DEFAULT, "[sbdraw] InvokeRect 异常: %{public}@", e.reason);
        return NO;
    }
}

// ─────────────────────────────────────────────────────
//  初始化：越狱 kernel r/w + attach SpringBoard
// ─────────────────────────────────────────────────────
extern "C" int SBDrawInit(void) {
    if (g_sb) return 0;

    // ① libjailbreak：绑用户态跨进程读（proc_vreadbuf）
    if (jb_load() != 0) {
        os_log_error(OS_LOG_DEFAULT, "[sbdraw] jb_load 失败: %{public}s", jb_status());
        return -1;
    }

    // ② DS 内核漏洞：拿真正的 kernel r/w（ds_kread64/kwrite64）
    {
        offsets_init();
        init_offsets();
        int dr = ds_run();
        os_log(OS_LOG_DEFAULT, "[sbdraw] ds_run = %d", dr);
        if (dr != 0) return -2;
        // 用 libjailbreak 的 virtBase 修正 DS 算错的 kernel_base
        uint64_t vb = jb_kernel_virtbase();
        if (vb) {
            kernel_base  = vb;
            kernel_slide = vb - 0xfffffff007004000ULL;
            os_log(OS_LOG_DEFAULT, "[sbdraw] kbase 修正为 0x%llx", kernel_base);
        }
    }

    // ③ 定位 SpringBoard
    uint64_t sbProc = proc_find_by_name("SpringBoard");
    if (!sbProc) { os_log_error(OS_LOG_DEFAULT, "[sbdraw] 找不到 SpringBoard"); return -3; }

    // ④ DS 的 RemoteCall attach
    g_sb = [[RemoteCall alloc] initWithProcess:@"SpringBoard" useMigFilterBypass:NO];
    if (!g_sb || g_sb.trojanMem == 0 || g_sb.pid <= 1) {
        os_log_error(OS_LOG_DEFAULT, "[sbdraw] attach 失败");
        g_sb = nil;
        return -4;
    }
    os_log(OS_LOG_DEFAULT, "[sbdraw] attach OK pid=%d", g_sb.pid);
    return 0;
}

// 创建绘制层：一个 UIWindow + 一个红框 + 一行文字
extern "C" int SBDrawCreate(void) {
    if (!g_sb) return -1;

    uint64_t workspaceCls = C(g_sb, "SBMainWorkspace");
    uint64_t windowCls    = C(g_sb, "UIWindow");
    uint64_t viewCls      = C(g_sb, "UIView");
    uint64_t labelCls     = C(g_sb, "UILabel");
    uint64_t colorCls     = C(g_sb, "UIColor");
    if (!workspaceCls || !windowCls || !viewCls || !labelCls || !colorCls) return -2;

    // SpringBoard 的 windowScene
    uint64_t workspace = M(g_sb, workspaceCls, "sharedInstance", 0, 0, 0, 0);
    uint64_t scene = workspace ? M(g_sb, workspace, "mainWindowScene", 0, 0, 0, 0) : 0;
    if (!scene) return -3;

    CGRect scr = UIScreen.mainScreen.bounds;

    // ── 窗口 ──
    uint64_t win = M(g_sb, windowCls, "alloc", 0, 0, 0, 0);
    win = M(g_sb, win, "init", 0, 0, 0, 0);
    if (!win) return -4;
    InvokeRect(g_sb, win, "setFrame:", scr);
    M(g_sb, win, "setWindowScene:", scene, 0, 0, 0);
    // windowLevel = 10000010
    {
        uint64_t scratch = g_sb.trojanMem + 0x1200;
        double lvl = 10000010.0;
        [g_sb remote_write:scratch from:&lvl size:sizeof(lvl)];
        uint64_t sig = M(g_sb, win, "methodSignatureForSelector:", S(g_sb, "setWindowLevel:"), 0, 0, 0);
        uint64_t inv = M(g_sb, C(g_sb, "NSInvocation"), "invocationWithMethodSignature:", sig, 0, 0, 0);
        M(g_sb, inv, "setTarget:", win, 0, 0, 0);
        M(g_sb, inv, "setSelector:", S(g_sb, "setWindowLevel:"), 0, 0, 0);
        M(g_sb, inv, "setArgument:atIndex:", scratch, 2, 0, 0);
        M(g_sb, inv, "invoke", 0, 0, 0, 0);
    }
    M(g_sb, win, "setOpaque:", 0, 0, 0, 0);
    M(g_sb, win, "setUserInteractionEnabled:", 0, 0, 0, 0);
    M(g_sb, win, "setHidden:", 0, 0, 0, 0);
    uint64_t clear = M(g_sb, colorCls, "clearColor", 0, 0, 0, 0);
    M(g_sb, win, "setBackgroundColor:", clear, 0, 0, 0);

    // ── 红框（居中偏上）──
    uint64_t box = M(g_sb, viewCls, "alloc", 0, 0, 0, 0);
    box = M(g_sb, box, "init", 0, 0, 0, 0);
    InvokeRect(g_sb, box, "setFrame:", CGRectMake(scr.size.width/2 - 60, scr.size.height/2 - 120, 120, 160));
    uint64_t red = M(g_sb, colorCls, "redColor", 0, 0, 0, 0);
    M(g_sb, box, "setBackgroundColor:", red, 0, 0, 0);
    M(g_sb, box, "setAlpha:", 0, 0, 0, 0);   // 稍后调
    {
        uint64_t scratch = g_sb.trojanMem + 0x1300;
        double a = 0.45;
        [g_sb remote_write:scratch from:&a size:sizeof(a)];
        uint64_t sig = M(g_sb, box, "methodSignatureForSelector:", S(g_sb, "setAlpha:"), 0, 0, 0);
        uint64_t inv = M(g_sb, C(g_sb, "NSInvocation"), "invocationWithMethodSignature:", sig, 0, 0, 0);
        M(g_sb, inv, "setTarget:", box, 0, 0, 0);
        M(g_sb, inv, "setSelector:", S(g_sb, "setAlpha:"), 0, 0, 0);
        M(g_sb, inv, "setArgument:atIndex:", scratch, 2, 0, 0);
        M(g_sb, inv, "invoke", 0, 0, 0, 0);
    }
    M(g_sb, win, "addSubview:", box, 0, 0, 0);

    // ── 文字 ──
    uint64_t label = M(g_sb, labelCls, "alloc", 0, 0, 0, 0);
    label = M(g_sb, label, "init", 0, 0, 0, 0);
    InvokeRect(g_sb, label, "setFrame:", CGRectMake(scr.size.width/2 - 140, scr.size.height/2 - 160, 280, 40));
    uint64_t white = M(g_sb, colorCls, "whiteColor", 0, 0, 0, 0);
    M(g_sb, label, "setTextColor:", white, 0, 0, 0);
    uint64_t txt = SBStr(g_sb, @"WZ 跨进程绘制测试");
    M(g_sb, label, "setText:", txt, 0, 0, 0);
    M(g_sb, label, "setTextAlignment:", 1, 0, 0, 0);   // center
    M(g_sb, win, "addSubview:", label, 0, 0, 0);

    g_window = win;
    g_box = box;
    g_label = label;
    os_log(OS_LOG_DEFAULT, "[sbdraw] 创建完成 win=0x%llx box=0x%llx label=0x%llx",
           win, box, label);
    return 0;
}

// 移动红框（验证"读取+更新"这一半）
extern "C" int SBDrawTick(void) {
    if (!g_sb || !g_box) return -1;
    CGRect scr = UIScreen.mainScreen.bounds;
    g_boxIndex++;
    CGFloat t = g_boxIndex * 0.15;
    CGFloat x = scr.size.width/2 - 60 + sin(t) * 120.0;
    CGFloat y = scr.size.height/2 - 120 + cos(t) * 80.0;
    InvokeRect(g_sb, g_box, "setFrame:", CGRectMake(x, y, 120, 160));
    if (g_label) {
        NSString *s = [NSString stringWithFormat:@"跨进程绘制 #%d", g_boxIndex];
        M(g_sb, g_label, "setText:", SBStr(g_sb, s), 0, 0, 0);
    }
    return 0;
}

// 移除绘制层
extern "C" void SBDrawDestroy(void) {
    if (!g_sb) return;
    if (g_window) M(g_sb, g_window, "setHidden:", 1, 0, 0, 0);
    os_log(OS_LOG_DEFAULT, "[sbdraw] 已隐藏");
    g_window = g_box = g_label = 0;
}

extern "C" uint64_t SBDrawWindow(void) { return g_window; }
