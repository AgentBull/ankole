# Ankole 文档

[English](./README.md)

这份文档帮助你了解 Ankole 怎样工作，以及各部分代码在哪里。需要查看详细约定时，
可继续阅读表格中的设计文档。

## 产品边界

Ankole 是面向企业内部的私有化 Agent 系统，让 Agent 可以执行耗时较长的数字工作。
一套部署称为站点，可以包含多个租户。各租户拥有自己的 Agent、用户、外部平台连接、
配置和数据；站点管理员管理共享基础设施。见 [Tenants](design-docs/Tenants.md)。

主体（Principal）表示“谁对这次操作负责”，可以是人、Agent 或系统服务。授权管理
模块（AuthZ）判断这个主体可以做什么。

Agent 可以从外部平台消息、定时任务和 Background Agent Job 接收工作。即使进程失败，
它也能继续执行。PostgreSQL 保存重启后仍然需要的数据。

## 系统地图

```text
外部平台与定时任务
        |
        v
SignalsGateway --> Conversations --> AIGateway --> 模型提供商
                          |               |
                          +-- PostgreSQL -+
                          |
                    环境工具 / Codex
                          v
                     Agent Computer
```

| 模块 | 用途 | 详细文档 |
| --- | --- | --- |
| SignalsGateway | 接收外部平台事件、启动 Agent 回合并发送回复 | [SignalsGateway](design-docs/SignalsGateway.md) |
| Conversations | 驱动主模型循环并恢复持久步骤 | [RuntimeFabric](design-docs/RuntimeFabric.md) |
| AIGateway | 选择模型提供商，并为每个主体保存 Response | [AIGateway](design-docs/AIGateway.md) |
| Brain | 保存租户共享知识，并在 Agent 需要时找出这些知识 | [BrainV3](design-docs/BrainV3.md) |
| RuntimeFabric | 传送实时消息和 RPC 调用，协调 HTTP 文件中继 | [RuntimeFabric](design-docs/RuntimeFabric.md) |
| Files | 在控制面的云盘中保存每个 Agent 的持久文件 | [Files](design-docs/Files.md) |
| Agent Workers | 创建、停止和替换每个 Agent 唯一的 Worker | [Agent Workers](design-docs/AgentWorkers.md) |
| Agent Computer | 运行 Codex 和环境工具 | `app/agent_computer/` |
| PostgreSQL | 保存重启后仍然需要的事实 | `app/control_plane/priv/repo/migrations/` 下的迁移 |

Schedule 在任务到期时创建一条 `ActorEvent`。`BackgroundAgentJob` 执行发起它的
对话回合之外的工作。AppConfigure 保存管理员可以在运行期间修改的设置。

## 各进程负责什么

Elixir 控制面运行 Phoenix 和 OTP。它负责写 PostgreSQL、监督服务进程、保存外部平台
凭据，并提供公开 API。

Rust 内核提供共享的原生能力，包括加密、CEL 求值、Protobuf 校验、压缩和对象存储。它不决定或保存工作项的生命周期。

Agent Computer 运行在每个 Agent 的 Worker 中：一个独占容器的 Bun 进程。它执行环境
工具，并管理 Codex 会话。它的本地状态可以重建，也不会直接写控制面的业务记录。

RuntimeFabric 只传送实时数据。PostgreSQL 记录已经完成的决定和工作。Worker 连接不保留
此前的流量，系统只能从 PostgreSQL 恢复。

## Agent 文件系统

Agent Home 位于持久存储上的 `/workspace`，删除 Worker 实例或更换镜像后仍保留，其中包含：

- `SOUL.md`、`MISSION.md` 和 `DESIGN.md`
- `.codex/`：Codex 配置与线程文件
- `installed-skills/`：云盘 `skills/` 下文件的本地副本
- `sessions/<workspace-id>/`：Session 工作区，ID 由 PostgreSQL 从 10000 开始分配
- `jobs/<workspace-owner-job-id>/`：BackgroundAgentJob 工作区

旧路径 `/agents/<agent_uid>` 是指向 Home 的符号链接；路径检查先解析链接。
Codex SQLite 在 `/var/cache/ankole/codex`，丢失后可以从线程文件恢复。

PostgreSQL 保存领域文档和工作状态，Worker 在回合开始时将部分记录写成 Home 文件。
Agent 云盘独立保存附件、生成图片、发布的文件、Skill 和 Automation 脚本，Worker 不运行时
也能访问。见 [Files](design-docs/Files.md) 和 [Agent Workers](design-docs/AgentWorkers.md)。

