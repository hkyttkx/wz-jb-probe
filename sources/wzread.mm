//
//  wzread.mm
//  跨进程读「王牌战争」的运行时数据
//  偏移全部来自 Il2CppDumper 的 dump.cs
//
#import <Foundation/Foundation.h>
#import <mach/mach.h>

#import <os/log.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <libkern/OSByteOrder.h>
#import "wzread.h"

// libjailbreak 的跨进程读（已验证可用）
extern "C" uint64_t jb_proc_by_pid(pid_t pid);
extern "C" int      jb_read_process(uint64_t proc, uint64_t addr, void *buf, size_t len);

// proc_pidinfo（iOS SDK 无 libproc.h，自行声明）
extern "C" int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
#define PROC_PIDREGIONPATHINFO 8
#define PROC_PIDREGIONINFO     7

// ── dump.cs 里的偏移 ─────────────────────────────────
// Battle
#define OFF_Battle_Ins            0x88    // static Battle Ins
#define OFF_Battle_LoadFinish     0x18
#define OFF_Battle_SelfPlayer     0x20
#define OFF_Battle_MainCamera     0x28
#define OFF_Battle_OtherPlayersDic 0x58
#define OFF_Battle_NearPlayersDic 0x60
#define OFF_Battle_TeamPlayerDic  0x100
// OtherPlayerController
#define OFF_OPC_TargetPos         0x3C4
#define OFF_OPC_Info              0x3F0
#define OFF_OPC_RebirthTime       0x3FC
#define OFF_OPC_IsDun             0x41E
// PlayerInfo
#define OFF_PI_IsOnline           0x18
#define OFF_PI_HeadId             0x1C
#define OFF_PI_Blood              0x24

static pid_t     g_pid   = 0;
static uint64_t  g_proc  = 0;
static task_t    g_task  = MACH_PORT_NULL;
static uint64_t  g_ga_base = 0;      // IL2CPP 模块基址
static uint64_t  g_main_base = 0;    // 主二进制基址
static uint64_t  g_main_size = 0;
static uint64_t  g_ga_size = 0;
static uint64_t  g_battleIns = 0;    // 找到的 Battle 实例
static char      g_status[512] = {0};

extern "C" const char *WZReadStatus(void) { return g_status; }

// ── 读内存（走 libjailbreak 的 proc_vreadbuf）─────────
extern "C" int mach_vm_read_overwrite(vm_map_t, uint64_t, uint64_t, uint64_t, uint64_t *);

static int rd(uint64_t addr, void *buf, size_t len) {
    if (!addr) return -1;
    // ① 优先 libjailbreak 的跨进程读
    if (g_proc) {
        if (jb_read_process(g_proc, addr, buf, len) == 0) return 0;
    }
    // ② 回退：用 task port 直读（task_for_pid 已成功）
    if (g_task != MACH_PORT_NULL) {
        uint64_t out = 0;
        kern_return_t kr = mach_vm_read_overwrite(g_task, addr, len,
                                                 (uint64_t)(uintptr_t)buf, &out);
        if (kr == KERN_SUCCESS && out == len) return 0;
    }
    return -1;
}
static uint64_t rd64(uint64_t addr) { uint64_t v=0; rd(addr,&v,8); return v; }
static uint32_t rd32(uint64_t addr) { uint32_t v=0; rd(addr,&v,4); return v; }
static float    rdf (uint64_t addr) { float v=0; rd(addr,&v,4); return v; }

// 地址是否像堆/数据指针
static int looksPtr(uint64_t p) {
    if (p < 0x100000000ULL) return 0;             // 太小
    if (p > 0x0000FFFF00000000ULL) return 0;      // 太大（非用户态）
    return (p % 8) == 0;                          // 8 字节对齐
}
// 地址是否可读（试探读一字节）
static int readable(uint64_t p) {
    uint32_t t = 0;
    return rd(p, &t, 4) == 0;
}


// ── 手写声明（iOS SDK 禁用了 mach_vm.h）──
typedef int vm_region_flavor_t;
typedef struct vm_region_basic_info_64 {
    int      protection;
    int      max_protection;
    uint32_t inheritance;
    uint8_t  shared;
    uint8_t  reserved;
    uint32_t offset;
    int      behavior;
    uint16_t user_wired_count;
} vm_region_basic_info_data_64_t;
#define VM_REGION_BASIC_INFO_64 9
#define VM_REGION_BASIC_INFO_COUNT_64 9
extern "C" kern_return_t mach_vm_region(vm_map_t target_task,
                                        uint64_t *address,
                                        uint64_t *size,
                                        vm_region_flavor_t flavor,
                                        void *info,
                                        unsigned *infoCnt,
                                        mach_port_t *object_name);

