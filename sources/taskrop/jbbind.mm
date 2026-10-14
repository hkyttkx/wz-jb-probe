//
//  jbbind.mm
//  只做一件事：把 libjailbreak 的「用户态跨进程读取」能力绑进来。
//  （内核读写由 darksword.m 提供，这里不再重复实现 ds_*）
//
//  —— kread64/kwrite64 在 SPTM 设备上不可用，但 proc_vreadbuf 可用，
//     所以目标进程的内存读取走 libjailbreak，内核操作走 DS。
//
#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>
#import <stdio.h>
#import <mach/mach.h>
#import <os/log.h>
#import <dlfcn.h>

typedef int      (*fn_int_v)(void);
typedef uint64_t (*fn_u64_v)(void);
typedef uint64_t (*fn_u64_i)(int);
typedef uint64_t (*fn_u64_u64)(uint64_t);
typedef int      (*fn_vread)(uint64_t, const void*, void*, size_t);
typedef int      (*fn_vwrite)(uint64_t, const void*, const void*, size_t);

static void      *g_jb_handle = NULL;
static void      *g_sysinfo   = NULL;
static fn_u64_v   p_proc_self = NULL;
static fn_u64_i   p_proc_find = NULL;
static fn_u64_u64 p_proc_task = NULL;
static fn_vread   p_proc_vread = NULL;
static fn_vwrite  p_proc_vwrite = NULL;

extern "C" int ds_compat_bind(void *h) {
    if (!h) return -1;
    g_jb_handle   = h;
    g_sysinfo     = dlsym(h, "gSystemInfo");
    p_proc_self   = (fn_u64_v)   dlsym(h, "proc_self");
    p_proc_find   = (fn_u64_i)   dlsym(h, "proc_find");
    p_proc_task   = (fn_u64_u64) dlsym(h, "proc_task");
    p_proc_vread  = (fn_vread)   dlsym(h, "proc_vreadbuf");
    p_proc_vwrite = (fn_vwrite)  dlsym(h, "proc_vwritebuf");
    os_log(OS_LOG_DEFAULT, "[jbbind] self=%p find=%p task=%p vread=%p vwrite=%p",
           p_proc_self, p_proc_find, p_proc_task, p_proc_vread, p_proc_vwrite);
    return (p_proc_find && p_proc_vread) ? 0 : -1;
}

// 兼容层：原来的 ds_sync_kernel_info 现在由 darksword.m 的 ds_run 负责填充，
// 保留空实现以免调用点报错。
extern "C" void ds_sync_kernel_info(void) { }

// 从 libjailbreak 的 gSystemInfo 取内核虚拟基址（标准 16 位形态）
// kernelConstant: slide=0x00 staticBase=0x08 base=0x10 virtBase=0x18
extern "C" uint64_t jb_kernel_virtbase(void) {
    if (!g_sysinfo) return 0;
    uint8_t *p = (uint8_t *)g_sysinfo;
    uint64_t v[4];
    for (int i = 0; i < 4; i++) v[i] = *(uint64_t *)(p + i * 8);
    // 选一个符合内核规范地址形态（0xfffffff...）的
    for (int i = 3; i >= 0; i--) {
        if (v[i] >= 0xfffffff000000000ULL && v[i] < 0xffffffff00000000ULL) return v[i];
    }
    return 0;
}

// ── 真正的"跨进程读目标进程内存"（上面已证明可用）────────
extern "C" uint64_t jb_proc_by_pid(pid_t pid) {
    return p_proc_find ? p_proc_find(pid) : 0;
}
extern "C" int jb_read_process(uint64_t proc, uint64_t addr, void *buf, size_t len) {
    return p_proc_vread ? p_proc_vread(proc, (const void *)addr, buf, len) : -1;
}
extern "C" int jb_write_process(uint64_t proc, uint64_t addr, const void *buf, size_t len) {
    return p_proc_vwrite ? p_proc_vwrite(proc, (const void *)addr, buf, len) : -1;
}
