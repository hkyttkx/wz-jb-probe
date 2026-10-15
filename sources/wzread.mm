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
#define OFF_OPC_IsDun            0x41E
#define OFF_OPC_LFootForIK       0x408
#define OFF_OPC_RFootForIK       0x410
#define OFF_OPC_CullingIndex     0x418
#define OFF_OPC_WorldPos         0x43C
#define OFF_OPC_Cameraforward    0x45C
// PlayerInfo
#define OFF_PI_IsOnline           0x18
#define OFF_PI_HeadId             0x1C
#define OFF_PI_Blood              0x24

// .NET Dictionary 布局（IL2CPP 与标准 .NET 基本一致）
#define OFF_DICT_ENTRIES 0x18
#define OFF_DICT_COUNT   0x20
#define ENTRY_SIZE       0x18
#define OFF_ENTRY_VALUE  0x10

static pid_t     g_pid   = 0;
static uint64_t  g_proc  = 0;
static task_t    g_task  = MACH_PORT_NULL;
static uint64_t  g_ga_base = 0;      // IL2CPP 模块基址
static uint64_t  g_main_base = 0;    // 主二进制基址
static uint64_t  g_main_size = 0;
static uint64_t  g_ga_size = 0;
static uint64_t  g_battleIns = 0;    // 找到的 Battle 实例
static uint64_t  g_battleSF  = 0;    // Battle 静态字段区基址
static uint64_t  g_manualIns = 0;    // 手动锚点（U3D 工具读出的真值）
static char      g_status[512] = {0};

// IL2CPP 模块的段信息（在 findModulesByMachO 里填充）
static uint64_t  g_ga_data_addr = 0; // __DATA 实际运行地址
static uint64_t  g_ga_data_size = 0;
static uint64_t  g_ga_text_vm   = 0; // __TEXT 的链接时 vmaddr（算 slide 用）

// 前置声明：定义在文件后部（WZReadInit 需要提前引用）
static void findModulesByMachO(void);
static void parseSegments(uint64_t base, uint64_t maxSize);

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

// 浮点辅助：是否为有限数（非 NaN / 非 Inf）
static int fx_finite(float f) {
    union { float f; uint32_t u; } v; v.f = f;
    return ((v.u >> 23) & 0xFF) != 0xFF;
}
static float z_absf(float f) { return f < 0 ? -f : f; }

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
#import <mach/vm_region.h>
extern "C" kern_return_t mach_vm_region(vm_map_t target_task,
                                        uint64_t *address,
                                        uint64_t *size,
                                        vm_region_flavor_t flavor,
                                        void *info,
                                        unsigned *infoCnt,
                                        mach_port_t *object_name);

// ── 找 GameAssembly 的内存区域 ───────────────────────
typedef struct { uint64_t addr; uint64_t size; } Reg;
#define WZ_MAX_REGIONS 8192
static Reg g_regs[WZ_MAX_REGIONS];
static int g_regCount = 0;
static int g_regTruncated = 0;   // 1=区域数超过上限，表被截断

static void scanRegions(void) {
    g_regCount = 0;
    uint64_t addr = 0;
    while (addr < 0x0000FFFF00000000ULL && g_regCount < WZ_MAX_REGIONS) {
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
        if (++g_regCount >= WZ_MAX_REGIONS) { g_regTruncated = 1; break; }
        addr = ri.address + ri.size;
    }
    snprintf(g_status, sizeof(g_status),
             "pid=%d proc=0x%llx GA=0x%llx(0x%llx) regions=%d",
             g_pid, g_proc, g_ga_base, g_ga_size, g_regCount);
}

// 用 task port 枚举区域（regions 用地址+大小，路径另外查）
static void scanRegionsMVM(void) {
    g_regCount = 0;
    if (g_task == MACH_PORT_NULL) { os_log(OS_LOG_DEFAULT, "[wzread] 无 task port"); return; }
    uint64_t addr = 0;
    while (addr < 0x0000FFFF00000000ULL && g_regCount < WZ_MAX_REGIONS) {
        uint64_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kern_return_t kr = mach_vm_region(g_task, &addr, &size, VM_REGION_BASIC_INFO_64,
                                          &info, &cnt, &obj);
        if (kr != KERN_SUCCESS || size == 0) break;
        // ★ 防死循环：size 为 0 或 addr 不前进时强制跳出
        uint64_t next = addr + size;
        if (next <= addr) break;
        // 只记录可读区域（模块/堆）。门槛 128KB：
        // 原来 1MB 太大，GameAssembly 的小段（__DATA_CONST 等）会被丢掉
        if ((info.protection & 1) && size >= 0x20000) {
            g_regs[g_regCount].addr = addr;
            g_regs[g_regCount].size = size;
            if (++g_regCount >= WZ_MAX_REGIONS) { g_regTruncated = 1; break; }
        }
        addr = next;
    }
    // 路径信息由 scanRegions() 补充；跨进程时 proc_pidinfo 通常不返回 path
    snprintf(g_status, sizeof(g_status),
             "pid=%d proc=0x%llx task=%d regions=%d",
             g_pid, g_proc, g_task, g_regCount);
}


