---
title: 文件管理
description: Agent Home 文件系统如何工作——布局、什么持久、文件如何在控制面与 worker 间移动、Console 的 worker-file 界面。
section: User guide
order: 45
---

Agent Home 是 agent 的 worker 在回合中读取和写入的共享文件系统。它持有人设文档、工作空间文件、已安装 skill、session 状态和任务产物。本页是该文件系统的运维者视角——布局、什么持久、文件如何在控制面与 worker 间移动、管理它们的 Console 路由。

先把决定性的性质说清楚：Agent Home 是**模型视为路径的真实文件系统**，不是抽象。模型可见的绝对路径就是容器路径——worker 不翻译路径。持久的是文件系统本身（在持久卷上）；临时的是读写它的进程。

## 布局

Agent Home 挂载在 `/agents`，按 actor key 布局：

```text
/agents/<agent-key>/
├── .codex/                    # Codex 配置
├── SOUL.md                    # 人设：语气与行为
├── MISSION.md                 # 人设：范围与职责
├── DESIGN.md                  # 人设：工作约定
├── user-files/                # 运维者提供的文件
├── installed-skills/          # agent 安装的 skill bundle
├── sessions/<base64url-session-id>/   # 按 session 的工作空间
└── jobs/<job-id>/             # 按任务的工作空间
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

人设文档（`SOUL.md`、`MISSION.md`、`DESIGN.md`）是 agent 自己的库文档——通过 Console 撰写、投影进文件系统。`sessions/` 和 `jobs/` 是按 session 和按任务的工作空间，按 session 或任务 id 隔离。模型逐字看到这些路径——没有路径翻译层。

## 什么持久，什么临时

| 路径 | 持久？ | 为什么 |
|---|---|---|
| `/agents/<key>/SOUL.md`、`MISSION.md`、`DESIGN.md` | 是 | 从 PostgreSQL 投影；熬过 worker 重启 |
| `/agents/<key>/user-files/` | 是 | 在持久卷上 |
| `/agents/<key>/installed-skills/` | 是 | 在持久卷上；由 Agent Library 同步 |
| `/agents/<key>/sessions/<id>/` | 是 | 在持久卷上；按 session 上下文 |
| `/agents/<key>/jobs/<id>/` | 是 | 在持久卷上；按任务工作空间 |
| Worker 本地临时（`/tmp`） | 否 | 临时；worker 重启即消失 |

Agent Home 由 `ankole_agents_data` 卷（Compose）或 RWX PVC（Helm）支撑。重启的 worker 读同样的文件；丢失的卷带走文件。如何保护 Agent Home 见[备份与还原](../backup-and-restore/)。

## 文件如何在控制面与 worker 间移动

worker 直接读 Agent Home——正常操作不通过 RPC 从控制面取文件。显式移动文件有两条路径：

- **文件传输 lane**——一条专用的 RuntimeFabric lane，用于在 worker 上上传、下载、移动和删除文件。Console 的 `/agent-computer-workers/:worker_id/files` 路由用它。它有自己的编解码和路径安全检查，与 RPC lane 分开。
- **Worker-file Console 路由**——在特定 worker 上管理文件的运维界面：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/agent-computer-workers/:worker_id/files` | 列出文件 |
| `GET` | `/agent-computer-workers/:worker_id/files/content` | 下载文件内容 |
| `POST` | `/agent-computer-workers/:worker_id/files` | 上传文件 |
| `POST` | `/agent-computer-workers/:worker_id/file-moves` | 移动文件 |
| `DELETE` | `/agent-computer-workers/:worker_id/files` | 删除文件 |

这些路由按 worker id 范围限定，不按 agent——它们操作 worker 的 Agent Home 包含的任何东西。

## 人设文档

三份人设文档——`SOUL.md`、`MISSION.md`、`DESIGN.md`——是运维者撰写的、agent 每个回合读取的文件（见 [Agent](../agents/)）。它们存在 PostgreSQL 的 `agent_library_container_entries` 表里（作为 agent 拥有的、按内容寻址的行），投影进文件系统 `/agents/<key>/`。运维者通过 `PUT /agents/:agent_uid/library-documents/:document_kind` 撰写；agent 作为文件读取。

这意味着人设文档是**持久事实（PostgreSQL）投影为文件（Agent Home）**。通过 Console 编辑文档更新 PostgreSQL 行；下次回合读更新后的投影。它们如何到达系统 prompt 见 [Prompt 组装](../prompt-assembly/)。

## 已安装 skill

`installed-skills/` 目录持有 agent 已安装的 skill bundle——区别于随应用镜像发布的 builtin skill（`app/library/skills/`）。Agent Library 将此目录与 worker 可见存储中观察到的东西同步，所以从存储消失的 skill 反映在注册表里。同步模型见 [Agent Library](../agent-library/)；用户视角见 [Skills](../skills/)。

## 本指南不是什么

它不是文件系统权限指南——worker 在 bubblewrap 约束下运行，上述路径是 agent 在该 sandbox 内看到的。它不是文件传输协议参考——文件传输 lane 是 [Kernel](../kernel/) 页的范围。它也不是 Console API 参考的替代；worker-file 路由的确切请求形态在那里。

## 下一步

- 人设文档，读 [Agent](../agents/)。
- 同步 skill 的 Agent Library，读 [Agent Library](../agent-library/)。
- 保护 Agent Home 的备份，读[备份与还原](../backup-and-restore/)。
- Console 路由，读 [Console API 参考](../console-api/)。
