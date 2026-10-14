# WZJBProbe — libjailbreak 可用性探测

在越狱环境（Relaxin / RootHide，iOS 17.1.2，iPhone 14 Pro）上验证：

1. `jbclient_initialize_primitives()` 能否取得 kernel r/w
2. `proc_find` / `proc_self` 能否定位进程
3. `kreadbuf` 内核读是否可用
4. `proc_vreadbuf` **跨进程读**是否可用

## 结构

```
sources/
  jb.h                    libjailbreak 导出符号的最小声明
  main.mm                 入口
  AppDelegate.{h,mm}      窗口
  ProbeViewController.{h,mm}  探测逻辑 + 结果显示
Vendor/
  libjailbreak.dylib      Dopamine/Relaxin 系（含 arm64 / arm64e 两个 slice）
  libchoma.dylib          libjailbreak 依赖
Entitlements.plist        platform-application 等
project.yml               xcodegen 工程描述
.github/workflows/build.yml  CI
```

## 关键设计

- **dylib 的 `LC_ID_DYLIB` 是 `@loader_path/libjailbreak.dylib`** → 运行时从**主可执行文件所在目录**加载。
  所以 CI 里把 dylib 复制到 `.app/` 顶层（不是 Frameworks/），不需要改 install_name。
- **ARCHS = arm64e**：libjailbreak 的内核原语需要 PAC 能力。
- **ldid 伪签名 + entitlements**：越狱环境下由 trust cache 放行。

## 构建

推送到 GitHub 后，Actions → Build JBProbe → Run workflow，
产物为 `WZJBProbe-ipa` artifact（未签名 IPA，已用 ldid 伪签）。

## 安装

见对话中的说明。
