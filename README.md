# Cursor 大模型网络修复脚本

## 文件说明

- `cursor-model-network-repair.ps1`：跨平台检测（Windows / macOS / Linux 上需 PowerShell）；**深度网络栈修复仅 Windows**
- `run.sh`：**Mac / Linux / Git Bash** 通用启动入口（依赖 `pwsh`）
- `一键修复-Cursor大模型网络.cmd`：**Windows** 双击入口（运行结束后窗口会自动关闭）
- `logs/`：每次执行后生成日志

## 通用运行命令（Mac 与 Windows）

在 `网络修复` 目录下执行（路径按你的实际位置调整）：

**推荐（跨平台一致，需已安装 PowerShell 7）：**

```bash
pwsh -NoProfile -ExecutionPolicy Bypass -File "./cursor-model-network-repair.ps1"
```

**macOS / Linux 也可用 shell 包装（会自动调用 `pwsh`）：**

```bash
chmod +x ./run.sh
./run.sh
```

**仅 Windows、且未安装 pwsh 时，可用系统自带 Windows PowerShell：**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\cursor-model-network-repair.ps1"
```

说明：Unix 上未安装 `pwsh` 时，请先从 [Get PowerShell](https://aka.ms/powershell) 安装；脚本在 macOS/Linux 上会执行连通性与 HTTPS 探测，**不会像 Windows 那样执行 netsh / Winsock 重置**。

## 「Model not available / region」和本脚本的关系

- 脚本解决的是 **DNS、TCP 443、本机 WinHTTP 代理、Winsock/TCP-IP 栈** 等问题。
- Cursor 提示 **「This model provider doesn't serve your region」** 属于服务端 **账号/计费地区或合规策略**，与「能不能连上 443」不是同一类问题。
- **TCP 全绿仍可能继续出现 region 提示**，此时应查阅官方地区说明并核对账号，而不是反复跑网络重置。

官方文档（请在浏览器中打开核对最新政策）：

- [Regions | Cursor Docs](https://cursor.com/docs/account/regions)

脚本新增 **HTTPS 探测**（对 `https://api2.cursor.sh/`）：在 TLS 能建立的前提下根据 HTTP 状态码与响应片段提示是否 **更像地区/策略拦截**；若 TCP 通但出现相关信号，会打印上述文档链接。

## 如何区分该走哪条路

| 现象 | 建议 |
|------|------|
| DNS 失败或 TCP 443 失败 | 使用本脚本 + 查代理/防火墙/运营商 |
| TCP 与 HTTPS 探测正常，Cursor 仍报 region | 阅读 [regions 文档](https://cursor.com/docs/account/regions)，核对订阅与提供商在您地区的可用性 |
| HTTPS 探测提示可能为 region，且 TCP 到 `api2.cursor.sh` 正常 | 按文档处理账号/地区；本地栈修复通常无法消除该提示 |

## Claude Code 一键（检测网络 + 注入 OpenRouter 环境后启动）

- **`ClaudeCodeNetLauncher.exe`**：双击后等价于运行 `cursor-model-network-repair.ps1 -LaunchClaude`（会请求管理员权限以执行 Winsock 等修复）。
- **`ClaudeCode网络一键.cmd`**：同上，适合不方便运行 exe 的环境。

启动 Claude Code 时，脚本会：

1. 读取 **`%USERPROFILE%\.claude\settings.json`** 里的 `env`（你的 OpenRouter Key、`ANTHROPIC_BASE_URL` 等）。
2. 若同目录存在 **`claude-code-launch.json`**，其中的 `env` 会覆盖同名变量（便于只给本仓库放一份补充配置）。
3. 自动补齐 OpenRouter 官方文档推荐的默认值（例如 `ANTHROPIC_API_KEY` 置空、模型 ID 使用 `anthropic/...` 前缀）。
4. 在 **「网络修复」文件夹的上一级目录**（例如 `...\AI·Project`）打开 Claude Code；若该路径不存在则回退到 `Desktop\AI` 或 `Desktop`。

**说明**：若上游仍返回 **「not available in your region」**，属于模型/账号地区策略，本脚本无法通过改 DNS 消除；请在 OpenRouter 后台调整 [Provider routing](https://openrouter.ai/docs/guides/routing/provider-selection) 或更换可用模型。

## 一键运行

双击：`一键修复-Cursor大模型网络.cmd`

## 命令行运行

```powershell
powershell -ExecutionPolicy Bypass -File ".\cursor-model-network-repair.ps1"
```

## 可选参数

- `-NoDnsChange`：不改 DNS，只做缓存/代理/网络栈修复
- `-ForceRepair`：即使初检通过也强制执行修复
- `-FixStoreOnlyNoReboot`：仅修复 Microsoft Store（不执行 Winsock/TCP 重置，尽量避免必须重启）

## 配置项（settings.json）

编辑 `src/support/settings.json`：

- `repairs.fixMicrosoftStoreLinkAfterRepair`：是否在网络栈修复完成后，额外执行 Microsoft Store 链接修复（`wsreset` + Store 包重注册 + `ms-windows-store://` 协议探测）。

示例：

```powershell
powershell -ExecutionPolicy Bypass -File ".\cursor-model-network-repair.ps1" -NoDnsChange
```

## 检测目标

- OpenAI: `api.openai.com`、`chat.openai.com`
- Anthropic: `api.anthropic.com`、`claude.ai`
- Cursor: `api2.cursor.sh`、`api.cursor.sh`

## 注意事项

- 脚本包含 `winsock` / `tcp-ip` 重置，通常建议执行后重启电脑。
- 若修复后仍失败，除地区策略外，还可能是公司网关、代理冲突或运营商拦截。
- 是否通过代理/VPN 变更出口须自行对照 Cursor 用户协议与当地法规。