// 用 task port 枚举区域（regions 用地址+大小，路径另外查）
static void scanRegionsMVM(void) {
    g_regCount = 0;
    if (g_task == MACH_PORT_NULL) { os_log(OS_LOG_DEFAULT, "[wzread] 无 task port"); return; }
    uint64_t addr = 0;
    while (addr < 0x0000FFFF00000000ULL && g_regCount < 64) {
        uint64_t size = 0;
        vm_region_basic_info_data_64_t info;
        unsigned cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kern_return_t kr = mach_vm_region(g_task, &addr, &size, VM_REGION_BASIC_INFO_64,
                                          &info, &cnt, &obj);
        if (kr != KERN_SUCCESS || size == 0) break;
        // 只记录可读且较大的区域（模块/堆）
        if ((info.protection & 1) && size >= 0x1000) {
            g_regs[g_regCount].addr = addr;
            g_regs[g_regCount].size = size;
            g_regCount++;
        }
        addr += size;
    }
    // 路径信息另查（proc_pidinfo 有就用，没有就算了）
    for (int i = 0; i < g_regCount; i++) {
        char path[512] = {0};
        // 尝试用 sysctl/proc_pidinfo 补路径（失败不影响）
        (void)path;
    }
    snprintf(g_status, sizeof(g_status),
             "pid=%d proc=0x%llx task=%d regions=%d",
             g_pid, g_proc, g_task, g_regCount);
}

// ── 找 GameAssembly 的内存区域 ───────────────────────
typedef struct { uint64_t addr; uint64_t size; } Reg;
static Reg g_regs[64];
static int g_regCount = 0;

static void scanRegions(void) {
    g_regCount = 0;
    uint64_t addr = 0;
    while (addr < 0x0000FFFF00000000ULL && g_regCount < 64) {
        char path[512] = {0};
        // PROC_PIDREGIONPATHINFO: {r_address, r_size, path...}
        struct { uint64_t address; uint64_t size; char path[1024]; char pad[2]; } ri;
        memset(&ri, 0, sizeof(ri));
        int sz = proc_pidinfo(g_pid, PROC_PIDREGIONPATHINFO, addr, &ri, sizeof(ri));
        if (sz <= 0) break;
        if (ri.size == 0) break;
        // Unity IL2CPP 的代码段命名不统一：GameAssembly / UnityFramework / 主二进制
        if (!g_ga_base && (strstr(ri.path, "GameAssembly") ||
                           strstr(ri.path, "UnityFramework"))) {
            g_ga_base = ri.address;
            g_ga_size = ri.size;
            os_log(OS_LOG_DEFAULT, "[wzread] IL2CPP 模块 %s @ 0x%llx size 0x%llx",
                   ri.path, g_ga_base, g_ga_size);
        }
        // 兜底：记录 .app 主二进制
        if (!g_main_base && strstr(ri.path, ".app/") && !strstr(ri.path, "Frameworks")) {
            g_main_base = ri.address; g_main_size = ri.size;
        }
        g_regs[g_regCount].addr = ri.address;
        g_regs[g_regCount].size = ri.size;
        g_regCount++;
        addr = ri.address + ri.size;
    }
    snprintf(g_status, sizeof(g_status),
             "pid=%d proc=0x%llx GA=0x%llx(0x%llx) regions=%d",
             g_pid, g_proc, g_ga_base, g_ga_size, g_regCount);
}

extern "C" void WZReadProbe(char *out, size_t n) {
    int o = 0;
    o += snprintf(out+o, n-o, "pid=%d proc=0x%llx\n", g_pid, g_proc);
    o += snprintf(out+o, n-o, "IL2CPP模块: base=0x%llx size=0x%llx\n", g_ga_base, g_ga_size);
    o += snprintf(out+o, n-o, "主二进制:  base=0x%llx size=0x%llx\n", g_main_base, g_main_size);
    o += snprintf(out+o, n-o, "regions(%d):\n", g_regCount);
    for (int i = 0; i < g_regCount && o < (int)n - 80; i++) {
        char p[256]={0};
        struct { uint64_t address; uint64_t size; char path[1024]; char pad[2]; } ri;
        memset(&ri,0,sizeof(ri));
        if (proc_pidinfo(g_pid, PROC_PIDREGIONPATHINFO, g_regs[i].addr, &ri, sizeof(ri)) > 0)
            snprintf(p, sizeof(p), "%s", ri.path[0] ? ri.path : "-");
        o += snprintf(out+o, n-o, "  %014llx +%08llx  %s\n",
                      g_regs[i].addr, g_regs[i].size, p);
    }
}

