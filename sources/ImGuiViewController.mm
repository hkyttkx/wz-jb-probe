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
#import "wzdraw.h"

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
    float _menuScale;       // 菜单缩放 0.7 ~ 1.6
    CGPoint _ballPos;       // 悬浮球左上角（屏幕 point）
    CGPoint _panelPos;      // 菜单左上角（屏幕 point）
    BOOL _hasBallPos;
    BOOL _hasPanelPos;
    BOOL _drawing;   // 跨进程绘制是否运行中
    BOOL _started;   // 是否已进入主菜单
    BOOL _showDraw;  // 是否显示绘制叠加
    int  _wzDrawPid; // 要读的游戏 pid
    BOOL _hudRunning;// 主 App：HUD 是否在运行
    char _gameName[64];   // 游戏进程名（默认 sc）
    int  _gamePid;        // 连接到的 pid
    BOOL _gameConnected;
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
    _hasBallPos = NO;
    _started = NO;
    _showDraw = YES;
    _hasPanelPos = NO;
    {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        float sc = [ud floatForKey:@"WZMenuScale"];
        _menuScale = (sc >= 0.5f && sc <= 2.0f) ? sc : 1.0f;
        if ([ud objectForKey:@"WZBallX"]) {
            _ballPos = CGPointMake([ud floatForKey:@"WZBallX"], [ud floatForKey:@"WZBallY"]);
            _hasBallPos = YES;
        }
        if ([ud objectForKey:@"WZPanelX"]) {
            _panelPos = CGPointMake([ud floatForKey:@"WZPanelX"], [ud floatForKey:@"WZPanelY"]);
            _hasPanelPos = YES;
        }
    }
    // HUD 宿主进程：默认悬浮 + 收起（只显示悬浮球）
    extern int gHUDHostMode;
    if (gHUDHostMode) { _overlayMode = YES; _menuVisible = NO; }
    else              { _overlayMode = NO;  _menuVisible = YES; }

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

- (UIWindow *)hudWin {
    return self.view.window;
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

- (void)runJobAsync:(NSArray<NSString *> *)args {
    NSString *out = [self outPath];
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
    self.outputText = @"跨进程绘制已启动，看桌面/游戏画面";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char exe[PATH_MAX]; uint32_t sz = sizeof(exe);
        if (_NSGetExecutablePath(exe, &sz) != 0) return;
        posix_spawnattr_t attr; posix_spawnattr_init(&attr);
        posix_spawnattr_set_persona_np(&attr, 99, 1);
        posix_spawnattr_set_persona_uid_np(&attr, 0);
        posix_spawnattr_set_persona_gid_np(&attr, 0);
        const char *argv[8]; int c = 0;
        argv[c++] = exe;
        for (NSString *a in args) argv[c++] = a.UTF8String;
        argv[c++] = out.UTF8String;
        argv[c] = NULL;
        pid_t pid = 0;
        (void)posix_spawn(&pid, exe, NULL, &attr, (char *const *)argv, environ);
        posix_spawnattr_destroy(&attr);
    });
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
    UIWindow *win = [self hudWin];
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
    // 主 App 是普通用户，杀不动 root 宿主；
    // 用一个 uid=0 的 --exit 子进程去 kill（TrollSpeed 同款做法）
    char exe[PATH_MAX];
    uint32_t sz = sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) != 0) return;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, 1);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    const char *argv[] = { exe, "--exit", NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, NULL, &attr, (char *const *)argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc == 0) {
        int st = 0; waitpid(pid, &st, 0);
        os_log(OS_LOG_DEFAULT, "[WZ] 已请求关闭 HUD");
    } else {
        os_log(OS_LOG_DEFAULT, "[WZ] 关闭 HUD 失败 rc=%d", rc);
    }
    _hudHostPid = 0;
}

- (void)saveScale {
    [[NSUserDefaults standardUserDefaults] setFloat:_menuScale forKey:@"WZMenuScale"];
}

