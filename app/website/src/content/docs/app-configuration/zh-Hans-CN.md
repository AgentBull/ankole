---
title: AppConfigure
description: 运维者管理的运行时配置存储——它是什么、与环境变量的区别、scope、加密、解密权限。
section: User guide
order: 43
---

AppConfigure 是 Ankole 的数据库-backed 运行时配置存储。它持有运维者在安装运行期间通过 Console 更改的设置——AI agent 限制、Brain dreaming、directory 同步间隔、plugin 启用等。本页是 AppConfigure 是什么、与环境变量有何不同、如何使用它的运维者视角。

先把决定性的性质说清楚：AppConfigure 是**运行时可改、PostgreSQL-backed 的配置**。它不是环境变量（部署时设定），也不是自由形态的键值存储（每个键在启动时由拥有它的子系统声明）。通过 Console 改一个键，它就生效——多数键立即，少数下次进程启动。

## 与环境变量的区别

Ankole 从两个生命周期不同的地方读配置：

| | 环境变量 | AppConfigure |
|---|---|---|
| 生命周期 | 进程启动时设定，需重启才改 | 通过 Console 运行时改 |
| 存储 | 部署的 `.env` 或 Secret | PostgreSQL（`app_configurations` 表） |
| 什么属于这里 | 引导 secret、数据库 URL、端口、日志级别 | agent 设置、Brain 配置、plugin 启用、同步间隔 |
| 加密 | 部分（worker 认证 key） | 按键：每个定义的 `encrypted` 标志 |

设置能等到 PostgreSQL 起来，就属于 AppConfigure。等不到——PostgreSQL 可达之前就需要——就属于环境变量。完整划分见[环境变量](../environment-variables/)。

## Console 界面

AppConfigure 键通过四条 Console 路由管理：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/app-configurations` | 列出 console 可见条目（元数据，不含加密值） |
| `GET` | `/app-configurations/:key` | 读取一个条目 |
| `PUT` | `/app-configurations/:key` | 存储一个值 |
| `DELETE` | `/app-configurations/:key` | 把一个值重置为默认 |
| `POST` | `/app-configurations/:key/decryptions` | 揭示一个加密值 |

列出和读取返回元数据和非加密值。加密键的值在读取时不返回——只有解密动作揭示它，且解密是单独授权的动作。

## Scope

AppConfigure 条目带 scope：

- **`global`**——整套部署一个值。多数键是全局的。
- **`agent:<uid>`**——全局默认的按 agent 覆盖。子系统在个别 agent 需要不同设置时声明带 agent scope 的键。

scope 是键定义的一部分，不是运维者选的。全局键取一个值；agent-scoped 键取一个全局默认加按 agent 覆盖。

## 加密

每个 AppConfigure 定义带 `encrypted` 标志。为 `true` 时：

- 值在 PostgreSQL 中静态加密，用 kernel 支持的 AEAD 原语。
- `GET` 路由不返回值——只返回元数据。
- `POST .../decryptions` 路由揭示值，且是单独授权的动作（与 `read` 分开）。

这与 [WorkerEnv secret](../worker-env/) 同模型——但 AppConfigure 面向子系统拥有的配置，WorkerEnv 面向 agent 的 shell 环境。

## 运维者动的键

完整列表在[环境变量](../environment-variables/)的"AppConfigure 键"一节。运维者最常动的：

- **AI agent 限制**——`ai_agent.max_iterations`、`max_output_tokens`、`inactivity_timeout_ms`
- **Brain**——`brain.dreaming`、`brain.knowledge`、`brain.embedding`、`brain.search`、`brain.sources`
- **Plugin**——`plugins.enabled_ids`（下次启动生效）
- **Directory 同步**——`principals.identity_providers.directory_full_sync_interval_hours`
- **SSRF**——`security.ssrf_filter`
- **后台任务**——`agent_computer.background_agent_job.max_turns_per_worker`

## 改动何时生效

- **多数键**立即生效——下次读取捡起新值。
- **`plugins.enabled_ids`**下次进程启动生效，因为激活或停用 plugin 增删受监督子进程。
- **加密键**（provider 凭证、secret）在下次读取时解密——无需重启，但已解析旧值的进行中回合保留它直到回合结束。

## 本指南不是什么

它不是配置参考——完整键列表带描述在[环境变量](../environment-variables/)。它不是运行时加新键的方式——每个键在启动时由子系统声明，未声明的键无法存储。它也不是 Console 各子系统路由的替代——provider 凭证更好通过 `/ai-gateway/providers/:id` 设，而非通过原始 AppConfigure 键。

## 下一步

- 完整键列表，读[环境变量](../environment-variables/)。
- Console 界面，读 [Console 运维操作](../console-operations/)和 [Console API 参考](../console-api/)。
- 加密 shell secret（另一个存储），读 [WorkerEnv secret](../worker-env/)。
