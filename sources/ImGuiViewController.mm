//
//  ImGuiViewController.mm
//  ImGui + Metal 界面；数据由 root 子进程探测后经文件回传
//
#import "ImGuiViewController.h"
#import <MetalKit/MetalKit.h>
#import <spawn.h>
#import <mach-o/dyld.h>
#import <sys/wait.h>
#import <unistd.h>
#import <string.h>
#import <limits.h>

#import "imgui.h"
#import "imgui_impl_metal.h"

extern char **environ;
extern "C" {
int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);
}

@interface ImGuiViewController () <MTKViewDelegate>
@property (nonatomic, strong) MTKView *mtkView;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) NSString *probeText;
@property (nonatomic, assign) BOOL  probeRunning;
@property (nonatomic, assign) BOOL  probeDone;
@end

@implementation ImGuiViewController {
    ImFont *_font;
    dispatch_source_t _timer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    self.mtkView.delegate = self;
    self.mtkView.preferredFramesPerSecond = 60;
    self.mtkView.clearColor = MTLClearColorMake(0.06, 0.06, 0.08, 1.0);
    self.mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.mtkView];

    self.commandQueue = [device newCommandQueue];

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    ImGuiStyle &st = ImGui::GetStyle();
    st.WindowRounding = 8.0f;
    st.FrameRounding  = 5.0f;
    ImGui_ImplMetal_Init(device);

    self.probeText = @"（尚未运行探测）";

    // 起一次 root 探测
    [self runRootProbe];

    // 每秒刷新一次（读结果文件）
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                    dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(_timer, ^{
        [ws refreshProbeFile];
    });
    dispatch_resume(_timer);
}

- (NSString *)probeOutputPath {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [doc stringByAppendingPathComponent:@"probe.txt"];
}

- (void)runRootProbe {
    self.probeRunning = YES;
    NSString *out = [self probeOutputPath];
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char exe[PATH_MAX];
        uint32_t sz = sizeof(exe);
        if (_NSGetExecutablePath(exe, &sz) != 0) {
            self.probeText = @"取自身路径失败";
            self.probeRunning = NO;
            return;
        }

        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        posix_spawnattr_set_persona_np(&attr, 99, 1);
        posix_spawnattr_set_persona_uid_np(&attr, 0);
        posix_spawnattr_set_persona_gid_np(&attr, 0);

        const char *argv[] = { exe, "--probe", out.UTF8String, NULL };
        pid_t pid = 0;
        int rc = posix_spawn(&pid, exe, NULL, &attr, (char *const *)argv, environ);
        posix_spawnattr_destroy(&attr);

        if (rc != 0) {
            self.probeText = [NSString stringWithFormat:
                @"posix_spawn 失败 rc=%d (%s)\n提权不可用。", rc, strerror(rc)];
            self.probeRunning = NO;
            self.probeDone = YES;
            return;
        }

        int stat = 0;
        waitpid(pid, &stat, 0);
        self.probeRunning = NO;
        self.probeDone = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshProbeFile];
        });
    });
}

- (void)refreshProbeFile {
    NSString *txt = [NSString stringWithContentsOfFile:[self probeOutputPath]
                                              encoding:NSUTF8StringEncoding error:nil];
    if (txt.length) self.probeText = txt;
}

#pragma mark - 界面

- (void)drawUI {
    ImGuiIO &io = ImGui::GetIO();
    ImGui::SetNextWindowPos(ImVec2(16, 60), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(io.DisplaySize.x - 32, io.DisplaySize.y - 140), ImGuiCond_FirstUseEver);

    ImGui::Begin("WZ Probe — libjailbreak", NULL, ImGuiWindowFlags_NoCollapse);
    ImGui::Text("状态: %s", self.probeDone ? "已完成" : (self.probeRunning ? "运行中…" : "待运行"));
    ImGui::Separator();

    if (ImGui::Button("重新探测")) {
        [self runRootProbe];
    }
    ImGui::SameLine();
    ImGui::TextDisabled("(root 子进程 / uid=0)");

    ImGui::Separator();
    ImGui::BeginChild("out", ImVec2(0, 0), true, ImGuiWindowFlags_HorizontalScrollbar);
    ImGui::TextUnformatted(self.probeText.UTF8String);
    ImGui::EndChild();

    ImGui::End();

    // 底部提示条
    ImGui::SetNextWindowPos(ImVec2(16, io.DisplaySize.y - 52), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(io.DisplaySize.x - 32, 36), ImGuiCond_Always);
    ImGui::Begin("##status", NULL,
                 ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);
    ImGui::Text("ImGui %s | %.1f FPS | Metal", IMGUI_VERSION, io.Framerate);
    ImGui::End();
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(view.bounds.size.width, view.bounds.size.height);

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