// ── 初始化 ───────────────────────────────────────────
extern "C" int WZReadInit(pid_t pid) {
    g_pid = pid;
    g_proc = jb_proc_by_pid(pid);

    kern_return_t kr = task_for_pid(mach_task_self(), pid, &g_task);
    os_log(OS_LOG_DEFAULT, "[wzread] proc=0x%llx task_for_pid=%d", g_proc, kr);

    if (!g_proc && kr != KERN_SUCCESS) {
        snprintf(g_status,sizeof(g_status),"proc_find 与 task_for_pid 都失败 (pid=%d)",pid);
        return -1;
    }
    snprintf(g_status,sizeof(g_status),"ok proc=0x%llx task=%d", g_proc, g_task);

    scanRegionsMVM();       // ★ 用 task port 枚举（proc_pidinfo 对别的进程不给）
    if (!g_ga_base) {
        snprintf(g_status,sizeof(g_status),"未找到 IL2CPP 模块（regions=%d main=0x%llx）",
                 g_regCount, g_main_base);
        return 2;      // 非致命：probe 仍会输出区域列表
    }
    return 0;
}

// ── 扫描找 Battle.Ins ────────────────────────────────
//  策略：在 GameAssembly 的可写数据段里逐个 8 字节当候选指针，
//  读候选指向的对象，验证 Battle 的字段形态。
static int checkBattleObj(uint64_t o) {
    if (!looksPtr(o) || !readable(o)) return 0;
    uint64_t self  = rd64(o + OFF_Battle_SelfPlayer);
    uint64_t cam   = rd64(o + OFF_Battle_MainCamera);
    uint64_t dic   = rd64(o + OFF_Battle_OtherPlayersDic);
    uint64_t team  = rd64(o + OFF_Battle_TeamPlayerDic);
    // 至少 SelfPlayer / MainCamera / OtherPlayersDic / TeamPlayerDic 里
    // 有 3 个是合法指针
    int ok = 0;
    if (looksPtr(self) && readable(self))  ok++;
    if (looksPtr(cam)  && readable(cam))   ok++;
    if (looksPtr(dic)  && readable(dic))   ok++;
    if (looksPtr(team) && readable(team))  ok++;
    uint8_t lf = 0;
    rd(o + OFF_Battle_LoadFinish, &lf, 1);
    if (lf > 1) ok -= 2;                 // LoadFinish 应是 bool
    return ok >= 3;
}

// 通过扫描区域开头找 Mach-O 模块（拿不到路径时的替代）
static void findModulesByMachO(void) {
    for (int i = 0; i < g_regCount; i++) {
        uint32_t magic = 0;
        if (rd(g_regs[i].addr, &magic, 4) != 0) continue;
        if (magic == 0xFEEDFACF || magic == 0xFEEDFACE) {
            // Mach-O 头 → 读文件类型
            uint32_t filetype = 0;
            rd(g_regs[i].addr + 12, &filetype, 4);
            uint64_t sz = g_regs[i].size;
            os_log(OS_LOG_DEFAULT, "[wzread] Mach-O @0x%llx size=0x%llx type=%u",
                   g_regs[i].addr, sz, filetype);
            // 大模块（>8MB）很可能是 UnityFramework
            if (sz > 0x800000 && !g_ga_base) {
                g_ga_base = g_regs[i].addr;
                g_ga_size = sz;
                os_log(OS_LOG_DEFAULT, "[wzread] 疑似 IL2CPP 模块 @0x%llx (0x%llx)",
                       g_ga_base, g_ga_size);
            }
            if (!g_main_base) { g_main_base = g_regs[i].addr; g_main_size = sz; }
        }
    }
}

