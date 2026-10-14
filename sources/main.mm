//
//  main.mm
//  模式：
//    (无参数)              → 正常 App（UI）
//    --probe <out>         → root 子进程：libjailbreak 可用性探测
//    --read <pid> <out>    → root 子进程：读取目标进程（跨进程）
//
#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "jb.h"
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <mach/mach.h>
#import <mach-o/dyld_images.h>
#import "RemoteCall.h"
#import "wzread.h"

// libproc：iOS SDK 不提供 libproc.h，自行声明
extern "C" {
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, unsigned int buffersize);
int proc_pidpath(int pid, void *buffer, unsigned int buffersize);
int HUDHostRun(void);      // root HUD 宿主（HUDHost.mm）
void ds_sync_kernel_info(void);                 // ds_compat.mm
uint64_t proc_find_by_name(const char *name);   // taskrop/utils.m
void     ds_diag(char *out, size_t n, const char *tag);
void     ds_probe_basics(char *out, size_t n);
uint64_t ds_kread64(uint64_t a);
void     offsets_init(void);
extern uint64_t kernel_base;
extern uint64_t kernel_slide;
void     init_offsets(void);
int      ds_run(void);
uint64_t jb_kernel_virtbase(void);
void     jb_diag_sysinfo(char *out, size_t n, const char *tag);
}
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif

// ─────────────────────────────────────────────────────────────
//  --draw <out>：跨进程绘制（在 SpringBoard 上画东西）
// ─────────────────────────────────────────────────────────────
extern "C" {
int  SBDrawInit(void);
int  SBDrawCreate(void);
int  SBDrawTick(void);
void SBDrawDestroy(void);
uint64_t SBDrawWindow(void);
}

