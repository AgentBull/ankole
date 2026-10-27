---
title: Agent Computer Worker
description: 环境工具、Codex、持久 Home，以及控制面更替后的恢复。
section: Developer guide
order: 108
---

Agent Computer Worker 是每个 Agent 专属的隔离运行环境，相当于它自己的电脑。创建 Agent 时，系统仅记录 Worker Provider 绑定关系并写入一条状态为 `absent` 的 Worker 记录；直到首次调用环境工具或执行 Codex 任务时，控制面才会按需拉起实例。纯文本问答与控制面内置工具不依赖 Worker。

## 执行与归属

在职责划分上，Bun Worker 负责运行 Shell 命令、文件与浏览器工具、Skills、MCP 调用、自动化脚本以及 Codex Job；控制面的 `Ankole.Sessions` 负责驱动主 Agent 循环，将输入消费记录与工具执行结果持久化落库，并生成最终回复；AIGateway 则负责维护持久化的 Response 链与托管工具（Hosted Tools）。

启动实例时，控制面会向 Worker 注入 `WORKER_ID`、RuntimeFabric 连接地址、代数（generation）凭据与存储参数。每个 Worker 实例只服务于所属的单个 Agent，不直连数据库，并在派生子进程前剥离平台凭据。容器本身构成 Agent 的安全隔离边界：所有命令均以 `uid 1000` 普通用户身份运行，不提供 `sudo` 权限。

## WorkerPool 与实时连接

Agent 绑定的 Worker Provider 决定了它归属的资源池、底层运行平台、实例规格与存储方式。多个 Agent 可以共用同一个资源池，平台仍会为每个 Agent 分配各自独立的电脑实例。实例空闲后可按策略销毁或暂停回收，而 Agent 的 Home 目录持久保留。详细的资源池配置与生命周期规则见 [WorkerPool](../worker-management/)。

Worker 启动后，会向 `/runtime-fabric/worker/websocket` 建立经过鉴权的 WebSocket 长连接，并加入专属的 Phoenix Channel，通过 RuntimeFabric 的 Protobuf 消息信封传递环境工具调用、执行结果、Codex 控制指令与运行进度。控制面通过校验 generation 与 incarnation 标识来拦截已被新实例接替的旧 Worker。大文件字节流通过一次性 HTTP 中继地址传输，用于故障恢复的权威状态则统一保存在 PostgreSQL 中。

## 操作标识与恢复

普通环境工具任务使用包含 Agent、Session 与触发输入信息的 `RunRef` 追踪上下文，每次具体调用由 Response ID 与 call ID 唯一标识。控制面断线或重启期间，Worker 内的命令会继续运行；新启动的会话 Driver 上线后会先探测现有工作区，接管仍在执行的在途调用或直接取回已完成的结果。如果 Worker 进程意外消失，控制面仅重试无副作用的安全调用，其余无法确认执行状态的调用统一返回 `interrupted`。

后台 Codex 任务使用带有 Job ID 和尝试次数（attempt）的 `JobTurnRef` 标识，并在 Worker 内部维护独立的模型循环。重连时，`adopt` 请求可以无缝接管同一个正在运行的回合、线程与工作区；任务协调者（Job owner）则通过 attempt 栅栏校验并接纳任务终态，在同一数据库事务内将已生效的输入 ID 标记为已消费。

容量核算上，每个打开的环境工作区和每个运行中的 Codex 回合各占用一个 Worker 槽位；主对话与 Workflow 的模型推理调用不占槽位。

## 文件系统契约

Agent Home 是挂载在 `/workspace` 上的持久化存储目录。`/agents/<agent_uid>` 是指向 `/workspace` 的符号链接；路径安全检查会先解析符号链接，再校验目标路径是否位于 Home 边界之内。目录结构如下：

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

模型看到的绝对路径就是容器内的真实路径，Worker 不会为模型做路径转换，且所有命令的工作目录都必须位于 Agent Home 内部。根目录下，`SOUL.md` 和 `MISSION.md` 定义 Agent 的行事风格与核心职责，`DESIGN.md` 提供制作视觉内容时遵循的设计系统，`ConfidentialityPolicy.md` 指导 Agent 在向 Brain 写入记忆时如何选择披露范围——这四份长期文档均由 [Agent Library](../agent-library/) 统一管理。`installed-skills/`、`sessions/` 和 `jobs/` 分别存放已同步的 Skill、会话工作区与后台任务工作区，其中每个 Session 都会由 PostgreSQL 分配一个从 `10000` 起步的稳定数字工作区 ID。

销毁实例或升级镜像后，Agent Home 中的数据依然保留；重建实例只会清除 `/var/cache/ankole` 缓存目录。需要注意底层存储平台的边界：Docker 本地卷依赖宿主机磁盘；Cloudflare 容器若被强制终止，可能会丢失最近一次 R2 备份之后的写入。各平台的具体存储限制见 [工作节点](../worker-management/)。

控制面云盘独立保存消息附件、已发布文件、已安装 Skill 和 Automation 脚本。需要读写云盘时使用 `ankole-files` 命令行工具；后台任务工作区与 Codex 线程文件则留在持久化的 Agent Home 内。每轮执行开始前，Worker 会将本地 `installed-skills/` 目录与云盘上的 Skill 文件同步对齐。

Codex 的主目录位于 `/workspace/.codex`，线程文件跨实例持久保留；即便 `/var/cache/ankole/codex` 下的可重建 SQLite 缓存被清空替换，Codex 仍可依据线程文件恢复上下文。后台任务在运行期间通过 `skill_view` 按需加载 Skill。

## 进度与容量

主循环的流式输出与工具状态展示由控制面 Driver 负责，而环境工具执行结果与 Codex 运行进度则由 Worker 通过 RuntimeFabric 上报。实时进度推送采取尽力而为策略，故障恢复始终以 PostgreSQL 中落盘的完成记录与执行结果为准。

Worker 通过心跳定期上报当前活跃的工作区、运行中的 Codex 回合与空闲槽位数。控制面依据 Provider YAML 中的 `idleReleaseAfter` 配置回收空闲实例（设为 `never` 则常驻运行）。网络重连会保留原有的进程 incarnation 与在途工作。

延伸阅读：单写者与操作栅栏见 [Sessions](../sessions/)，持久化 Responses 见 [AIGateway](../ai-gateway/)，Skills 管理见 [Agent Library](../agent-library/)，Worker 实例状态与生命周期见 [工作节点](../worker-management/)。
