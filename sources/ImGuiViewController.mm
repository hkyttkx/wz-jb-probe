//
//  ImGuiViewController.mm
//  可开关的 HUD：普通模式（App 内操作）/ 悬浮模式（覆盖游戏）
//
#import "ImGuiViewController.h"
#import <MetalKit/MetalKit.h>
#import <spawn.h>
#import <mach-o/dyld.h>
#import <sys/wait.h>
#import <unistd.h>
#import <string.h>
#import <limits.h>
#import <stdlib.h>
#import <ctype.h>
#import <os/log.h>

#import "imgui.h"
#import "imgui_impl_metal.h"
#import "HUDWindow.h"

extern char **environ;
extern "C" {
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, unsigned int buffersize);
int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);
}

typedef struct { int pid; char name[128]; } ProcEntry;
#define MAXPROC 512

@interface ImGuiViewController () <MTKViewDelegate>
@property (nonatomic, strong) MTKView *mtkView;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) NSString *outputText;
@property (nonatomic, assign) BOOL busy;
@end

@implementation ImGuiViewController {
    ProcEntry _procs[MAXPROC];
    int  _procCount;
    int  _selRow;
    dispatch_source_t _timer;
    BOOL _menuVisible;    // 悬浮模式下菜单是否展开
    BOOL _overlayMode;    // 是否悬浮模式
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    self.mtkView.delegate = self;
    self.mtkView.preferredFramesPerSecond = 60;
    self.mtkView.opaque = NO;
    self.mtkView.backgroundColor = [UIColor clearColor];
    self.mtkView.clearColor = MTLClearColorMake(0.04, 0.04, 0.055, 0.92);  // 半透明底
    self.mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.mtkView];

    self.commandQueue = [device newCommandQueue];
    self.outputText = @"选择目标进程 → 点「读取目标进程」。";
    _selRow = -1;
    _procCount = 0;
    _menuVisible = YES;
    _overlayMode = NO;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    ImGuiStyle &st = ImGui::GetStyle();
    st.WindowRounding = 8.0f;
    st.FrameRounding  = 5.0f;
    st.WindowBorderSize = 1.0f;
    st.WindowPadding = ImVec2(14, 12);
    st.ItemSpacing = ImVec2(10, 9);
    {
        ImGuiIO &io = ImGui::GetIO();
        io.Fonts->Clear();
        static ImFontConfig cfg;
        cfg.FontDataOwnedByAtlas = false;
        static ImVector<ImWchar> ranges;
        ImFontGlyphRangesBuilder b;
        b.AddRanges(io.Fonts->GetGlyphRangesDefault());
        b.AddRanges(io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
        b.BuildRanges(&ranges);
        NSString *fp = [[NSBundle mainBundle] pathForResource:@"font" ofType:@"ttf"];
        if (fp) io.Fonts->AddFontFromFileTTF(fp.UTF8String, 32.0f, &cfg, ranges.Data);
        else    io.Fonts->AddFontDefault();
        io.Fonts->Build();
    }
    ImGui_ImplMetal_Init(device);

    [self refreshProcs];

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(_timer, ^{ [ws refreshProcs]; });
    dispatch_resume(_timer);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self applyGeometry];      // 此时窗口已就绪
}

- (HUDWindow *)hudWin {
    UIWindow *w = self.view.window;
    return [w isKindOfClass:[HUDWindow class]] ? (HUDWindow *)w : nil;
}

- (NSString *)outPath {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [doc stringByAppendingPathComponent:@"job.txt"];
}

- (void)refreshProcs {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return;
    pid_t *pids = (pid_t *)malloc(sizeof(pid_t) * n);
    if (!pids) return;
    int got = proc_listallpids(pids, sizeof(pid_t) * n);
    int cnt = 0;
    for (int i = 0; i < got && cnt < MAXPROC; i++) {
        char nm[128] = {0};
        if (proc_name(pids[i], nm, sizeof(nm)) <= 0 || nm[0] == 0) continue;
        _procs[cnt].pid = pids[i];
        strlcpy(_procs[cnt].name, nm, sizeof(_procs[cnt].name));
        cnt++;
    }
    free(pids);
    _procCount = cnt;
}