- (void)applyGeometry {
    UIWindow *win = [self hudWin];
    if (!win) return;
    CGRect scr = UIScreen.mainScreen.bounds;
    [UIView setAnimationsEnabled:NO];
    if (!_overlayMode) {
        win.frame = scr;
        win.backgroundColor = [UIColor blackColor];
        win.opaque = YES;
        self.mtkView.clearColor = MTLClearColorMake(0.04f, 0.04f, 0.055f, 1.0f);
    } else {
        win.backgroundColor = [UIColor clearColor];
        win.opaque = NO;
        self.mtkView.clearColor = MTLClearColorMake(0.0f, 0.0f, 0.0f, 0.0f);  // 完全透明

        // 用真实屏幕尺寸判断横竖屏（宿主进程 UIDevice.orientation 不可靠）
        BOOL land = scr.size.width > scr.size.height;
        _isLandscape = land;

        if (_menuVisible) {
            // 横屏：更宽更扁；竖屏：细长
            CGFloat w = land ? MIN(scr.size.width  - 40.0, 980.0 * _menuScale)
                             : MIN(scr.size.width  - 24.0, 470.0 * _menuScale);
            CGFloat h = land ? MIN(scr.size.height - 40.0, 560.0 * _menuScale)
                             : MIN(scr.size.height - 24.0, 760.0 * _menuScale);
            CGFloat x, y;
            if (_hasPanelPos) { x = _panelPos.x; y = _panelPos.y; }
            else { x = (scr.size.width - w) * 0.5; y = (scr.size.height - h) * 0.5; }
            x = MAX(0, MIN(x, scr.size.width  - w));
            y = MAX(0, MIN(y, scr.size.height - h));
            _panelPos = CGPointMake(x, y); _hasPanelPos = YES;
            win.frame = CGRectMake(x, y, w, h);
        } else {
            CGFloat shortSide = MIN(scr.size.width, scr.size.height);
            CGFloat d = MAX(shortSide * 0.17 * _menuScale, 44.0);
            CGFloat x, y;
            if (_hasBallPos) { x = _ballPos.x; y = _ballPos.y; }
            else if (land)   { x = scr.size.width - d - 24.0; y = scr.size.height * 0.5 - d * 0.5; }
            else             { x = scr.size.width - d - 14.0; y = 60.0; }
            x = MAX(0, MIN(x, scr.size.width  - d));
            y = MAX(0, MIN(y, scr.size.height - d));
            _ballPos = CGPointMake(x, y); _hasBallPos = YES;
            win.frame = CGRectMake(x, y, d, d);
        }
    }
    [UIView setAnimationsEnabled:YES];

    // 尺寸/位置突变后清输入状态，防止按钮"卡住"
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseButtonEvent(0, false);
    io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);

    os_log(OS_LOG_DEFAULT, "[WZ] geom ov=%d menu=%d scale=%.2f %.0fx%.0f",
           _overlayMode, _menuVisible, _menuScale, win.frame.size.width, win.frame.size.height);
}

// 拖动（delta 单位 = ImGui 像素）
- (void)moveWindowBy:(CGPoint)deltaPx {
    UIWindow *win = [self hudWin];
    if (!win) return;
    CGFloat sc = UIScreen.mainScreen.scale;
    CGRect scr = UIScreen.mainScreen.bounds;
    CGRect f = win.frame;
    f.origin.x += deltaPx.x / sc;
    f.origin.y += deltaPx.y / sc;
    f.origin.x = MAX(0, MIN(f.origin.x, scr.size.width  - f.size.width));
    f.origin.y = MAX(0, MIN(f.origin.y, scr.size.height - f.size.height));
    win.frame = f;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (_menuVisible) {
        _panelPos = f.origin; _hasPanelPos = YES;
        [ud setFloat:f.origin.x forKey:@"WZPanelX"];
        [ud setFloat:f.origin.y forKey:@"WZPanelY"];
    } else {
        _ballPos = f.origin; _hasBallPos = YES;
        [ud setFloat:f.origin.x forKey:@"WZBallX"];
        [ud setFloat:f.origin.y forKey:@"WZBallY"];
    }
}

#pragma mark - 界面

