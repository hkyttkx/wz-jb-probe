//
//  jb.mm — libjailbreak 运行时加载实现（纯 C 风格，避免 ObjC 依赖）
//
#import "jb.h"
#import <dlfcn.h>
#import <dirent.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <limits.h>
#import <os/log.h>

extern "C" int ds_compat_bind(void *h);

static void *g_handle = NULL;
static char  g_jbroot[PATH_MAX] = {0};
static char  g_status[1024]     = {0};
static char  g_error[1024]      = {0};
static int   g_ok               = 0;

// ── 函数指针 ─────────────────────────────────────────
typedef int      (*fn_int_void)(void);
typedef uint64_t (*fn_u64_void)(void);
typedef uint64_t (*fn_u64_int)(pid_t);
typedef uint64_t (*fn_u64_u64)(uint64_t);
typedef int      (*fn_int_u64)(uint64_t);
typedef int      (*fn_vread)(uint64_t, const void*, void*, size_t);
typedef int      (*fn_kread)(uint64_t, void*, size_t);
typedef int      (*fn_kcall)(uint64_t*, uint64_t, int, const uint64_t*);

static fn_int_void  p_jbd_init = NULL;
static fn_int_void  p_init     = NULL;
static fn_u64_void  p_self     = NULL;
static fn_u64_int   p_find     = NULL;
static fn_u64_u64   p_task     = NULL;
static fn_int_u64   p_rele     = NULL;
static fn_vread     p_vread    = NULL;
static fn_kread     p_kread    = NULL;
static fn_u64_u64   p_kread64f = NULL;
static fn_kcall     p_kcall    = NULL;

// ── 扫描 RootHide 的 jbroot ──────────────────────────
static int scan_jbroot(void) {
    const char *bases[] = {
        "/var/containers/Bundle/Application",
        "/private/var/containers/Bundle/Application",
        "/var/mobile/Containers/Shared/AppGroup",
        "/private/var/mobile/Containers/Shared/AppGroup",
    };
    int readable = 0;
    for (unsigned i = 0; i < sizeof(bases)/sizeof(bases[0]); i++) {
        if (access(bases[i], R_OK) != 0) continue;
        readable++;
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
    snprintf(g_error, sizeof(g_error),
             "未找到 .jbroot-* 目录（候选根可读 %d/4）", readable);
    return 0;
}

int jb_load(void) {
    if (g_ok) return 0;

    char buf[1024];
    snprintf(g_status, sizeof(g_status), "扫描 jbroot…\n");

    if (!scan_jbroot()) {
        snprintf(g_status, sizeof(g_status), "%s", g_error);
        return -1;
    }

    int off = snprintf(buf, sizeof(buf), "jbroot: %s\n", g_jbroot);

    static const char *cands[] = {
        "/usr/lib/libjailbreak.dylib",
        "/basebin/libjailbreak.dylib",
        "/usr/lib/libjailbreak/libjailbreak.dylib",
        "/basebin/libjailbreak/libjailbreak.dylib",
    };

    for (unsigned i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
        char full[PATH_MAX];
        snprintf(full, sizeof(full), "%s%s", g_jbroot, cands[i]);
        if (access(full, R_OK) != 0) continue;

        void *h = dlopen(full, RTLD_NOW | RTLD_GLOBAL);
        if (!h) {
            const char *de = dlerror();
            off += snprintf(buf + off, sizeof(buf) - off,
                            "dlopen失败 %s: %.200s\n", cands[i], de ? de : "?");
            continue;
        }

        g_handle = h;
        p_jbd_init = (fn_int_void) dlsym(h, "jbclient_initialize_jailbreakd_primitives");
        p_init     = (fn_int_void) dlsym(h, "jbclient_initialize_primitives");
        p_self     = (fn_u64_void) dlsym(h, "proc_self");
        p_find     = (fn_u64_int)  dlsym(h, "proc_find");
        p_task     = (fn_u64_u64)  dlsym(h, "proc_task");
        p_rele     = (fn_int_u64)  dlsym(h, "proc_rele");
        p_vread    = (fn_vread)    dlsym(h, "proc_vreadbuf");
        p_kread    = (fn_kread)    dlsym(h, "kreadbuf");
        p_kread64f = (fn_u64_u64)  dlsym(h, "kread64");
        p_kcall    = (fn_kcall)    dlsym(h, "kcall");

        snprintf(buf + off, sizeof(buf) - off,
                 "已加载: %s\n符号: jbd_init=%s init=%s vread=%s kread=%s\n",
                 cands[i],
                 p_jbd_init ? "有" : "无",
                 p_init     ? "有" : "无",
                 p_vread    ? "有" : "无",
                 p_kread    ? "有" : "无");
        snprintf(g_status, sizeof(g_status), "%s", buf);
        g_ok = 1;
        {
            int bindRc = ds_compat_bind(h);
            os_log(OS_LOG_DEFAULT, "[jb] ds_compat_bind=%d", bindRc);
        }
        return 0;
    }

    snprintf(buf + off, sizeof(buf) - off, "jbroot 内未找到 libjailbreak.dylib");
    snprintf(g_status, sizeof(g_status), "%s", buf);
    return -1;
}

const char *jb_status(void) { return g_status; }
const char *jb_error(void)  { return g_error; }

int jb_init_primitives(void) {
    if (p_jbd_init) return p_jbd_init();   // 越狱环境正确入口
    if (p_init)     return p_init();       // 回退
    return -99;
}

uint64_t jb_proc_self(void)   { return p_self ? p_self() : 0; }
uint64_t jb_proc_find(pid_t p){ return p_find ? p_find(p) : 0; }
uint64_t jb_proc_task(uint64_t p){ return p_task ? p_task(p) : 0; }
int jb_proc_rele(uint64_t p)  { return p_rele ? p_rele(p) : -1; }
int jb_proc_vreadbuf(uint64_t p, const void *a, void *o, size_t n){
    return p_vread ? p_vread(p, a, o, n) : -1;
}
int jb_kreadbuf(uint64_t a, void *o, size_t n){ return p_kread ? p_kread(a, o, n) : -1; }
uint64_t jb_kread64(uint64_t a){ return p_kread64f ? p_kread64f(a) : 0; }
int jb_kcall(uint64_t *r, uint64_t f, int c, const uint64_t *v){
    return p_kcall ? p_kcall(r, f, c, v) : -1;
}
