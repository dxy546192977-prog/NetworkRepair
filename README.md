# 中国区访问大模型网络受限的修复工具

一键诊断并修复 macOS / Windows 上 Cursor 连接 OpenAI、Anthropic、Cursor API 的网络问题。

## 快速开始

### macOS

**方式一（推荐）：** 在 Finder 中双击 `Mac双击运行.app`

**方式二（命令行）：**

```bash
./src/bin/cursor-network-repair
```

**方式三（安装到系统）：**

```bash
./install.sh
cursor-network-repair
```

### Windows

双击 `Win双击运行.exe`

## 检测目标

| 服务 | 域名 |
|------|------|
| OpenAI | `api.openai.com`、`chat.openai.com` |
| Anthropic | `api.anthropic.com`、`claude.ai` |
| Cursor | `api2.cursor.sh`、`api.cursor.sh` |

## 修复内容

- DNS 缓存刷新 + mDNSResponder 重启
- /etc/hosts 劫持检测与清理
- ARP 缓存清理
- 系统代理检测
- DNS 切换到公共解析器
- Cursor 代理设置修复

## 自定义配置

编辑 `src/support/settings.json` 可自定义 DNS 服务器、检测目标、超时时间等。

## 详细文档

参见 [src/docs/README.md](src/docs/README.md)