- (void)drawStartPage {
    ImGuiIO &io = ImGui::GetIO();
    const float W = io.DisplaySize.x, H = io.DisplaySize.y;
    const float sc = UIScreen.mainScreen.scale;

    ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(W, H), ImGuiCond_Always);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0,0));
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.05f,0.06f,0.09f,1.0f));
    ImGui::Begin("##start", NULL,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                 ImGuiWindowFlags_NoSavedSettings);
    ImDrawList *dl = ImGui::GetWindowDrawList();

    // 背景渐变
    dl->AddRectFilledMultiColor(ImVec2(0,0), ImVec2(W,H),
        IM_COL32(14,20,38,255), IM_COL32(24,16,40,255),
        IM_COL32(10,14,28,255), IM_COL32(18,12,32,255));

    // 顶部装饰光斑
    dl->AddCircleFilled(ImVec2(W*0.5f, H*0.18f), W*0.42f,
                        IM_COL32(60,120,220,26), 64);
    dl->AddCircleFilled(ImVec2(W*0.5f, H*0.18f), W*0.28f,
                        IM_COL32(90,160,255,22), 64);

    // 标题
    const char *t1 = "WZ HUD";
    ImGui::SetWindowFontScale(2.4f);
    ImVec2 s1 = ImGui::CalcTextSize(t1);
    ImGui::SetCursorPos(ImVec2((W - s1.x)*0.5f, H*0.235f));
    ImGui::TextColored(ImVec4(0.86f, 0.93f, 1.0f, 1.0f), "%s", t1);
    ImGui::SetWindowFontScale(1.0f);

    const char *t2 = "跨进程读取 · 绘制";
    ImVec2 s2 = ImGui::CalcTextSize(t2);
    ImGui::SetCursorPos(ImVec2((W - s2.x)*0.5f, H*0.235f + 92*sc));
    ImGui::TextColored(ImVec4(0.45f, 0.55f, 0.70f, 1.0f), "%s", t2);

    // 主按钮
    float bw = W * 0.62f, bh = 118.0f;
    float bx = (W - bw) * 0.5f, by = H * 0.45f;
    ImGui::SetCursorPos(ImVec2(bx, by));
    ImVec2 mp = ImGui::GetCursorScreenPos();

    bool running = _hudRunning;
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 60.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(0, 0));
    if (running) {
        ImGui::PushStyleColor(ImGuiCol_Button,        ImVec4(0.55f,0.16f,0.20f,1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.68f,0.22f,0.26f,1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive,  ImVec4(0.45f,0.12f,0.16f,1.0f));
    } else {
        ImGui::PushStyleColor(ImGuiCol_Button,        ImVec4(0.13f,0.42f,0.85f,1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.18f,0.52f,0.98f,1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive,  ImVec4(0.10f,0.34f,0.72f,1.0f));
    }
    if (ImGui::Button("##hudbtn", ImVec2(bw, bh))) {
        if (running) [self stopHudFromMain];
        else         [self startHudFromMain];
    }
    ImGui::PopStyleColor(3);
    ImGui::PopStyleVar(2);

    // 按钮文字（大号）
    const char *bt = running ? "关闭 HUD" : "启动 HUD";
    ImGui::SetWindowFontScale(1.7f);
    ImVec2 bs = ImGui::CalcTextSize(bt);
    dl->AddText(ImVec2(mp.x + (bw - bs.x)*0.5f, mp.y + (bh - bs.y)*0.5f),
                IM_COL32(255,255,255,255), bt);
    ImGui::SetWindowFontScale(1.0f);

    // 状态行
    char st[160];
    snprintf(st, sizeof(st), "状态：%s", running ? "运行中" : "未运行");
    ImVec2 ss = ImGui::CalcTextSize(st);
    ImGui::SetCursorPos(ImVec2((W - ss.x)*0.5f, by + bh + 46*sc));
    ImGui::TextColored(running ? ImVec4(0.4f,1.0f,0.5f,1.0f) : ImVec4(0.5f,0.55f,0.62f,1.0f),
                       "%s", st);

    // 底部提示卡
    float cw = W * 0.80f, ch = 130.0f;
    float cx = (W - cw)*0.5f, cy = H - ch - 120*sc;
    dl->AddRectFilled(ImVec2(cx, cy), ImVec2(cx+cw, cy+ch),
                      IM_COL32(255,255,255,14), 20.0f);
    const char *h1 = "启动后悬浮球会出现在屏幕上";
    const char *h2 = "点悬浮球可展开菜单（读取 / 绘制）";
    ImVec2 h1s = ImGui::CalcTextSize(h1), h2s = ImGui::CalcTextSize(h2);
    dl->AddText(ImVec2(cx + (cw-h1s.x)*0.5f, cy + 26*sc),
                IM_COL32(150,175,210,255), h1);
    dl->AddText(ImVec2(cx + (cw-h2s.x)*0.5f, cy + 70*sc),
                IM_COL32(120,140,175,255), h2);

    ImGui::End();
    ImGui::PopStyleColor();
    ImGui::PopStyleVar();
}

// 主 App：启动 HUD（拉起 root 宿主）
// 连接游戏：先确认进程存在，再走 --wz
- (void)connectGameAndProbe {
    // 本地先确认（列表里有没有这个名字）
    int foundPid = 0;
    for (int i = 0; i < _procCount; i++)
        if (strcmp(_procs[i].name, _gameName) == 0 && _procs[i].pid > foundPid)
            foundPid = _procs[i].pid;
    if (!foundPid) {
        _gameConnected = NO;
        self.outputText = [NSString stringWithFormat:
            @"未找到游戏进程 \"%s\"\n\n请先打开游戏，再点「连接游戏并探测」。", _gameName];
        return;
    }
    _gamePid = foundPid;
    _gameConnected = YES;
    [self runJob:@[ @"--wz", [NSString stringWithUTF8String:_gameName] ]];
}

- (void)startHudFromMain {
    [self startHUDHost];
    _hudRunning = YES;
    _started = YES;
}
- (void)stopHudFromMain {
    [self stopHUDHost];
    _hudRunning = NO;
    strlcpy(_gameName, "sc", sizeof(_gameName));
    _gamePid = 0;
    _gameConnected = NO;
}

// 双击悬浮球 = 直接展开功能菜单（不经过中间态）
- (void)toggleMenuDirect {
    _menuVisible = !_menuVisible;
    HUDSetPassthrough(!_menuVisible);
    [self applyGeometry];
}

- (void)drawUI {
    extern int gHUDHostMode;

    // 主 App：只有开关页
    if (!gHUDHostMode) { [self drawStartPage]; return; }

    // HUD 宿主：悬浮球 / 菜单
    if (!_started) { _started = YES; }

    ImGuiIO &io = ImGui::GetIO();
    const float W = io.DisplaySize.x, H = io.DisplaySize.y;

    // ── 悬浮球 ──
    if (!_menuVisible) {
        ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
        ImGui::SetNextWindowSize(ImVec2(W, H), ImGuiCond_Always);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
        ImGui::Begin("##ball", NULL,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                     ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                     ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBackground);
        ImGui::InvisibleButton("##hit", ImVec2(W, H));
        bool hovered = ImGui::IsItemActive() || ImGui::IsItemHovered();
        bool clicked = ImGui::IsItemClicked();
        if (ImGui::IsItemActive()) {
            ImVec2 d = ImGui::GetIO().MouseDelta;
            if (d.x != 0.0f || d.y != 0.0f) [self moveWindowBy:CGPointMake(d.x, d.y)];
        }
        ImDrawList *dl = ImGui::GetWindowDrawList();
        ImVec2 c(W * 0.5f, H * 0.5f);
        float r = MIN(W, H) * 0.44f;
        if (hovered)
            dl->AddCircleFilled(ImVec2(c.x, c.y + 4), r, IM_COL32(30,90,180,90), 48);
        dl->AddCircleFilled(c, r, hovered ? IM_COL32(40,110,200,250) : IM_COL32(26,72,140,235), 48);
        dl->AddCircle(c, r, IM_COL32(120,190,255,255), 48, 3.0f);
        const char *txt = "菜单";
        ImVec2 ts = ImGui::CalcTextSize(txt);
        dl->AddText(ImVec2(c.x - ts.x*0.5f, c.y - ts.y*0.5f), IM_COL32_WHITE, txt);
        if (clicked) {
            _menuVisible = YES;
            HUDSetPassthrough(NO);
            [self applyGeometry];      // ★ 窗口放大成菜单
        }
        ImGui::End();
        ImGui::PopStyleVar();
        return;
    }

    [self drawMenuPanel];
}

// HUD 宿主：菜单面板
- (void)drawMenuPanel {
    ImGuiIO &io = ImGui::GetIO();
    const float W = io.DisplaySize.x, H = io.DisplaySize.y;
    const float pad = 16.0f;
    const float pw = W - pad*2.0f;
    const float ph = H - pad*2.0f;

    ImGui::SetNextWindowPos(ImVec2(pad, pad), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(pw, ph), ImGuiCond_Always);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(18, 14));
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(10, 10));
    ImGui::Begin("##main", NULL,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse |
                 ImGuiWindowFlags_NoSavedSettings);

    // 顶栏
    {
        ImVec2 ws = ImGui::GetWindowSize();
        ImGui::SetCursorPos(ImVec2(0, 0));
        ImGui::InvisibleButton("##dragbar", ImVec2(ws.x - 8.0f, 40.0f));
        if (ImGui::IsItemActive()) {
            ImVec2 d = ImGui::GetIO().MouseDelta;
            if (d.x != 0.0f || d.y != 0.0f) [self moveWindowBy:CGPointMake(d.x, d.y)];
        }
        ImDrawList *dl = ImGui::GetWindowDrawList();
        ImVec2 wp = ImGui::GetWindowPos();
        dl->AddText(ImVec2(wp.x + 16, wp.y + 8), IM_COL32(150,155,170,255), "≡  按住拖动");
    }

    ImGui::TextColored(ImVec4(0.35f,1.0f,0.45f,1.0f), "● 运行中");
    ImGui::SameLine();
    ImGui::TextDisabled("· %d 进程", _procCount);
    {
        float bw = 200.0f;
        ImGui::SameLine(ImGui::GetContentRegionAvail().x - bw);
        if (ImGui::Button("收起菜单", ImVec2(bw, kBtnH))) {
            _menuVisible = NO; HUDSetPassthrough(YES);
            [self applyGeometry];      // ★ 窗口缩回球
        }
    }
    ImGui::Separator();

    // 目标进程
    ImGui::TextDisabled("目标进程");
    ImGui::SameLine(ImGui::GetContentRegionAvail().x - 110.0f);
    if (ImGui::Button("刷新", ImVec2(100, kBtnH - 16))) [self refreshProcs];
    ImGui::BeginChild("##proc", ImVec2(0, ph * 0.26f), true);
    for (int i = 0; i < _procCount; i++) {
        char label[160];
        snprintf(label, sizeof(label), "%5d   %s", _procs[i].pid, _procs[i].name);
        if (ImGui::Selectable(label, _selRow == i)) _selRow = i;
    }
    ImGui::EndChild();

    if (_selRow >= 0 && _selRow < _procCount)
        ImGui::Text("已选：%s (pid=%d)", _procs[_selRow].name, _procs[_selRow].pid);
    else
        ImGui::TextDisabled("已选：（点列表选一行）");

    {
        float half = (pw - 40.0f) * 0.5f;
        ImGui::BeginDisabled(_selRow < 0 || self.busy);
        if (ImGui::Button("读取目标进程", ImVec2(half, kBtnH)) && _selRow >= 0)
            [self runJob:@[ @"--read", [NSString stringWithFormat:@"%d", _procs[_selRow].pid] ]];
        ImGui::EndDisabled();
        ImGui::SameLine();
        if (ImGui::Button("libjailbreak 自检", ImVec2(half, kBtnH)))
            [self runJob:@[ @"--probe" ]];
    }
    if (self.busy) ImGui::TextColored(ImVec4(1.0f,0.8f,0.3f,1.0f), "  执行中…");
    ImGui::Separator();

    // ── 游戏连接（固定按进程名，避免选错）──
    ImGui::TextColored(ImVec4(0.6f,1.0f,0.6f,1.0f), "游戏连接");
    ImGui::Text("目标进程名：");
    ImGui::SameLine();
    ImGui::TextColored(ImVec4(1.0f,0.85f,0.4f,1.0f), "%s", _gameName);
    ImGui::SameLine();
    ImGui::Text("  状态：");
    ImGui::SameLine();
    if (_gameConnected)
        ImGui::TextColored(ImVec4(0.4f,1.0f,0.5f,1.0f), "已连接 pid=%d", _gamePid);
    else
        ImGui::TextColored(ImVec4(0.9f,0.5f,0.4f,1.0f), "未连接");

    {
        float half = (pw - 40.0f) * 0.5f - 4.0f;
        if (ImGui::Button("① 连接游戏并探测", ImVec2(half, kBtnH))) {
            [self connectGameAndProbe];
        }
        ImGui::SameLine();
        ImGui::BeginDisabled(!_gameConnected || self.busy);
        if (ImGui::Button("② 读玩家并绘制", ImVec2(half, kBtnH))) {
            [self runJob:@[ @"--wz", [NSString stringWithUTF8String:_gameName] ]];
        }
        ImGui::EndDisabled();
    }
    ImGui::Separator();

    ImGui::Separator();

    ImGui::TextDisabled("输出");
    ImGui::BeginChild("##out", ImVec2(0, 0), true, ImGuiWindowFlags_HorizontalScrollbar);
    ImGui::TextUnformatted(self.outputText.UTF8String);
    ImGui::EndChild();

    ImGui::End();
    ImGui::PopStyleVar(2);
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
