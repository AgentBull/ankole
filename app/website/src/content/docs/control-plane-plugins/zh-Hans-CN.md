---
title: Control Plane Plugins
description: 控制面第一方 Elixir 扩展模型：激活生命周期、子系统适配器契约、同步事务钩子、Cohort 监督树与重启生效边界。
section: Developer guide
order: 110
---

Control Plane Plugins 用于通过受信任的第一方 Elixir/OTP 代码扩展 Ankole 站点能力。插件模块可通过 `Ankole.Plugins` 注册 `AppConfigure` 系统配置键、声明各子系统适配器、挂载同步领域事务钩子，并启动受监督的常驻后台子进程。

从交付形态上看，Control Plane Plugins 是编译期直接打包进控制面发布镜像的第一方 Elixir 模块（`:control_plane_plugin_modules`），并非在运行期从外部下载或放在沙箱中隔离运行的第三方插件市场。系统在每次进程启动时自动扫描并严格校验这些模块：其中声明为 `:optional` 的可选插件由站点级启用列表控制，在下一次进程启动时激活；而声明了 `activation: :always` 的核心内置插件只要随当前版本编译进镜像，便始终保持激活。

## 已发现与已激活

运行时将插件区分成两个明确阶段：

- **已发现（Discovered）**：已编译进当前发布包、且顺利通过启动期结构校验的全部插件模块。站点管理员可在 Site Admin Console 中浏览完整的插件目录。
- **已激活（Active）**：`activation/0` 返回 `:always` 的常驻插件，或者 `activation/0` 返回 `:optional` 且已被列入全局配置 `plugins.enabled_ids` 的可选插件（注：在站点首次初始化 `setup.completed` 完成之前，所有已发现插件均处于临时激活状态以供初始化向导使用）。只有处于“已激活”状态的插件，才会真正注册 `AppConfigure` 配置定义、对外暴露子系统适配器与领域事务钩子，并拉起旗下的受监督子进程。

对于“已发现但未激活”的插件，它依然会展示在管理台插件列表中，此前在 PostgreSQL 中保存过的 `AppConfigure` 配置值也会原样保留，但不会向当前运行时注入任何配置定义、适配器、钩子或工作进程。

## 插件契约

每个插件模块均需实现 `Ankole.Plugins.Plugin` 行为（behaviour），其中仅有一个必填回调：

- **`plugin_id/0`**：全局唯一的小写字符串标识符，必须匹配正则 `~r/\A[a-z][a-z0-9_-]*\z/`。

其余回调均可按需选配实现：

- **`activation/0`**：返回 `:optional | :always`（默认为 `:optional`）。`:optional` 插件受 `plugins.enabled_ids` 开关控制；`:always` 插件随构建常驻启用，并直接拒绝任何禁用请求。
- **`display_name/0`**、**`description/0`**：供管理控制台展示的多语言标题与简介映射。
- **`app_config_definitions/0`**、**`app_config_patterns/0`**：声明由该插件管理的 `Ankole.AppConfigure` 静态键与动态键模式定义。
- **`adapter_declarations/0`**：以原子键分组声明各子系统适配器列表，并使用 `Ankole.Plugins.ConfigField` 描述浏览器端配置表单的字段结构。
- **`hooks/0`**：返回形如 `[{hook_point, module}]` 的同步领域事务钩子列表。钩子模块针对已开放的钩子挂载点（`:create_agent`、`:create_invitation`、`:enable_signal_binding`、`:enable_identity_provider`、`:store_file`、`:commit_files`、`:create_pod_page`、`:restore_pod_page`、`:insert_base_records`、`:admit_compute`）实现 `Ankole.Plugins.Hook.before_commit_in_tx/2` 回调，在宿主业务事务正式提交前同步执行校验；一旦返回 `{:error, reason}`，整个调用方业务事务便会立即回滚。
- **`children/0`**：返回交由插件运行时监督树统一拉起和监管的 `Supervisor.child_spec()` 列表。

控制面启动期间，`Ankole.Plugins.Spec.from_module/1` 会读取上述全部回调并构造出经过严格校验的 `Spec` 结构体。一旦检测到字段结构有误、插件 ID 重复或违背任一子系统契约，应用启动流程会当即中止报错，并明确指出问题所在的模块名。

## 子系统契约与站点级扩展点

`Ankole.Plugins.Contracts` 集中登记了全部 5 类子系统适配器契约，每类契约均可定义启动期静态校验（`validate`）、运行时快照刷新（`refresh`）以及停用前安全拦截（`veto_disable`）：

- **`signals.adapter`**：声明外部消息渠道或事件源适配器，由 `Ankole.Signals.Adapters` 校验，供信号路由规则（Signal Bindings）与 Conversations 消息投递调用。
- **`signals.webhook_handler`**：为 `/webhooks/v1/:handler_id/:instance_id/:kind` 入口注册 HTTP Webhook 接收处理器，由 `Ankole.Signals.WebhookHandlers` 校验。
- **`principals.identity_provider`**：声明企业身份源（IdP）单点登录与通讯录同步适配器，由 `Ankole.IdentityProviders` 校验。
- **`ai_gateway.provider`**：声明上游模型提供商适配器，由 `Ankole.AIGateway.Providers` 校验，并通过 `refresh` 将已激活的 Provider 定义同步至 AI Gateway 注册表。
- **`agent_workers.provider_kind`**：声明底层 Agent Worker 计算平台类型（`Ankole.AgentWorkers.ProviderKind`），同时实现 `refresh`（发布已发现与已激活的平台规格）和 `veto_disable`（调用 `Ankole.AgentWorkers.Providers.veto_disable_in_tx/2`：只要任一租户名下仍存在绑定了该平台类型的 Worker 记录，便直接拦截插件禁用请求）。

