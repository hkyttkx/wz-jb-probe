//
//  ds_compat.m
//  用 libjailbreak(越狱 kernel r/w) 实现 DarkSpeed 的 ds_* 全套接口。
//  这样 TaskRop/RemoteCall.m + offsets.m + utils.m 可以原样复用，
//  不需要 DS 漏洞，也不需要 ds_run()。
//
#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>
#import <stdio.h>
#import <mach/mach.h>
#import <os/log.h>
#import <sys/sysctl.h>
#import <dlfcn.h>

// ── libjailbreak（Relaxin/Dopamine）导出 ──────────────
extern "C" {

// 运行时从 jbroot 的 libjailbreak 取符号（不静态链接，避免启动即加载而崩）
typedef int      (*fn_int_v)(void);
typedef uint64_t (*fn_u64_v)(void);
typedef uint64_t (*fn_u64_u64)(uint64_t);
typedef uint32_t (*fn_u32_u64)(uint64_t);
typedef uint16_t (*fn_u16_u64)(uint64_t);
typedef uint8_t  (*fn_u8_u64)(uint64_t);
typedef int      (*fn_i_u64v)(uint64_t, uint64_t);
typedef int      (*fn_i_u64u32)(uint64_t, uint32_t);
typedef int      (*fn_i_u64u16)(uint64_t, uint16_t);
typedef int      (*fn_i_u64u8)(uint64_t, uint8_t);
typedef int      (*fn_i_r)(uint64_t, void*, size_t);
typedef int      (*fn_i_w)(uint64_t, const void*, size_t);
typedef uint64_t (*fn_u64_i)(int);

static fn_int_v   p_jb_init   = NULL;
static fn_u64_u64 p_kread64   = NULL;
static fn_u32_u64 p_kread32   = NULL;
static fn_u16_u64 p_kread16   = NULL;
static fn_u8_u64  p_kread8    = NULL;
static fn_i_u64v  p_kwrite64  = NULL;
static fn_i_u64u32 p_kwrite32 = NULL;
static fn_i_u64u16 p_kwrite16 = NULL;
static fn_i_u64u8 p_kwrite8   = NULL;
static fn_u64_u64 p_kreadptr  = NULL;
static fn_u64_u64 p_kreadsmr  = NULL;
static fn_i_r     p_kreadbuf  = NULL;
static fn_i_w     p_kwritebuf = NULL;
static fn_u64_v   p_proc_self = NULL;
static fn_u64_i   p_proc_find = NULL;
static fn_u64_u64 p_proc_task = NULL;

// 由 jb_load() 之后调用，绑定符号
extern "C" int ds_compat_bind(void *h) {
    if (!h) return -1;
    p_jb_init   = (fn_int_v)     dlsym(h, "jbclient_initialize_primitives");
    p_kread64   = (fn_u64_u64)   dlsym(h, "kread64");
    p_kread32   = (fn_u32_u64)   dlsym(h, "kread32");
    p_kread16   = (fn_u16_u64)   dlsym(h, "kread16");
    p_kread8    = (fn_u8_u64)    dlsym(h, "kread8");
    p_kwrite64  = (fn_i_u64v)    dlsym(h, "kwrite64");
    p_kwrite32  = (fn_i_u64u32)  dlsym(h, "kwrite32");
    p_kwrite16  = (fn_i_u64u16)  dlsym(h, "kwrite16");
    p_kwrite8   = (fn_i_u64u8)   dlsym(h, "kwrite8");
    p_kreadptr  = (fn_u64_u64)   dlsym(h, "kread_ptr");
    p_kreadsmr  = (fn_u64_u64)   dlsym(h, "kread_smrptr");
    p_kreadbuf  = (fn_i_r)       dlsym(h, "kreadbuf");
    p_kwritebuf = (fn_i_w)       dlsym(h, "kwritebuf");
    p_proc_self = (fn_u64_v)     dlsym(h, "proc_self");
    p_proc_find = (fn_u64_i)     dlsym(h, "proc_find");
    p_proc_task = (fn_u64_u64)   dlsym(h, "proc_task");
    return p_kread64 ? 0 : -1;
}
}
// libjailbreak 的全局内核信息（info.h）
extern "C" {
struct {
    struct { uint64_t slide; uint64_t staticBase; uint64_t base;
             uint64_t virtBase; uint64_t virtSize; uint64_t physBase;
             uint64_t physSize; uint64_t cpuTTEP; uint64_t kernel_el;
             uint64_t pointer_mask; uint64_t T1SZ_BOOT; } kernelConstant;
} gSystemInfo;
}

