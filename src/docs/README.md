# Cursor 大模型网络修复脚本 — 详细文档

## 前提条件

- **macOS**：10.15+ (Catalina 及以上)，需有管理员权限（sudo）
- **Windows**：PowerShell 5.1+（系统自带）或 PowerShell 7

## 文件说明

### macOS 原生工具包

- `Mac双击运行.app`：**macOS 双击入口**，在 Finder 中双击即可自动打开终端并执行修复（使用终端图标）
- `src/bin/cursor-network-repair`：macOS CLI 入口脚本
- `src/lib/network_repair.sh`：核心修复逻辑（DNS 缓存刷新、mDNS 重启、ARP 清除、代理检测、DNS 切换）
- `src/lib/network_check.sh`：网络检测函数库（DNS 解析、TCP 443、HTTPS 探测）
- `src/support/settings.json`：可自定义配置（检测目标、DNS 服务器、超时时间）
- `src/VERSION`：版本号

### Windows / 跨平台

- `Win双击运行.exe`：**Windows** 单文件双击入口（推荐，由 Go 启动器构建）
- `src/cursor-model-network-repair.ps1`：跨平台检测（Windows / macOS / Linux）；**深度网络栈修复仅 Windows**
- `src/run.sh`：**Mac / Linux / Git Bash** 通用启动入口（依赖 `pwsh`）
- `src/bin/cursor-company.cmd` + `src/bin/cursor-company.ps1`：Windows 版 `cursor-company` 启动包装器（继承代理环境后启动 Cursor，默认带 HTTP/2 启动门禁）

### 构建工具

- `tools/build-win-exe.sh`：构建 Windows EXE（需要 Go 编译器）
- `tools/win-launcher/`：Go 源码

### 通用

- `src/logs/`：每次执行后自动生成日志
- `install.sh`：安装到系统（`~/.local/bin`）

## 一键运行

**macOS：** 在 Finder 中双击 `Mac双击运行.app`

**Windows：** 双击 `Win双击运行.exe`（默认 `-OneClickFix` 全自动修复）

## 安装到系统（macOS）

```bash
./install.sh
```

安装后可在任意目录运行：

```bash
cursor-network-repair
```

升级时：

```bash
./install.sh --upgrade
```

## 命令行运行

**macOS (原生 bash，推荐)：**

```bash
./src/bin/cursor-network-repair
```

**跨平台（需 PowerShell 7）：**

```bash
pwsh -NoProfile -ExecutionPolicy Bypass -File "./src/cursor-model-network-repair.ps1"
```

**Windows (PowerShell)：**

```powershell
powershell -ExecutionPolicy Bypass -File ".\src\cursor-model-network-repair.ps1"
```

**Windows 增强诊断：**

```powershell
powershell -ExecutionPolicy Bypass -File ".\src\cursor-model-network-repair.ps1" -Doctor
powershell -ExecutionPolicy Bypass -File ".\src\cursor-model-network-repair.ps1" -ProbeHttp2
powershell -ExecutionPolicy Bypass -File ".\src\cursor-model-network-repair.ps1" -InstallCursorWrapper
powershell -ExecutionPolicy Bypass -File ".\src\cursor-model-network-repair.ps1" -OneClickFix
```

## 可选参数

**macOS 原生版本：**

| 参数 | 说明 |
|------|------|
| `--no-dns-change` | 不改 DNS，只做缓存刷新/代理检测 |
| `--force-repair` | 即使初检通过也强制执行修复 |
| `--help` | 显示帮助信息 |

**PowerShell 版本 (Windows)：**

| 参数 | 说明 |
|------|------|
| `-NoDnsChange` | 不改 DNS，只做缓存/代理/网络栈修复 |
| `-ForceRepair` | 即使初检通过也强制执行修复 |
| `-Doctor` | 只做诊断，不执行修复；输出 `network-doctor-*.json` 和 `network-doctor-latest.json` |
| `-ProbeHttp2` | 仅执行 Cursor 目标 HTTP/2 探测 |
| `-InstallCursorWrapper` | 安装 `cursor-company` 到 `%USERPROFILE%\.local\bin` |
| `-OneClickFix` | 全流程自动修复（提权 + wrapper + 修复 + HTTP/2 验证） |
| `-FixStoreOnlyNoReboot` | 仅执行 Microsoft Store 修复（进程关闭/缓存清理/重注册/服务拉起），不执行 Winsock/TCP 重置 |

`cursor-company` 额外参数：

| 参数 | 说明 |
|------|------|
| `-SkipHttp2Gate` | 临时跳过 HTTP/2 启动门禁（仅排障时使用） |

HTTP/2 探测实现说明：

- 优先 `curl --http2`
- 如果当前 `curl` 不支持 HTTP/2，会自动回退到 `PowerShell 7 (pwsh)` 探测

## 自定义配置

编辑 `src/support/settings.json` 可修改以下参数：

