# Audio LAN Protocol — "ALV1"

低延迟局域网音频传输协议。Windows 端抓取系统混音（WASAPI loopback），
通过 UDP 发送裸 PCM 到 Mac 端播放。Mac 的系统音频和本 app 的音频都走
默认输出设备（蓝牙耳机），由 macOS 自动混音，无需额外混音逻辑。

所有多字节整数均为 **小端序**（x86 / Apple Silicon 均为小端）。

## 包格式

### 公共头部（所有包）
| offset | size | field | 说明 |
|--------|------|-------|------|
| 0  | 4 | magic | `0x414C5631` ("ALV1") |
| 4  | 4 | type  | `0` = config, `1` = audio |

### Config 包 (type = 0)
总长度 20 字节，无 payload。

| offset | size | field | 说明 |
|--------|------|-------|------|
| 8  | 4 | sample_rate | 采样率 (Hz)，如 48000 |
| 12 | 4 | channels    | 声道数，如 2 |
| 16 | 4 | frame_size  | 每个 audio 包的帧数，如 120 |

发送端启动时发一次，之后**每秒重发一次**，便于接收端随时加入。
接收端按 config 配置 AudioUnit；收到相同 config 时忽略。

### Audio 包 (type = 1)
| offset | size | field | 说明 |
|--------|------|-------|------|
| 8  | 4 | seq | 序号，从 0 递增 |
| 12 | 8 | timestamp | 发送端微秒级单调时间戳（接收端可忽略） |
| 20 | N | payload | `frame_size * channels * 4` 字节的 float32 交错 PCM |

`N = frame_size * channels * 4`。默认 120 帧 / 2 声道 → 960 字节 payload，
整包 980 字节，低于以太网 MTU 1500，**不会 IP 分片**（Wi-Fi 丢包不会放大）。

## 参数约定

- 编码：float32 (IEEE 754)，WASAPI shared mode 原生格式，零转换。
- 采样率：跟随 Windows 端 mix format（通常 44100 或 48000），接收端自适应。
- 声道：固定 2（立体声）。
- 传输：UDP，无重传、无 FEC。丢包由接收端 jitter buffer 吸收，严重时输出静音。
- 端口：默认 7777，可配置。
