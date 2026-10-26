---
title: 主体与 AuthZ
description: Ankole 实例的权限边界，包括主体、授权规则、权限组成员关系和运行时权限检查。
section: Developer guide
order: 106
---

Ankole 中的每个动作都有明确的主体：人员登录、Agent 运行一个回合、任务唤醒所有者。主体能做什么，由 AuthZ 在动作发生时决定。本页以 `Ankole.Principals` 和 `Ankole.AuthZ` 的实际代码为准说明这条边界。

授权是运行时事实，由系统边界强制执行，不是写给模型的一条约定。主体（Principal）是持久、可问责的身份；授权规则存储在 PostgreSQL 中。每个受检查的动作都由 Kernel 根据明确的快照求值，调用方必须服从求值结果。

## 主体：统一的问责身份

人员、Agent 和系统服务共用一种持久、可问责的主体。每个 Principal 只属于一个租户，使用全局唯一的不透明 `uid`。`principals` 记录包含 `:human`、`:agent` 或 `:system` 的 `type`、`:active` 或 `:disabled` 的 `status`，以及仅对 `:human` 生效的 `:member` 或 `:guest` 的 `membership`（`:agent` 与 `:system` 为 `nil`）。

人员主体对应一条 `HumanUser` 记录、零条或多条站点级 `SiteCredential` 记录（`principal_site_credentials`，例如已验证的邮箱验证码地址），以及零条或多条租户级 `ExternalIdentity` 记录（`principal_external_identities`，来自联邦身份源提供商）；Agent 主体对应一条 `Agent` 记录。所有主体汇聚于同一张表，使问责结构完全统一：每条审计记录、授权规则和权限组成员关系都指向同一个稳定的 Principal `uid`。

人员的 `membership` 控制租户内协作边界：内部 `member` 会自动加入计算式 `all_humans` 组；外部 `guest` 需要显式的 Pod 页面共享或 Agent 授权，不能加入内置管理员组（`siteadmin` 或 `pod_admin`），不能使用个人空间（Private space），也不会获得 Brain 的 `world` 范围。

被停用的主体不是“部分可用”。Kernel 会为它返回 `principal_disabled`，所以停用一个主体会在整个实例内撤销它的权限，不必逐条删除每一份授权。

## grant：谁能做什么

`permission_grants` 中的每条记录必须且只能拥有以下三类受让人所有者之一（`num_nonnulls(principal_uid, group_id, source_page_id) = 1`，由 `Ankole.AuthZ.Validations.GrantShape` 与 PostgreSQL Check 约束共同保证）：

- 单个主体（`principal_uid`）；
- 单个权限组（`group_id`）；
- **Pod 页面 Userset**（`source_page_id` 搭配精确的 `source_action`：`page_view`、`page_write_records`、`page_edit` 或 `page_manage`）。

Pod ACL 授权还会存储 `target_page_id` 与 `target_scope`（`container` 作用于继承子树，`self` 仅作用于目标页面本身）。每条授权规则包含：

- `resource_pattern`——由 `Input.validate_resource_pattern_syntax` 校验，覆盖统一的冒号分隔命名空间：`site_console:**`（站点控制台）、`tenant_console:**`（Pod 管理）、`agent:<uid>` 与 `agent:<uid>:tool:<fn>`（运行时 Agent 与工具调用），以及 `pod:**`（`pod:space:**`、`pod:private:<uid>:**`、`pod:**:<page-id>:**`、`pod:**:<page-id>:page`）。不允许使用裸 `"**"` 模式；
- `action`——精确动作字符串，不允许包含冒号；
- `condition`——CEL 布尔表达式，默认 `"true"`，由 `Input.validate_condition_syntax` 校验；
- `description` 与 `metadata`，供运维人员阅读。

主体、权限组和 Userset 授权分别由各自的部分唯一索引保证自然键（`owner + resource_pattern + action + condition`）唯一。创建、Upsert 和更新授权规则均由控制面执行，数据库会拒绝无效的所有者结构或畸形规则。

## group：静态与计算式成员

权限组是一组具名主体，通过组授权可以避免为每个主体逐条创建记录。权限组包含 `domain`（`:operator`、`:directory`、`:im_group` 或 `:signal_source`）、`kind`（`:static` 或 `:computed`），以及动态组使用的 CEL `computed_condition`。

每个租户都包含内置动态组 `all_humans`（条件为 `principal.type == "human" && principal.membership == "member" && principal.status == "active"`）以及内置静态组 `pod_admin`（授予该 Pod 内的 `tenant_console:**` 操作权限）。特权站点租户还包含内置静态组 `siteadmin`（授予 `site_console:**` 与 `tenant_console:**`）。只有启用状态的内部人类成员（`member`）才能加入 `siteadmin` 或 `pod_admin`。在站点控制台切换数据租户不会改变操作者身份或其 `siteadmin` 权限查找。静态成员关系保存在 `principal_group_memberships` 中；计算成员关系基于授权快照求值。外部目录与 IM 群组通过 `principal_group_external_bindings` 同步。

## 一个决定是如何做出的

控制面与 Kernel 分工明确，使 AuthZ 成为强制边界而非提示建议：