```json
{
  "targets": ["api.openai.com", "..."],
  "dns": { "primary": "1.1.1.1", "secondary": "8.8.8.8" },
  "timeouts": { "dns_sec": 4, "tcp_sec": 6, "https_probe_sec": 20 },
  "probe_url": "https://api2.cursor.sh/",
  "diagnostics": {
    "cursorHttp2Targets": ["https://api2.cursor.sh/", "https://api.cursor.sh/"]
  },
  "repairs": {
    "fixMicrosoftStoreLinkAfterRepair": true
  },
  "integrations": {
    "cursorWrapper": {
      "enabled": false,
      "command": "cursor-company",
      "installOnOneClick": false
    },
    "launchClaudeCodeOnExeSuccess": false,
    "showTrayBalloonOnExeFinish": true
  }
}
```

- **targets**：检测的域名列表
- **dns**：修复时切换到的公共 DNS 服务器（建议家庭网络用 `1.1.1.1` / `8.8.8.8`）
- **timeouts**：各检测步骤的超时秒数
- **probe_url**：HTTPS 探测的 URL
- **diagnostics.cursorHttp2Targets**：`probe-http2` / `doctor` 使用的 HTTP/2 探测目标
- **repairs.fixMicrosoftStoreLinkAfterRepair**：为 `true` 时，在 `Run-Repair` 网络栈修复结束后继续执行 Microsoft Store 链接修复（清理 Store 缓存、重注册 `Microsoft.WindowsStore`、探测 `ms-windows-store://` 协议）
- **integrations.cursorWrapper**：`installOnOneClick` 为 `false` 时，`-OneClickFix` 不安装 `cursor-company`；`enabled` 仅作文档标记
- **integrations.launchClaudeCodeOnExeSuccess**：为 `true` 且由 `Win双击运行.exe` 触发的一键成功结束时，才会自动打开 Claude Code（默认 `false`）；但静默模式下会强制跳过，避免弹出终端窗口
- **integrations.showTrayBalloonOnExeFinish**：exe 静默一键结束时是否显示任务栏气泡（默认 `true`）；设为 `false` 则完全静默

如配置文件不存在或格式错误，脚本会回退到内置默认值，不影响运行。

## 检测目标

| 服务 | 域名 |
|------|------|
| OpenAI | `api.openai.com`、`chat.openai.com` |
| Anthropic | `api.anthropic.com`、`claude.ai` |
| Cursor | `api2.cursor.sh`、`api.cursor.sh` |

## 「Model not available / region」和本脚本的关系

- 脚本解决的是 **DNS、TCP 443、本机代理、网络栈** 等问题。
- Cursor 提示 **「This model provider doesn't serve your region」** 属于服务端**账号/计费地区或合规策略**，与「能不能连上 443」不是同一类问题。
- **TCP 全绿仍可能继续出现 region 提示**，此时应查阅官方地区说明并核对账号。

官方文档：[Regions | Cursor Docs](https://cursor.com/docs/account/regions)

## 如何区分该走哪条路

| 现象 | 建议 |
|------|------|
| DNS 失败或 TCP 443 失败 | 使用本脚本 + 查代理/防火墙/运营商 |
| TCP 与 HTTPS 探测正常，Cursor 仍报 region | 阅读 [regions 文档](https://cursor.com/docs/account/regions)，核对订阅与提供商在您地区的可用性 |
| HTTPS 探测提示可能为 region，且 TCP 正常 | 按文档处理账号/地区；本地栈修复通常无法消除该提示 |

## 注意事项

- **macOS**：修复步骤需要 `sudo` 权限（刷新 DNS 缓存、重启 mDNS 服务等），脚本会自动请求密码。
- **Windows**：脚本包含 `winsock` / `tcp-ip` 重置，通常建议执行后重启电脑。
- 若修复后仍失败，除地区策略外，还可能是公司网关、代理冲突或运营商拦截。
- 是否通过代理/VPN 变更出口须自行对照 Cursor 用户协议与当地法规。

## 构建 Windows EXE

```bash
cd tools && chmod +x build-win-exe.sh && ./build-win-exe.sh
```

构建产物：根目录下 `Win双击运行.exe`（x64）

## 目录结构

```
网络修复/
├── Mac双击运行.app/                     # macOS 双击入口 (终端图标)
├── Win双击运行.exe                      # Windows 单文件双击入口 (x64)
├── install.sh                          # ZIP 安装器
├── README.md                           # 快速入门
├── src/                                # 核心脚本
│   ├── bin/
│   │   └── cursor-network-repair       # macOS CLI 入口
│   │   ├── cursor-company.cmd          # Windows Cursor wrapper 入口
│   │   └── cursor-company.ps1          # Windows Cursor wrapper 实现
│   ├── lib/
│   │   ├── network_repair.sh           # 核心修复逻辑
│   │   ├── network_check.sh            # 网络检测函数库
│   │   └── set_icon.py                 # App 图标设置
│   ├── support/
│   │   └── settings.json               # 可自定义配置
│   ├── docs/
│   │   └── README.md                   # 本文档（详细说明）
│   ├── logs/                           # 运行日志 (自动生成)
│   ├── VERSION                         # 版本号
│   ├── cursor-model-network-repair.ps1 # PowerShell 版 (Windows)
│   └── run.sh                          # pwsh 启动器
└── tools/                              # 构建工具
    ├── build-win-exe.sh                # 构建 Windows EXE
    └── win-launcher/                   # Go 源码
        ├── go.mod
        └── main.go
```
