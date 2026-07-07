# Auvol

Windows 系统音频 → 局域网 → Mac 蓝牙耳机，低延迟。

Windows 播放的音频通过局域网实时传输到 Mac，与 Mac 自身音频混合后从默认输出设备（蓝牙耳机）播放。避免来回切换蓝牙连接。

## 架构

- **Mac 端** (`mac/`)：原生 Swift Xcode 项目（xcodegen 生成），SwiftUI 菜单栏 app，AVAudioEngine 播放，Bonjour 广播。`Auvol.app`
- **Windows 端** (`windows/`)：C++ Win32 GUI，WASAPI loopback 抓取系统混音，UDP 裸 float32 PCM 发送。`Auvol.exe`
- **协议**：ALV1，UDP 裸 PCM float32，见 [PROTOCOL.md](./PROTOCOL.md)

## 前置要求

### Windows 端必须装 VB-Cable

Windows 的 Realtek/Intel SST 驱动会在 WASAPI loopback 路径上降质音频。**必须装 VB-Cable 虚拟声卡绕过**：

1. 下载 https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip
2. 解压，右键 `VBCABLE_Setup_x64.exe` → 以管理员身份运行 → Install
3. 重启 Windows
4. 声音设置 → 输出设备 → 选 **CABLE Input (VB-Audio Virtual Cable)**

这样应用音频输出到 CABLE Input，Auvol 从 CABLE 抓取原始未降质数据。

## 构建

改完代码后一键编译并更新两端（Mac 接收端 + Windows 桌面 `Auvol.exe`）：

```sh
./deploy.sh
```

Windows 端需 **Disconnect → 重新 Connect** 才会用到新 exe。

### Mac 端（Xcode）
```sh
cd mac
xcodegen generate
open Auvol.xcodeproj
```
在 Xcode 里 Command+R 运行，或 Product → Archive 导出。

### Windows 端（交叉编译）
```sh
cd windows
x86_64-w64-mingw32-windres -i Auvol.rc -o Auvol_rc.o
x86_64-w64-mingw32-g++ -std=c++17 -O2 \
  -D_WIN32_WINNT=0x0600 -DWIN32_LEAN_AND_MEAN -DUNICODE -D_UNICODE \
  -static -static-libgcc -static-libstdc++ \
  -o Auvol.exe Auvol.cpp Auvol_rc.o \
  -lole32 -lws2_32 -lksuser -lgdi32 -lcomctl32 -luxtheme -mwindows
```

## 使用

1. **Mac**：把系统输出设成蓝牙耳机，启动 `Auvol.app`（菜单栏出现波形图标，自动监听 UDP 7777）
2. **Windows**：默认输出设为 CABLE Input，运行 `Auvol.exe`，输入 Mac 的 IP，点 Connect
3. 在 Windows 播放任意音频 → Mac 耳机里就能听到，和 Mac 自身声音混在一起

## Mac 菜单栏

- 绿色圆点 = 正在播放接收到的音频
- 橙色圆点 = 监听中，等待发送端
- 可调目标缓冲（40–200ms，默认 80ms）
- 实时显示缓冲水位、包数、欠载、溢出

## 调参

- **卡顿/爆音**：Mac 菜单栏滑大 Target buffer（80→120ms）
- **延迟太大**：滑小（80→50ms）；Starved/s 升高说明已过低

## 限制

- 无重传/无 FEC：丢包 → 接收端补静音
- 无时钟同步：长时间运行可能偶发欠载/溢出
- 单源单宿
- Windows 端手动填 IP
