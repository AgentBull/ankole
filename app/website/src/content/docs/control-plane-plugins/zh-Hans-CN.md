---
title: Control Plane Plugins
description: 控制面第一方 Elixir 扩展模型——激活模式、子系统契约、事务钩子、Cohort 监督树与下次启动生效边界。
section: Developer guide
order: 110
---

Control Plane Plugins 用于以受信任的第一方 Elixir/OTP 代码扩展 Ankole 站点。插件可通过 `Ankole.Plugins` 贡献 `AppConfigure` 配置键、子系统适配器、同步事务钩子以及受监督子进程。

Control Plane Plugins 是编译进发布包的第一方 Elixir 模块（`:control_plane_plugin_modules`），不是运行时动态下载或隔离执行的第三方插件市场。系统在启动时发现并校验这些模块：`:optional` 插件通过全局启用列表选用并在下一次进程启动时激活；声明了 `activation: :always` 的构建内置插件只要编译进当前构建便始终保持激活。

## 已发现与已激活

插件在运行时区分两个阶段：

- **已发现（Discovered）**——编译进发布包并通过启动形态校验的所有插件模块。站点管理员可在 Site Admin Console 中查看完整目录。
- **已激活（Active）**——`activation/0` 为 `:always` 的插件，或 `activation/0` 为 `:optional` 且位于 `plugins.enabled_ids` 中的插件（在首次初始化 `setup.completed` 完成前，所有已发现插件均临时激活）。只有已激活插件才会注册 `AppConfigure` 定义、发布子系统适配器与领域钩子，并启动受监督子进程。

已发现但未激活的插件仍显示在目录中，其已保存的 `AppConfigure` 配置值保留在 PostgreSQL 内，但不会向运行时注入任何定义、适配器、钩子或进程。

## 插件契约

插件模块实现 `Ankole.Plugins.Plugin` 行为（behaviour），其中只有一个回调是必需的：

- **`plugin_id/0`**——全局唯一的小写标识符，匹配 `~r/\A[a-z][a-z0-9_-]*\z/`。

其余回调均为可选：

- **`activation/0`**——返回 `:optional | :always`（默认 `:optional`）。`:optional` 插件受 `plugins.enabled_ids` 控制；`:always` 插件随源码构建固定启用，且拒绝禁用请求。
- **`display_name/0`**、**`description/0`**——供管理界面展示的多语言文本映射。
- **`app_config_definitions/0`**、**`app_config_patterns/0`**——插件声明的 `Ankole.AppConfigure` 键与模式定义。
- **`adapter_declarations/0`**——以原子键声明的子系统适配器列表，使用 `Ankole.Plugins.ConfigField` 描述浏览器表单字段结构。
- **`hooks/0`**——返回 `[{hook_point, module}]` 的同步领域事务钩子。钩子模块在已声明钩子点（`:create_agent`、`:create_invitation`、`:enable_signal_binding`、`:enable_identity_provider`、`:store_file`、`:commit_files`、`:create_pod_page`、`:restore_pod_page`、`:insert_base_records`、`:admit_compute`）上实现 `Ankole.Plugins.Hook.before_commit_in_tx/2`，在业务事务提交前执行校验；返回 `{:error, reason}` 会回滚调用方事务。
- **`children/0`**——交由插件运行时监督树启动的 `Supervisor.child_spec()` 列表。

`Ankole.Plugins.Spec.from_module/1` 在启动时读取上述回调并构造经过严格校验的 `Spec`。一旦出现结构错误、重复 ID 或子系统契约校验失败，应用启动会立即中止并指明责任模块。

## 子系统契约与站点级扩展点

`Ankole.Plugins.Contracts` 统一登记了全部 5 个子系统适配器契约。每个契约可定义启动校验 `validate`、快照发布 `refresh` 以及禁用拦截 `veto_disable`：

- **`signals.adapter`**——声明消息或事件适配器，由 `Ankole.Signals.Adapters` 校验，供 Signal Bindings 与 Conversations 投递使用。
- **`signals.webhook_handler`**——为 `/webhooks/v1/:handler_id/:instance_id/:kind` 入口声明 HTTP Webhook 处理器，由 `Ankole.Signals.WebhookHandlers` 校验。
- **`principals.identity_provider`**——声明企业身份源与目录同步适配器，由 `Ankole.IdentityProviders` 校验。
- **`ai_gateway.provider`**——声明模型提供商适配器，由 `Ankole.AIGateway.Providers` 校验，并通过 `refresh` 将已激活声明同步至 AI Gateway。
- **`agent_workers.provider_kind`**——声明 Agent Worker 基础设施类型（`Ankole.AgentWorkers.ProviderKind`），同时提供 `refresh`（发布已发现与已激活规格）和 `veto_disable`（`Ankole.AgentWorkers.Providers.veto_disable_in_tx/2`，当任一租户仍持有该类型的已分配 Worker 记录时拒绝禁用该插件）。

