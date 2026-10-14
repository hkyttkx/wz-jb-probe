//
//  wzdraw.h
//  绘制层：读取模块在这里"放"要画的东西，UI 每帧消费
//  —— 与数据来源解耦：谁读到的都行，只要调用 WZDrawXxx
//
#ifndef WZDRAW_H
#define WZDRAW_H

#ifdef __cplusplus
extern "C" {
#endif

#define WZ_MAX_ITEMS 512

typedef enum {
    WZ_ITEM_BOX = 0,     // 方框
    WZ_ITEM_TEXT,        // 文字
    WZ_ITEM_LINE,        // 线
    WZ_ITEM_CIRCLE,      // 圆
} WZItemKind;

typedef struct {
    int   kind;
    float x, y;          // 屏幕坐标（像素，左上）
    float w, h;          // 框/圆用
    float x2, y2;        // 线用（终点）
    float r, g, b, a;    // 颜色
    float thickness;
    char  text[64];
} WZDrawItem;

// 每帧开始前清空（UI 调用）
void WZDrawClear(void);
// 取当前帧的项（UI 调用）
int  WZDrawCount(void);
const WZDrawItem *WZDrawGet(int index);

// 读取模块/任何来源填充（线程安全，内部加锁）
void WZDrawBox(float x, float y, float w, float h,
               float r, float g, float b, float a, float thickness);
void WZDrawLine(float x1, float y1, float x2, float y2,
                float r, float g, float b, float a, float thickness);
void WZDrawCircle(float cx, float cy, float radius,
                  float r, float g, float b, float a, float thickness);
void WZDrawText(float x, float y, const char *text,
                float r, float g, float b, float a);
// 血条（框 + 填充比例 0..1）
void WZDrawHealthBar(float x, float y, float w, float h, float ratio);

#ifdef __cplusplus
}
#endif
#endif
