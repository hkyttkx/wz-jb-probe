//
//  ImGuiViewController.mm
//  可开关的 HUD：普通模式（App 内）/ 悬浮模式（root 宿主，覆盖游戏）
//  支持横竖屏自适应
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
#import <float.h>
#import <os/log.h>
#import <signal.h>

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

static const float kBtnH = 66.0f;    // ≈22pt 触摸高度
static const float kBtnW = 250.0f;

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
    BOOL _menuVisible;
    BOOL _overlayMode;
    pid_t _hudHostPid;
    BOOL _isLandscape;      // 当前是否横屏
    float _safeTop;         // 安全区（像素）
    float _safeBottom;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    self.mtkView.delegate = self;
    self.mtkView.preferredFramesPerSecond = 60;
    self.mtkView.opaque = NO;
    self.mtkView.backgroundColor = [UIColor clearColor];
    self.mtkView.clearColor = MTLClearColorMake(0.04f, 0.04f, 0.055f, 1.0f);
    self.mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.mtkView];

    self.commandQueue = [device newCommandQueue];
    self.outputText = @"选一行进程 → 点「读取目标进程」。";
    _selRow = -1;
    _procCount = 0;
    _menuVisible = YES;
    _overlayMode = NO;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    ImGuiStyle &st = ImGui::GetStyle();
    st.WindowRounding = 10.0f;  st.FrameRounding = 6.0f;  st.GrabRounding = 6.0f;
    st.WindowBorderSize = 0.0f;
    st.WindowPadding = ImVec2(16, 14);
    st.FramePadding  = ImVec2(12, 10);
    st.ItemSpacing   = ImVec2(10, 10);
    st.ScrollbarSize = 24.0f;
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
        if (fp) io.Fonts->AddFontFromFileTTF(fp.UTF8String, 30.0f, &cfg, ranges.Data);
        else    io.Fonts->AddFontDefault();
        io.Fonts->Build();
    }
    ImGui_ImplMetal_Init(device);

    [self updateOrientation];
    [self refreshProcs];

    // 监听旋转
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onOrientation:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(_timer, ^{ [ws refreshProcs]; });
    dispatch_resume(_timer);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

- (void)onOrientation:(NSNotification *)n {
    [self updateOrientation];
    [self applyGeometry];
    // 旋转后坐标全变，清掉 ImGui 的指针状态，避免"按下去没抬起"卡死
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseButtonEvent(0, false);
    io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);
}

- (void)updateOrientation {
    CGRect b = UIScreen.mainScreen.bounds;
    _isLandscape = b.size.width > b.size.height;
    UIEdgeInsets ins = self.view.safeAreaInsets;
    CGFloat sc = UIScreen.mainScreen.scale;
    _safeTop    = (ins.top  > 0 ? ins.top  : 44.0) * sc;
    _safeBottom = (ins.bottom > 0 ? ins.bottom : 34.0) * sc;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self applyGeometry];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self updateOrientation];
    [self applyGeometry];
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
        if (pids[i] == getpid()) strlcpy(nm, "WZJBProbe", sizeof(nm));
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

#pragma mark - 几何

// 收起态：右上角圆形按钮（直径自适应）
- (CGRect)circleFrame {
    CGRect scr = UIScreen.mainScreen.bounds;
    CGFloat shortSide = MIN(scr.size.width, scr.size.height);
    CGFloat d = shortSide * 0.17;          // 自适应直径
    d = MAX(d, 56.0);                       // 不小于 56pt
    CGFloat m = 14.0;
    CGFloat top = (self.view.safeAreaInsets.top > 0 ? self.view.safeAreaInsets.top : 44.0) + m;
    return CGRectMake(scr.size.width - d - m, top, d, d);
}

