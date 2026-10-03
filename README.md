# Starlight

Starlight 是一款原生 SwiftUI 游戏串流客户端，可以把电脑上的游戏和桌面串流到 iPhone、iPad、Mac 和 Apple Vision Pro。它兼容 [Sunshine](https://github.com/LizardByte/Sunshine) 与 NVIDIA GameStream 主机，底层协议使用 [Moonlight](https://moonlight-stream.org) 项目的 [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)。

## 功能

- **主机**：通过 Bonjour 自动发现局域网主机，也可以手动添加；PIN 配对，客户端证书和私钥保存在钥匙串中
- **应用**：浏览主机上的应用列表，启动、恢复或退出正在运行的应用
- **视频**：H.264、HEVC、AV1 硬件解码，支持 HDR 和 YUV 4:4:4；AV1 序列头由项目自行解析，不依赖 FFmpeg
- **音频**：Opus 解码，支持立体声与环绕声
- **输入**
  - 触控：多点触控、触控板、直接点按三种模式（iOS）
  - 键盘与鼠标：远程光标 / 本地光标，macOS 使用 AppKit 单独实现
  - 手柄：通过 GameController 支持，可模拟 Xbox 或 PlayStation 手柄，支持震动、自适应扳机和体感
- **其他**：串流统计浮层、侧边抽屉菜单

## 系统要求

- iOS / iPadOS 26.5、macOS 26.5 或 visionOS 26.5 及以上
- 运行 [Sunshine](https://github.com/LizardByte/Sunshine) 或 NVIDIA GameStream 的主机

## 构建

需要 Xcode 26 或更高版本。

```sh
git clone --recursive https://github.com/Zayrick/Starlight-iOS.git
cd Starlight-iOS
open Starlight.xcodeproj
```

如果克隆时没有加 `--recursive`，请先拉取子模块：

```sh
git submodule update --init --recursive
```

选择 `Starlight` scheme 和目标设备后即可运行。在真机上运行前，请在 Signing & Capabilities 中改成你自己的开发团队和 Bundle Identifier。

## 项目结构

```text
Starlight/
├── GameStream/        主机发现、配对、证书、HTTP 接口
├── Streaming/         串流会话、视频与音频渲染、统计
│   └── Input/         触控、键鼠、手柄输入
└── *.swift            SwiftUI 界面
Packages/MoonlightCore/
├── MoonlightCommon/   moonlight-common-c（子模块）及 Apple 加密后端
├── COpus/             libopus（子模块）
├── MoonlightCrypto/   基于 CryptoKit 的 AES-GCM
└── MoonlightBridge/   供 Swift 调用的 C 桥接层
```

## 隐私

Starlight 不收集任何个人信息，只与你选择连接的串流主机直接通信。详见 [隐私政策](PRIVACY.md)。

## 许可证

Starlight 以 [GNU 通用公共许可证第 3 版（GPLv3）](LICENSE) 发布。

本项目使用的第三方组件：

| 组件 | 许可证 |
| --- | --- |
| [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) | GPLv3 |
| [ENet](https://github.com/cgutman/enet)（moonlight-common-c 内置） | MIT |
| [nanors](https://github.com/sleepybishop/nanors)（moonlight-common-c 内置） | MIT |
| [Opus](https://opus-codec.org) | BSD 3-Clause |

各组件的完整许可证文本见 [Starlight/Licenses](Starlight/Licenses)，App 内也可以在“设置 → 关于 Starlight”中查看。

## 免责声明

Starlight 是独立项目，与 Moonlight、NVIDIA 和 LizardByte（Sunshine）没有关联，也未获得它们的认可。NVIDIA 和 GameStream 是 NVIDIA Corporation 的商标。
