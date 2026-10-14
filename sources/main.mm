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

// libproc：iOS SDK 不提供 libproc.h，自行声明
extern "C" {
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, unsigned int buffersize);
int proc_pidpath(int pid, void *buffer, unsigned int buffersize);
int HUDHostRun(void);      // root HUD 宿主（HUDHost.mm）
}
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif

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
        if (argc > 2 && strcmp(argv[1], "--probe") == 0) {
            return do_probe_and_write(argv[2]);
        }
        if (argc > 3 && strcmp(argv[1], "--read") == 0) {
            return do_read_target((pid_t)atoi(argv[2]), argv[3]);
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
