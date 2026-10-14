//
//  wzdraw.mm
//  绘制项的容器（线程安全）
//
#import "wzdraw.h"
#import <string.h>
#import <os/lock.h>

static WZDrawItem g_items[WZ_MAX_ITEMS];
static int        g_count = 0;
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;

extern "C" void WZDrawClear(void) {
    os_unfair_lock_lock(&g_lock);
    g_count = 0;
    os_unfair_lock_unlock(&g_lock);
}

extern "C" int WZDrawCount(void) { return g_count; }

extern "C" const WZDrawItem *WZDrawGet(int index) {
    if (index < 0 || index >= g_count) return NULL;
    return &g_items[index];
}

static WZDrawItem *push(void) {
    if (g_count >= WZ_MAX_ITEMS) return NULL;
    WZDrawItem *it = &g_items[g_count++];
    memset(it, 0, sizeof(*it));
    it->thickness = 1.5f;
    it->a = 1.0f;
    return it;
}

extern "C" void WZDrawBox(float x, float y, float w, float h,
                          float r, float g, float b, float a, float thickness) {
    os_unfair_lock_lock(&g_lock);
    WZDrawItem *it = push();
    if (it) {
        it->kind = WZ_ITEM_BOX;
        it->x = x; it->y = y; it->w = w; it->h = h;
        it->r = r; it->g = g; it->b = b; it->a = a;
        it->thickness = thickness > 0 ? thickness : 1.5f;
    }
    os_unfair_lock_unlock(&g_lock);
}

extern "C" void WZDrawLine(float x1, float y1, float x2, float y2,
                           float r, float g, float b, float a, float thickness) {
    os_unfair_lock_lock(&g_lock);
    WZDrawItem *it = push();
    if (it) {
        it->kind = WZ_ITEM_LINE;
        it->x = x1; it->y = y1; it->x2 = x2; it->y2 = y2;
        it->r = r; it->g = g; it->b = b; it->a = a;
        it->thickness = thickness > 0 ? thickness : 1.5f;
    }
    os_unfair_lock_unlock(&g_lock);
}

extern "C" void WZDrawCircle(float cx, float cy, float radius,
                             float r, float g, float b, float a, float thickness) {
    os_unfair_lock_lock(&g_lock);
    WZDrawItem *it = push();
    if (it) {
        it->kind = WZ_ITEM_CIRCLE;
        it->x = cx; it->y = cy; it->w = radius * 2.0f; it->h = radius * 2.0f;
        it->r = r; it->g = g; it->b = b; it->a = a;
        it->thickness = thickness > 0 ? thickness : 1.5f;
    }
    os_unfair_lock_unlock(&g_lock);
}

extern "C" void WZDrawText(float x, float y, const char *text,
                           float r, float g, float b, float a) {
    if (!text) return;
    os_unfair_lock_lock(&g_lock);
    WZDrawItem *it = push();
    if (it) {
        it->kind = WZ_ITEM_TEXT;
        it->x = x; it->y = y;
        it->r = r; it->g = g; it->b = b; it->a = a;
        strlcpy(it->text, text, sizeof(it->text));
    }
    os_unfair_lock_unlock(&g_lock);
}

extern "C" void WZDrawHealthBar(float x, float y, float w, float h, float ratio) {
    if (ratio < 0) ratio = 0;
    if (ratio > 1) ratio = 1;
    // 底框
    WZDrawBox(x, y, w, h, 0.0f, 0.0f, 0.0f, 0.85f, 1.0f);
    // 填充（绿→黄→红）
    float r = ratio > 0.5f ? (1.0f - ratio) * 2.0f : 1.0f;
    float g = ratio > 0.5f ? 1.0f : ratio * 2.0f;
    if (w * ratio > 0.5f)
        WZDrawBox(x + 1, y + 1, w * ratio - 2, h - 2, r, g, 0.15f, 0.95f, 1.0f);
}
