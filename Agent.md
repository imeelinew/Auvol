# Auvol — Agent 开发规范

本项目是 **Mac 接收端 + Windows 发送端** 的双端音频传输系统。任何开发工作都必须按双端流程进行。

## 硬性规则

**在无法连接 Windows 电脑之前，不要修改任何代码。**

包括：不要编辑源文件、不要运行 `./deploy.sh`、不要提交声称「已修复」的改动。可以先阅读代码、分析问题、向用户说明阻塞原因，但 **不得动手改**。

只有 Windows SSH 连通且身份验证通过后，才允许进入开发流程。

## 开发前：必须验证 Windows 连通

每次开始开发任务时，**第一步**验证 SSH 可达。

### 路径选择

Mac 通过 **OpenSSH** 控制 Windows，有两条路径（详见 `~/.codex/skills/windows-tailscale-ssh-control/SKILL.md`）：

| 路径 | SSH 别名 | 地址 | 场景 |
|------|----------|------|------|
| 远程 Tailscale | `eli` / `win` | `100.112.117.86` | 外出、通用默认 |
| 局域网直连 | `eli-lan` | `192.168.101.170` | 在家同一 WiFi，更快 |

Mac 侧 Tailnet 由 **Surge 内置 Tailscale**（`surge-mac`）提供；Mac 上 **没有** 独立 Tailscale App。

### 连通性检查

**默认（远程）：**

```bash
~/.codex/skills/windows-tailscale-ssh-control/scripts/winps.sh 'hostname; whoami'
```

**在家（优先，更快）：**

```bash
WIN_HOST=eli-lan ~/.codex/skills/windows-tailscale-ssh-control/scripts/winps.sh 'hostname; whoami'
```

期望输出：

```text
ELI
eli\rfnor
```

若失败，按 `~/.codex/skills/windows-tailscale-ssh-control/SKILL.md` 排查对应路径。不要用 `tailscale ping` 或 `ping 100.x` 判断 Mac→Windows 连通性。

连通之前：**停止，不改代码，告知用户连接失败。**

## 双端开发流程

连通后，按以下顺序工作：

1. **读两端代码**：`mac/`（Swift 接收/播放）与 `windows/`（C++ WASAPI 发送）
2. **改代码**：哪端有问题改哪端；协议变更需同时更新 `PROTOCOL.md` 与两端实现
3. **编译并部署两端**（改完必须执行，不要只改不部署）：

   ```bash
   ./deploy.sh
   ```

   在家部署可加速：

   ```bash
   WIN_HOST=eli-lan ./deploy.sh
   ```

   该脚本会：交叉编译 `windows/Auvol.exe` → 编译 Mac 接收端 → 推到 Windows 桌面 → 重启 Mac 接收端

4. **告知用户**：Windows 需 **Disconnect → 重新 Connect** 才会用到新 exe
5. **联调验证**：在 Windows 播放音频，确认 Mac 端接收正常；必要时查看 Mac 菜单栏统计（Buffer、Lost pkts、Starved/s）

## 项目结构

| 路径 | 说明 |
|------|------|
| `mac/` | Mac 菜单栏 app，UDP 接收 + AVAudioEngine 播放 |
| `windows/` | Windows GUI，WASAPI loopback 采集 + UDP 发送 |
| `PROTOCOL.md` | ALV2 协议定义 |
| `deploy.sh` | 一键编译并更新 Mac + Windows 桌面 App |

## Windows 连接信息

```text
用户:       rfnor
电脑名:     ELI
桌面 exe:   C:\Users\rfnor\Desktop\Auvol.exe
Mac IP:     192.168.101.162（Windows 端默认填入）

远程 SSH:   eli / win  →  100.112.117.86  (Surge 内置 Tailscale)
局域网 SSH: eli-lan    →  192.168.101.170 (同一 WiFi，不走 Tailscale)
MagicDNS:   eli.tail5f875c.ts.net（仅人工参考，自动化用别名）
```

远程命令：

```bash
# 默认远程
~/.codex/skills/windows-tailscale-ssh-control/scripts/winps.sh '<powershell 命令>'

# 在家局域网
WIN_HOST=eli-lan ~/.codex/skills/windows-tailscale-ssh-control/scripts/winps.sh '<powershell 命令>'
```

`deploy.sh` 通过 `WIN_HOST` 环境变量选择路径（默认 `eli`）。

## 禁止事项

- **禁止**在 Windows 不可达时修改代码或提交
- **禁止**只改 Mac 端或只改 Windows 端而不部署、不联调（除非用户明确要求仅做只读分析）
- **禁止**改完代码不跑 `./deploy.sh` 就声称完成
- **禁止**在 Mac 上重装独立 Tailscale App（与 Surge 冲突）
- **禁止**用临时 HTTP agent 替代 OpenSSH 控制面
- **禁止**在自动化里依赖 MagicDNS hostname；统一用 `eli` 或 `eli-lan` 别名

## 只读任务例外

以下情况可以在不连 Windows 时进行，且 **不得改代码**：

- 阅读代码、解释架构、回答用户问题
- 查看 git 历史、审查 diff
- 撰写文档（用户明确要求时）

只要涉及 **实现、修复、重构、调参**，就必须先连 Windows。
