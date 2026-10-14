//
//  ImGuiViewController.mm
//  菜单式控制台：进程列表 / 选择目标 / 跨进程读取 / 输出
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

// libproc：自行声明（iOS SDK 无此头文件）
extern "C" {
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, unsigned int buffersize);
}

#import "imgui.h"
#import "imgui_impl_metal.h"

extern char **environ;
extern "C" {
int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);
}

typedef struct { int pid; char name[128]; } ProcEntry;
#define MAXPROC 512

// 大小写无关的子串匹配（iOS 的 string.h 不保证有 strcasestr）
static bool ci_contains(const char *hay, const char *needle) {
    if (!needle || !needle[0]) return true;
    size_t nl = strlen(needle);
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < nl && p[i] &&
               tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i])) i++;
        if (i == nl) return true;
    }
    return false;
}

@interface ImGuiViewController () <MTKViewDelegate>
@property (nonatomic, strong) MTKView *mtkView;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) NSString *outputText;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL autoRefresh;
@property (nonatomic, assign) BOOL showProbe;
@end

@implementation ImGuiViewController {
    ProcEntry _procs[MAXPROC];
    int  _procCount;
    int  _selRow;
    char _filter[64];
    dispatch_source_t _timer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    self.mtkView.delegate = self;
    self.mtkView.preferredFramesPerSecond = 60;
    self.mtkView.clearColor = MTLClearColorMake(0.05, 0.05, 0.07, 1.0);
    self.mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.mtkView];

    self.commandQueue = [device newCommandQueue];
    self.outputText = @"就绪。选择目标进程后点「读取目标」。";
    self.autoRefresh = YES;
    self.showProbe = NO;
    _selRow = -1;
    _procCount = 0;
    strlcpy(_filter, "", sizeof(_filter));

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    ImGuiStyle &st = ImGui::GetStyle();
    st.WindowRounding = 8.0f;
    st.FrameRounding = 5.0f;
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
        else    io.Fonts->AddDefaultFont();
        io.Fonts->Build();
    }
    ImGui_ImplMetal_Init(device);

    [self refreshProcs];

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(_timer, ^{ if (ws.autoRefresh) [ws refreshProcs]; });
    dispatch_resume(_timer);
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

// 以 uid=0 起子进程执行任务；argv = 任务参数，结尾自动补输出文件路径
- (void)runJob:(NSArray<NSString *> *)args {
    if (self.busy) return;
    self.busy = YES;
    self.outputText = @"执行中…";

    NSString *out = [self outPath];
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char exe[PATH_MAX];
        uint32_t sz = sizeof(exe);
        if (_NSGetExecutablePath(exe, &sz) != 0) {
            self.outputText = @"取自身路径失败";
            self.busy = NO;
            return;
        }

        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        posix_spawnattr_set_persona_np(&attr, 99, 1);
        posix_spawnattr_set_persona_uid_np(&attr, 0);
        posix_spawnattr_set_persona_gid_np(&attr, 0);

        const char *argv[10];
        int c = 0;
        argv[c++] = exe;
        for (NSString *a in args) argv[c++] = a.UTF8String;
        argv[c++] = out.UTF8String;
        argv[c] = NULL;

        pid_t pid = 0;
        int rc = posix_spawn(&pid, exe, NULL, &attr, (char *const *)argv, environ);
        posix_spawnattr_destroy(&attr);

        if (rc != 0) {
            self.outputText = [NSString stringWithFormat:@"posix_spawn 失败 rc=%d (%s)", rc, strerror(rc)];
            self.busy = NO;
            return;
        }
        int stat = 0;
        waitpid(pid, &stat, 0);

        NSString *res = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:nil];
        self.outputText = res.length ? res : @"（无输出）";
        self.busy = NO;
    });
}

#pragma mark - 界面