extern "C" void WZReadProbe(char *out, size_t n) {
    int o = 0;
    o += snprintf(out+o, n-o, "pid=%d proc=0x%llx\n", g_pid, g_proc);
    o += snprintf(out+o, n-o, "IL2CPP模块: base=0x%llx size=0x%llx\n", g_ga_base, g_ga_size);
    o += snprintf(out+o, n-o, "  __TEXT.vm = 0x%llx\n", g_ga_text_vm);
    o += snprintf(out+o, n-o, "  __DATA    = 0x%llx size=0x%llx\n", g_ga_data_addr, g_ga_data_size);
    o += snprintf(out+o, n-o, "主二进制:  base=0x%llx size=0x%llx\n", g_main_base, g_main_size);
    o += snprintf(out+o, n-o, "regions(%d)%s:\n", g_regCount,
                  g_regTruncated ? " 【已截断!】" : "");
    for (int i = 0; i < g_regCount && i < 60 && o < (int)n - 80; i++) {
        char p[256]={0};
        struct { uint64_t address; uint64_t size; char path[1024]; char pad[2]; } ri;
        memset(&ri,0,sizeof(ri));
        if (proc_pidinfo(g_pid, PROC_PIDREGIONPATHINFO, g_regs[i].addr, &ri, sizeof(ri)) > 0)
            snprintf(p, sizeof(p), "%s", ri.path[0] ? ri.path : "-");
        o += snprintf(out+o, n-o, "  %014llx +%08llx  %s\n",
                      g_regs[i].addr, g_regs[i].size, p);
    }

    // ── Battle.Ins 深度诊断 ──────────────────────────
    uint64_t bi = WZFindBattleIns();
    o += snprintf(out+o, n-o, "\n── Battle 诊断 ──\n");
    o += snprintf(out+o, n-o, "Battle.Ins = 0x%llx\n", bi);
    if (bi) {
        o += snprintf(out+o, n-o, "  vtable(= [0])     = 0x%llx\n", rd64(bi + 0x00));
        o += snprintf(out+o, n-o, "  LoadFinish(0x18)  = 0x%llx\n", rd64(bi + OFF_Battle_LoadFinish));
        o += snprintf(out+o, n-o, "  SelfPlayer(0x20)  = 0x%llx\n", rd64(bi + OFF_Battle_SelfPlayer));
        o += snprintf(out+o, n-o, "  MainCamera(0x28)  = 0x%llx\n", rd64(bi + OFF_Battle_MainCamera));
        o += snprintf(out+o, n-o, "  OtherDic(0x58)    = 0x%llx\n", rd64(bi + OFF_Battle_OtherPlayersDic));
        o += snprintf(out+o, n-o, "  NearDic(0x60)     = 0x%llx\n", rd64(bi + OFF_Battle_NearPlayersDic));
        o += snprintf(out+o, n-o, "  TeamDic(0x100)    = 0x%llx\n", rd64(bi + OFF_Battle_TeamPlayerDic));
        // 原始 dump：前 0x120 字节
        o += snprintf(out+o, n-o, "  原始 [0x00..0x120):\n");
        for (uint64_t a = 0; a < 0x120 && o < (int)n - 120; a += 16) {
            uint64_t v0 = rd64(bi + a), v1 = rd64(bi + a + 8);
            o += snprintf(out+o, n-o, "    +%03llx: %016llx %016llx\n",
                          (unsigned long long)a,
                          (unsigned long long)v0, (unsigned long long)v1);
        }
        // 字典内部
        uint64_t dic = rd64(bi + OFF_Battle_OtherPlayersDic);
        o += snprintf(out+o, n-o, "  ── 字典 0x%llx ──\n", dic);
        if (dic && readable(dic)) {
            o += snprintf(out+o, n-o, "    buckets(0x10) = 0x%llx\n", rd64(dic + 0x10));
            o += snprintf(out+o, n-o, "    entries(0x18) = 0x%llx\n", rd64(dic + 0x18));
            o += snprintf(out+o, n-o, "    count  (0x20) = %u\n", rd32(dic + 0x20) & 0x7FFFFFFF);
            o += snprintf(out+o, n-o, "    ver    (0x28) = %u\n", rd32(dic + 0x28));
            o += snprintf(out+o, n-o, "    freeL  (0x30) = %u\n", rd32(dic + 0x30));
            o += snprintf(out+o, n-o, "    freeC  (0x34) = %u\n", rd32(dic + 0x34));
            o += snprintf(out+o, n-o, "    原始 [0x00..0x50):\n");
            for (uint64_t a = 0; a < 0x50 && o < (int)n - 120; a += 16) {
                uint64_t v0 = rd64(dic + a), v1 = rd64(dic + a + 8);
                o += snprintf(out+o, n-o, "      +%03llx: %016llx %016llx\n",
                              (unsigned long long)a,
                              (unsigned long long)v0, (unsigned long long)v1);
            }
        }
    } else {
        o += snprintf(out+o, n-o, "  (未找到) %s\n", g_status);
    }
    o += snprintf(out+o, n-o, "玩家数 = %d\n", WZReadPlayers(NULL, 0));

    // ── OtherPlayerController 直读路线诊断 ──
    o += snprintf(out+o, n-o, "\n── OtherPlayer 直读 ──\n");
    {
        static WZPlayer t[64];
        int n2 = WZScanOtherPlayers(t, 64);
        o += snprintf(out+o, n-o, "扫描到 %d 个 OtherPlayerController\n", n2);
        for (int i = 0; i < n2 && i < 8; i++) {
            o += snprintf(out+o, n-o,
                "  #%d obj=0x%llx pos=(%.1f,%.1f,%.1f) blood=%d head=%d online=%d\n",
                i, t[i].obj, t[i].pos.x, t[i].pos.y, t[i].pos.z,
                t[i].blood, t[i].headId, t[i].online);
        }
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

    // ★ 三路递进定位 IL2CPP 模块：
    //   ① scanRegions  —— 有 path 信息时能按名字匹配 GameAssembly/UnityFramework
    //   ② scanRegionsMVM —— task port 枚举（补区域表）
    //   ③ findModulesByMachO —— 按 Mach-O magic 兜底（跨进程无 path 时的主路径）
    scanRegions();
    scanRegionsMVM();
    if (!g_ga_base) findModulesByMachO();

    if (!g_ga_base) {
        snprintf(g_status,sizeof(g_status),"未找到 IL2CPP 模块（regions=%d main=0x%llx）",
                 g_regCount, g_main_base);
        return 2;      // 非致命：probe 仍会输出区域列表
    }
    snprintf(g_status, sizeof(g_status),
             "ok GA=0x%llx(0x%llx) data=0x%llx regions=%d",
             g_ga_base, g_ga_size, g_ga_data_addr, g_regCount);
    return 0;
}

// ── 解析单个 OtherPlayerController → WZPlayer ──
// 返回 1 成功
static int zPlayerFromObj(uint64_t o, WZPlayer *p) {
    if (!looksPtr(o) || !readable(o)) return 0;
    memset(p, 0, sizeof(*p));
    p->obj = o;

    // 坐标：优先 WorldPos(0x43C)，回退 m_TargetPos(0x3C4)
    float wx = rdf(o + OFF_OPC_WorldPos);
    float wy = rdf(o + OFF_OPC_WorldPos + 4);
    float wz = rdf(o + OFF_OPC_WorldPos + 8);
    int wOK = (wx == wx && wy == wy && wz == wz) &&      // 非 NaN
              (fx_finite(wx) && fx_finite(wy) && fx_finite(wz)) &&
              (wx != 0.0f || wy != 0.0f || wz != 0.0f) &&
              (z_absf(wx) < 1e7f && z_absf(wy) < 1e7f && z_absf(wz) < 1e7f);

    float tx = rdf(o + OFF_OPC_TargetPos);
    float ty = rdf(o + OFF_OPC_TargetPos + 4);
    float tz = rdf(o + OFF_OPC_TargetPos + 8);
    int tOK = (tx == tx && ty == ty && tz == tz) &&
              (fx_finite(tx) && fx_finite(ty) && fx_finite(tz)) &&
              (tx != 0.0f || ty != 0.0f || tz != 0.0f) &&
              (z_absf(tx) < 1e7f && z_absf(ty) < 1e7f && z_absf(tz) < 1e7f);

    if (wOK)      { p->pos.x = wx; p->pos.y = wy; p->pos.z = wz; }
    else if (tOK) { p->pos.x = tx; p->pos.y = ty; p->pos.z = tz; }

    // PlayerInfo
    uint64_t info = rd64(o + OFF_OPC_Info);
    if (looksPtr(info) && readable(info)) {
        p->blood  = (int)(rd32(info + OFF_PI_Blood) & 0x7FFFFFFF);
        p->headId = (int)rd32(info + OFF_PI_HeadId);
        p->online = (int)rd32(info + OFF_PI_IsOnline);
    }
    p->rebirthTime = (int)rd32(o + OFF_OPC_RebirthTime);
    p->isDun       = (int)rd32(o + OFF_OPC_IsDun);
    p->valid = 1;
    return 1;
}

// ── 判定候选 O 是否为 OtherPlayerController 对象 ──
// 依据 dump.cs 的真实字段布局
static int zIsOtherPlayerObj(uint64_t o) {
    if (!looksPtr(o) || !readable(o)) return 0;

    // ① Info（0x3F0）必须是合法指针，且内容像 PlayerInfo
    uint64_t info = rd64(o + OFF_OPC_Info);
    if (!looksPtr(info) || !readable(info)) return 0;
    int online = (int)rd32(info + OFF_PI_IsOnline);
    int head   = (int)rd32(info + OFF_PI_HeadId);
    int blood  = (int)rd32(info + OFF_PI_Blood);
    if (online != 0 && online != 1) return 0;          // isOnline: bool
    if (head < 0 || head > 100000) return 0;           // headId: 小整数
    if (blood < 0 || blood > 100000) return 0;         // blood: 合理范围

    // ② LFootForIK(0x408) / RFootForIK(0x410) 必须是合法指针
    uint64_t lf = rd64(o + OFF_OPC_LFootForIK);
    uint64_t rf = rd64(o + OFF_OPC_RFootForIK);
    if (!looksPtr(lf) || !looksPtr(rf)) return 0;

    // ③ WorldPos(0x43C) 必须是 3 个有限浮点
    float wx = rdf(o + OFF_OPC_WorldPos);
    float wy = rdf(o + OFF_OPC_WorldPos + 4);
    float wz = rdf(o + OFF_OPC_WorldPos + 8);
    if (!(wx == wx && wy == wy && wz == wz)) return 0;
    if (!(fx_finite(wx) && fx_finite(wy) && fx_finite(wz))) return 0;
    if (z_absf(wx) > 1e7f || z_absf(wy) > 1e7f || z_absf(wz) > 1e7f) return 0;

    // ④ CullingIndex(0x418) 小整数
    int ci = (int)rd32(o + OFF_OPC_CullingIndex);
    if (ci < 0 || ci > 100000) return 0;

    return 1;
}
//  策略：在 GameAssembly 的可写数据段里逐个 8 字节当候选指针，
//  读候选指向的对象，验证 Battle 的字段形态。
// ── Battle 静态字段布局（来自 dump.cs，Battle 类 static_fields 区）──
// 这是 IL2CPP 静态字段内存块，不是 Battle 对象内部。
//   +0x00 sToxicGasZone / +0x08 sSafeZone
//   +0x10..+0x78  14 个 readonly 委托（.cctor 后必然全部非零）
//   +0x80 <InLoading> bool
//   +0x88 Ins          ← 我们要找的
#define BF_INS_OFF   0x88
// readonly 委托字段区间（全部必须是非零指针）
#define BF_CB_FIRST  0x10
#define BF_CB_LAST   0x78

// 判定一个「静态字段区基址」SF 是否是 Battle 的 static_fields 块
//   SF + 0x88 = Ins 字段；其值应是合法的 Battle 对象指针
static int checkBattleSF(uint64_t SF) {
    if (SF < 0x100000000ULL) return 0;            // 太小
    if (SF & 7) return 0;                         // 必须 8 字节对齐

    // ① 核心判定：0x10..0x78 的 14 个 readonly 委托必须全部是非零合法指针
    //    （Battle..cctor 执行后这些一定被赋值；误命中几乎不可能凑齐 14 个连续非零指针）
    int hits = 0, total = 0;
    for (uint64_t off = BF_CB_FIRST; off <= BF_CB_LAST; off += 8) {
        uint64_t v = 0;
        if (rd(SF + off, &v, 8) != 0) return 0;
        total++;
        if (v >= 0x100000000ULL && (v & 7) == 0) hits++;
    }
    if (total < 14 || hits < 14) return 0;        // 必须 14/14 全中

    // ② Ins 字段（SF + 0x88）必须是合法对象指针
    uint64_t P = rd64(SF + BF_INS_OFF);
    if (P < 0x100000000ULL || (P & 7)) return 0;

    // ③ Ins 对象的 vtable 必须落在 IL2CPP 模块范围内
    uint64_t vt = rd64(P + 0x00);
    if (g_ga_base && g_ga_size) {
        if (vt < g_ga_base || vt >= g_ga_base + g_ga_size) return 0;
    } else {
        if (vt < 0x100000000ULL || (vt & 7)) return 0;
    }

    // ④ LoadFinish（Battle+0x18）必须是 bool
    uint8_t lf = 0;
    rd(P + OFF_Battle_LoadFinish, &lf, 1);
    if (lf > 1) return 0;

    // ⑤ OtherPlayersDic（Battle+0x58）必须是合法字典
    uint64_t dic = rd64(P + OFF_Battle_OtherPlayersDic);
    if (!looksPtr(dic) || !readable(dic)) return 0;
    uint64_t ent = rd64(dic + OFF_DICT_ENTRIES);
    if (!looksPtr(ent) || !readable(ent)) return 0;

    return 1;
}

// 兼容旧调用名：给定 Battle 对象地址 P，反推其静态字段区是否成立
static int checkBattleObj(uint64_t o) {
    if (o < 0x100000000ULL) return 0;
    uint64_t sf = o - BF_INS_OFF;                 // 尝试：o 就是 Ins 字段位置
    if (checkBattleSF(sf) && rd64(sf + BF_INS_OFF) == o) return 1;
    return 0;
}

// 通过扫描区域开头找 Mach-O 模块（拿不到路径时的替代）
// 解析 Mach-O 的 LC_SEGMENT_64，输出 __TEXT/__DATA 的 vmaddr 与 vmsize
// ★ 注意：只对「已经选定为 IL2CPP 模块」的那个 Mach-O 调用，避免被系统库污染
static void parseSegments(uint64_t base, uint64_t maxSize) {
    (void)maxSize;
    uint32_t magic = 0;
    if (rd(base, &magic, 4) != 0 || magic != 0xFEEDFACF) return;

    uint32_t ncmds = 0;
    rd(base + 16, &ncmds, 4);
    uint64_t cmdAddr = base + 32;   // mach_header_64 大小

    uint64_t textVM = 0, dataAddr = 0, dataSize = 0;

    for (uint32_t i = 0; i < ncmds && i < 2048; i++) {
        uint32_t cmd = 0, cmdsize = 0;
        if (rd(cmdAddr, &cmd, 4) != 0) break;
        if (rd(cmdAddr + 4, &cmdsize, 4) != 0) break;
        if (cmdsize < 8 || cmdsize > 0x10000) break;

        if (cmd == 0x19) {   // LC_SEGMENT_64
            char segname[17] = {0};
            rd(cmdAddr + 8, segname, 16);
            uint64_t vmaddr = 0, vmsize = 0;
            rd(cmdAddr + 24, &vmaddr, 8);
            rd(cmdAddr + 32, &vmsize, 8);
            os_log(OS_LOG_DEFAULT, "[wzread] seg %s vm=0x%llx sz=0x%llx", segname, vmaddr, vmsize);
            if (strcmp(segname, "__TEXT") == 0 && !textVM) {
                textVM = vmaddr;
            }
            if (!dataAddr &&
                (strcmp(segname, "__DATA") == 0 || strcmp(segname, "__DATA_CONST") == 0)) {
                dataAddr = vmaddr;
                dataSize = vmsize;
            }
        }
        cmdAddr += cmdsize;
    }

    // 全部段读完后统一算 slide，再写回全局（避免中途半成品状态）
    if (textVM && dataAddr) {
        uint64_t slide = base - textVM;
        g_ga_data_addr = dataAddr + slide;
        g_ga_data_size = dataSize;
        g_ga_text_vm   = textVM;
    }
}

static void findModulesByMachO(void) {
    uint64_t bestAddr = 0, bestSize = 0;
    uint64_t mainAddr = 0, mainSize = 0;

    for (int i = 0; i < g_regCount; i++) {
        uint32_t magic = 0;
        if (rd(g_regs[i].addr, &magic, 4) != 0) continue;
        if (magic != 0xFEEDFACF && magic != 0xFEEDFACE) continue;

        uint32_t filetype = 0;
        rd(g_regs[i].addr + 12, &filetype, 4);
        uint64_t sz = g_regs[i].size;
        os_log(OS_LOG_DEFAULT, "[wzread] Mach-O @0x%llx size=0x%llx type=%u",
               g_regs[i].addr, sz, filetype);

        // 主二进制 = 第一个 Mach-O（通常是 app 可执行文件，加载最早）
        if (!mainAddr) { mainAddr = g_regs[i].addr; mainSize = sz; }

        // IL2CPP 候选 = 最大的 Mach-O（UnityFramework 113MB 必是最大）
        if (sz > bestSize) { bestAddr = g_regs[i].addr; bestSize = sz; }
    }

    if (!g_main_base && mainAddr) { g_main_base = mainAddr; g_main_size = mainSize; }

    // ★ 关键修复：无条件解析段，不再被 !g_ga_base 挡住
    //   并且只有"最大的 Mach-O"才认定为 IL2CPP 模块
    if (!g_ga_base && bestAddr && bestSize > 0x200000) {
        g_ga_base = bestAddr;
        g_ga_size = bestSize;
        parseSegments(bestAddr, bestSize);
        os_log(OS_LOG_DEFAULT,
               "[wzread] IL2CPP 模块 @0x%llx (0x%llx) __DATA=0x%llx(0x%llx)",
               g_ga_base, g_ga_size, g_ga_data_addr, g_ga_data_size);
    } else if (g_ga_base && !g_ga_data_addr) {
        // g_ga_base 已由 scanRegions 填上，但段信息缺失 —— 补解析
        parseSegments(g_ga_base, g_ga_size);
        os_log(OS_LOG_DEFAULT,
               "[wzread] 补解析段: module=0x%llx __DATA=0x%llx(0x%llx)",
               g_ga_base, g_ga_data_addr, g_ga_data_size);
    }
}

extern "C" uint64_t WZFindBattleIns(void) {
    // ★ 优先：手动锚点（由 U3D 工具读出真值后设置）
    if (g_manualIns) {
        uint64_t sf = g_manualIns - BF_INS_OFF;   // 若 manualIns 就是对象地址
        // 先按「Ins 对象地址」理解：其静态字段区 = ？无法反推，直接当对象用
        if (looksPtr(g_manualIns) && readable(g_manualIns)) {
            uint64_t vt = rd64(g_manualIns);
            int vtOK = 1;
            if (g_ga_base && g_ga_size)
                vtOK = (vt >= g_ga_base && vt < g_ga_base + g_ga_size);
            if (vtOK) {
                g_battleIns = g_manualIns;
                snprintf(g_status,sizeof(g_status),"Battle.Ins=0x%llx (锚点)",g_manualIns);
                return g_manualIns;
            }
        }
        (void)sf;
    }

    if (g_battleIns && checkBattleObj(g_battleIns)) return g_battleIns;
    if (!g_ga_base) findModulesByMachO();
    if (!g_ga_base) {
        // 兜底：用主二进制作为扫描范围
        if (g_main_base) { g_ga_base = g_main_base; g_ga_size = g_main_size; }
        else return 0;
    }
    os_log(OS_LOG_DEFAULT, "[wzread] 扫描 0x%llx+0x%llx 找 Battle.Ins (data=0x%llx+0x%llx)",
           g_ga_base, g_ga_size, g_ga_data_addr, g_ga_data_size);

    uint64_t step = 8;
    uint8_t  blk[0x1000];

    // 内部扫描器：把每个 8 字节槽当作候选「静态字段区基址 SF」，
    // 因为 SF+0x88 恰是 Ins 字段，所以 SF 的候选 = 槽地址 - 0x88。
    // 直接遍历内存，对每个候选 SF 调 checkBattleSF 判定。
    #define SCAN_RANGE(START, LEN) do {                                        \
        uint64_t _end = (START) + (LEN);                                       \
        for (uint64_t _a = (START); _a + step <= _end; _a += sizeof(blk)) {    \
            size_t _want = sizeof(blk);                                        \
            if (_a + _want > _end) _want = (size_t)(_end - _a);                \
            if (rd(_a, blk, _want) != 0) break;                                \
            for (size_t _off = 0; _off + 8 <= _want; _off += step) {           \
                uint64_t _slot = _a + _off;                                    \
                if (_slot < BF_INS_OFF) continue;                              \
                uint64_t _sf = _slot - BF_INS_OFF;   /* 候选静态字段区基址 */  \
                if (!checkBattleSF(_sf)) continue;                             \
                uint64_t _ins = rd64(_sf + BF_INS_OFF);                        \
                g_battleIns = _ins;                                            \
                g_battleSF  = _sf;                                             \
                os_log(OS_LOG_DEFAULT, "[wzread] ★ Battle.Ins=0x%llx (SF=0x%llx slot=0x%llx)", \
                       _ins, _sf, _slot);                                      \
                snprintf(g_status,sizeof(g_status),"Battle.Ins=0x%llx SF=0x%llx",_ins,_sf); \
                return _ins;                                                   \
            }                                                                  \
        }                                                                      \
    } while (0)

    // ① 优先扫 __DATA 段（IL2CPP 托管静态字段在这里，命中率最高、范围最小）
    if (g_ga_data_addr && g_ga_data_size) {
        os_log(OS_LOG_DEFAULT, "[wzread] 阶段1: 扫 __DATA");
        SCAN_RANGE(g_ga_data_addr, g_ga_data_size);
    }

    // ② 再扫整个 IL2CPP 模块映射（含 __TEXT，兜底）
    os_log(OS_LOG_DEFAULT, "[wzread] 阶段2: 扫整个模块");
    SCAN_RANGE(g_ga_base, g_ga_size);

    // ③ 最后扫所有可写区域（有些游戏把对象放独立堆/匿名映射）
    os_log(OS_LOG_DEFAULT, "[wzread] 阶段3: 扫可写区域");
    for (int i = 0; i < g_regCount; i++) {
        uint64_t a = g_regs[i].addr, sz = g_regs[i].size;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (mach_vm_region(g_task, &a, &sz, VM_REGION_BASIC_INFO_64,
                           &info, &cnt, &obj) != KERN_SUCCESS) continue;
        if (!(info.protection & 2)) continue;      // 2 = VM_PROT_WRITE
        if (sz < 0x40000) continue;
        // 跳过已经扫过的 IL2CPP 模块范围
        if (a >= g_ga_base && a < g_ga_base + g_ga_size) continue;
        SCAN_RANGE(a, sz);
    }
    #undef SCAN_RANGE

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

extern "C" int WZReadPlayers(WZPlayer *out, int maxCount) {
    uint64_t bi = WZFindBattleIns();
    if (!bi) return 0;

    uint64_t dic = rd64(bi + OFF_Battle_OtherPlayersDic);
    if (!looksPtr(dic) || !readable(dic)) return 0;

    uint64_t entries = rd64(dic + OFF_DICT_ENTRIES);
    int count = (int)(rd32(dic + OFF_DICT_COUNT) & 0x7FFFFFFF);
    // 诊断模式（out==NULL）：不读数据，只返回 count，便于 WZReadProbe 展示
    if (!out) return count;
    if (!looksPtr(entries) || count <= 0) return 0;
    if (count > 2048) count = 2048;   // 放宽上限（原 512 太紧）

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

// ── 手动锚点：由 U3D 工具读出 Battle.Ins 真值后调用 ──
extern "C" void WZSetManualIns(uint64_t ins) {
    g_manualIns = ins;
    g_battleIns = 0;          // 清缓存，强制重算
    os_log(OS_LOG_DEFAULT, "[wzread] 设置手动锚点 Battle.Ins=0x%llx", ins);
}

// ── 从外部文件读取锚点（HUD 可写文件，方便无需重编译）──
// 文件格式：第一行 "ins=0x..." 或纯十六进制
#define WZ_ANCHOR_PATH "/var/mobile/Library/Caches/com.wz.jbprobe.anchor"
extern "C" int WZLoadAnchor(void) {
    FILE *f = fopen(WZ_ANCHOR_PATH, "r");
    if (!f) return -1;
    char line[128] = {0};
    if (!fgets(line, sizeof(line), f)) { fclose(f); return -1; }
    fclose(f);
    char *p = strstr(line, "0x");
    uint64_t v = 0;
    if (p) v = strtoull(p, NULL, 16);
    else   v = strtoull(line, NULL, 16);
    if (!v) return -1;
    WZSetManualIns(v);
    return 0;
}

// ══════════════════════════════════════════════════════
//  OtherPlayerController 直读路线（不依赖 Battle）
// ══════════════════════════════════════════════════════

static uint64_t g_manualObjs[64];
static int      g_manualObjCount = 0;

// 手动填入 OtherPlayerController 地址（U3D 工具读出）
extern "C" void WZSetManualObjs(const uint64_t *objs, int count) {
    if (count > 64) count = 64;
    for (int i = 0; i < count; i++) g_manualObjs[i] = objs[i];
    g_manualObjCount = count;
    os_log(OS_LOG_DEFAULT, "[wzread] 手动对象数 = %d", count);
}

// 验证单个地址：打印所有字段解析结果（调试用）
extern "C" int WZVerifyObj(uint64_t o, char *out, size_t n) {
    int off = 0;
    off += snprintf(out+off, n-off, "对象 0x%llx\n", o);
    if (!looksPtr(o) || !readable(o)) {
        off += snprintf(out+off, n-off, "  不可读\n");
        return -1;
    }
    uint64_t vt = rd64(o + 0);
    off += snprintf(out+off, n-off, "  vtable        = 0x%llx (模块内=%s)\n", vt,
                    (g_ga_base && vt >= g_ga_base && vt < g_ga_base+g_ga_size) ? "是" : "否");
    off += snprintf(out+off, n-off, "  m_TargetPos   = (%.1f, %.1f, %.1f) @0x3C4\n",
                    rdf(o+OFF_OPC_TargetPos), rdf(o+OFF_OPC_TargetPos+4), rdf(o+OFF_OPC_TargetPos+8));
    off += snprintf(out+off, n-off, "  WorldPos      = (%.1f, %.1f, %.1f) @0x43C\n",
                    rdf(o+OFF_OPC_WorldPos), rdf(o+OFF_OPC_WorldPos+4), rdf(o+OFF_OPC_WorldPos+8));
    off += snprintf(out+off, n-off, "  m_speed       = %.1f @0x3D0\n", rdf(o+0x3D0));
    off += snprintf(out+off, n-off, "  Info          = 0x%llx @0x3F0\n", rd64(o+OFF_OPC_Info));
    uint64_t info = rd64(o+OFF_OPC_Info);
    if (looksPtr(info) && readable(info)) {
        off += snprintf(out+off, n-off, "    role        = 0x%llx @0x10\n", rd64(info+0x10));
        off += snprintf(out+off, n-off, "    isOnline    = %u\n", rd32(info+OFF_PI_IsOnline) & 0xFF);
        off += snprintf(out+off, n-off, "    headId      = %d\n", (int)rd32(info+OFF_PI_HeadId));
        off += snprintf(out+off, n-off, "    headFrame   = %d\n", (int)rd32(info+0x20));
        off += snprintf(out+off, n-off, "    blood       = %d\n", (int)rd32(info+OFF_PI_Blood));
        off += snprintf(out+off, n-off, "    playerState = %u\n", rd32(info+0x28) & 0xFF);
        off += snprintf(out+off, n-off, "    reLiveTime  = %d\n", (int)rd32(info+0x2C));
    } else {
        off += snprintf(out+off, n-off, "    (Info 不可读)\n");
    }
    off += snprintf(out+off, n-off, "  LFootForIK    = 0x%llx @0x408\n", rd64(o+OFF_OPC_LFootForIK));
    off += snprintf(out+off, n-off, "  RFootForIK    = 0x%llx @0x410\n", rd64(o+OFF_OPC_RFootForIK));
    off += snprintf(out+off, n-off, "  CullingIndex  = %d @0x418\n", (int)rd32(o+OFF_OPC_CullingIndex));
    off += snprintf(out+off, n-off, "  RebirthTime   = %d @0x3FC\n", (int)rd32(o+OFF_OPC_RebirthTime));
    off += snprintf(out+off, n-off, "  IsDun         = %u @0x41E\n", rd32(o+OFF_OPC_IsDun) & 0xFF);
    off += snprintf(out+off, n-off, "  IsVirtual     = %u @0x41F\n", rd32(o+OFF_OPC_IsDun+1) & 0xFF);
    off += snprintf(out+off, n-off, "  RedNameScore  = %d @0x438\n", (int)rd32(o+0x438));
    off += snprintf(out+off, n-off, "  → 判定结果: %s\n", zIsOtherPlayerObj(o) ? "★ 有效 OtherPlayerController" : "× 不符合");
    return zIsOtherPlayerObj(o) ? 0 : -1;
}

// 扫描托管堆找所有 OtherPlayerController
extern "C" int WZScanOtherPlayers(WZPlayer *out, int maxCount) {
    int n = 0;

    // ① 先用手动列表（优先）
    for (int i = 0; i < g_manualObjCount && n < maxCount; i++) {
        if (zIsOtherPlayerObj(g_manualObjs[i]))
            zPlayerFromObj(g_manualObjs[i], &out[n++]);
    }
    if (n > 0) return n;

    // ② 扫描托管堆范围（OtherPlayerController 实测在 0x16xxxxxxx ~ 0x17xxxxxxx）
    const uint64_t ranges[][2] = {
        { 0x160000000ULL, 0x10000000ULL },   // 0x160000000 - 0x170000000
        { 0x170000000ULL, 0x10000000ULL },   // 0x170000000 - 0x180000000
    };
    uint8_t blk[0x1000];
    for (int r = 0; r < 2 && n < maxCount; r++) {
        uint64_t start = ranges[r][0], len = ranges[r][1];
        uint64_t end = start + len;
        for (uint64_t a = start; a + 8 <= end && n < maxCount; a += sizeof(blk)) {
            size_t want = sizeof(blk);
            if (a + want > end) want = (size_t)(end - a);
            if (rd(a, blk, want) != 0) continue;   // 整块不可读就跳过（不 break）
            for (size_t off = 0; off + 8 <= want && n < maxCount; off += 8) {
                uint64_t cand = *(uint64_t *)(blk + off);
                if (!looksPtr(cand)) continue;
                if (!zIsOtherPlayerObj(cand)) continue;
                // 去重
                int dup = 0;
                for (int k = 0; k < n; k++) if (out[k].obj == cand) { dup = 1; break; }
                if (dup) continue;
                if (zPlayerFromObj(cand, &out[n])) n++;
            }
        }
    }
    os_log(OS_LOG_DEFAULT, "[wzread] 扫描到 %d 个 OtherPlayerController", n);
    return n;
}
