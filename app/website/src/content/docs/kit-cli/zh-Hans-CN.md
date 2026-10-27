---
title: kit CLI 参考
description: devkit 命令行参考——汇总日常运维与开发常用的 `bun run kit` 命令、具体用途及对应的脚本别名。
section: Reference
order: 200
---

`kit` 是 Ankole 的开发工具箱（devkit）命令行程序，可在仓库根目录下通过 `bun run kit <command>` 调用，涵盖环境初始化、本地依赖服务、开发环境、数据库生命周期、激活码查询、日志格式化、代码生成与仓库静态分析等功能。本页汇总了各常用命令的说明。

简言之，`kit` 是位于 `tools/devkit/` 下的 Bun + TypeScript 程序；仓库根目录的 `package.json` 已将常用子命令封装为快捷脚本（如 `services:start`、`services:stop`、`dev`、`analyze` 等），作为 `bun run kit` 的简写别名，两种调用方式完全等效。

## 环境与检测

| 命令 | 用途 |
|---|---|
| `kit env-setup` | 安装开发 Ankole 所需的主机工具链，包括系统构建软件包、Docker、Rust、Elixir/Erlang 工具链及固定版本的 Bun。附加 `--print` 时仅打印安装命令而不实际执行。 |
| `kit is-ci` | 在 CI 环境中以状态码 `0` 退出，否则返回 `1`，供按 CI 环境分支处理的脚本调用。 |
| `kit is-dev` | 在开发环境中以状态码 `0` 退出，否则返回 `1`。 |

在新机器上首次搭建环境时运行一次 `env-setup` 即可；其余两条主要用于其他命令或脚本内部的环境检测。

## 本地服务与开发环境

| 命令 | 用途 |
|---|---|
| `kit external-services start` | 启动 devkit Docker Compose 服务（PostgreSQL 18 与 `ankole-function-runtime`）。对应脚本别名为 `bun run services:start`。 |
| `kit external-services stop` | 停止 devkit Compose 服务。对应脚本别名为 `bun run services:stop`。 |
| `kit external-services status` | 查看 devkit 服务的健康状态。对应脚本别名为 `bun run services:status`。 |
| `kit dev` | 启动完整本地开发环境——包括 PostgreSQL 18、`ankole-function-runtime`、Phoenix 与前端资源，并使用 Docker Worker 后端为每个 Agent 创建独立的 Worker 容器。对应脚本别名为 `bun run dev`，运行期间请保持该终端窗口开启。 |

`kit dev` 用于一键拉起整套本地技术栈：先启动或检查 PostgreSQL 18 与 `ankole-function-runtime`，创建并迁移本地控制面数据库（`ankole_dev`），构建缺失或过期的 Worker 镜像，最后以 Docker Worker 后端启动控制面。未显式设置 `BASE_DB_URLS` 时，控制面在开发引导阶段还会自动创建并初始化四个本地 Base 分片数据库（`ankole_base_00` 至 `ankole_base_03`）。新建 Agent 时，控制面会为其创建 Worker 容器，并在容器内通过 `bun --watch` 直接运行本地 Agent Computer 源码；可通过 `docker ps -a --filter label=ankole.installation=dev` 查看这些容器。请勿同时启动第二个 `kit dev` 实例。在终端按下 `Ctrl+C` 停止服务时，系统会一并清理带有 `dev` 安装标签的 Worker 容器；下次重启后，控制面会在已有 Agent 需要执行任务时自动重建容器。

## 数据库生命周期

`kit app-db` 用于管理本地控制面数据库：

| 命令 | 用途 |
|---|---|
| `kit app-db create` | 若本地应用数据库尚不存在，则创建该数据库。 |
| `kit app-db drop` | 删除本地应用数据库。此操作不可逆，必须附加 `--yes` 确认。 |
| `kit app-db rebuild` | 删除并重新创建本地应用数据库，随后自动运行 Ecto 迁移。必须附加 `--yes` 确认。 |
| `kit app-db migrate` | 对当前配置的本地数据库运行控制面 Ecto 迁移。 |

`create`、`drop` 与 `rebuild` 共用以下选项：`--start-services` 会在操作前先启动 Compose 服务，`--pull` 会预先拉取最新服务镜像，`--wait-timeout` 用于设置等待服务通过健康检查的超时秒数（默认 `60`）。由于 `app-db rebuild` 会彻底删除本地 `ankole_dev` 数据库，请仅在确认本地数据可丢弃时运行。

## 设置与检查

| 命令 | 用途 |
|---|---|
| `kit show bootstrap-activation-code` | 打印当前的初始化激活码。首次打开设置页面需要输入激活码、但又看不到 `kit dev` 终端输出时，可运行此命令查看。 |
| `kit logs pretty` | 从标准输入（stdin）读取 Ankole 结构化 JSON 日志并格式化打印。可将日志流通过管道传给该命令，获得易于阅读的本地输出。 |

## 代码生成与分析

| 命令 | 用途 |
|---|---|
| `kit generate [collection-name:]<schematic-name> [options]` | 按指定模板（Schematic）生成或更新文件。例如 `bun run kit g code-workspace`（对应脚本别名 `bun run workspace:update`）用于重新生成 VS Code 工作区文件。 |
| `kit analyze all` | 运行全部仓库静态分析检查。对应脚本别名为 `bun run analyze`。 |
| `kit analyze smells` | 检测并报告代码异味。对应脚本别名为 `bun run analyze:smells`。 |
| `kit analyze unused` | 检测并报告未使用的代码。对应脚本别名为 `bun run analyze:unused`。 |
| `kit analyze structure` | 检查并报告仓库目录与模块结构。对应脚本别名为 `bun run analyze:structure`。 |
| `kit analyze cycles` | 检测并报告循环依赖。对应脚本别名为 `bun run analyze:cycles`。 |

## worker 测试运行器

`kit agent-computer-test` 会在标准 Worker 容器运行时内执行 Agent Computer Worker 包的测试套件，确保测试在与真实回合一致的环境中运行。可通过 `--suite` 指定 `unit` 或 `integration`，也可通过 `--image` 直接指定现成的 Agent Computer Worker Docker 镜像以跳过构建步骤。

## 发现更多

```bash
bun run kit --help
```

`kit` 基于 `@crustjs` 构建为分层命令树，每一级均支持 `--help`。上文列出了运维与日常开发最常用的命令；如需查看某条命令下的完整子命令与参数列表（如 `kit app-db --help`），可直接在终端查询帮助信息。

## 下一步

- 查看串联使用这些命令的本地部署流程，请参阅 [快速开始](../quickstart/)。
- 了解 `kit dev` 启动了哪些组件及其职责，请参阅 [架构概览](../architecture/)。