extern "C" uint64_t WZFindBattleIns(void) {
    if (g_battleIns && checkBattleObj(g_battleIns)) return g_battleIns;
    if (!g_ga_base) findModulesByMachO();
    if (!g_ga_base) {
        // 兜底：用主二进制作为扫描范围
        if (g_main_base) { g_ga_base = g_main_base; g_ga_size = g_main_size; }
        else return 0;
    }
    os_log(OS_LOG_DEFAULT, "[wzread] 扫描 0x%llx+0x%llx 找 Battle.Ins", g_ga_base, g_ga_size);
    // 扫整个 GameAssembly 映射（含 __DATA）
    uint64_t step = 8;
    uint64_t end  = g_ga_base + g_ga_size;
    uint8_t  blk[0x1000];
    for (uint64_t a = g_ga_base; a + step <= end; a += sizeof(blk)) {
        size_t want = sizeof(blk);
        if (a + want > end) want = (size_t)(end - a);
        if (rd(a, blk, want) != 0) break;
        for (size_t off = 0; off + 8 <= want; off += step) {
            uint64_t cand = *(uint64_t *)(blk + off);
            if (!looksPtr(cand)) continue;
            if (checkBattleObj(cand)) {
                g_battleIns = cand;
                os_log(OS_LOG_DEFAULT, "[wzread] ★ Battle.Ins = 0x%llx (slot 0x%llx)",
                       cand, a + off);
                snprintf(g_status,sizeof(g_status),"Battle.Ins=0x%llx",cand);
                return cand;
            }
        }
    }
    snprintf(g_status,sizeof(g_status),"未找到 Battle.Ins");
    return 0;
}

// ── Dictionary 遍历 ──────────────────────────────────
// .NET Dictionary 布局（.NET/Mono 通用，偏移按 64 位）：
//   +0x10 buckets
//   +0x18 entries
//   +0x20 count      (低位 32 位)
//   +0x28 version
//   +0x30 freeList
//   +0x34 freeCount
//   +0x38 comparer
// Entry 结构（.NET 标准）：
//   +0x00 hashCode (4)
//   +0x04 next     (4)
//   +0x08 key
//   +0x10 value
#define OFF_DICT_ENTRIES 0x18
#define OFF_DICT_COUNT   0x20
#define ENTRY_SIZE       0x18
#define OFF_ENTRY_VALUE  0x10

extern "C" int WZReadPlayers(WZPlayer *out, int maxCount) {
    uint64_t bi = WZFindBattleIns();
    if (!bi) return 0;

    uint64_t dic = rd64(bi + OFF_Battle_OtherPlayersDic);
    if (!looksPtr(dic) || !readable(dic)) return 0;

    uint64_t entries = rd64(dic + OFF_DICT_ENTRIES);
    int count = (int)(rd32(dic + OFF_DICT_COUNT) & 0x7FFFFFFF);
    if (!looksPtr(entries) || count <= 0 || count > 512) return 0;

    int n = 0;
    uint8_t eb[ENTRY_SIZE * 8];
    for (int i = 0; i < count && n < maxCount; i += 8) {
        int batch = (count - i > 8) ? 8 : (count - i);
        if (rd(entries + (uint64_t)i * ENTRY_SIZE, eb, (size_t)batch * ENTRY_SIZE) != 0) break;
        for (int k = 0; k < batch && n < maxCount; k++) {
            uint64_t v = *(uint64_t *)(eb + k * ENTRY_SIZE + OFF_ENTRY_VALUE);
            if (!looksPtr(v) || !readable(v)) continue;
            WZPlayer *p = &out[n];
            memset(p, 0, sizeof(*p));
            p->obj = v;
            p->pos.x = rdf(v + OFF_OPC_TargetPos);
            p->pos.y = rdf(v + OFF_OPC_TargetPos + 4);
            p->pos.z = rdf(v + OFF_OPC_TargetPos + 8);
            uint64_t info = rd64(v + OFF_OPC_Info);
            if (looksPtr(info) && readable(info)) {
                p->blood  = (int)(rd32(info + OFF_PI_Blood) & 0x7FFFFFFF);
                p->headId = (int)rd32(info + OFF_PI_HeadId);
                p->online = (int)rd32(info + OFF_PI_IsOnline);
            }
            p->rebirthTime = (int)rd32(v + OFF_OPC_RebirthTime);
            p->isDun       = (int)rd32(v + OFF_OPC_IsDun);
            p->valid = 1;
            n++;
        }
    }
    return n;
}

// ── 相机 ─────────────────────────────────────────────
extern "C" int WZReadCamera(WZVec3 *pos, WZVec3 *angles, float *fov) {
    uint64_t bi = WZFindBattleIns();
    if (!bi) return -1;
    uint64_t cam = rd64(bi + OFF_Battle_MainCamera);
    if (!looksPtr(cam) || !readable(cam)) return -1;
    // vThirdPersonCamera 内部结构未知，先返回原始地址供上层调试
    if (pos) { pos->x = (float)cam; pos->y = 0; pos->z = 0; }
    return 0;
}