在站点构建层面，第一方扩展还通过以下编译期、站点作用域的扩展点接入：

- **`Ankole.Plugins.ConfigField`**——由插件适配器向 Console 与 Pod 表单发布强类型的配置字段契约。
- **领域事务钩子（`hooks/0`）**——在所属领域的事务与锁顺序内同步执行 `Ankole.Plugins.Hook.before_commit_in_tx/2`。
- **外层 HTTP Plug**——由构建选定的外层路由在通过 `AnkoleWeb.runtime_forward` 转发给核心路由前，执行准入验证等请求 Plug。
- **双作用域扩展 JSON:API 路由**——在站点 Host 与 Pod Host 上按独立作用域挂载 `/api/v2/*` 类型化扩展 JSON:API 路由，均通过原生 `Ankole.AuthZ.Authorizer` 鉴权。
- **强类型前端插槽（`entries.json` `overrides`）**——包装公共前端入口（`PodAppSlots`、`ConsoleAppSlots`、`AuthAppSlots`），依据 HTML 壳层注入的站点激活插件快照（`ankole-active-plugins`）及可选的 OpenFeature `when` 条件按需懒加载扩展组件。

需要在不重启进程的前提下动态调整的运行时策略开关属于 OpenFeature（`Ankole.Features`），不通过插件启停控制。

## Cohort 监督树与下次启动生效边界

在已完成初始化的站点上，可选插件对全站生效且默认关闭，由站点管理员通过 PostgreSQL 中的全局配置键 `plugins.enabled_ids` 显式启用。

修改 `plugins.enabled_ids` 只会为**下一次 Ankole 进程启动**排定目标状态，不会在运行时热插拔子进程、适配器或配置定义。在写入该配置键的同一事务内，`Ankole.Plugins.Contracts.veto_disable/2` 允许各子系统在仍有持久化资源依赖该插件时拦截禁用操作。

运行时由 `Ankole.Plugins.Cohort` 以 `:rest_for_one` 策略按顺序监督 `Ankole.Plugins.Registry` 与 `Ankole.Plugins.Supervisor`，两者共享同一份不可变的启动快照：

- `Ankole.Plugins.Registry` 在启动时解析一次启动快照，校验已激活声明，注册插件 `AppConfigure` 键，触发各子系统 `refresh`，并将快照发布到 `:persistent_term`。
- `Ankole.Plugins.Supervisor` 启动所有已激活插件的 `children/0` 子进程。
- 若 `Ankole.Plugins.Registry` 崩溃，`Ankole.Plugins.Cohort` 会基于同一份不可变的启动快照按顺序重启 `Registry` 和 `Supervisor`，确保启动后的配置修改不会在故障恢复期间改变活跃插件集合；单个插件子进程的异常则隔离在 `Ankole.Plugins.Supervisor` 内部。

## 运维 API

站点管理员通过两条 JSON:API 路由查看与配置 Control Plane Plugins：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | 列出所有已发现插件及其 `activation`、`configured_enabled`、`active` 与 `restart_required` 状态 |
| `PUT` | `/api/v2/site/control-plane-plugins` | 以 `{ "data": { "id": string, "enabled": boolean } }` 为下一次进程启动配置 `:optional` 插件 |

两条路由均在特权租户下通过 `site_console:control_plane_plugins`（`read` 与 `update` 动作）进行权限校验。

## 职责边界

Control Plane Plugins 与控制面运行在同一个 BEAM 节点和信任域内。面向模型的 Worker 工具与 Skill 不属于这里，而是由 [Agent Library](../agent-library/) 管理；控制面适配器插件与同名的 Agent Plugin 各自拥有独立的启用状态。

## 下一步

- 了解插件可声明的消息与 Webhook 适配器，请参阅 [Signals](../signals/)。
- 了解 `AppConfigure` 配置键与特性开关策略，请参阅 [AppConfigure](../app-configuration/) 与 [Console](../console-api/)。
- 了解站点管理权限模型，请参阅 [主体与 AuthZ](../principal-authz/)。