// 展开态：居中面板（横竖屏比例不同）
- (CGRect)panelFrame {
    CGRect scr = UIScreen.mainScreen.bounds;
    CGFloat w = _isLandscape ? scr.size.width  * 0.56 : scr.size.width  * 0.90;
    CGFloat h = _isLandscape ? scr.size.height * 0.86 : scr.size.height * 0.70;
    return CGRectMake((scr.size.width - w) * 0.5, (scr.size.height - h) * 0.5, w, h);
}

- (void)setOverlay:(BOOL)on {
    if (on) [self startHUDHost]; else [self stopHUDHost];
    _overlayMode = on;
    _menuVisible = !on;
    [self applyGeometry];
    HUDWindow *win = [self hudWin];
    if (win) win.hidden = on;
}

- (void)startHUDHost {
    if (_hudHostPid > 0) return;
    char exe[PATH_MAX];
    uint32_t sz = sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) != 0) return;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, 1);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);

    const char *argv[] = { exe, "--hud", NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, NULL, &attr, (char *const *)argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc == 0) { _hudHostPid = pid; os_log(OS_LOG_DEFAULT, "[WZ] HUD宿主 pid=%d", pid); }
    else os_log(OS_LOG_DEFAULT, "[WZ] HUD宿主启动失败 rc=%d", rc);
}

- (void)stopHUDHost {
    if (_hudHostPid > 0) {
        kill(_hudHostPid, SIGKILL);
        os_log(OS_LOG_DEFAULT, "[WZ] HUD宿主停止 pid=%d", _hudHostPid);
        _hudHostPid = 0;
    }
}

- (void)applyGeometry {
    HUDWindow *win = [self hudWin];
    if (!win) return;

    [UIView setAnimationsEnabled:NO];
    if (!_overlayMode) {
        win.frame = UIScreen.mainScreen.bounds;
        win.backgroundColor = [UIColor blackColor];
        win.opaque = YES;
        self.mtkView.clearColor = MTLClearColorMake(0.04f, 0.04f, 0.055f, 1.0f);
    } else {
        win.backgroundColor = [UIColor clearColor];
        win.opaque = NO;
        self.mtkView.clearColor = MTLClearColorMake(0.0f, 0.0f, 0.0f, 0.0f);  // 完全透明
        win.frame = _menuVisible ? [self panelFrame] : [self circleFrame];
    }
    [UIView setAnimationsEnabled:YES];

    // 尺寸突变后清输入状态，防止按钮"卡住"
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseButtonEvent(0, false);
    io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);

    os_log(OS_LOG_DEFAULT, "[WZ] geom ov=%d menu=%d land=%d %.0fx%.0f",
           _overlayMode, _menuVisible, _isLandscape, win.frame.size.width, win.frame.size.height);
}

#pragma mark - 界面

