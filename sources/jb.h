//
//  jb.h — libjailbreak 运行时加载封装
//
//  不静态链接 dylib，改为运行时：
//    ① 扫描 RootHide 的 jbroot（.jbroot-<hex>）
//    ② dlopen 其中的 libjailbreak.dylib
//    ③ dlsym 取符号
//  这样用的是设备上那份（版本必然匹配）。
//
#ifndef JB_H
#define JB_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// 返回 0 成功，非 0 失败
int  jb_load(void);
const char *jb_status(void);        // 人类可读的状态/路径信息
const char *jb_error(void);

// 加载成功后才可用
int      jb_init_primitives(void);  // 首选 jailbreakd 入口，回退旧入口
uint64_t jb_proc_self(void);
uint64_t jb_proc_find(pid_t pid);
uint64_t jb_proc_task(uint64_t proc);
int      jb_proc_rele(uint64_t proc);
int      jb_proc_vreadbuf(uint64_t proc, const void *addr, void *out, size_t len);
int      jb_kreadbuf(uint64_t kaddr, void *out, size_t size);
uint64_t jb_kread64(uint64_t va);
int      jb_kcall(uint64_t *result, uint64_t func, int argc, const uint64_t *argv);

#ifdef __cplusplus
}
#endif

#endif /* JB_H */
