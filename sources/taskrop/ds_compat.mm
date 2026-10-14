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

// ── libjailbreak（Relaxin/Dopamine）导出 ──────────────
extern "C" {
int      jbclient_initialize_primitives(void);
uint64_t proc_self(void);
uint64_t proc_find(pid_t pid);
uint64_t proc_task(uint64_t proc);
int      proc_rele(uint64_t proc);

int      kreadbuf(uint64_t kaddr, void *out, size_t size);
int      kwritebuf(uint64_t kaddr, const void *in, size_t size);
uint64_t kread64(uint64_t va);
uint32_t kread32(uint64_t va);
uint16_t kread16(uint64_t va);
uint8_t  kread8(uint64_t va);
int      kwrite64(uint64_t va, uint64_t v);
int      kwrite32(uint64_t va, uint32_t v);
int      kwrite16(uint64_t va, uint16_t v);
int      kwrite8(uint64_t va, uint8_t v);
uint64_t kread_ptr(uint64_t va);
uint64_t kread_smrptr(uint64_t va);
void     kwrite_zone_element(uint64_t dst, const void *src, uint64_t len);
int      kalloc(uint64_t *addr, uint64_t size);
int      kfree(uint64_t addr, uint64_t size);
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
int  ds_run(void)      { return jbclient_initialize_primitives(); }
bool ds_is_ready(void) { return true; }

bool ds_isvalid(uint64_t v) { return v > 0xffff000000000000ULL; }

uint64_t ds_kread64(uint64_t a)  { return kread64(a); }
uint32_t ds_kread32(uint64_t a)  { return kread32(a); }
uint16_t ds_kread16(uint64_t a)  { return kread16(a); }
uint8_t  ds_kread8(uint64_t a)   { return kread8(a); }

void ds_kwrite64(uint64_t a, uint64_t v) { kwrite64(a, v); }
void ds_kwrite32(uint64_t a, uint32_t v) { kwrite32(a, v); }
void ds_kwrite16(uint64_t a, uint16_t v) { kwrite16(a, v); }
void ds_kwrite8(uint64_t a, uint8_t v)   { kwrite8(a, v); }

void ds_kread(uint64_t a, void *b, uint64_t n)  { kreadbuf(a, b, n); }
void ds_kreadbuf(uint64_t a, void *b, uint64_t n){ kreadbuf(a, b, n); }
void ds_kwrite(uint64_t a, void *b, uint64_t n) { kwritebuf(a, b, n); }
void ds_kwritebuf(uint64_t a, const void *b, uint64_t n) { kwritebuf(a, b, n); }

void ds_kwritezoneelement(uint64_t d, const void *s, uint64_t n) {
    kwrite_zone_element(d, s, n);
}

void ds_khexdump(uint64_t addr, size_t size) {
    for (size_t i = 0; i < size; i += 16) {
        printf("%016llx: ", (unsigned long long)(addr + i));
        for (size_t j = 0; j < 16 && i + j < size; j++)
            printf("%02x ", kread8(addr + i + j));
        printf("\n");
    }
}

uint64_t ds_kreadptr(uint64_t va)    { return kread_ptr(va); }
uint64_t ds_kreadsmrptr(uint64_t va) { return kread_smrptr(va); }

// kalloc 数组指针解码：低 4 位为 index，其余为 base
uint64_t ds_kallocarrdec(uint64_t ptr) { return ptr & ~0xFULL; }

uint64_t ds_get_kernel_base(void)  { return gSystemInfo.kernelConstant.base; }
uint64_t ds_get_kernel_slide(void) { return gSystemInfo.kernelConstant.slide; }

uint64_t ds_get_pcbinfo(void)         { return 0; }   // DS 漏洞专用，越狱下不需要
uint64_t ds_get_rw_socket_pcb(void)   { return 0; }
uint64_t ds_get_our_proc(void)        { return proc_self(); }
uint64_t ds_get_our_task(void)        { return proc_task(proc_self()); }

bool ds_adopt_krw(int c, int r, uint64_t b, uint64_t s) { (void)c;(void)r;(void)b;(void)s; return false; }
void ds_set_xproc_lock_path(const char *p) { (void)p; }
}  // extern "C"
