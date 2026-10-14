//
//  jb.h — libjailbreak 导出符号的最小声明
//  只声明我们用到的，避免引入整套头文件依赖。
//  符号来源：Vendor/libjailbreak.dylib（Dopamine/Relaxin 系）
//
#ifndef JB_H
#define JB_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── 初始化 ───────────────────────────────────────────
// 越狱环境下连接 jailbreakd，取得 kernel r/w primitives
int jbclient_initialize_primitives(void);

// ── 进程查找 ─────────────────────────────────────────
uint64_t proc_self(void);
uint64_t proc_find(pid_t pid);
uint64_t proc_task(uint64_t proc);
int      proc_rele(uint64_t proc);

// ── 跨进程读写（我们要的）─────────────────────────────
int proc_vreadbuf(uint64_t proc, const void *addr, void *outdata, size_t datalen);
int proc_vwritebuf(uint64_t proc, const void *addr, const void *indata, size_t datalen);

// ── 内核读写 ─────────────────────────────────────────
int      kreadbuf(uint64_t kaddr, void *output, size_t size);
int      kwritebuf(uint64_t kaddr, const void *input, size_t size);
uint64_t kread64(uint64_t va);
int      kwrite64(uint64_t va, uint64_t v);

// ── 内核调用 ─────────────────────────────────────────
int kcall(uint64_t *result, uint64_t func, int argc, const uint64_t *argv);

#ifdef __cplusplus
}
#endif

#endif /* JB_H */