- (void)runJob:(NSArray<NSString *> *)args {
    if (self.busy) return;
    self.busy = YES;
    self.outputText = @"执行中…";
    NSString *out = [self outPath];
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char exe[PATH_MAX];
        uint32_t sz = sizeof(exe);
        if (_NSGetExecutablePath(exe, &sz) != 0) { self.outputText = @"取路径失败"; self.busy = NO; return; }

        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        posix_spawnattr_set_persona_np(&attr, 99, 1);
        posix_spawnattr_set_persona_uid_np(&attr, 0);
        posix_spawnattr_set_persona_gid_np(&attr, 0);

        const char *argv[10]; int c = 0;
        argv[c++] = exe;
        for (NSString *a in args) argv[c++] = a.UTF8String;
        argv[c++] = out.UTF8String;
        argv[c] = NULL;

        pid_t pid = 0;
        int rc = posix_spawn(&pid, exe, NULL, &attr, (char *const *)argv, environ);
        posix_spawnattr_destroy(&attr);
        if (rc != 0) { self.outputText = [NSString stringWithFormat:@"spawn 失败 %d (%s)", rc, strerror(rc)]; self.busy = NO; return; }
        int stat = 0; waitpid(pid, &stat, 0);
        NSString *res = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:nil];
        self.outputText = res.length ? res : @"（无输出）";
        self.busy = NO;
    });
}

#pragma mark - 界面

- (void)setOverlay:(BOOL)on {
    HUDWindow *win = [self hudWin];
    if (win) HUDSetOverlayMode(win, on);
    _overlayMode = on;
    _menuVisible = !on;               // 进入悬浮先收起
    [self applyGeometry];
}

// 关键：悬浮模式下窗口只占菜单那块，避免"糊一层黑纸"
- (void)applyGeometry {
    HUDWindow *win = [self hudWin];
    if (!win) return;
    CGRect scr = UIScreen.mainScreen.bounds;

    [UIView setAnimationsEnabled:NO];   // 免得动画期间 ImGui 尺寸抖动
    if (!_overlayMode) {
        win.frame = scr;                // 普通模式：全屏正常 App
        win.backgroundColor = [UIColor blackColor];
        win.opaque = YES;
        self.mtkView.clearColor = MTLClearColorMake(0.04, 0.04, 0.055, 1.0);
    } else {
        win.backgroundColor = [UIColor clearColor];
        win.opaque = NO;
        self.mtkView.clearColor = MTLClearColorMake(0.04, 0.04, 0.055, 0.94);
        if (_menuVisible) {
            CGFloat w = MIN(scr.size.width - 40.0, 520.0);
            CGFloat h = MIN(scr.size.height * 0.66, 900.0);
            win.frame = CGRectMake((scr.size.width - w) * 0.5,
                                   (scr.size.height - h) * 0.5, w, h);
        } else {
            CGFloat s = 104.0;          // 收起：右上角小方块
            win.frame = CGRectMake(scr.size.width - s - 16.0, 92.0, s, s);
        }
    }
    [UIView setAnimationsEnabled:YES];
    os_log(OS_LOG_DEFAULT, "[WZ] geometry overlay=%d menu=%d frame=%.0fx%.0f",
           _overlayMode, _menuVisible, win.frame.size.width, win.frame.size.height);
}