extern "C" {

// ── DS 依赖的全局内核基址（原在 darksword.m 里，这里用 libjailbreak 的值）──
uint64_t kernel_base  = 0;
uint64_t kernel_slide = 0;
int      control_socket = -1;
int      rw_socket      = -1;

// 由宿主在启用时调用一次，把 libjailbreak 的内核信息同步过来
void ds_sync_kernel_info(void) {
    kernel_base  = gSystemInfo.kernelConstant.base;
    kernel_slide = gSystemInfo.kernelConstant.slide;
}

// ── ds_* 全套实现 ────────────────────────────────────
void ds_set_log_callback(void (*cb)(const char *))   { (void)cb; }
void ds_set_progress_callback(void (*cb)(double))    { (void)cb; }

// 越狱环境下不需要 DS 漏洞：kernel r/w 已由 libjailbreak 提供
int  ds_run(void)      { return p_jb_init ? p_jb_init() : -1; }
bool ds_is_ready(void) { return true; }

bool ds_isvalid(uint64_t v) { return v > 0xffff000000000000ULL; }

uint64_t ds_kread64(uint64_t a)  { return p_kread64(a); }
uint32_t ds_kread32(uint64_t a)  { return p_kread32(a); }
uint16_t ds_kread16(uint64_t a)  { return p_kread16(a); }
uint8_t  ds_kread8(uint64_t a)   { return p_kread8(a); }

void ds_kwrite64(uint64_t a, uint64_t v) { if (p_kwrite64) p_kwrite64(a, v); }
void ds_kwrite32(uint64_t a, uint32_t v) { if (p_kwrite32) p_kwrite32(a, v); }
void ds_kwrite16(uint64_t a, uint16_t v) { if (p_kwrite16) p_kwrite16(a, v); }
void ds_kwrite8(uint64_t a, uint8_t v)   { if (p_kwrite8)  p_kwrite8(a, v); }

void ds_kread(uint64_t a, void *b, uint64_t n)  { if (p_kreadbuf) p_kreadbuf(a, b, n); }
void ds_kreadbuf(uint64_t a, void *b, uint64_t n){ if (p_kreadbuf) p_kreadbuf(a, b, n); }
void ds_kwrite(uint64_t a, void *b, uint64_t n) { if (p_kwritebuf) p_kwritebuf(a, b, n); }
void ds_kwritebuf(uint64_t a, const void *b, uint64_t n) { if (p_kwritebuf) p_kwritebuf(a, b, n); }

void ds_kwritezoneelement(uint64_t d, const void *s, uint64_t n) {
    // libjailbreak 未导出 zone 专用写，用普通内核写兜底
    if (p_kwritebuf) p_kwritebuf(d, s, n);
}

void ds_khexdump(uint64_t addr, size_t size) {
    for (size_t i = 0; i < size; i += 16) {
        printf("%016llx: ", (unsigned long long)(addr + i));
        for (size_t j = 0; j < 16 && i + j < size; j++)
            printf("%02x ", p_kread8 ? p_kread8(addr + i + j) : 0);
        printf("\n");
    }
}

uint64_t ds_kreadptr(uint64_t va)    { return p_kreadptr(va); }
uint64_t ds_kreadsmrptr(uint64_t va) { return p_kreadsmr(va); }

// kalloc 数组指针解码：低 4 位为 index，其余为 base
uint64_t ds_kallocarrdec(uint64_t ptr) { return ptr & ~0xFULL; }

uint64_t ds_get_kernel_base(void)  { return gSystemInfo.kernelConstant.base; }
uint64_t ds_get_kernel_slide(void) { return gSystemInfo.kernelConstant.slide; }

uint64_t ds_get_pcbinfo(void)         { return 0; }   // DS 漏洞专用，越狱下不需要
uint64_t ds_get_rw_socket_pcb(void)   { return 0; }
uint64_t ds_get_our_proc(void)        { return p_proc_self ? p_proc_self() : 0; }
uint64_t ds_get_our_task(void)        { return (p_proc_task && p_proc_self) ? p_proc_task(p_proc_self()) : 0; }

bool ds_adopt_krw(int c, int r, uint64_t b, uint64_t s) { (void)c;(void)r;(void)b;(void)s; return false; }
void ds_set_xproc_lock_path(const char *p) { (void)p; }
}  // extern "C"
