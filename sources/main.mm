//
//  main.mm
//  两种模式：
//    · 无参数            → 正常 App（普通用户，显示 UI）
//    · --probe <outfile> → root 子进程（由 App 用 persona_uid=0 拉起）
//
#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "jb.h"
#import <string.h>
#import <stdio.h>
#import <unistd.h>
#import <stdlib.h>
#import <libproc.h>

// ── root 子进程：做探测，把结果写到 outfile ──────────
static int do_probe_and_write(const char *outpath) {
    char buf[8192];
    int off = 0;

    uid_t u = getuid();
    off += snprintf(buf + off, sizeof(buf) - off,
                    "uid = %d  (root=%s)\n", (int)u, (u == 0) ? "是" : "否");

    int lr = jb_load();
    off += snprintf(buf + off, sizeof(buf) - off,
                    "jb_load() = %d\n%s\n", lr, jb_status());

    if (lr == 0) {
        int r = jb_init_primitives();
        off += snprintf(buf + off, sizeof(buf) - off,
                        "init_primitives() = %d  %s\n", r, (r == 0) ? "OK" : "FAIL");

        if (r == 0) {
            uint64_t sp = jb_proc_self();
            off += snprintf(buf + off, sizeof(buf) - off,
                            "proc_self() = 0x%llx\n", sp);

            uint64_t kv = 0;
            jb_kreadbuf(sp, &kv, sizeof(kv));
            off += snprintf(buf + off, sizeof(buf) - off,
                            "kreadbuf(proc_self) = 0x%llx\n", kv);

            uint64_t canary = 0xDEADBEEFCAFEBABEULL, back = 0;
            int vr = jb_proc_vreadbuf(sp, (const void *)&canary, &back, sizeof(back));
            off += snprintf(buf + off, sizeof(buf) - off,
                            "proc_vreadbuf(自己) = %d\n  原值 0x%llx\n  读回 0x%llx  %s\n",
                            vr, canary, back,
                            (back == canary) ? "OK 跨进程读可用" : "MISMATCH");

            uint64_t ld = jb_proc_find(1);
            if (ld) {
                uint64_t lv = 0;
                jb_kreadbuf(ld, &lv, sizeof(lv));
                off += snprintf(buf + off, sizeof(buf) - off,
                                "proc_find(1) = 0x%llx  首字段 0x%llx  OK\n", ld, lv);
                jb_proc_rele(ld);
            } else {
                off += snprintf(buf + off, sizeof(buf) - off, "proc_find(1) FAIL\n");
            }
            off += snprintf(buf + off, sizeof(buf) - off,
                            "\n=== 结论 ===\nlibjailbreak 可用，跨进程读写具备。\n");
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
        if (argc > 2 && strcmp(argv[1], "--probe") == 0) {
            return do_probe_and_write(argv[2]);
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
 for (int i = 0; i < got && shown < 80; i++) {
                    char nm[256] = {0};
                    if (proc_name(pids[i], nm, sizeof(nm)) <= 0) continue;
                    if (nm[0] == 0) continue;
                    off += snprintf(buf + off, sizeof(buf) - off,
                                    "  %5d  %s\n", (int)pids[i], nm);
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
        if (argc > 2 && strcmp(argv[1], "--probe") == 0) {
            return do_probe_and_write(argv[2]);
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