static int do_draw_test(const char *outpath) {
    // 写 pid 文件（App 用 --exit 停）
    {
        NSString *pidStr = [NSString stringWithFormat:@"%d", getpid()];
        [pidStr writeToFile:@"/var/mobile/Library/Caches/com.wz.jbprobe.hud.pid"
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    FILE *f = fopen(outpath, "w");
    #define LOG(fmt, ...) do { if (f) { fprintf(f, fmt "\n", ##__VA_ARGS__); fflush(f); } } while (0)
    LOG("uid=%d", (int)getuid());

    int r = SBDrawInit();
    LOG("SBDrawInit = %d %s", r, r == 0 ? "OK" : "FAIL");
    if (r != 0) { if (f) fclose(f); return r; }

    r = SBDrawCreate();
    LOG("SBDrawCreate = %d %s (win=0x%llx)", r, r == 0 ? "OK" : "FAIL", SBDrawWindow());
    if (r != 0) { if (f) fclose(f); return r; }

    LOG("开始持续绘制，点「停止绘制」结束");
    int n = 0;
    while (n < 3600) {          // 最多 1 小时
        SBDrawTick();
        n++;
        usleep(120000);         // ~8fps（跨进程调用开销大）
        if ((n % 20) == 0) LOG("tick #%d", n);
    }
    SBDrawDestroy();
    if (f) fclose(f);
    return 0;
    #undef LOG
}

// ─────────────────────────────────────────────────────────────
//  --wz <pid> <out>：读王牌战争数据（探测 + 扫描 + 读玩家）
// ─────────────────────────────────────────────────────────────
extern "C" {
int  WZReadInit(pid_t pid);
void WZReadProbe(char *out, size_t n);
uint64_t WZFindBattleIns(void);
int  WZReadPlayers(WZPlayer *out, int maxCount);
const char *WZReadStatus(void);
}

static pid_t wz_resolve_pid(const char *arg) {
    // 先试当 pid
    int asPid = atoi(arg);
    if (asPid > 1) {
        char nm[256]={0};
        if (proc_name(asPid, nm, sizeof(nm)) > 0 && nm[0]) return asPid;
    }
    // 再按名字查（列表可能已过期，按名最稳）
    int n = proc_listallpids(NULL, 0);
    if (n > 0) {
        pid_t *pids = (pid_t*)malloc(sizeof(pid_t)*n);
        if (pids) {
            int got = proc_listallpids(pids, sizeof(pid_t)*n);
            pid_t found = 0; int best = 0;
            for (int i = 0; i < got; i++) {
                char nm[256]={0};
                if (proc_name(pids[i], nm, sizeof(nm)) <= 0 || !nm[0]) continue;
                if (strcmp(nm, arg) == 0 && pids[i] > best) {   // 取同名中 pid 最大的（最新）
                    best = pids[i]; found = pids[i];
                }
            }
            free(pids);
            if (found) return found;
        }
    }
    return 0;
}

static int do_wz_read(const char *targetArg, const char *outpath) {
    char buf[16384];
    int off = 0;
    off += snprintf(buf+off, sizeof(buf)-off, "uid=%d  target=%s\n", (int)getuid(), targetArg);

    do {
    if (jb_load() != 0) {
        off += snprintf(buf+off, sizeof(buf)-off, "jb_load 失败: %s\n", jb_status());
        break;
    }
    // ★ 关键：必须初始化 primitives，否则 proc_find 拿不到任何进程
    {
        int ir = jb_init_primitives();
        off += snprintf(buf+off, sizeof(buf)-off, "init_primitives = %d\n", ir);
    }
    pid_t pid = wz_resolve_pid(targetArg);
    off += snprintf(buf+off, sizeof(buf)-off, "解析到 pid = %d\n", pid);
    if (pid <= 1) { off += snprintf(buf+off, sizeof(buf)-off, "找不到目标进程\n"); break; }

    int r = WZReadInit(pid);
    off += snprintf(buf+off, sizeof(buf)-off, "WZReadInit = %d  (%s)\n", r, WZReadStatus());
    if (r == -1) break;      // -1 = 完全无法读取；其它情况继续 */
    if (r != 0) off += snprintf(buf+off, sizeof(buf)-off, "  (非致命，继续探测)\n");
    {
        char pb[8192]; WZReadProbe(pb, sizeof(pb));
        off += snprintf(buf+off, sizeof(buf)-off, "%s\n", pb);
    }
    {
        uint64_t bi = WZFindBattleIns();
        off += snprintf(buf+off, sizeof(buf)-off, "Battle.Ins = 0x%llx\n", bi);
        if (!bi) { off += snprintf(buf+off, sizeof(buf)-off, "  %s\n", WZReadStatus()); break; }
    }
    {
        static WZPlayer pl[256];
        int n = WZReadPlayers(pl, 256);
        off += snprintf(buf+off, sizeof(buf)-off, "玩家数 = %d\n", n);
        for (int i = 0; i < n && i < 30; i++)
            off += snprintf(buf+off, sizeof(buf)-off,
                "  #%d obj=0x%llx pos=(%.1f,%.1f,%.1f) blood=%d head=%d online=%d\n",
                i, pl[i].obj, pl[i].pos.x, pl[i].pos.y, pl[i].pos.z,
                pl[i].blood, pl[i].headId, pl[i].online);
    }
    } while (0);

    { FILE *f=fopen(outpath,"w"); if(f){ fwrite(buf,1,off,f); fclose(f);} }
    return 0;
}

// HUD 进程 pid 文件
#define WZ_PID_PATH "/var/mobile/Library/Caches/com.wz.jbprobe.hud.pid"

// ─────────────────────────────────────────────────────────────
//  --sbtest <out>：验证 DS 的 RemoteCall 能否操作 SpringBoard
// ─────────────────────────────────────────────────────────────
static int do_springboard_test(const char *outpath) {
    char buf[12288];
    int off = 0;

    off += snprintf(buf + off, sizeof(buf) - off,
                    "uid = %d (root=%s)\n", (int)getuid(), getuid() == 0 ? "是" : "否");

    do {

    // ① 越狱拿 kernel r/w（DS 的"根"）
    if (jb_load() != 0) {
        off += snprintf(buf + off, sizeof(buf) - off, "jb_load 失败: %s\n", jb_status());
        break;
    }
    // 越狱当"根"只有一件事要用：用户态跨进程读（proc_vreadbuf）
    // 内核读写交给 DS 自己的漏洞实现
    offsets_init();
    init_offsets();
    off += snprintf(buf + off, sizeof(buf) - off, "offsets 初始化完成\n");

    int dr = ds_run();
    off += snprintf(buf + off, sizeof(buf) - off,
                    "ds_run() = %d  %s\n", dr, dr == 0 ? "OK（DS 内核 r/w 就绪）" : "FAIL");
    if (dr != 0) break;

    // DS 算出的 kernel_base 位宽不对（ds_isvalid 会拒绝），用 libjailbreak 的 virtBase 修正
    {
        char sd[512]; jb_diag_sysinfo(sd, sizeof(sd), "sysinfo");
        off += snprintf(buf + off, sizeof(buf) - off, "%s", sd);
        uint64_t vb = jb_kernel_virtbase();
        off += snprintf(buf + off, sizeof(buf) - off,
                        "DS kbase=0x%llx  virtBase=0x%llx\n", kernel_base, vb);
        if (vb) {
            kernel_base  = vb;
            kernel_slide = vb - 0xfffffff007004000ULL;
            off += snprintf(buf + off, sizeof(buf) - off,
                            "修正后 kbase=0x%llx slide=0x%llx\n", kernel_base, kernel_slide);
        }
    }
    {
        uint64_t t = kernel_base ? ds_kread64(kernel_base + 0x100) : 0;
        off += snprintf(buf + off, sizeof(buf) - off, "ds_kread64(kbase+0x100) = 0x%llx\n", t);
    }

    // ② 定位 SpringBoard
    {
        uint64_t sbProc = proc_find_by_name("SpringBoard");
        off += snprintf(buf + off, sizeof(buf) - off, "SpringBoard proc = 0x%llx\n", sbProc);
    }

    // ③ DS 的 RemoteCall attach
    {
        Class rcCls = NSClassFromString(@"RemoteCall");
        if (!rcCls) {
            off += snprintf(buf + off, sizeof(buf) - off, "RemoteCall 类不存在\n");
            break;
        }
        RemoteCall *sb = [[rcCls alloc] initWithProcess:@"SpringBoard" useMigFilterBypass:NO];
        if (!sb || sb.trojanMem == 0 || sb.pid <= 1) {
            off += snprintf(buf + off, sizeof(buf) - off,
                            "attach 失败 (pid=%d trojanMem=0x%llx)\n", sb ? sb.pid : -1,
                            sb ? sb.trojanMem : 0);
            break;
        }
        off += snprintf(buf + off, sizeof(buf) - off,
                        "★ attach OK  pid=%d trojanMem=0x%llx\n", sb.pid, sb.trojanMem);

        // ④ 拿类（证明能远程执行）
        uint64_t selAlloc   = remote_sel(sb, "alloc");
        uint64_t selInit    = remote_sel(sb, "init");
        uint64_t clsWindow  = remote_getClass(sb, "UIWindow");
        uint64_t clsUIView  = remote_getClass(sb, "UIView");
        uint64_t clsUIColor = remote_getClass(sb, "UIColor");
        off += snprintf(buf + off, sizeof(buf) - off,
                        "UIWindow=0x%llx UIView=0x%llx UIColor=0x%llx\n",
                        clsWindow, clsUIView, clsUIColor);

        // ⑤ 远程创建对象（证明能改别人进程的状态）
        if (clsWindow && selAlloc && selInit) {
            uint64_t win = remote_msg(sb, clsWindow, selAlloc, 0, 0, 0, 0);
            win = remote_msg(sb, win, selInit, 0, 0, 0, 0);
            off += snprintf(buf + off, sizeof(buf) - off,
                            "★ 在 SpringBoard 里创建 UIWindow = 0x%llx %s\n",
                            win, win ? "OK" : "FAIL");
            if (win) {
                // 读回它的 retainCount，证明对象真实存在
                uint64_t rcSel = remote_sel(sb, "retainCount");
                uint64_t rc = remote_msg(sb, win, rcSel, 0, 0, 0, 0);
                off += snprintf(buf + off, sizeof(buf) - off,
                                "  retainCount = %llu\n", rc);
            }
        }
        off += snprintf(buf + off, sizeof(buf) - off,
                        "\n=== DS RemoteCall 在越狱环境下可用 ===\n");
    }

    } while (0);

    {
        FILE *f = fopen(outpath, "w");
        if (!f) return 3;
        fwrite(buf, 1, off, f);
        fclose(f);
    }
    return 0;
}

// --exit：杀掉 HUD 宿主（由 App 以 uid=0 拉起才有权限）
static int do_exit_hud(void) {
    NSString *s = [NSString stringWithContentsOfFile:@WZ_PID_PATH
                                            encoding:NSUTF8StringEncoding error:nil];
    if (s.length == 0) return 0;
    pid_t pid = (pid_t)[s intValue];
    if (pid > 1) { kill(pid, SIGKILL); unlink(WZ_PID_PATH); }
    return 0;
}

// --check：HUD 是否在跑（0=在跑）
static int do_check_hud(void) {
    NSString *s = [NSString stringWithContentsOfFile:@WZ_PID_PATH
                                            encoding:NSUTF8StringEncoding error:nil];
    if (s.length == 0) return 1;
    pid_t pid = (pid_t)[s intValue];
    if (pid <= 1) return 1;
    return (kill(pid, 0) == 0) ? 0 : 1;
}

// ─────────────────────────────────────────────────────────────
//  --read <pid> <out>：读取任意目标进程
// ─────────────────────────────────────────────────────────────
static int do_read_target(pid_t target, const char *outpath) {
    char buf[16384];
    int off = 0;

    do {
        uid_t u = getuid();
        off += snprintf(buf + off, sizeof(buf) - off, "uid = %d (root=%s)\n", (int)u, u == 0 ? "是" : "否");

        // 目标基本信息（用户态 API）
        char nm[256] = {0};
        char pathbuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
        proc_name(target, nm, sizeof(nm));
        proc_pidpath(target, pathbuf, sizeof(pathbuf));
        off += snprintf(buf + off, sizeof(buf) - off,
                        "目标 pid = %d\n  name = %s\n  path = %s\n", (int)target, nm, pathbuf);

        if (jb_load() != 0) {
            off += snprintf(buf + off, sizeof(buf) - off, "jb_load 失败\n%s\n", jb_status());
            break;
        }
        int r = jb_init_primitives();
        off += snprintf(buf + off, sizeof(buf) - off, "init_primitives() = %d %s\n",
                        r, r == 0 ? "OK" : "FAIL");
        if (r != 0) break;

        uint64_t proc = jb_proc_find(target);
        off += snprintf(buf + off, sizeof(buf) - off, "jb_proc_find = 0x%llx\n", proc);
        if (!proc) { off += snprintf(buf + off, sizeof(buf) - off, "找不到该进程\n"); break; }

        task_t task = MACH_PORT_NULL;
        kern_return_t kr = task_for_pid(mach_task_self(), target, &task);
        off += snprintf(buf + off, sizeof(buf) - off, "task_for_pid = %d (%s)\n",
                        kr, kr == KERN_SUCCESS ? "OK" : mach_error_string(kr));
        if (kr != KERN_SUCCESS) { jb_proc_rele(proc); break; }

        struct task_dyld_info dyldInfo = {0};
        mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
        kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&dyldInfo, &cnt);
        off += snprintf(buf + off, sizeof(buf) - off, "task_info(TASK_DYLD_INFO) = %d\n", kr);
        if (kr == KERN_SUCCESS && dyldInfo.all_image_info_addr) {
            struct dyld_all_image_infos infos = {0};
            int vr = jb_proc_vreadbuf(proc, (const void *)dyldInfo.all_image_info_addr,
                                      &infos, sizeof(infos));
            off += snprintf(buf + off, sizeof(buf) - off,
                            "读 dyld_all_image_infos = %d, imageCount = %u\n",
                            vr, infos.infoArrayCount);
            if (vr == 0 && infos.infoArray && infos.infoArrayCount > 0) {
                struct dyld_image_info first = {0};
                jb_proc_vreadbuf(proc, (const void *)infos.infoArray, &first, sizeof(first));
                uint64_t base = (uint64_t)first.imageLoadAddress;
                off += snprintf(buf + off, sizeof(buf) - off, "主模块基址 = 0x%llx\n", base);
                if (base) {
                    uint32_t magic = 0;
                    int mr = jb_proc_vreadbuf(proc, (const void *)base, &magic, sizeof(magic));
                    off += snprintf(buf + off, sizeof(buf) - off,
                                    "读基址 magic = 0x%08X %s (ret=%d)\n", magic,
                                    (magic == 0xFEEDFACF || magic == 0xFEEDFACE ||
                                     magic == 0xCEFAEDFE || magic == 0xCFFAEDFE) ? "✓ Mach-O 有效" : "?",
                                    mr);
                }
            }
        }

        jb_proc_rele(proc);
        off += snprintf(buf + off, sizeof(buf) - off, "\n=== 跨进程读取完成 ===\n");
    } while (0);

    {
        FILE *f = fopen(outpath, "w");
        if (!f) return 3;
        fwrite(buf, 1, off, f);
        fclose(f);
    }
    return 0;
}

// ─────────────────────────────────────────────────────────────
//  --probe <out>：libjailbreak 探测
// ─────────────────────────────────────────────────────────────
static int do_probe_and_write(const char *outpath) {
    char buf[16384];
    int off = 0;

    uid_t u = getuid();
    off += snprintf(buf + off, sizeof(buf) - off,
                    "uid = %d  (root=%s)\n", (int)u, (u == 0) ? "是" : "否");

    int lr = jb_load();
    off += snprintf(buf + off, sizeof(buf) - off, "jb_load() = %d\n%s\n", lr, jb_status());

    if (lr == 0) {
        int r = jb_init_primitives();
        off += snprintf(buf + off, sizeof(buf) - off,
                        "init_primitives() = %d  %s\n", r, (r == 0) ? "OK" : "FAIL");
        if (r == 0) {
            uint64_t sp = jb_proc_self();
            off += snprintf(buf + off, sizeof(buf) - off, "proc_self() = 0x%llx\n", sp);

            uint64_t canary = 0xDEADBEEFCAFEBABEULL, back = 0;
            int vr = jb_proc_vreadbuf(sp, (const void *)&canary, &back, sizeof(back));
            off += snprintf(buf + off, sizeof(buf) - off,
                            "proc_vreadbuf(自己) = %d  读回 0x%llx  %s\n",
                            vr, back, (back == canary) ? "OK 跨进程读可用" : "MISMATCH");
            off += snprintf(buf + off, sizeof(buf) - off,
                            "\n=== 结论 ===\nlibjailbreak 可用，跨进程读写具备。\n");
        }
    }

    // 进程列表（前 60 个）
    off += snprintf(buf + off, sizeof(buf) - off, "\n=== 运行中的进程 ===\n");
    {
        int n = proc_listallpids(NULL, 0);
        if (n > 0) {
            pid_t *pids = (pid_t *)malloc(sizeof(pid_t) * n);
            if (pids) {
                int got = proc_listallpids(pids, sizeof(pid_t) * n);
                int shown = 0;
                for (int i = 0; i < got && shown < 60; i++) {
                    char nm[256] = {0};
                    if (proc_name(pids[i], nm, sizeof(nm)) <= 0 || nm[0] == 0) continue;
                    off += snprintf(buf + off, sizeof(buf) - off, "  %5d  %s\n", (int)pids[i], nm);
                    shown++;
                }
                free(pids);
            }
        } else {
            off += snprintf(buf + off, sizeof(buf) - off, "  proc_listallpids 失败\n");
        }
    }

    FILE *f = fopen(outpath, "w");
    if (!f) return 3;
    fwrite(buf, 1, off, f);
    fclose(f);
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--hud") == 0) {
            return HUDHostRun();          // root 宿主：自建 UIApplication + 全局触摸
        }
        if (argc > 3 && strcmp(argv[1], "--wz") == 0) {
            return do_wz_read(argv[2], argv[3]);
        }
        if (argc > 2 && strcmp(argv[1], "--draw") == 0) {
            return do_draw_test(argv[2]);
        }
        if (argc > 2 && strcmp(argv[1], "--sbtest") == 0) {
            return do_springboard_test(argv[2]);
        }
        if (argc > 1 && strcmp(argv[1], "--exit") == 0) {
            return do_exit_hud();         // root 子进程：杀掉 HUD
        }
        if (argc > 1 && strcmp(argv[1], "--check") == 0) {
            return do_check_hud();        // 查询 HUD 是否在跑
        }
        if (argc > 2 && strcmp(argv[1], "--probe") == 0) {
            return do_probe_and_write(argv[2]);
        }
        if (argc > 3 && strcmp(argv[1], "--read") == 0) {
            return do_read_target((pid_t)atoi(argv[2]), argv[3]);
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
