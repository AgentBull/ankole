---
title: kit CLI 参考
description: devkit 命令界面——运维者或贡献者会跑的每一条 `bun run kit` 命令、它做什么，以及包裹它的脚本。
section: Reference
order: 200
---

`kit` 是 Ankole 的 devkit 命令行。在仓库根目录用 `bun run kit <command>` 调用，覆盖环境准备、本地服务、开发环境、数据库生命周期、激活码、日志、代码生成和仓库分析。本页是每条命令的参考。

先说明最关键的一点：`kit` 是 `tools/devkit/` 里的一个 Bun + TypeScript 程序，仓库 `package.json` 的脚本把常用命令（`services:start`、`services:stop`、`dev`、`analyze` 等）包了起来，你不必打全 `bun run kit` 形态。两种形态都行；脚本只是别名。

## 环境与检测

| 命令 | 做什么 |
|---|---|
| `kit env-setup` | 安装 Ankole 开发所需的主机工具链——系统构建软件包、Docker、Rust、Elixir/Erlang 工具链、固定版本的 Bun。加 `--print` 可只打印安装命令而不执行。 |
| `kit is-ci` | 在 CI 环境退出 `0`，否则 `1`。供按 CI 分支的脚本使用。 |
| `kit is-dev` | 在开发环境退出 `0`，否则 `1`。 |

在一台新机器上跑一次 `env-setup`；其余是其它命令内部调用的检测助手。

## 本地服务与开发环境

| 命令 | 做什么 |
|---|---|
| `kit external-services start` | 启动 devkit Docker Compose 服务（PostgreSQL 18 与 `ankole-function-runtime`）。包裹为 `bun run services:start`。 |
| `kit external-services stop` | 停止 devkit Compose 服务。包裹为 `bun run services:stop`。 |
| `kit external-services status` | 报告 devkit 服务健康。包裹为 `bun run services:status`。 |
| `kit dev` | 启动完整开发环境——PostgreSQL 18、`ankole-function-runtime`、Phoenix 与前端资源，并使用 Docker Worker 后端为每个 Agent 创建一个 Worker 容器。包裹为 `bun run dev`。保持该终端开着。 |

`kit dev` 是启动整套本地栈的命令。它启动或检查 PostgreSQL 18 与 `ankole-function-runtime`、创建并迁移本地控制面数据库（`ankole_dev`）、构建缺失或过期的 worker 镜像，并以 Docker Worker 后端启动控制面。未设置 `BASE_DB_URLS` 时，控制面开发引导还会自动创建并准备四个本地 Base 分片数据库（`ankole_base_00` 至 `ankole_base_03`）。创建 Agent 时，控制面为它创建 Worker 容器；容器用 `bun --watch` 运行本地 Agent Computer 源码。用 `docker ps -a --filter label=ankole.installation=dev` 列出这些容器。不要再开第二个 `kit dev`；在它的终端按 `Ctrl+C` 停止，这也会删除 `dev` 安装的 Worker 容器，因此重启后，控制面会在已有 Agent 下次需要 Worker 时重新创建它。

## 数据库生命周期

`kit app-db` 拥有本地控制面数据库：

| 命令 | 做什么 |
|---|---|
| `kit app-db create` | 若 app 数据库不存在则创建。 |
| `kit app-db drop` | 删除 app 数据库。需要 `--yes` 确认破坏性操作。 |
| `kit app-db rebuild` | 删除、创建并迁移 app 数据库。需要 `--yes`；重建后跑 Ecto migration。 |
| `kit app-db migrate` | 对已配置的本地数据库跑控制面 Ecto migration。 |

`create`、`drop` 和 `rebuild` 共享以下选项：`--start-services` 在操作前启动 Compose，`--pull` 先拉取最新服务镜像，`--wait-timeout` 设置等待服务健康检查的秒数（默认 `60`）。`app-db rebuild` 会删除本地 `ankole_dev` 数据库——只在数据确实可丢弃时才运行。

## 设置与检查

| 命令 | 做什么 |
|---|---|
| `kit show bootstrap-activation-code` | 打印当前设置激活码。首次访问页面需要 code 而 `kit dev` 终端看不见时用它。 |
| `kit logs pretty` | 把 stdin 里的 Ankole 结构化 JSON 日志行漂亮打印。把日志流管给它，得到可读的本地输出。 |

## 代码生成与分析

| 命令 | 做什么 |
|---|---|
| `kit generate [collection-name:]<schematic-name> [options]` | 按 schematic 生成或修改文件。`bun run kit g code-workspace`（包裹为 `bun run workspace:update`）重新生成 VS Code 工作区。 |
| `kit analyze all` | 跑全部仓库分析。包裹为 `bun run analyze`。 |
| `kit analyze smells` | 报告代码异味。包裹为 `bun run analyze:smells`。 |
| `kit analyze unused` | 报告未使用代码。包裹为 `bun run analyze:unused`。 |
| `kit analyze structure` | 报告仓库结构。包裹为 `bun run analyze:structure`。 |
| `kit analyze cycles` | 报告依赖循环。包裹为 `bun run analyze:cycles`。 |

## worker 测试运行器

`kit agent-computer-test` 在规范 worker 容器运行时里跑 Agent Computer Worker 包测试，于是测试在与真实回合相同的环境里执行。它取 `--suite` 为 `unit` 或 `integration`，以及一个 `--image` 指向特定 Agent Computer Worker Docker 镜像，而不构建。

## 发现更多

```bash
bun run kit --help
```

`kit` 是一个 `@crustjs` 命令树，每一层都有 `--help`。上面的命令是运维者或贡献者实际会跑的；某条命令的完整子命令面（比如 `kit app-db --help`），直接问 CLI。

## 下一步

- 用到这些命令的本地环境走查，读 [快速开始](../quickstart/)。
- `kit dev` 启动了什么，读 [架构概览](../architecture/)。
