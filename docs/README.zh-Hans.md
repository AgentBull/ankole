# Ankole 文档

[English](./README.md)

这份文档帮助你了解 Ankole 怎样工作，以及各部分代码在哪里。需要查看详细约定时，
可继续阅读表格中的设计文档。

## 产品边界

Ankole 是面向企业内部的私有化 Agent 系统，让 Agent 可以执行耗时较长的数字工作。
每家企业拥有一套私有化部署实例，其中包含自己的 Agent、用户、外部平台连接、配置
和数据。

主体（Principal）表示“谁对这次操作负责”，可以是人、Agent 或系统服务。授权管理
模块（AuthZ）判断这个主体可以做什么。

Agent 可以从外部平台消息、定时任务和 Background Agent Job 接收工作。即使进程失败，
它也能继续执行。PostgreSQL 保存重启后仍然需要的数据。

## 系统地图

```text
外部平台与定时任务
        |
        v
SignalsGateway ---- PostgreSQL ---- AIGateway ---- 模型提供商
        |                              ^
        | turn_start                   | response.create
        v                              |
   Agent Computer ---------------------+
   模型循环与工具
```

| 模块 | 用途 | 详细文档 |
| --- | --- | --- |
| SignalsGateway | 接收外部平台事件、启动 Agent 回合并发送回复 | [SignalsGateway](design-docs/SignalsGateway.md) |
| AIGateway | 选择模型提供商，并为每个主体保存 Response | [AIGateway](design-docs/AIGateway.md) |
| Brain | 保存有用知识，并在 Agent 需要时找出这些知识 | [Brain](design-docs/Brain.md) |
| RuntimeFabric | 在进程之间传送实时消息、RPC 调用和文件 | [RuntimeFabric](design-docs/RuntimeFabric.md) |
| Agent Computer | 运行模型循环、Codex 和工具 | `app/agent_computer/` |
| PostgreSQL | 保存重启后仍然需要的事实 | `app/control_plane/priv/repo/migrations/` 下的迁移 |

Schedule 在任务到期时创建一条 `ActorEvent`。`BackgroundAgentJob` 执行发起它的
对话回合之外的工作。AppConfigure 保存管理员可以在运行期间修改的设置。

## 各进程负责什么

Elixir 控制面运行 Phoenix 和 OTP。它负责写 PostgreSQL、监督服务进程、保存外部平台
凭据，并提供公开 API。

Rust 内核提供共享的原生能力，包括加密、CEL 求值、Protobuf 校验、压缩和 ZeroMQ
连接。它不决定或保存工作项的生命周期。

Agent Computer 在 Bun 执行进程中运行。它执行当前回合，运行工具和沙箱，并管理
Codex 会话。它的本地状态可以重建，也不会直接写控制面的业务记录。

RuntimeFabric 只传送实时数据。PostgreSQL 记录已经完成的决定和工作。ZeroMQ 不保留
此前的流量，系统只能从 PostgreSQL 恢复。

## Agent 文件系统

Agent Home 位于 `/agents/<agent-key>`，其中包含以下共享资源：

- `.codex`：同一 Agent 共享的 Codex 状态
- `SOUL.md`、`MISSION.md` 和 `DESIGN.md`
- `user-files`：用户产物
- `installed-skills`：供执行进程使用的已安装 Skill 副本
- `sessions/<base64url-session-id>`：各 Session 的工作区
- `jobs/<job-id>`：各 BackgroundAgentJob 的工作区

Session 与 Job 的工作区都是 Agent Home 的子目录。`/workspace` 不是 Agent 路径。
同一 Agent 的 Job 共享该 Agent 的 `.codex` 状态。

PostgreSQL 保存领域文档和工作状态。控制面把其中一些记录 materialize 成 Agent Home
文件，供执行进程使用。

## 仓库地图

