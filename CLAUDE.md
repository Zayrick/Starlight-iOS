# CLAUDE.md

Starlight 是原生 SwiftUI 游戏串流客户端（iOS / iPadOS / macOS / visionOS），连接 Sunshine 与 NVIDIA GameStream 主机，底层协议使用 moonlight-common-c。用户与项目文档使用简体中文。

## 构建与验证

- 首次需拉取子模块：`git submodule update --init --recursive`（moonlight-common-c、opus）
- 改动后至少编译 iOS；涉及 `#if os(...)` 分支或共享代码时三个平台都要编译：

```sh
xcodebuild -project Starlight.xcodeproj -scheme Starlight \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/starlight-dd CODE_SIGNING_ALLOWED=NO build
# 另两个平台：'generic/platform=macOS'、'generic/platform=visionOS Simulator'
```

- 没有单元测试（`StarlightTests` 目标存在但目录为空）；`StarlightUITests` 中 `StarlightUITests.swift` 只有一个 iOS UI 测试，按英文标签 `"Search"` 查找按钮，需在英文环境运行。
- App Store 截图用 `scripts/screenshots.sh` 生成（iPhone、iPad × 四种语言，输出到 `Screenshots/`）。它运行 `AppStoreScreenshots` 测试，依赖 DEBUG 构建下的 `-ScreenshotMode` 启动参数：`ScreenshotMode.swift` 提供示例主机、应用和串流画面，代替网络。改动 `HostStore`、`StreamSession` 的网络路径时保留这些分支。
- 部署目标 26.5（iOS / macOS / visionOS），可直接使用 Liquid Glass 等 26 系列 API（如 `glassEffect`、`.glassProminent`）。

## 项目结构

- `Starlight/*.swift`：SwiftUI 界面（`ContentView` 按平台分出 macOS 侧边栏 / iOS TabView / visionOS TabView）
- `Starlight/GameStream/`：主机发现（Bonjour `_nvstream._tcp`）、`HostStore`（主机列表、配对、应用列表）、`PairingSession`、客户端证书与钥匙串、GameStream HTTP 接口、`StreamSettings`（设置项与 `@AppStorage` 键）
- `Starlight/Streaming/`：`StreamController` 持有唯一的活动会话 → `StreamSession`（启动/恢复应用、连接、阶段与错误）→ `MoonlightClient`（C 桥接的 Swift 端）；`VideoRenderer`（VideoToolbox + `AVSampleBufferDisplayLayer`）、`AudioRenderer`、`AV1SequenceHeader`（自行解析，不依赖 FFmpeg）
- `Starlight/Streaming/Input/`：`StreamInput` 统一发送键鼠/触控/手柄；`StreamSurface+UIKit` 与 `StreamSurface+AppKit` 分平台实现
- `Packages/MoonlightCore/`：本地 SPM 包。App 只 import `MoonlightBridge`（`SL` 前缀的窄 C 接口），其余目标是上游源码与 Apple 加密后端

## 关键约束

- **默认 MainActor 隔离**：项目开启 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 和 Approachable Concurrency。模型、网络、加密类型需显式标 `nonisolated`（参照 `GameStreamModels.swift`、`StreamSettings.swift`）。
- **同一时间只能有一个串流会话**：moonlight-common-c 持有全局状态，新会话必须经 `StreamController`，并等待上一个会话拆除完成。
- **平台分支**：iOS 用 `landscapeCover` 全屏呈现串流；macOS / visionOS 用独立的 `StreamWindow` 窗口。抽屉、边缘手柄、触控模式只在 iOS 上有；visionOS 没有输入设置。改动 UI 时检查 `#if os(...)` 的每个分支。
- **子模块不要改**：`moonlight-common-c/`、`opus/` 是上游代码；适配写在 `MoonlightBridge.c`、`PlatformCryptoApple.c` 或 Swift 侧。
- 新文件放进 `Starlight/` 即可，工程使用文件系统同步分组，不需要改 `project.pbxproj`。

## 本地化

- 开发语言是英文，支持 `en`、`zh-Hans`、`zh-Hant`（台湾）、`zh-HK`。文字在 `Starlight/Localizable.xcstrings`，权限说明在 `Starlight/InfoPlist.xcstrings`。
- 源码里只写**英文** key，不要硬编码中文。SwiftUI 视图的字面量会自动本地化；返回 `String` 的地方（错误信息、枚举 `title`、拼接的说明文字、UIKit 属性）要用 `String(localized:)`。
- 不要用字符串拼接出句子，把整句放进一个带插值的 key。多个参数时，译文使用 `%1$@`、`%2$lld` 这类带位置的占位符。
- 新增或修改文字时，同时在 `.xcstrings` 里补齐三种中文译文，并符合当地习惯：
  - 简体中文：设备、设置、分辨率、帧率、手柄、网络、应用
  - 台湾：裝置、設定、解析度、影格速率、控制器、網路、App、「」引号
  - 香港：裝置、設定、解像度、幀率、手掣、網絡、App、「」引号、遙距
- 可以用编译产物核对 key：`Objects-normal/*/*.stringsdata` 是编译器实际提取出的 key（JSON）。

## 代码风格

- 每个文件开头是标准文件头；主要类型在文件头里用一段英文说明职责。
- 注释用英文：`///` 文档注释写完整句子，行内 `//` 注释简短，不加句号，用来解释原因而不是复述代码。（`DevicesView.swift` 中现有的中文注释保持原样即可。）
- 优先使用 Swift 新语法：`switch` / `if` 表达式、隐式返回、`@Observable`、`@Environment(Type.self)`。
- 提交信息遵循 Conventional Commits，例如 `feat(streaming): ...`、`fix(settings): ...`、`style(devices): ...`、`chore: ...`。