## 仓库地图

| 路径 | 内容 |
| --- | --- |
| `app/control_plane/` | Elixir 控制面、Phoenix API、Ecto 表结构和迁移 |
| `app/kernel/` | 共享 Rust 内核及其宿主语言接口 |
| `app/agent_computer/` | Bun 执行进程、工具、Codex 运行器和浏览器 |
| `app/webapps/` | 登录、安装和管理 Console 的 React 应用 |
| `app/library/` | 内置 Skill、Agent Plugin 和 Agent 模板 |
| `app/locales/` | 共享翻译表 |
| `plugins/` | 第一方 Control Plane Plugin |
| `libs/` | 外部平台客户端和共享 UI 代码 |
| `tools/devkit/` | 工作区开发命令 |
| `tools/e2e/` | 端到端测试运行器、辅助服务和测试集 |
| `docs/` | 当前公开架构与运维文档 |

`plugins/` 下当前的 Control Plane Plugin 提供 Lark、DingTalk、Slack、Microsoft
365、Google Workspace、WeCom、Telegram、Discord、LINE、WhatsApp 和 Email 适配器。
Telegram、Discord、LINE 和 WhatsApp 是消费级 IM 适配器：它们把一个 bot 连接到一个
Agent，并通过管理员手工映射、已知手机号或独立账号把每个发送者映射到主体。Email
适配器连接一个专用邮箱，只通过显式的 `email` 身份绑定接纳发送者。本地密码身份源属于
控制面本身。中国市场模型
Plugin 为 AIGateway 增加模型提供商。

## 控制面启动顺序

`Ankole.Application` 在启动子进程前注册请求日志 handler。子进程按以下顺序启动：

1. Repo、PubSub 和 OIDC 签名密钥
2. AppConfigure 注册表与缓存
3. Observability、I18n 翻译表与安装引导
4. Worker provider 配置与初始化，然后启动 Oban
5. Plugin cohort 与本地密码重试限制
6. AIGateway 凭据池、任务与 Response 流监督进程，以及 WorkerFiles 监督进程
7. SignalsGateway 与 Workflow 监督进程
8. 可选的身份启动同步
9. AIGateway 模型信息缓存与 DNSCluster
10. Phoenix 请求入口

这个顺序是契约。后启动的进程可以使用前面已经启动的服务。Phoenix 请求入口最后启动，
避免请求到达时所需服务尚未就绪。

## 重启后保留哪些数据

PostgreSQL 保存以下数据，因为 Ankole 重启后仍然需要它们：

- 主体、人员、Agent、权限组、成员关系和授权规则
- AppConfigure 值和加密的外部平台配置
- 消息连接、频道、消息、删除标记、ActorEvent 和待发回复
- 定时规则和每次计划执行
- AIGateway 对话、消息、压缩结果和模型提供商
- Brain 页面、版本、chunk、claim、时间线、链接、Source、schema pack、矛盾与 skill lesson
- BackgroundAgentJob 及其回合记录
- 对话工作区的 epoch 与工具回执

对话驱动进程从这些事实重建进度。进程退出不会删除工作历史。

## 消息生命周期

下面以一条明确发给 Agent 的外部平台消息为例：

1. 平台适配器把事件转换为 Ankole 的统一格式。
2. SignalsGateway 检查 Agent 的消息策略，并更新平台消息的本地副本。
3. SignalsGateway 合并相关输入，写入一条 `ActorEvent` 工作记录。
4. Conversations 启动或唤醒对话驱动进程。准入认领输入，并递增工作区的 epoch。
5. 驱动进程准备 Agent 上下文，请求 AIGateway 创建有状态 Response。
6. AIGateway 保存 Response，并把实时事件发给当前订阅者。
7. 驱动进程在数据库事务中执行控制面工具。只有环境工具或 Codex Job 才请求 Worker。
8. 同一个事务记录完整工具轮次、消费已应用的输入、删除工具回执。下一条 Response 继续这份 tape。
9. 运行结束时，同一个事务检查 epoch、完成输入、把回复写入 outbox。
10. 平台适配器发送回复，并记录平台返回的结果。

Response 结束不等于对话运行结束。驱动进程退出后，新进程从持久输入、tape 和工具回执
恢复运行。

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
- 在 `app/control_plane/lib/ankole/conversations/tools/` 添加主 Agent 工具。
  环境工具和 Codex Job 工具放在 `app/agent_computer/src/tools/`，并重新生成声明的 Worker catalog。