| 路径 | 内容 |
| --- | --- |
| `app/control_plane/` | Elixir 控制面、Phoenix API、Ecto 表结构和迁移 |
| `app/kernel/` | 共享 Rust 内核及其宿主语言接口 |
| `app/agent_computer/` | Bun 执行进程、工具、Codex 运行器和浏览器 |
| `app/webapps/` | 登录、安装和管理 Console 的 React 应用 |
| `app/library/` | 内置 Skill、Agent Plugin 和 Agent 模板 |
| `app/locales/` | 共享英文与简体中文翻译 |
| `plugins/` | 第一方 Control Plane Plugin |
| `libs/` | 外部平台客户端和共享 UI 代码 |
| `tools/devkit/` | 工作区开发命令 |
| `tools/e2e/` | 端到端测试运行器、辅助服务和测试集 |
| `docs/` | 当前公开架构与运维文档 |

当前外部平台适配器包括 Lark、DingTalk、Slack、Microsoft 365 和 Google
Workspace。中国市场模型 Plugin 为 AIGateway 增加模型提供商。

## 控制面启动顺序

`Ankole.Application` 按以下顺序启动子进程：

1. Telemetry、Repo 和 Brain 任务监督进程
2. AppConfigure 注册表与缓存
3. I18n 翻译表与安装引导
4. Oban
5. Plugin 注册表与监督进程
6. PubSub 与 AIGateway Response 流监督进程
7. SignalsGateway 监督进程
8. 可选的身份启动同步与 RuntimeEvents
9. AIGateway 模型信息缓存
10. DNSCluster 与 Phoenix 请求入口

这个顺序是契约。后启动的进程可以使用前面已经启动的服务。Phoenix 请求入口最后启动，
避免请求到达时所需服务尚未就绪。

## 重启后保留哪些数据

PostgreSQL 保存以下数据，因为 Ankole 重启后仍然需要它们：

- 主体、人员、Agent、权限组、成员关系和授权规则
- AppConfigure 值和加密的外部平台配置
- 消息连接、频道、消息、删除标记、ActorEvent 和待发回复
- 定时规则和每次计划执行
- AIGateway 对话、消息、压缩结果和模型提供商
- Brain 词条、正文、关系、资料、引用、聊天摘要、游标和审计记录
- BackgroundAgentJob 及其回合记录

系统可以重新生成投递、激活、执行进程分配和在线执行进程记录。即使这些记录丢失，
工作历史也不会丢失。

## 消息生命周期

下面以一条明确发给 Agent 的外部平台消息为例：

1. 平台适配器把事件转换为 Ankole 的统一格式。
2. SignalsGateway 检查 Agent 的消息策略，并更新平台消息的本地副本。
3. SignalsGateway 合并相关输入，写入一条 `ActorEvent` 工作记录。
4. ActorRuntime 分配一个执行进程，并发送带本次 `turn fence` 的 `turn_start` 消息。
5. Agent Computer 准备 Agent 文件、Session 工作区、上下文和工具。
6. 执行进程请求 AIGateway 创建一条有状态 Response。
7. AIGateway 保存 Response，并把实时事件发给当前订阅者。
8. 执行进程运行工具，并把后续 Response 依次连接起来。
9. 回合结束时，执行进程报告最终采用的 Response ID。
10. SignalsGateway 检查 `turn fence` 和 Response 链。
11. 同一个数据库事务完成 `ActorEvent`，并记录需要发送的回复。
12. 平台适配器发送回复，并记录平台返回的结果。

Response 结束不等于 Agent 回合结束。如果回合完成消息丢失，ActorRuntime 会重新分配
这项工作。

实时预览可以丢失。最终回复必须来自已经写入数据库的 outbox 记录。只有外部平台确认
成功后，Ankole 才会把回复标记为已发送。

## 四种 ID 不能混用

| 标识 | 含义 |
| --- | --- |
| `source_event_id` | 一次外部平台事件，也是防止重复接收的键 |
| `source_entry_id` | 一条外部平台可见消息 |
| `actor_event_id` | 一项写入数据库的 Ankole 工作 |
| `ai_message_id` | 一条 AIGateway 消息记录 |

这些标识不能互相替代。负责相应数据的模块会分配并检查自己的标识。

## 两种 Plugin 和 Skill 的关系

Control Plane Plugin 是 Ankole 信任的 Elixir 代码。它可以增加配置、适配器、模型
服务商和由 OTP 监督的进程。