- (void)drawUI {
    ImGuiIO &io = ImGui::GetIO();
    const float W = io.DisplaySize.x, H = io.DisplaySize.y;

    // ── 悬浮模式 + 收起：只留一个小唤醒按钮 ──
    if (_overlayMode && !_menuVisible) {
        const float bw = 130.0f, bh = 130.0f;
        ImGui::SetNextWindowPos(ImVec2(W - bw - 40.0f, 260.0f), ImGuiCond_Always);
        ImGui::SetNextWindowSize(ImVec2(bw, bh), ImGuiCond_Always);
        ImGui::Begin("##mini", NULL,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                     ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                     ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBackground);
        if (ImGui::Button("菜单", ImVec2(bw - 16, bh - 16))) {
            _menuVisible = YES;
            HUDSetPassthrough(NO);
        }
        ImGui::End();
        return;
    }

    // ── 主面板（填满当前窗口，窗口尺寸由 applyGeometry 控制）──
    const float pw = W;
    const float ph = H - 70.0f;      // 底部留状态条
    ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(pw, ph), ImGuiCond_Always);
    ImGui::Begin("WZ 控制台", NULL, ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoMove);

    // 状态 + 模式切换
    ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.5f, 1.0f), "libjailbreak 可用");
    ImGui::SameLine();
    ImGui::TextDisabled("· %d 个进程", _procCount);

    ImGui::SameLine(ImGui::GetWindowWidth() - ( _overlayMode ? 420.0f : 260.0f));
    if (_overlayMode) {
        if (ImGui::Button("收起", ImVec2(120, 0))) {
            _menuVisible = NO;
            HUDSetPassthrough(YES);       // 收起后触摸穿透，游戏可玩
        }
        ImGui::SameLine();
        if (ImGui::Button("退出悬浮", ImVec2(170, 0))) {
            [self setOverlay:NO];
        }
    } else {
        if (ImGui::Button("开启悬浮 HUD", ImVec2(240, 0))) {
            [self setOverlay:YES];
        }
    }
    ImGui::Separator();

    // 进程列表
    if (ImGui::Button("刷新", ImVec2(110, 0))) [self refreshProcs];
    ImGui::SameLine();
    ImGui::TextDisabled("点一行选中目标");

    ImGui::BeginChild("##proc", ImVec2(0, ph * 0.42f), true);
    for (int i = 0; i < _procCount; i++) {
        char label[160];
        snprintf(label, sizeof(label), "%5d   %s", _procs[i].pid, _procs[i].name);
        if (ImGui::Selectable(label, _selRow == i)) _selRow = i;
    }
    ImGui::EndChild();

    // 目标 + 操作
    if (_selRow >= 0 && _selRow < _procCount)
        ImGui::Text("目标：%s  (pid=%d)", _procs[_selRow].name, _procs[_selRow].pid);
    else
        ImGui::TextDisabled("目标：（未选择）");

    ImGui::BeginDisabled(_selRow < 0 || self.busy);
    if (ImGui::Button("读取目标进程", ImVec2(230, 0)) && _selRow >= 0)
        [self runJob:@[ @"--read", [NSString stringWithFormat:@"%d", _procs[_selRow].pid] ]];
    ImGui::SameLine();
    if (ImGui::Button("自检", ImVec2(120, 0)))
        [self runJob:@[ @"--probe" ]];
    ImGui::EndDisabled();
    ImGui::SameLine();
    if (self.busy) ImGui::TextColored(ImVec4(1.0f, 0.8f, 0.3f, 1.0f), "执行中…");

    // 输出
    ImGui::BeginChild("##out", ImVec2(0, 0), true, ImGuiWindowFlags_HorizontalScrollbar);
    ImGui::TextUnformatted(self.outputText.UTF8String);
    ImGui::EndChild();

    ImGui::End();

    // 底部状态
    ImGui::SetNextWindowPos(ImVec2((W - pw) * 0.5f, (H + ph) * 0.5f - 96.0f), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(pw, 60.0f), ImGuiCond_Always);
    ImGui::Begin("##st", NULL,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove |
                 ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoSavedSettings |
                 ImGuiWindowFlags_NoBringToFrontOnFocus);
    ImGui::Text("ImGui %s", IMGUI_VERSION);
    ImGui::SameLine();
    ImGui::TextColored(ImVec4(0.5f, 0.8f, 1.0f, 1.0f), "  %.0f FPS", io.Framerate);
    ImGui::SameLine();
    ImGui::TextDisabled("  %s · Metal", _overlayMode ? "悬浮模式" : "普通模式");
    ImGui::End();
}

#pragma mark - 触摸 → ImGui

- (void)feedPos:(UITouch *)t {
    if (!t) return;
    CGPoint p = [t locationInView:self.mtkView];
    CGFloat sc = UIScreen.mainScreen.scale;
    ImGui::GetIO().AddMousePosEvent((float)(p.x * sc), (float)(p.y * sc));
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    [self feedPos:touches.anyObject]; ImGui::GetIO().AddMouseButtonEvent(0, true);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    [self feedPos:touches.anyObject];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    [self feedPos:touches.anyObject]; ImGui::GetIO().AddMouseButtonEvent(0, false);
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    ImGui::GetIO().AddMouseButtonEvent(0, false);
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    ImGuiIO &io = ImGui::GetIO();
    CGSize d = view.drawableSize;
    if (d.width < 1.0 || d.height < 1.0) {
        CGFloat sc = UIScreen.mainScreen.scale;
        d = CGSizeMake(view.bounds.size.width * sc, view.bounds.size.height * sc);
    }
    io.DisplaySize = ImVec2(d.width, d.height);
    io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);

    id<MTLCommandBuffer> cb = [self.commandQueue commandBuffer];
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) { [cb commit]; return; }

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();
    [self drawUI];
    ImGui::Render();

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
    [cb presentDrawable:view.currentDrawable];
    [cb commit];
}

@end
