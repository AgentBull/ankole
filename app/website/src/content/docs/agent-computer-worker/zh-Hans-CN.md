---
title: Agent Computer Worker
description: 环境工具、Codex、持久 Home，以及控制面更替后的恢复。
section: Developer guide
order: 108
---

Agent Computer Worker 是一个 Agent 自己的电脑。创建 Agent 时只保存 provider 绑定和 absent Worker 行；首次执行环境工具或 Codex 时，控制面才启动它。纯问答和控制面工具不依赖 Worker。

## 执行与归属

Bun Worker 执行命令、文件与浏览器工具、Skills、MCP 调用、自动化脚本和 Codex Job。控制面的 `Ankole.Conversations` 运行主 Agent loop，提交输入消费与工具结果，拥有最终回复。AIGateway 拥有持久 Response 链与 hosted 工具。

控制面提供 `WORKER_ID`、RuntimeFabric 地址、generation 凭据与存储设置。Worker 只服务自己的 Agent，从子进程环境中移除凭据，不连接数据库。容器是 Agent 的隔离边界；命令以 uid 1000 执行，没有 sudo。

## WorkerPool 与实时连接

Agent 保存的 Worker provider 决定所属池、平台、实例配置和存储。多个 Agent 可以使用同一个池，平台为每个 Agent 创建独立电脑。空闲回收可以删除或暂停实例，Home 保留。配置与生命周期规则见 [WorkerPool](../worker-management/)。

Worker 建立一条到 `/runtime-fabric/worker/websocket` 的已认证 WebSocket，加入自己的 Phoenix Channel。RuntimeFabric protobuf envelope 传递环境调用、结果、Codex 控制与进度。generation 和 incarnation 校验拒绝已被替换的 Worker。文件字节走一次性 HTTP 中继地址，持久恢复事实由 PostgreSQL 保存。

## 操作标识与恢复

环境工作使用包含 Agent、Session 与触发输入的 `RunRef`，每个调用由 Response ID 与 call ID 标识。新 Driver 探测已有工作区，领养在途调用或取回结果。控制面断线时命令继续运行。Worker 进程消失后，只重试安全调用，其余无法确认的调用返回 `interrupted`。

Codex 使用带 Job ID 与 attempt 的 `JobTurnRef`。`adopt` 请求保留同一个运行中回合、线程与工作区。Job owner 按 attempt 栅栏接纳终态，在同一事务消费已应用输入 ID。Codex 保留自己的模型 loop。

打开的环境工作区和运行中的 Codex 回合各占一个 Worker 槽位，主对话与 Workflow 的模型调用不占槽位。

## 文件系统契约

Agent Home 是 `/workspace` 上的持久存储。旧路径 `/agents/<agent_uid>` 链接到这里；路径检查先解析符号链接，再校验 Home 边界。目录结构如下：

```text
/workspace/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── ConfidentialityPolicy.md
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/
```

模型可见的绝对路径就是容器路径，worker 不为模型翻译路径，命令的工作目录必须位于 Agent Home 内。`SOUL.md` 和 `MISSION.md` 定义 Agent 的行为与职责，`DESIGN.md` 是视觉内容使用的设计系统。`ConfidentialityPolicy.md` 指导写入 Brain 时的披露范围选择。四份文档都由 [Agent Library](../agent-library/) 管理。`installed-skills/`、`sessions/` 和 `jobs/` 分别保存 Skill、会话工作区和后台任务工作区。PostgreSQL 为每个 Session 分配从 10000 开始的稳定数字工作区 ID。

Home 在删除实例和更换镜像后保留，重建只删除 `/var/cache/ankole` 缓存。Docker 本地卷依赖宿主；Cloudflare 被强制停止时可能丢失最后一次 R2 备份后的写入。各类型的存储限制见 [工作节点](../worker-management/)。

控制面云盘独立保存附件、发布的文件、Skill 和 Automation 脚本。用 `ankole-files` 读写云盘；Job 工作区与 Codex 线程文件留在持久 Home。回合开始前，Worker 将 `installed-skills/` 与云盘同步。

Codex Home 是 `/workspace/.codex`。线程文件跨实例保留；即使 `/var/cache/ankole/codex` 中的 SQLite 丢失，Codex 仍可从线程文件恢复。后台 Job 用 `skill_view` 加载 Skill，不复制 Skill 根目录到工作区。

## 进度与容量

Driver 拥有主 loop 的流式输出与工具展示；Worker 通过 RuntimeFabric 上报环境结果与 Codex 进度。进度是尽力而为的，恢复依据 PostgreSQL 中的完成事实与已存储结果。

心跳报告活跃工作区、Codex 回合与空槽位。控制面按 provider YAML 的 `idleReleaseAfter` 回收空闲实例，`never` 保持运行。重连保留进程 incarnation 与在途工作。

写入与操作栅栏见 [Actor Runtime](../actor-runtime/)，Responses 见 [AIGateway](../ai-gateway/)，Skills 见 [Agent Library](../agent-library/)，provider 状态见 [工作节点](../worker-management/)。