- (void)drawUI {
    ImGuiIO &io = ImGui::GetIO();
    const float W = io.DisplaySize.x, H = io.DisplaySize.y;
    const float padX = 45.0f, topY = 210.0f, statusH = 150.0f;
    const float botY = H - statusH - 60.0f;

    ImGui::SetNextWindowPos(ImVec2(padX, topY), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(W - padX * 2.0f, botY - topY), ImGuiCond_Always);
    ImGui::Begin("WZ 控制台", NULL, ImGuiWindowFlags_NoCollapse);

    // ── 状态 ──
    ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.5f, 1.0f), "libjailbreak: 可用");
    ImGui::SameLine();
    ImGui::TextDisabled("| uid=0 子进程读取 | 载入 %d 个进程", _procCount);
    ImGui::Separator();

    // ── 进程选择 ──
    if (ImGui::Button("刷新列表", ImVec2(150, 0))) [self refreshProcs];
    ImGui::SameLine();
    ImGui::Checkbox("自动刷新", &self.autoRefresh);
    ImGui::SameLine();
    ImGui::SetNextItemWidth(260);
    ImGui::InputTextWithHint("##filter", "过滤进程名…", _filter, sizeof(_filter));

    ImGui::Spacing();
    ImGui::BeginChild("##proc", ImVec2(0, 330), true);
    for (int i = 0; i < _procCount; i++) {
        if (_filter[0] && !strcasestr(_procs[i].name, _filter)) continue;
        char label[192];
        snprintf(label, sizeof(label), "%5d  %s", _procs[i].pid, _procs[i].name);
        bool sel = (_selRow == i);
        if (ImGui::Selectable(label, sel)) _selRow = i;
    }
    ImGui::EndChild();

    // ── 操作 ──
    const char *selName = (_selRow >= 0 && _selRow < _procCount) ? _procs[_selRow].name : "(未选择)";
    ImGui::Text("目标: %s", selName);
    ImGui::SameLine();
    if (_selRow >= 0) ImGui::TextDisabled("pid=%d", _procs[_selRow].pid);

    ImGui::BeginDisabled(_selRow < 0 || self.busy);
    if (ImGui::Button("读取目标进程", ImVec2(190, 0)) && _selRow >= 0) {
        [self runJob:@[ @"--read", [NSString stringWithFormat:@"%d", _procs[_selRow].pid] ]];
    }
    ImGui::SameLine();
    if (ImGui::Button("运行自检", ImVec2(150, 0))) {
        [self runJob:@[ @"--probe" ]];
    }
    ImGui::EndDisabled();
    ImGui::SameLine();
    if (self.busy) ImGui::TextColored(ImVec4(1.0f, 0.8f, 0.3f, 1.0f), "执行中…");

    ImGui::Separator();

    // ── 输出 ──
    ImGui::BeginChild("##out", ImVec2(0, 0), true, ImGuiWindowFlags_HorizontalScrollbar);
    ImGui::TextUnformatted(self.outputText.UTF8String);
    ImGui::EndChild();

    ImGui::End();

    // ── 底部状态条 ──
    ImGui::SetNextWindowPos(ImVec2(padX, H - statusH), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(W - padX * 2.0f, statusH - 50.0f), ImGuiCond_Always);
    ImGui::Begin("##status", NULL,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);
    ImGui::Text("ImGui %s", IMGUI_VERSION);
    ImGui::SameLine();
    ImGui::TextColored(ImVec4(0.5f, 0.8f, 1.0f, 1.0f), "  %.1f FPS", io.Framerate);
    ImGui::SameLine();
    ImGui::TextDisabled("  Metal · Relaxin · iOS 17.1.2");
    ImGui::TextDisabled("DisplaySize: %.0f x %.0f", W, H);
    ImGui::End();
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    ImGuiIO &io = ImGui::GetIO();
    CGSize drawable = view.drawableSize;
    if (drawable.width < 1.0 || drawable.height < 1.0) {
        CGFloat sc = UIScreen.mainScreen.scale;
        drawable = CGSizeMake(view.bounds.size.width * sc, view.bounds.size.height * sc);
    }
    io.DisplaySize = ImVec2(drawable.width, drawable.height);
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
