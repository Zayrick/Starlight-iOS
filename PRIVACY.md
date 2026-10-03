# 隐私政策

生效日期：2026 年 10 月 3 日

Starlight 是一款游戏串流客户端，用来连接你自己的串流主机（Sunshine 或 NVIDIA GameStream）。我们重视你的隐私，本政策说明 Starlight 如何处理你的信息。

## 简要说明

**Starlight 不收集任何个人信息。** 它没有账号系统，不包含分析、广告或崩溃上报工具，也不会把任何数据发送给开发者或第三方。

## 保存在你设备上的数据

为了正常使用，Starlight 会在你的设备上保存以下数据。这些数据只留在你的设备上（以及系统备份中），开发者无法访问：

- **主机信息**：你添加或自动发现的串流主机的名称、IP 地址、MAC 地址、GPU 型号等，用于重新连接和显示主机。
- **配对凭据**：配对时生成的客户端证书和私钥，保存在系统钥匙串中，用于向主机证明身份。
- **应用设置**：分辨率、码率、输入方式等串流偏好。

删除 Starlight 即可清除主机信息和设置。钥匙串中的配对凭据可能在删除 App 后仍由系统保留，重新安装后会继续使用。

## 发送到串流主机的数据

串流时，Starlight 只与**你自己选择连接的主机**直接通信，不经过任何中间服务器：

- 配对和串流所需的协议信息，包括客户端证书和固定的设备标识（不是你设备的真实标识）；
- 你的输入：触控、键盘、鼠标、手柄操作；开启相应功能时，还包括手柄或设备的体感数据；
- 串流参数，例如分辨率、帧率和编码格式。

主机发回的视频和音频只在设备上实时解码播放，不会被录制或保存。

这些数据由你的主机软件（例如 Sunshine）处理，适用该软件自己的隐私政策。

## 权限

- **本地网络**：用于在局域网中发现主机并与之连接。
- **体感（可选）**：在“用本机代替震动与体感”开启时，读取设备的运动传感器，并把数据发送到主机供游戏使用。

## 儿童隐私

Starlight 不收集任何人的个人信息，包括儿童。

## 开源

Starlight 以 GPLv3 开源，你可以在 [GitHub](https://github.com/Zayrick/Starlight-iOS) 上查看源代码，核实本政策描述的行为。

## 政策变更

如果本政策发生变化，我们会更新本页面并修改上方的生效日期。

## 联系方式

如有疑问，请在 [GitHub Issues](https://github.com/Zayrick/Starlight-iOS/issues) 中提出。

---

# Privacy Policy

Effective date: October 3, 2026

Starlight is a game streaming client that connects to your own streaming host (Sunshine or NVIDIA GameStream). This policy explains how Starlight handles your information.

## Summary

**Starlight does not collect any personal information.** It has no accounts, contains no analytics, advertising or crash reporting tools, and sends no data to the developer or any third party.

## Data stored on your device

Starlight stores the following on your device so that it can work. This data stays on your device (and in your system backups), and the developer cannot access it:

- **Host information**: the name, IP addresses, MAC address, GPU model and similar details of hosts you add or discover, used to reconnect to and display them.
- **Pairing credentials**: a client certificate and private key generated during pairing, stored in the system Keychain and used to authenticate with your hosts.
- **Settings**: streaming preferences such as resolution, bitrate and input options.

Deleting Starlight removes host information and settings. The system may keep the pairing credentials in the Keychain after the app is deleted; they are reused if you reinstall.

## Data sent to your streaming host

While streaming, Starlight communicates directly with **the hosts you choose to connect to**, with no intermediate server:

- protocol information required for pairing and streaming, including the client certificate and a fixed client identifier (not your device's real identifier);
- your input: touch, keyboard, mouse and gamepad actions, plus gamepad or device motion data when the related features are enabled;
- stream parameters such as resolution, frame rate and codec.

Video and audio from the host are decoded and played in real time on your device and are never recorded or stored.

This data is processed by your host software (such as Sunshine) under that software's own privacy policy.

## Permissions

- **Local Network**: to discover and connect to hosts on your local network.
- **Motion (optional)**: when "Use this device for rumble and motion" is enabled, Starlight reads the device's motion sensors and sends the data to your host for use in games.

## Children's privacy

Starlight does not collect personal information from anyone, including children.

## Open source

Starlight is open source under GPLv3. You can review the source code on [GitHub](https://github.com/Zayrick/Starlight-iOS) to verify the behavior described here.

## Changes

If this policy changes, we will update this page and the effective date above.

## Contact

If you have questions, please open an issue on [GitHub Issues](https://github.com/Zayrick/Starlight-iOS/issues).
