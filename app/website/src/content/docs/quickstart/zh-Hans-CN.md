---
title: 快速开始
description: 准备受支持的工具链，并从源码运行完整的 Ankole 开发环境。
section: Getting started
order: 2
---

本页是本地源码安装的简明路径。仓库
[`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)
是环境准备、产品设置、飞书/Lark 配置、故障排查和端到端验收的事实来源。

完整本地环境会运行 PostgreSQL、Phoenix/OTP 控制面、Web Console、前端资源和
一个受管的 Docker Agent Computer Worker。

## 选择受支持的环境

使用 macOS 或 Linux；Windows 请使用 WSL2。你需要可以安装系统软件包的账号、
稳定的网络，以及：

- macOS 上的 Docker Desktop，或 Linux 上带 Compose 的 Docker Engine；
- 用于真实 Agent Turn 的 LLM provider API key；
- 如果要完成文档规定的端到端测试，还需要能创建企业自建应用的飞书账号。

GitHub Codespaces 适合代码和测试工作。基准飞书流程假设浏览器和 Ankole 都使用
`localhost:4000`。Codespaces 提供转发后的 HTTPS origin 时，必须调整并验证
callback。

## 克隆并检查仓库

```bash
git clone https://github.com/AgentBull/ankole.git
cd ankole
git status --short
```

除非命令另有说明，后续命令都从仓库根目录执行。

## 安装并验证系统工具

先检查仓库环境安装脚本，再执行：

```bash
bash tools/devkit/scripts/env-setup.sh
```

脚本会安装系统构建软件包、Docker、带 `rustfmt` 和 `clippy` 的 stable Rust、
仓库指定的 Elixir/Erlang 工具链，以及仓库固定的 Bun 版本。

脚本完成后打开新终端。macOS 需要启动 Docker Desktop；如果脚本把 Linux 用户
加入了 `docker` group，请先注销再登录。回到仓库根目录并验证：

```bash
bun --version
elixir --version
rustc --version
cargo clippy --version
docker compose version
docker info
```

`bun --version` 必须与根目录 `package.json` 的 `packageManager` 一致。其他命令
必须成功，`docker info` 必须能连接 daemon。任一工具检查失败时都不要继续。

## 安装依赖并初始化 PostgreSQL

按顺序执行：

```bash
bun install
bun run services:start
bun run services:status
bun run control-plane:setup
```

这些命令会安装 workspace 和 Elixir 依赖，通过 devkit Compose 启动 PostgreSQL，
创建开发数据库，执行 Ecto migration 并加载 seed。第一次 Elixir 编译可能需要
几分钟。

不要因为一个设置命令失败就重置数据库。保留第一个可操作错误，并按
`CONTRIBUTING.md` 的故障排查顺序处理。

## 启动完整开发环境

```bash
bun dev
```

保持该终端运行。devkit 会启动或检查 PostgreSQL，创建并迁移本地数据库，构建缺失
或过期的 Worker 镜像，启动 Phoenix 和前端资源，并启动一个受管 Docker Worker。

在另一个终端验证可见边界：

```bash
bun run services:status
curl -I http://localhost:4000/
docker ps --filter name=ankole-dev-agent-computer
```

打开 [http://localhost:4000](http://localhost:4000)。不要再启动第二个
`bun dev`。在原终端按 `Ctrl+C` 停止受管控制面和 Worker。PostgreSQL 会继续
运行；需要时单独停止：

```bash
bun run services:stop
```

## 完成产品设置和验收

首次访问时，在页面点击重新打印，从 `bun dev` 终端读取
`SETUP ACTIVATION CODE`。必要时可在另一个终端读取当前 code：

```bash
bun run kit show bootstrap-activation-code
```

PostgreSQL 健康、HTTP 页面可以打开且 `ankole-dev-agent-computer` 持续运行，表示
本地技术环境已启动。完整产品设置还要求：

1. 首位管理员成功登录；
2. 至少有一个可用 LLM provider 和 Agent；
3. Signal binding 已启用；
4. `local-dev-worker` 已 ready；
5. 一条真实飞书/Lark 消息到达 Agent，并收到预期回复。

请严格使用
[`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)
中的权限、事件、callback、Console 字段和验收消息。页面可见或容器正在运行都不能
证明完整端到端路径成功。

生产部署请继续阅读[安装部署指南](../installation/)。
