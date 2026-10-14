//
//  jb.mm — libjailbreak 运行时加载实现
//
#import "jb.h"
#import <dlfcn.h>
#import <dirent.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <limits.h>

static void *g_handle = NULL;
static char  g_jbroot[PATH_MAX]  = {0};
static char  g_loaded[PATH_MAX]  = {0};
static char  g_status[640]       = {0};
static char  g_error[640]        = {0};
static int   g_loaded_ok         = 0;

// ── 函数指针 ─────────────────────────────────────────
static int      (*p_jbd_init)(void)                       = NULL;
static int      (*p_init)(void)                           = NULL;
static uint64_t (*p_self)(void)                           = NULL;
static uint64_t (*p_find)(pid_t)                          = NULL;
static uint64_t (*p_task)(uint64_t)                       = NULL;
static int      (*p_rele)(uint64_t)                       = NULL;
static int      (*p_vread)(uint64_t, const void*, void*, size_t) = NULL;
static int      (*p_kread)(uint64_t, void*, size_t)       = NULL;
static uint64_t (*p_kread64fn)(uint64_t)                  = NULL;
static int      (*p_kcall)(uint64_t*, uint64_t, int, const uint64_t*) = NULL;

// ── 扫描 RootHide 的 jbroot ──────────────────────────
static int scan_jbroot(void) {
    const char *bases[] = {
        "/var/containers/Bundle/Application",
        "/private/var/containers/Bundle/Application",
        "/var/mobile/Containers/Shared/AppGroup",
        "/private/var/mobile/Containers/Shared/AppGroup",
    };
    int foundPath[4] = {0};
    for (int i = 0; i < 4; i++) {
        if (access(bases[i], R_OK) != 0) continue;
        foundPath[i] = 1;
        DIR *d = opendir(bases[i]);
        if (!d) continue;
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (strncmp(e->d_name, ".jbroot-", 8) == 0) {
                snprintf(g_jbroot, sizeof(g_jbroot), "%s/%s", bases[i], e->d_name);
                closedir(d);
                return 1;
            }
        }
        closedir(d);
    }
    // 记录哪些目录可读，方便诊断
    int any = 0;
    for (int i = 0; i < 4; i++) if (foundPath[i]) any = 1;
    snprintf(g_error, sizeof(g_error),
             "未找到 .jbroot-* 目录 (可读的候选根: %s)", any ? "有" : "无");
    return 0;
}

int jb_load(void) {
    if (g_loaded_ok) return 0;

    NSMutableString *st = [NSMutableString string];

    if (!scan_jbroot()) {
        snprintf(g_status, sizeof(g_status), "%s", g_error);
        return -1;
    }
    [st appendFormat:@"jbroot: %s\n", g_jbroot];

    static const char *cands[] = {
        "/usr/lib/libjailbreak.dylib",
        "/basebin/libjailbreak.dylib",
        "/usr/lib/libjailbreak/libjailbreak.dylib",
        "/basebin/libjailbreak/libjailbreak.dylib",
        "/usr/lib/libjailbreak-compat.dylib",
    };

    for (unsigned i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
        char full[PATH_MAX];
        snprintf(full, sizeof(full), "%s%s", g_jbroot, cands[i]);
        if (access(full, R_OK) != 0) {
            [st appendFormat:@"  跳过(不存在): %s\n", cands[i]];
            continue;
        }
        void *h = dlopen(full, RTLD_NOW | RTLD_GLOBAL);
        if (!h) {
            const char *de = dlerror();
            [st appendFormat:@"  dlopen失败: %s\n    %s\n", cands[i], de ? de : "?"];
            continue;
        }
        g_handle = h;
        snprintf(g_loaded, sizeof(g_loaded), "%s", full);
        [st appendFormat:@"  已加载: %s\n", cands[i]];

        p_jbd_init = dlsym(h, "jbclient_initialize_jailbreakd_primitives");
        p_init     = dlsym(h, "jbclient_initialize_primitives");
        p_self     = dlsym(h, "proc_self");
        p_find     = dlsym(h, "proc_find");
        p_task     = dlsym(h, "proc_task");
        p_rele     = dlsym(h, "proc_rele");
        p_vread    = dlsym(h, "proc_vreadbuf");
        p_kread    = dlsym(h, "kreadbuf");
        p_kread64fn= dlsym(h, "kread64");
        p_kcall    = dlsym(h, "kcall");

        [st appendFormat:@"  符号: jbd_init=%s init=%s vread=%s kread=%s\n",
            p_jbd_init ? "有" : "无",
            p_init     ? "有" : "无",
            p_vread    ? "有" : "无",
            p_kread    ? "有" : "无"];

        snprintf(g_status, sizeof(g_status), "%s", st.UTF8String);
        g_loaded_ok = 1;
        return 0;
    }

    snprintf(g_error, sizeof(g_error), "%s", st.UTF8String);
    snprintf(g_status, sizeof(g_status), "%s", st.UTF8String);
    return -1;
}

const char *jb_status(void) { return g_status; }
const char *jb_error(void)  { return g_error; }

int jb_init_primitives(void) {
    // 优先 jailbreakd 入口（越狱环境正确路径），回退旧入口
    if (p_jbd_init) return p_jbd_init();
    if (p_init)     return p_init();
    return -99;
}

uint64_t jb_proc_self(void)  { return p_self ? p_self() : 0; }
uint64_t jb_proc_find(pid_t p){ return p_find ? p_find(p) : 0; }
uint64_t jb_proc_task(uint64_t p){ return p_task ? p_task(p) : 0; }
int      jb_proc_rele(uint64_t p){ return p_rele ? p_rele(p) : -1; }
int      jb_proc_vreadbuf(uint64_t p, const void *a, void *o, size_t n){
    return p_vread ? p_vread(p, a, o, n) : -1;
}
int      jb_kreadbuf(uint64_t a, void *o, size_t n){ return p_kread ? p_kread(a, o, n) : -1; }
uint64_t jb_kread64(uint64_t a){ return p_kread64fn ? p_kread64fn(a) : 0; }
int      jb_kcall(uint64_t *r, uint64_t f, int c, const uint64_t *v){
    return p_kcall ? p_kcall(r, f, c, v) : -1;
}