- **控制面负责持久状态、Ash 授权执行与快照组装。** 受保护的 Ash 动作通过 `Ankole.AuthZ.Extension` 声明编译期规则，并由 `Ankole.AuthZ.Authorizer` 在运行时基于 `%Ankole.AuthZ.Actor{principal, interactive_principal, turn_authority, authn, interactive_authn}` 强制执行。经过验证的浏览器、OIDC 和 Worker 认证事实会写入 `context.request.authn` 供 CEL 条件读取。当存在 `interactive_principal`（例如由人类触发的 Agent 回合）时，Agent 与人类必须同时通过检查（`Human ∩ Agent`）。
- **Kernel 与 PostgreSQL 负责确定性规则求值。** 对于常规检查，`Ankole.AuthZ.Snapshot` 用单条 SQL 加载主体、组成员关系和候选授权，Rust Kernel 对资源模式、动态组和 CEL 条件求值。对于 Pod 页面，4 位 ACL 锚点图（`page_view=1`、`page_write_records=2`、`page_edit=4`、`page_manage=8`；角色掩码 `view=1`、`contribute=3`、`edit=7`、`manage=15`）先在 Rust Kernel 中求值一次与请求相关的 CEL 条件，再由 PostgreSQL 通过 `WITH RECURSIVE`（`UNION` 最小不动点）合并直接授权、权限组、容器继承和 Userset 边。

`Ankole.AuthZ` 的公开入口包括：`authorize(subject, resource, action, context)`、返回布尔值的 `allowed?/4`、返回单动作完整决策 Map 的 `authorize_decision/4`、对同一资源的动作列表批量求值的 `authorize_all_decision/4`、基于单次快照执行多组独立资源/动作检查的 `authorize_checks/3`，以及用于 Pod 上下文求值的 `evaluate_pod_context/2`。所有入口均不信任调用方对主体权限的自述。

## 决定状态

一个决定以四种状态之一返回，每种状态都对应调用方的义务：

- **`allow`**——动作被允许；继续执行。
- **`deny`**——动作被禁止，并指明 `deniedAction`。调用方不得执行。
- **`principal_disabled`**——主体已停用，按带具体原因的拒绝处理。
- **`invalid_request`**——请求本身格式无效，调用方应修正请求而非盲目重试。

每次求值都会发出诊断信息，使拒绝可观测。`Ankole.AuthZ.Decision.result/1` 将决策 Map 转换为 `:ok | {:error, reason}` 供调用方分支处理。

## 强制实际发生在哪里

AuthZ 不是 Agent 能绕开的一层，因为运行时会在所有关键边界执行检查：

- AIGateway 从经验证的 token 解析每次调用的主体，由该主体的授权决定可访问的模型选择符与提供方。
- 工具准备与派发阶段对 `agent:<uid>:tool:<fn>`（动作 `invoke` 及规范化后的 `context.request.args`）求值，并在人类触发的回合中对 Pod 操作取 `Human ∩ Agent` 权限交集。
- 会话 Driver 在提交前检查持久栅栏；Worker 的 Job 操作检查持久 Job attempt 栅栏与已认证连接身份。
- 站点控制台（`/api/v2`）与 Pod 管理（`/api/v2/pod/admin`）操作要求经验证的浏览器凭证、CSRF 保护以及当前有效的 `site_console:**` 或 `tenant_console:**` 授权。

模型无法自行宣称“我有权限”。系统边界核对主体与授权规则，并严格执行求值结果。

## 运维界面

`/api/v2` 下的站点控制台 JSON:API 路由暴露主体、权限组和授权管理（`site_console:**`），而 Pod 管理员通过 `/api/v2/pod/admin/*` 管理本租户成员、邀请、设置和身份提供方（`tenant_console:**`）：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/principals` | 列出主体 |
| `POST` | `/api/v2/principals` | 预创建人类内部成员主体 |
| `GET` | `/api/v2/principals/:uid` | 读取单个主体 |
| `PATCH` | `/api/v2/principals/:uid` | 更新人类主体资料（`display_name`） |
| `PATCH` | `/api/v2/principals/:uid/membership` | 修改人类主体的 `membership`（`member` 或 `guest`） |
| `GET` | `/api/v2/principals/:uid/access` | 查看人类访问状态、限制项与恢复审查投影 |
| `POST` | `/api/v2/principals/:uid/access-disables` | 暂停（`suspended`）或离职解绑（`offboarded`）人类主体 |
| `POST` | `/api/v2/principals/:uid/access-restorations` | 清除限制项后恢复已停用的人类主体 |
| `GET` | `/api/v2/principals/:uid/groups` | 列出主体所属的权限组 |
| `GET` | `/api/v2/principals/:uid/grants` | 列出主体的授权规则 |
| `GET` | `/api/v2/principal-groups` | 列出权限组 |
| `POST` | `/api/v2/principal-groups` | 创建运维权限组 |
| `GET` | `/api/v2/principal-groups/:name` | 读取单个权限组 |
| `PATCH` | `/api/v2/principal-groups/:name` | 更新权限组 |
| `DELETE` | `/api/v2/principal-groups/:name` | 删除运维权限组 |
| `POST` | `/api/v2/principal-groups/computed-member-previews` | 预览计算式权限组的匹配成员 |
| `POST` | `/api/v2/permission-grants` | 创建运维授权规则（通过 `/api/v2/permission-grants/:id` 执行 `PATCH`/`DELETE`） |

授权与成员管理统一经过 `Ankole.AuthZ`，在写入前校验所有者结构、资源模式语法和 CEL 条件语法；PostgreSQL 的 Check 约束与部分唯一索引在存储层强制相同的不变量。

## 主体和 AuthZ 不是什么

AuthZ 不是 Prompt 指令，也不是对模型的期望。它核对主体并强制执行求值结果。主体不是用来在一个实例内划分企业边界的临时字段，也不是按请求分配的角色；它是稳定、可问责的身份，可以被授权、分组和求值。Kernel 也不是第二套策略引擎，只对控制面组装的快照执行确定性求值。控制面管理状态，Kernel 负责求值，调用方必须执行结果。

## 下一步

- 经过验证的 Token 怎样在 AIGateway 边缘解析成主体，见 [AIGateway API](../ai-gateway/)。
- Agent 主体的 Driver fence 怎样为一个回合设置隔离栏，见 [Sessions](../sessions/)。