- (void)drawUI {
    ImGuiIO &io = ImGui::GetIO();
    const float W = io.DisplaySize.x, H = io.DisplaySize.y;
    const float sc = UIScreen.mainScreen.scale;

    // ── 收起态：圆形按钮（自绘，支持点击）──
    if (_overlayMode && !_menuVisible) {
        ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
        ImGui::SetNextWindowSize(ImVec2(W, H), ImGuiCond_Always);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
        ImGui::Begin("##circle", NULL,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                     ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                     ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBackground);

        ImGui::InvisibleButton("##hit", ImVec2(W, H));
        bool hovered = ImGui::IsItemHovered();
        bool clicked = ImGui::IsItemClicked();

        ImDrawList *dl = ImGui::GetWindowDrawList();
        ImVec2 c(W * 0.5f, H * 0.5f);
        float r = MIN(W, H) * 0.46f;
        ImU32 fill = hovered ? IM_COL32(48, 118, 200, 240) : IM_COL32(30, 84, 152, 225);
        dl->AddCircleFilled(c, r, fill, 48);
        dl->AddCircle(c, r, IM_COL32(130, 200, 255, 255), 48, 4.0f * sc * 0.6f);

        const char *txt = "菜单";
        ImVec2 ts = ImGui::CalcTextSize(txt);
        dl->AddText(ImVec2(c.x - ts.x * 0.5f, c.y - ts.y * 0.5f), IM_COL32_WHITE, txt);

        if (clicked) {
            _menuVisible = YES;
            HUDSetPassthrough(NO);
            [self applyGeometry];
        }
        ImGui::End();
        ImGui::PopStyleVar();
        return;
    }

    // ── 展开态 / 普通模式面板 ──
    const float pad   = 20.0f;
    const float topIn = _overlayMode ? 14.0f : (_safeTop + 10.0f);
    const float botIn = _overlayMode ? 14.0f : (_safeBottom + 10.0f);
    const float pw = W - pad * 2.0f;
    const float ph = H - topIn - botIn;

    ImGui::SetNextWindowPos(ImVec2(pad, topIn), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(pw, ph), ImGuiCond_Always);
    ImGui::Begin("##main", NULL,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse |
                 ImGuiWindowFlags_NoSavedSettings);

    const float inner = ImGui::GetContentRegionAvail().y;

    // ① 状态 + 模式按钮
    ImGui::TextColored(ImVec4(0.35f, 1.0f, 0.45f, 1.0f), "● 就绪");
    ImGui::SameLine();
    ImGui::TextDisabled("| %d 进程 | %s%s", _procCount,
                        _overlayMode ? "悬浮" : "普通", _isLandscape ? "·横屏" : "·竖屏");

    if (_overlayMode) {
        float bw = 260.0f;
        ImGui::SameLine(ImGui::GetContentRegionAvail().x - bw);
        if (ImGui::Button("收起", ImVec2(105, kBtnH))) {
            _menuVisible = NO; HUDSetPassthrough(YES); [self applyGeometry];
        }
        ImGui::SameLine();
        if (ImGui::Button("退出", ImVec2(140, kBtnH))) [self setOverlay:NO];
    } else {
        ImGui::SameLine(ImGui::GetContentRegionAvail().x - 300.0f);
        if (ImGui::Button("开启悬浮", ImVec2(290, kBtnH))) [self setOverlay:YES];
    }
    ImGui::Separator();

    // ② 进程列表
    ImGui::TextDisabled("目标进程");
    ImGui::SameLine(ImGui::GetContentRegionAvail().x - 120.0f);
    if (ImGui::Button("刷新", ImVec2(110, kBtnH - 16))) [self refreshProcs];

    ImGui::BeginChild("##proc", ImVec2(0, inner * 0.34f), true);
    for (int i = 0; i < _procCount; i++) {
        char label[160];
        snprintf(label, sizeof(label), "%5d  %s", _procs[i].pid, _procs[i].name);
        if (ImGui::Selectable(label, _selRow == i)) _selRow = i;
    }
    ImGui::EndChild();

    // ③ 操作
    if (_selRow >= 0 && _selRow < _procCount)
        ImGui::Text("已选：%s (pid=%d)", _procs[_selRow].name, _procs[_selRow].pid);
    else
        ImGui::TextDisabled("已选：（点列表选一行）");

    ImGui::BeginDisabled(_selRow < 0 || self.busy);
    if (ImGui::Button("读取目标", ImVec2(kBtnW, kBtnH)) && _selRow >= 0)
        [self runJob:@[ @"--read", [NSString stringWithFormat:@"%d", _procs[_selRow].pid] ]];
    ImGui::SameLine();
    if (ImGui::Button("自检", ImVec2(120, kBtnH))) [self runJob:@[ @"--probe" ]];
    ImGui::EndDisabled();
    if (self.busy) { ImGui::SameLine(); ImGui::TextColored(ImVec4(1,0.8,0.3,1), "执行中…"); }
    ImGui::Separator();

    // ④ 输出
    ImGui::TextDisabled("输出");
    ImGui::BeginChild("##out", ImVec2(0, 0), true, ImGuiWindowFlags_HorizontalScrollbar);
    ImGui::TextUnformatted(self.outputText.UTF8String);
    ImGui::EndChild();

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
