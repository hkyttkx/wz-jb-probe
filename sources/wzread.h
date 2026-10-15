//
//  wzread.h
//  跨进程读游戏数据（王牌战争）
//  全部走 proc_vreadbuf（已验证可用），不需要内核读
//
#ifndef WZREAD_H
#define WZREAD_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float x, y, z;
} WZVec3;

typedef struct {
    int      valid;      // 1=有效
    uint64_t obj;        // OtherPlayerController 地址
    WZVec3   pos;        // m_TargetPos @0x3C4
    int      blood;      // Info->blood @0x24
    int      headId;     // Info->headId @0x1C
    int      online;     // Info->isOnline @0x18
    int      rebirthTime;// @0x3FC
    int      isDun;      // @0x41E
} WZPlayer;

// 初始化：绑定目标游戏进程
int  WZReadInit(pid_t pid);

// 探测：列出模块/内存区域（写入 out 文本）
void WZReadProbe(char *out, size_t n);

// 找 Battle.Ins（扫描）
uint64_t WZFindBattleIns(void);

// 读所有其他玩家
int  WZReadPlayers(WZPlayer *out, int maxCount);

// 读相机（自己视角）
int  WZReadCamera(WZVec3 *pos, WZVec3 *angles, float *fov);


// 手动锚点（U3D 工具读出真值后设置，跳过扫描）
void WZSetManualIns(uint64_t ins);
int  WZLoadAnchor(void);


// OtherPlayerController 直读路线
void WZSetManualObjs(const uint64_t *objs, int count);
int  WZVerifyObj(uint64_t o, char *out, size_t n);
int  WZScanOtherPlayers(WZPlayer *out, int maxCount);

// 状态文本
const char *WZReadStatus(void);

#ifdef __cplusplus
}
#endif
#endif