Agent Plugin 是标准 Codex Plugin 包，用来组合相关的 Agent 能力。它可以带一个
`workspace-template/` 目录，作为新 Job 的初始工作区。

Skill 独立于这两种 Plugin。Ankole 查找、配置和运行 Skill 时，不依赖 Control Plane
Plugin。

## 常见修改应放在哪里

- 在 `app/control_plane/lib/ankole/ai_gateway/providers/` 添加模型提供商，
  或使用 `ai_gateway.provider` Plugin contract。
- 在 `app/agent_computer/src/tools/` 添加执行进程工具，并在创建回合工具列表时注册。
- 添加消息平台时，用 Plugin 声明 ingress 和 outbox modules。
- 添加跨进程调用时，同时修改 ActorRuntime RPC lane 和执行进程 requester。
- 添加运行时设置时，由使用该设置的子系统在 AppConfigure 中声明。
- 在 `app/library/skills/<name>/` 添加内置 Skill。
- 通过 OpenAPI controller 添加 Console API，并重新生成网页客户端。

不能靠执行进程的本地文件保存会影响用户的结果。应调用控制面 RPC，或使用能写入
PostgreSQL 的 AIGateway 接口。

## 开发工作流

```sh
bun install
bun run services:start
bun run control-plane:setup
bun run dev
```

常用验证命令：

```sh
bun run test
bun run type-check
bun run lint
bun run fmt:check
bun run e2e
tools/e2e/run --chaos
tools/e2e/run --real-provider --providers=available
tools/e2e/run --real-llm
tools/e2e/run --brain-real-llm
```

默认 E2E 模式运行 gate suites。真实平台测试需要运维人员提供凭据。Brain 真实模型
测试不会随 `--all` 运行。

## 阅读顺序

1. 先读本文，确认各模块负责什么，以及数据怎样流动。
2. 阅读 [Tradeoffs and Known Limits](TradeoffsAndKnownLimits.md)。
3. 阅读将要修改的子系统设计文档。
4. Brain 部署前阅读 [Brain 运维文档](operations/Brain.zh-Hans.md)。

## 文档索引

| 文档 | 主题 |
| --- | --- |
| [AIGateway](design-docs/AIGateway.md) | 模型提供商、Response 历史、上下文压缩和生成文件 |
| [SignalsGateway](design-docs/SignalsGateway.md) | 接收平台消息、运行 Agent、预览和发送回复 |
| [Brain](design-docs/Brain.md) | 知识、检索、保存的资料和 Dreaming |
| [Brain 运维](operations/Brain.zh-Hans.md) | PostgreSQL 要求与运维恢复 |
| [RuntimeFabric](design-docs/RuntimeFabric.md) | ZeroMQ 消息、RPC 和文件传输 |
| [Schedule](design-docs/Schedule.md) | 单次唤醒、周期任务和 ActorEvent |
| [BackgroundAgentJob](design-docs/BackgroundAgentJob.md) | 进程失败后仍可继续的后台工作与 Codex 执行 |
| [主体（Principal）](design-docs/Principal.md) | 人和 Agent 的统一身份，以及外部账号合并 |
| [AuthZ](design-docs/AuthZ.md) | 权限组、授权规则和 CEL 条件 |
| [AppConfiguration](design-docs/AppConfiguration.md) | 启动配置和运行时设置 |
| [Plugins](design-docs/Plugins.md) | Control Plane Plugin 与 Agent Plugin |
| [MCP-backed Skills](design-docs/MCPBackedSkills.md) | Skill 怎样连接 MCP 服务以及怎样保护凭据 |
| [Web tools](design-docs/WebTools.md) | 网页搜索、正文读取和浏览器后备路径 |
| [I18n](design-docs/I18n.md) | 语言选择和翻译文件 |
| [Logger](design-docs/Logger.md) | 结构化日志契约 |
| [Tradeoffs and Known Limits](TradeoffsAndKnownLimits.md) | 当前限制和故障恢复范围 |

各外部平台的专属文档位于 `design-docs/plugins/`。
