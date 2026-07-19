<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="Auvol">
</p>

<h1 align="center">Auvol</h1>

<p align="center">
  通过局域网在 Windows 与 Mac 之间传输系统音频。<br>
  低延迟、无压缩 PCM、双向可选，以及两端原生界面。
</p>


<p align="center">
  <a href="https://github.com/imeelinew/Auvol/releases">下载</a> ·
  <a href="#安装">安装</a> ·
  <a href="#从源码构建">从源码构建</a>
</p>

<p align="center">
  <a href="README.md">简体中文</a>
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/imeelinew/Auvol/releases/latest"><img src="https://img.shields.io/github/v/release/imeelinew/Auvol" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-native-black" alt="macOS">
  <img src="https://img.shields.io/badge/Windows-WinUI%203-blue" alt="Windows WinUI 3">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/C%2B%2B-WASAPI-green" alt="C++ WASAPI">
</p>

---

<p align="center">
  <img alt="Auvol macOS 窗口" src=".github/assets/macos.png" width="420">
</p>

## 简介

Auvol 是一个面向局域网的系统音频传输工具，适合那些希望把 Windows 上的声音实时送到 Mac 耳机里播放、或者反过来把 Mac 音频送到 Windows 输出设备的人。

Mac 端以原生窗口呈现连接状态、传输方向、缓冲目标，以及当前缓冲、输出周期、时钟校正、源周期等实时指标；你也可以看到播放设备、信号电平和丢包统计。它在同一时刻只走一个方向：Windows → Mac，或 Mac → Windows。传输路径里没有编解码器，直接发送立体声 float32 PCM；稳态 48 kHz 时，唯一的采样率处理是两端物理时钟之间那一点点校正。

## 为什么开发 Auvol

跨设备听系统声音通常要靠蓝牙、HDMI，或者带压缩的远程桌面 / 投屏方案。Auvol 把它做成一条专门的局域网音频链路：一端采集系统输出，另一端送到默认播放设备，并尽量把延迟压在毫秒级。

- **局域网优先**：面向千兆有线或稳定 Wi‑Fi，用 UDP 运送原始 PCM。
- **双向可选**：同一套应用同时覆盖发送与接收，运行中可切换方向。
- **无压缩音质**：ALV2 协议传输 48 kHz 双声道 float32，不经过有损编码。
- **两端原生界面**：macOS 原生窗口 + Windows WinUI 3，状态与控制都放在本机 UI 里。
- **可观测的链路**：缓冲目标、时钟校正、丢包 / 迟到、欠载与溢出都直接可见，方便把延迟调到刚好够稳。

## Windows

<p align="center">
  <img alt="Auvol Windows 窗口" src=".github/assets/windows.png" width="520">
</p>

Windows 端用 WinUI 3 提供对端 IP、连接状态、传输方向和开始 / 停止控制。发送时通过 WASAPI 环回采集当前默认输出；接收时则播放到当前默认输出设备。

## 选择传输方向

在 Windows 上选好角色后按一次 **开始**。链路运行期间切换方向会立刻换角色，不必先停止。

- **Windows → Mac**：采集 Windows 当前默认输出，送到 Mac 播放。
- **Mac → Windows**：采集 Mac 系统音频，送到 Windows 当前默认输出；若要用蓝牙耳机，请先在 Windows 声音设置里选好设备。

在 Mac 上选择 **从 Windows 接收** 或 **发送到 Windows**。Mac 发送需要一次性授权系统音频采集。

无人值守启动可用：

```sh
Auvol.exe --send <mac-ip>
Auvol.exe --receive <mac-ip>
```

Windows 会记住对端 IP、方向，以及传输是否处于运行中。首次启动之后，下次登录可自动拉起并恢复进行中的会话；按停止或关闭窗口会记为暂停，下次登录则空闲打开。

## 其他功能

- 半双工实时传输：同一时刻只选一个方向
- ALV2 原始立体声 float32 PCM，带流身份、序号与发送端帧位置
- 默认约 12 ms 抖动缓冲目标，可按链路质量微调
- 默认音频设备变化、蓝牙断开、短暂 WASAPI / Core Audio 故障时自动恢复
- Mac 侧展示排队深度、时钟校正、丢包、欠载与溢出等关键队列时序
- Start / Stop 是全局暂停控制，不是故障恢复流程

## 安装

从 [Releases 页面](https://github.com/imeelinew/Auvol/releases)下载最新版，分别安装 macOS 与 Windows 客户端后，在同一局域网内填入对端 IP 并选择传输方向即可。

## 从源码构建

`deploy.sh` 会重新生成 Xcode 工程、构建两端应用，把 WinUI 应用安装到 `%LOCALAPPDATA%\Auvol`，并重启两端。Windows 源码工作区会同步到 `C:\dev\Auvol\windows`，再用 Visual Studio 的 x64 C++ 工具链构建。

```sh
# 同一局域网：推荐
WIN_HOST=eli-lan ./deploy.sh

# 通过 Surge Tailscale 远程部署
./deploy.sh
```

部署完成后，新的 Windows 应用会自动启动。日常使用中，设备切换与短暂音频故障会自动恢复。ALV1 与 ALV2 故意不兼容。

更细的协议说明见 [`PROTOCOL.md`](PROTOCOL.md)。
