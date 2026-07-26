---
title: 平台支持
description: Ankole 支持哪些部署目标、操作系统和开发主机——Compose 主机、Kubernetes 集群、worker 节点，以及贡献者机器。
section: Getting started
order: 5
---

Ankole 是自托管的服务端系统，不是按机器安装的软件，所以“平台支持”意味着两件不同的事：你在哪里**部署**它（运行控制面和 worker 的主机或集群），以及你在哪里**开发**它（贡献者跑 `kit dev` 的机器）。本页是两者的支持矩阵，外加 worker 节点的硬性要求。

先把决定性的性质说清楚：生产跑在 Linux 上。worker 需要 Linux 内核特性做沙箱，受支持的部署包面向 Linux 主机或 Linux Kubernetes 节点。开发可以在 macOS 或 Windows/WSL2 上进行，但发布出去的是 Linux。

## 部署目标

这些是生产环境受支持的运行方式。

| 目标 | 架构 | 方法 | 说明 |
|---|---|---|---|
| **单台 Linux 主机** | `amd64`、`arm64` | Docker Compose | 单主机，内置 PostgreSQL 和 Caddy HTTPS；规范的小型部署 |
| **Kubernetes 集群** | `amd64`、`arm64` Linux 节点 | Helm chart | 内置或外部 PostgreSQL；Agent Home 需要 RWX 存储 |

两种方法都在[安装部署指南](../installation/)中文档化，都从 GitHub Container Registry 拉取同一组已验证镜像。单机选 Compose，集群选 Helm——没有第三种受支持的部署形态。

### 单机要求（Compose）

一台 Linux `amd64` 或 `arm64` 主机，带 Docker Engine、Docker Compose 插件、持久化本地存储，并且 `80`、`443` 端口可用。主机内核必须接受 worker 的安全选项；若拒绝，换一个受支持的 Linux 内核，而不是削弱 worker。

### Kubernetes 要求（Helm）

Kubernetes 1.27 或更高版本、Helm 3 或更高版本、Linux `amd64` 或 `arm64` 节点、一个 HTTPS Ingress，以及 Agent Home 使用的 RWX StorageClass 或已有 RWX PVC。Chart 以 init container 运行数据库迁移和 worker key 引导；两者都成功后控制面才启动。

## worker 节点的硬性要求

Agent Computer worker 要获得强 bubblewrap 隔离，需要三样 Linux 专属的东西，Compose 和 Helm 部署包已经带上：

- `SYS_ADMIN` capability，
- 不受限的 seccomp profile，
- 未遮蔽的 `/proc`。

这些东西之所以存在，是因为 worker 在 bubblewrap 约束下跑 agent shell，而 bubblewrap 需要这些内核设施。把 worker 节点当作受信任的第一方计算边界——沙箱保护的是宿主机*免受* worker 的 shell 之扰，不是反过来；在这个契约之外，worker 节点不是跑不受信任代码的地方。无法提供这三样的主机不是受支持的 worker 目标。

## 外部 PostgreSQL

如果你自带 PostgreSQL 而不用内置的，外部服务器必须：

- 运行 PostgreSQL 18 或更高版本，
- 预加载 `pg_search`，
- 让应用数据库的 owner 能使用 `pg_search` 和 `vector`。

`pg_search` 是硬性依赖——Ankole 通过它使用 BM25 全文搜索——而且 Helm 回滚不会反向执行数据库迁移，所以每次升级前都要备份 PostgreSQL。

## 开发主机

这些是贡献者跑 `kit dev` 来开发 Ankole 本身的机器。

| 主机 | 状态 | 说明 |
|---|---|---|
| **macOS** | 受支持 | 在 `kit dev` 之前启动 Docker Desktop |
| **Linux** | 受支持 | 若 env-setup 脚本把你的用户加入了 `docker` 组，先注销再登录 |
| **Windows / WSL2** | 受支持 | 用 WSL2；env 安装器不支持原生 Windows shell |
| **Windows 原生** | 不受支持 | 用 WSL2 |

GitHub Codespaces 适合代码和测试工作，但基准的 signal binding 走查假设 `localhost:4000`，所以当 Codespaces 给你转发后的 HTTPS origin 时，要自己调整并验证回调。本地源码路径见[快速开始](../quickstart/)。

## 不受支持

这些不是受支持的部署或开发形态：

- **生产环境在 macOS 或 Windows 上运行控制面或 worker。** 在这些主机上开发没问题；生产用 Linux。
- **无法授予 `SYS_ADMIN`、不受限 seccomp profile 和未遮蔽 `/proc` 的 worker 节点。** worker 的沙箱契约依赖它们。
- **低于 18 的 PostgreSQL，或 18+ 但未预加载 `pg_search` 的 PostgreSQL。** BM25 依赖不是可选的。
- **Compose 和 Helm 之外的第三种部署方法。** 镜像是发布的；从镜像自行拼凑的临时部署不是受支持形态，即便它能跑。

如果你处于不受支持的形态，前进的方向是迁移到受支持的部署目标，而不是削弱 worker 沙箱或运行更旧的 PostgreSQL。

## 下一步

- 部署步骤，读[安装部署指南](../installation/)。
- 本地开发路径，读[快速开始](../quickstart/)。
- worker 的沙箱契约，读 [Agent Computer](../agent-computer/) 开发者页。