- 添加消息平台时，用 Plugin 声明 ingress 和 outbox modules。
- 添加跨进程调用时，同时修改 ActorRuntime RPC lane 和执行进程 requester。
- 添加运行时设置时，由使用该设置的子系统在 AppConfigure 中声明。
- 在 `app/library/skills/<name>/` 添加内置 Skill。
- 通过 OpenAPI controller 添加 Console API，并重新生成网页客户端。

会影响用户结果的持久状态，不能靠执行进程的本地文件保存。应调用控制面 RPC，或使用能写入
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
```

默认 E2E 模式运行门控测试套件。真实平台测试需要运维人员提供凭据。

## 阅读顺序

1. 先读本文，确认各模块负责什么，以及数据怎样流动。
2. 阅读 [Tradeoffs and Known Limits](TradeoffsAndKnownLimits.md)。
3. 阅读将要修改的子系统设计文档。

## 文档索引

| 文档 | 主题 |
| --- | --- |
| [Tenants](design-docs/Tenants.md) | 站点管理、数据上下文、隔离与租户生命周期 |
| [AIGateway](design-docs/AIGateway.md) | 模型提供商、Response 历史、上下文压缩和生成文件 |
| [Agent Token Quota](design-docs/AgentTokenQuota.md) | 按 Agent 的 token 额度、周期、重置与拒绝契约 |
| [SignalsGateway](design-docs/SignalsGateway.md) | 接收平台消息、运行 Agent、预览和发送回复 |
| [BrainV3](design-docs/BrainV3.md) | 租户共享知识、作用域披露、学习与 Dreaming |
| [Brain Markdoc](design-docs/BrainMarkdoc.md) | Brain 正文语法与控制台中的 Object 编辑 |
| [Skill Lessons](design-docs/SkillLessons.md) | 来自已完成工作的租约制逐 skill 现场笔记 |
| [RuntimeFabric](design-docs/RuntimeFabric.md) | Worker 通道消息、RPC 和文件中继 |
| [Agent Workers](design-docs/AgentWorkers.md) | 每个 Agent 唯一的 Worker：provider、生命周期、持久 Home 与缓存 |
| [Schedule](design-docs/Schedule.md) | 单次唤醒、周期任务和 ActorEvent |
| [BackgroundAgentJob](design-docs/BackgroundAgentJob.md) | 进程失败后仍可继续的后台工作与 Codex 执行 |
| [Automation Jobs](design-docs/AutomationJobs.md) | 由 Agent 拥有、消费触发器且不经过模型回合的脚本 |
| [Workflow](design-docs/Workflow.md) | 运行有界子 Agent 任务的固定程序 |
| [主体（Principal）](design-docs/Principal.md) | 人和 Agent 的统一身份，以及外部账号合并 |
| [本地密码身份源](design-docs/LocalPasswordIdentityProvider.md) | 不依赖外部服务的内置邮箱密码登录 |
| [人员离职禁用](design-docs/HumanOffboarding.md) | 人员禁用、认证撤销和任务启动检查 |
| [浏览器会话](design-docs/BrowserSessions.md) | 浏览器身份、认证新鲜度、并发登录与退出 |
| [OIDC 服务端](design-docs/OIDCServer.md) | OIDC 协议归属、客户端策略、令牌与注销 |
| [AuthZ](design-docs/AuthZ.md) | 权限组、授权规则和 CEL 条件 |
| [AppConfiguration](design-docs/AppConfiguration.md) | 启动配置和运行时设置 |
| [Plugins](design-docs/Plugins.md) | Control Plane Plugin 与 Agent Plugin |
| [MCP-backed Skills](design-docs/MCPBackedSkills.md) | Skill 怎样连接 MCP 服务以及怎样保护凭据 |
| [Web tools](design-docs/WebTools.md) | 网页搜索、正文读取和浏览器后备路径 |
| [I18n](design-docs/I18n.md) | 语言选择和翻译文件 |
| [Logger](design-docs/Logger.md) | 结构化日志契约 |
| [Tradeoffs and Known Limits](TradeoffsAndKnownLimits.md) | 当前限制和故障恢复范围 |

各外部平台的专属文档位于 `design-docs/plugins/`。

`design-docs/` 只保存技术架构、实现设计与通用契约。故障案例、复现记录和验证结果不属于 `docs/`；每次发布改了什么由 changelog 记录。
