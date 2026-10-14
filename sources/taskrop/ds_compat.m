//
//  ds_compat.m
//  用 libjailbreak(越狱) 的 kernel r/w 实现 DarkSpeed 的 ds_* 接口，
//  这样 TaskRop/RemoteCall.m 可以原样复用，不需要 DS 漏洞。
//
#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>
#import <mach/mach.h>
#import <os/log.h>

// libjailbreak 导出
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

// ── ds_* 映射 ────────────────────────────────────────
uint64_t ds_kread64(uint64_t a)                      { return kread64(a); }
uint32_t ds_kread32(uint64_t a)                      { return kread32(a); }
uint64_t ds_kreadptr(uint64_t a)                     { return kread_ptr(a); }
uint64_t ds_kreadsmrptr(uint64_t a)                  { return kread_smrptr(a); }
void     ds_kread(uint64_t a, void *b, uint64_t n)   { kreadbuf(a, b, n); }
void     ds_kreadbuf(uint64_t a, void *b, uint64_t n){ kreadbuf(a, b, n); }
void     ds_kwrite64(uint64_t a, uint64_t v)         { kwrite64(a, v); }
void     ds_kwrite32(uint64_t a, uint32_t v)         { kwrite32(a, v); }
void     ds_kwrite(uint64_t a, void *b, uint64_t n)  { kwritebuf(a, b, n); }
void     ds_kwritebuf(uint64_t a, const void *b, uint64_t n) { kwritebuf(a, b, n); }
void     ds_kwritezoneelement(uint64_t d, const void *s, uint64_t n) { kwrite_zone_element(d, s, n); }

// DarkSpeed 的 kalloc_array_decode：解 kalloc 数组指针（PAC/签名位）
// libjailbreak 未直接导出，按 DS 的算法用 kread 解
uint64_t ds_kallocarrdec(uint64_t ptr) {
    if (!ptr) return 0;
    // 典型实现：低 4 位是 index，高 56 位是 base
    uint64_t base = ptr & ~0xFULL;
    return base;
}

// 地址有效性（DS 的判定是内核指针区间）
bool ds_isvalid(uint64_t v) {
    return v > 0xffff000000000000ULL;
}

// 从 kernel 里读一个指针（带 PAC 剥离）
uint64_t ds_kread64_pacstrip(uint64_t a) {
    uint64_t v = kread64(a);
    return (v >> 56) ? (v | 0xffffff8000000000ULL) : (v & 0x0000ffffffffffffULL);
}

// ── 内核基址/滑动 ────────────────────────────────────
extern uint64_t kernel_base;
extern uint64_t kernel_slide;

uint64_t ds_get_kernel_base(void)  { return kernel_base; }
uint64_t ds_get_kernel_slide(void) { return kernel_slide; }
