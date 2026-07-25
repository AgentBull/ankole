---
title: 快速开始
description: 准备工具链，并从源码运行完整的 Ankole 开发环境。
section: Getting started
order: 2
---

本页是从源码本地安装的简明路径。仓库的 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) 仍然是环境准备、产品设置、飞书/Lark 配置、故障排查和端到端验收的事实来源——某个步骤需要更多细节时，回到那里查阅。

完整的本地环境会运行 PostgreSQL、Phoenix/OTP 控制面、Web Console、前端资源和一个受管的 Docker Agent Computer Worker。

## 适合谁看

你想在自己的机器上从源码运行 Ankole：在它上面做开发、复现某个问题，或者在正式部署之前亲眼看到每个组件都跑起来。如果只想拥有一套运行中的部署，请直接跳到[安装部署指南](../installation/)，使用 Docker Compose 或 Helm。

## 选择受支持的环境

使用 macOS 或 Linux；Windows 请使用 WSL2。你需要一个能安装系统软件包的账号、稳定的网络，以及：

- macOS 上的 Docker Desktop，或 Linux 上带 Compose 的 Docker Engine；
- 用于一次真实 agent 回合的 LLM provider API key；
- 如果要跑文档里的端到端测试，还要有一个能创建企业自建应用的飞书账号。

GitHub Codespaces 适合代码和测试工作。基准飞书流程假设浏览器和 Ankole 都使用 `localhost:4000`；当 Codespaces 给你的是转发后的 HTTPS origin 时，必须自己调整并验证回调。

## 克隆并检查仓库

```bash
git clone https://github.com/AgentBull/ankole.git
cd ankole
git status --short
```

除非步骤另有说明，后续命令都从仓库根目录执行。

## 安装并验证系统工具

先看一遍安装脚本，再执行：

```bash
bash tools/devkit/scripts/env-setup.sh
```

脚本会装好系统构建软件包、Docker、带 `rustfmt` 和 `clippy` 的 stable Rust 工具链、仓库指定的 Elixir/Erlang 工具链，以及仓库固定版本的 Bun。

脚本完成后，开一个新终端。macOS 上启动 Docker Desktop；如果脚本把你的 Linux 账号加入了 `docker` 组，先注销再登录。回到仓库根目录，逐项验证：

```bash
bun --version
elixir --version
rustc --version
cargo clippy --version
docker compose version
docker info
```

`bun --version` 必须与根目录 `package.json` 里的 `packageManager` 一致。其余每条命令都必须成功，`docker info` 必须能连上 daemon。任何一项失败，先停下来解决，再往下走——后面的步骤默认这些工具都可用。

## 安装依赖并初始化 PostgreSQL

按顺序执行：

```bash
bun install
bun run services:start
bun run services:status
bun run control-plane:setup
```

这些命令会安装 workspace 和 Elixir 依赖、通过 devkit Compose 启动 PostgreSQL、创建开发数据库、执行 Ecto migration 并加载 seed。第一次编译 Elixir 可能要几分钟。

有一件事值得先说清楚：不要因为某个设置命令失败就去重置数据库。保留第一个可以采取行动的错误，按 `CONTRIBUTING.md` 描述的顺序处理。

## 启动完整开发环境

```bash
bun dev
```

保持这个终端开着。devkit 会启动或检查 PostgreSQL、创建并迁移本地数据库、构建缺失或过期的 Worker 镜像、启动 Phoenix 和前端资源，并启动一个受管的 Docker Worker。

在另一个终端确认这些可见的边界：

```bash
bun run services:status
curl -I http://localhost:4000/
docker ps --filter name=ankole-dev-agent-computer
```

打开 [http://localhost:4000](http://localhost:4000)。不要再开第二个 `bun dev`。在原终端按 `Ctrl+C` 停止受管的控制面和 Worker。PostgreSQL 会继续运行；用完后再单独停止：

```bash
bun run services:stop
```

## 完成产品设置和验收

首次访问时，在页面上点击重新打印，从 `bun dev` 终端读取 `SETUP ACTIVATION CODE`。需要在另一个终端读取时：

```bash
bun run kit show bootstrap-activation-code
```

PostgreSQL 健康、HTTP 页面能打开、`ankole-dev-agent-computer` 持续运行，才算本地技术环境就绪。完整的产品设置还差几件事：

1. 首位管理员登录成功；
2. 至少有一个可用的 LLM provider 和一个 Agent；
3. 已启用一个 Signal binding；
4. `local-dev-worker` 进入就绪状态；
5. 一条真实的飞书/Lark 消息到达 Agent，并收到预期回复。

请严格遵循 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) 中的权限、事件、回调、Console 字段和验收消息。页面可见、容器在跑，都不能证明端到端路径已经走通。

生产部署请继续阅读[安装部署指南](../installation/)。