在此之外，第一方站点级构建还可通过以下编译期扩展点深度定制产品面：

- **`Ankole.Plugins.ConfigField`**：由插件适配器向 Console 与 Pod 配置页面输出强类型的动态表单字段定义。
- **同步领域事务钩子（`hooks/0`）**：严格在宿主领域的数据库事务与全局锁顺序内部同步执行 `Ankole.Plugins.Hook.before_commit_in_tx/2`。
- **外层 HTTP Plug**：构建选定的外层路由器可在调用 `AnkoleWeb.runtime_forward` 将请求转入核心路由器之前，先行执行自定义准入校验等外层请求 Plug。
- **双作用域扩展 JSON:API 路由**：支持在站点管理域名（Site Host）与工作区域名（Pod Host）上按各自独立的作用域挂载 `/api/v2/*` 强类型扩展 JSON:API 路由，统一走原生的 `Ankole.AuthZ.Authorizer` 权限体系鉴权。
- **强类型前端 UI 插槽（`entries.json` `overrides`）**：支持在外层包裹公共前端应用入口（`PodAppSlots`、`ConsoleAppSlots`、`AuthAppSlots`），根据 HTML 壳层下发的当前站点激活插件快照（`ankole-active-plugins`）及可选的 OpenFeature `when` 条件按需懒加载扩展界面组件。

需要说明的是：凡是要求在运行期间不重启进程即可实时切换的策略与灰度开关，均归属 OpenFeature（`Ankole.Features`）管理，不应做成插件启停开关。

## Cohort 监督树与下次启动生效边界

站点完成首次初始化后，所有 `:optional` 可选插件均作用于全站范围且默认处于关闭状态，须由站点管理员通过 PostgreSQL 中的站点级配置键 `plugins.enabled_ids` 显式开启。

修改 `plugins.enabled_ids` 仅会排定**下一次 Ankole 控制面进程启动时**的目标插件集合，绝不会在当前运行进程中动态热加载或热卸载子进程、适配器与配置项定义。在写入该配置键的同一个数据库事务内，系统会调用 `Ankole.Plugins.Contracts.veto_disable/2` 让各子系统检查依赖关系：只要仍有持久化业务资源依赖某个插件，禁用请求就会被当场拦截报错。

在进程运行期间，`Ankole.Plugins.Cohort` 采用 `:rest_for_one` 监督策略，按先后顺序监管 `Ankole.Plugins.Registry` 与 `Ankole.Plugins.Supervisor`，确保二者始终对齐同一份不可变的进程启动快照：

- `Ankole.Plugins.Registry` 在进程启动时一次性解析当时的启用快照，完成激活契约校验、注册插件专属的 `AppConfigure` 配置键、触发各子系统的 `refresh` 回调，并将只读快照发布至 `:persistent_term`。
- `Ankole.Plugins.Supervisor` 随后统一拉起所有已激活插件在 `children/0` 中声明的后台子进程。
- 一旦 `Ankole.Plugins.Registry` 意外崩溃，`Ankole.Plugins.Cohort` 会基于**最初那份不可变的启动快照**依次重启 `Registry` 与 `Supervisor`，从而保证启动后管理员在数据库中暂存的待生效变更绝不会在故障自愈中途意外混入当前运行态；而单个插件自有子进程的异常则被隔离在 `Ankole.Plugins.Supervisor` 内部局部恢复。

## 运维 API

站点管理员可通过以下两条 JSON:API 路由查询与切换 Control Plane Plugins：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | 列出全部已发现插件及其 `activation`、`configured_enabled`、`active` 与 `restart_required` 状态 |
| `PUT` | `/api/v2/site/control-plane-plugins` | 传入 `{ "data": { "id": string, "enabled": boolean } }`，排定某个 `:optional` 插件在下一次进程启动时的启用状态 |

这两条路由均在特权租户上下文下通过 `site_console:control_plane_plugins` 资源权限（分别校验 `read` 与 `update` 动作）执行鉴权。

## 职责边界

Control Plane Plugins 与控制面核心代码运行在同一个 BEAM 虚拟机节点与安全信任域内。面向大模型暴露的 Worker 电脑工具与操作技能（Skill）不属于控制面插件范畴，而是由 [Agent Library](../agent-library/) 独立管理；即使某个控制面适配器插件与某个 Agent Plugin 恰好同名，二者的启用状态也完全彼此独立。

## 下一步

- 了解插件可扩展的消息渠道与 Webhook 适配器契约，请参阅 [Signals](../signals/)。
- 了解 `AppConfigure` 系统配置键与特性开关管理，请参阅 [系统配置](../app-configuration/) 与 [Console API 参考](../console-api/)。
- 了解站点级管理操作的权限判定模型，请参阅 [主体与 AuthZ](../principal-authz/)。
